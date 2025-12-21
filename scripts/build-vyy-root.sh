#!/bin/bash
# Build vyy root filesystem
# Run inside build container (see dev.sh)

set -euo pipefail

ROOT="${1:-/vyy-root}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(dirname "$SCRIPT_DIR")/config"

echo "=== vyy build ==="

# -----------------------------------------------------------------------------
# 1. Prepare target directory
# -----------------------------------------------------------------------------
echo ">>> Preparing target directory..."
mkdir -p "$ROOT"

# -----------------------------------------------------------------------------
# 2. Setup repositories
# -----------------------------------------------------------------------------
echo ">>> Setting up repositories..."

mkdir -p "$ROOT/etc/pacman.d"

# Set up reliable European Arch mirrors on HOST
cat > /etc/pacman.d/mirrorlist << 'EOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.leaseweb.net/archlinux/$repo/os/$arch
Server = https://ftp.fau.de/archlinux/$repo/os/$arch
Server = https://mirror.netcologne.de/archlinux/$repo/os/$arch
EOF

# Ensure mirrorlists exist
if [[ ! -f /etc/pacman.d/cachyos-mirrorlist ]]; then
    echo "  Creating cachyos-mirrorlist..."
    cat > /etc/pacman.d/cachyos-mirrorlist << 'EOF'
Server = https://mirror.cachyos.org/repo/$arch/$repo
Server = https://de-1.cachyos.org/repo/$arch/$repo
Server = https://de-2.cachyos.org/repo/$arch/$repo
EOF
fi

if [[ ! -f /etc/pacman.d/cachyos-v4-mirrorlist ]]; then
    echo "  Creating cachyos-v4-mirrorlist..."
    cat > /etc/pacman.d/cachyos-v4-mirrorlist << 'EOF'
Server = https://mirror.cachyos.org/repo/$arch_v4/$repo
Server = https://de-1.cachyos.org/repo/$arch_v4/$repo
Server = https://de-2.cachyos.org/repo/$arch_v4/$repo
EOF
fi

# Copy mirrorlists to target
cp /etc/pacman.d/mirrorlist "$ROOT/etc/pacman.d/"
cp /etc/pacman.d/cachyos-mirrorlist "$ROOT/etc/pacman.d/"
cp /etc/pacman.d/cachyos-v4-mirrorlist "$ROOT/etc/pacman.d/"

# Install our pacman.conf on HOST (for pacstrap) and target
cp "$CONFIG_DIR/pacman.conf" /etc/pacman.conf
cp "$CONFIG_DIR/pacman.conf" "$ROOT/etc/pacman.conf"

# -----------------------------------------------------------------------------
# 3. Bootstrap with pacman -r (no user namespaces needed)
# -----------------------------------------------------------------------------
echo ">>> Installing packages with pacman..."

# Create essential directories
mkdir -p "$ROOT"/{var/lib/pacman,var/cache/pacman/pkg,etc}

# Retry wrapper for flaky mirrors
retry() {
    local max_attempts=5
    local attempt=1
    local delay=5
    while [[ $attempt -le $max_attempts ]]; do
        echo "  Attempt $attempt/$max_attempts..."
        if "$@"; then
            return 0
        fi
        echo "  Failed, retrying in ${delay}s..."
        sleep $delay
        ((attempt++))
        ((delay *= 2))
    done
    echo "  All 5 attempts failed"
    return 1
}

# Force refresh package databases
retry pacman -Syy

# Read packages from file, filter comments and empty lines
PACKAGES=$(grep -v '^#' "$CONFIG_DIR/packages.txt" | grep -v '^$' | tr '\n' ' ')

# Install packages to target root (no chroot, no user namespaces)
retry pacman -r "$ROOT" -Sy --noconfirm --needed $PACKAGES

# -----------------------------------------------------------------------------
# 4. Setup package signing keys
# -----------------------------------------------------------------------------
echo ">>> Setting up signing keys..."

# Copy the keyring
cp -a /etc/pacman.d/gnupg "$ROOT/etc/pacman.d/" 2>/dev/null || true

# Also ensure cachyos-keyring package is properly installed
arch-chroot "$ROOT" pacman-key --init 2>/dev/null || true
arch-chroot "$ROOT" pacman-key --populate archlinux cachyos 2>/dev/null || true

# -----------------------------------------------------------------------------
# 5. Install AUR packages (build if missing/outdated)
# -----------------------------------------------------------------------------
echo ">>> Installing AUR packages..."

AUR_CACHE="${VYY_AUR_CACHE:-$(dirname "$SCRIPT_DIR")/.aur-cache}"
AUR_PACKAGES_FILE="$CONFIG_DIR/aur-packages.txt"
AUR_BUILD_DIR="$AUR_CACHE/build"

mkdir -p "$AUR_CACHE"
mkdir -p "$AUR_BUILD_DIR"

