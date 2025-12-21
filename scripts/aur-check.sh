#!/bin/bash
# Check AUR for package updates and build if newer
# Caches built packages locally in $AUR_CACHE

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$ROOT_DIR/config"
BUILD_DIR="/tmp/aur-build"
AUR_CACHE="${VYY_AUR_CACHE:-$ROOT_DIR/.aur-cache}"

echo "=== AUR Package Update Check ==="
echo "Cache: $AUR_CACHE"
echo ""

mkdir -p "$AUR_CACHE"

get_aur_version() {
    local pkg="$1"
    curl -s "https://aur.archlinux.org/rpc/?v=5&type=info&arg=$pkg" | \
        jq -r '.results[0].Version // empty'
}

get_cached_version() {
    local pkg="$1"
    local version_file="$AUR_CACHE/${pkg}.version"
    if [[ -f "$version_file" ]]; then
        cat "$version_file"
    else
        echo ""
    fi
}

build_aur_package() {
    local pkg="$1"
    local aur_ver="$2"
    local aur_url="https://aur.archlinux.org/${pkg}.git"
    local pkg_dir="$BUILD_DIR/$pkg"

    echo "  Building $pkg..."
    rm -rf "$pkg_dir"
    git clone "$aur_url" "$pkg_dir"

    # Build in container
    podman run --rm \
        -v "$pkg_dir:/build" \
        -w /build \
        archlinux:latest \
        bash -c '
            set -e
            pacman -Sy --noconfirm base-devel git ostree rust cargo

            useradd -m builder
            chown -R builder:builder /build

            source /build/PKGBUILD
            if [[ -n "${makedepends[*]:-}" ]]; then
                pacman -S --noconfirm --needed "${makedepends[@]}" || true
            fi
            if [[ -n "${depends[*]:-}" ]]; then
                pacman -S --noconfirm --needed "${depends[@]}" || true
            fi

            # Extract sources, init git in src dirs for packages that check git toplevel
            su builder -c "cd /build && makepkg --noconfirm --skippgpcheck --skipinteg --nobuild" || true
            for d in /build/src/*/; do
                if [[ -d "$d" && ! -d "$d/.git" ]]; then
                    su builder -c "cd \"$d\" && git init && git add -A && git commit -m init" 2>/dev/null || true
                fi
            done

            su builder -c "cd /build && makepkg --noconfirm --skippgpcheck --skipinteg -e"
        '

    # Find and cache the package
    local pkg_file
    pkg_file=$(ls "$pkg_dir"/*.pkg.tar.zst 2>/dev/null | head -1)

    if [[ -n "$pkg_file" ]]; then
        # Remove old cached package
        rm -f "$AUR_CACHE/${pkg}"-*.pkg.tar.zst
        # Copy new package
        cp "$pkg_file" "$AUR_CACHE/"
        # Update version file
        echo "$aur_ver" > "$AUR_CACHE/${pkg}.version"
        echo "  Cached: $(basename "$pkg_file")"
    else
        echo "  ERROR: Build failed for $pkg"
        return 1
    fi

    rm -rf "$pkg_dir"
}

while IFS= read -r pkg || [[ -n "$pkg" ]]; do
    [[ "$pkg" =~ ^#.*$ || -z "$pkg" ]] && continue

    echo "Checking $pkg..."

    aur_ver=$(get_aur_version "$pkg")
    cached_ver=$(get_cached_version "$pkg")

    if [[ -z "$aur_ver" ]]; then
        echo "  WARNING: Package not found in AUR"
        continue
    fi

    echo "  AUR version: $aur_ver"
    echo "  Cached version: ${cached_ver:-none}"

    if [[ -z "$cached_ver" ]] || [[ "$aur_ver" != "$cached_ver" ]]; then
        echo "  Update available, building..."
        build_aur_package "$pkg" "$aur_ver"
    else
        echo "  Up to date"
    fi

    echo ""
done < "$CONFIG_DIR/aur-packages.txt"

rm -rf "$BUILD_DIR"

echo "=== AUR check complete ==="