get_aur_version() {
    curl -s "https://aur.archlinux.org/rpc/?v=5&type=info&arg=$1" | \
        grep -o '"Version":"[^"]*"' | cut -d'"' -f4
}

get_cached_version() {
    local version_file="$AUR_CACHE/${1}.version"
    [[ -f "$version_file" ]] && cat "$version_file" || echo ""
}

build_aur_package() {
    local pkg="$1"
    local aur_ver="$2"
    local pkg_dir="$AUR_BUILD_DIR/$pkg"

    echo "  Building $pkg..."
    rm -rf "$pkg_dir"
    git clone --depth 1 "https://aur.archlinux.org/${pkg}.git" "$pkg_dir"

    # Install makedepends
    (
        source "$pkg_dir/PKGBUILD"
        if [[ -n "${makedepends[*]:-}" ]]; then
            pacman -S --noconfirm --needed "${makedepends[@]}" 2>/dev/null || true
        fi
    )

    # Build as builder user
    chown -R builder:builder "$pkg_dir"

    # Extract sources first
    su builder -c "cd '$pkg_dir' && makepkg --noconfirm --skippgpcheck --nobuild -s" || true

    # Init git in source dirs (some packages check git toplevel)
    for d in "$pkg_dir"/src/*/; do
        if [[ -d "$d" && ! -d "$d/.git" ]]; then
            su builder -c "cd '$d' && git init && git add -A && git commit -m init" 2>/dev/null || true
        fi
    done

    # Continue build
    chown -R builder:builder "$pkg_dir"
    su builder -c "cd '$pkg_dir' && makepkg --noconfirm --skippgpcheck -e"

    # Cache the package
    local pkg_file
    pkg_file=$(ls "$pkg_dir"/*.pkg.tar.zst 2>/dev/null | head -1)
    if [[ -n "$pkg_file" ]]; then
        rm -f "$AUR_CACHE/${pkg}"-*.pkg.tar.zst
        cp "$pkg_file" "$AUR_CACHE/"
        echo "$aur_ver" > "$AUR_CACHE/${pkg}.version"
        echo "  Cached: $(basename "$pkg_file")"
    else
        echo "  ERROR: Build failed for $pkg"
        return 1
    fi

    rm -rf "$pkg_dir"
}

install_aur_package() {
    local pkg="$1"

    # Check versions
    local aur_ver cached_ver
    aur_ver=$(get_aur_version "$pkg")
    cached_ver=$(get_cached_version "$pkg")

    if [[ -z "$aur_ver" ]]; then
        echo "  WARNING: $pkg not found in AUR"
        return 1
    fi

    echo "  $pkg: AUR=$aur_ver, cached=${cached_ver:-none}"

    # Build if missing or outdated
    if [[ -z "$cached_ver" ]] || [[ "$aur_ver" != "$cached_ver" ]]; then
        build_aur_package "$pkg" "$aur_ver"
    fi

    # Install from cache
    local cached_pkg
    cached_pkg=$(ls "$AUR_CACHE"/${pkg}-*.pkg.tar.zst 2>/dev/null | head -1)
    if [[ -n "$cached_pkg" ]]; then
        echo "  Installing $pkg..."
        pacman -r "$ROOT" -U --noconfirm "$cached_pkg"
    else
        echo "  ERROR: $pkg not found in cache after build"
        return 1
    fi
}

# Install each AUR package from config
if [[ -f "$AUR_PACKAGES_FILE" ]]; then
    while IFS= read -r pkg || [[ -n "$pkg" ]]; do
        [[ "$pkg" =~ ^#.*$ || -z "$pkg" ]] && continue
        install_aur_package "$pkg"
    done < "$AUR_PACKAGES_FILE"
else
    echo "  No AUR packages file found at $AUR_PACKAGES_FILE"
fi

rm -rf "$AUR_BUILD_DIR"

# -----------------------------------------------------------------------------
# 6. Basic configuration
# -----------------------------------------------------------------------------
echo ">>> Configuring system..."

# Locale
echo "en_GB.UTF-8 UTF-8" > "$ROOT/etc/locale.gen"
arch-chroot "$ROOT" locale-gen
echo "LANG=en_GB.UTF-8" > "$ROOT/etc/locale.conf"

# Timezone (can be changed by user later)
ln -sf /usr/share/zoneinfo/UTC "$ROOT/etc/localtime"

# Hostname
echo "vyy" > "$ROOT/etc/hostname"

# -----------------------------------------------------------------------------
# 7. Restructure for OSTree (includes initramfs generation)
# -----------------------------------------------------------------------------
echo ">>> Restructuring for OSTree..."
"$SCRIPT_DIR/restructure.sh" "$ROOT"

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo "=== Build complete ==="
du -sh "$ROOT"
