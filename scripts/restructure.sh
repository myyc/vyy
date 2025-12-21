#!/bin/bash
# restructure.sh - Transform Arch layout into OSTree-compatible structure
# Run this AFTER build-vyy-root.sh, BEFORE ostree commit

set -euo pipefail

ROOT="${1:-/vyy-root}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(dirname "$SCRIPT_DIR")/config"

if [[ ! -d "$ROOT/usr" ]]; then
    echo "Error: $ROOT/usr not found. Is this a valid build root?"
    exit 1
fi

echo "=== Restructuring $ROOT for OSTree ==="

# -----------------------------------------------------------------------------
# 1. VERIFY MERGED-USR
# -----------------------------------------------------------------------------
echo ">>> Verifying merged-usr layout..."

# Arch should already have merged-usr, but verify
for dir in bin sbin lib lib64; do
    if [[ -d "$ROOT/$dir" && ! -L "$ROOT/$dir" ]]; then
        echo "Warning: /$dir is a directory, not a symlink. Fixing..."
        if [[ -d "$ROOT/usr/$dir" ]]; then
            cp -a "$ROOT/$dir"/* "$ROOT/usr/$dir"/ 2>/dev/null || true
        else
            mv "$ROOT/$dir" "$ROOT/usr/$dir"
        fi
        rm -rf "$ROOT/$dir"
        ln -sf "usr/$dir" "$ROOT/$dir"
    fi
done

# -----------------------------------------------------------------------------
# 2. MOVE /etc TO /usr/etc
# -----------------------------------------------------------------------------
echo ">>> Moving /etc to /usr/etc..."

mkdir -p "$ROOT/usr/etc"
if [[ -d "$ROOT/etc" ]]; then
    # Copy everything from /etc to /usr/etc
    cp -a "$ROOT/etc/." "$ROOT/usr/etc/" 2>/dev/null || true
    rm -rf "$ROOT/etc"
fi
mkdir -p "$ROOT/etc"

# Create minimal gshadow - sysusers will add entries at boot
# (pacstrap's gshadow has entries that conflict with sysusers.d)
echo "root:::" > "$ROOT/usr/etc/gshadow"
chmod 640 "$ROOT/usr/etc/gshadow"

# -----------------------------------------------------------------------------
# 3. OSTREE FILESYSTEM STRUCTURE
# -----------------------------------------------------------------------------
echo ">>> Setting up OSTree filesystem structure..."

# Create required directories
mkdir -p "$ROOT/sysroot"
mkdir -p "$ROOT/var"

# /ostree MUST be a symlink to sysroot/ostree (critical for boot!)
rm -rf "$ROOT/ostree"
ln -sf sysroot/ostree "$ROOT/ostree"

# Root-level symlinks for OSTree
rm -rf "$ROOT/home" "$ROOT/root" "$ROOT/mnt" "$ROOT/opt" "$ROOT/srv" "$ROOT/media"
ln -sf var/home "$ROOT/home"
ln -sf var/roothome "$ROOT/root"
ln -sf var/mnt "$ROOT/mnt"
ln -sf /var/opt "$ROOT/opt"
ln -sf var/srv "$ROOT/srv"
ln -sf run/media "$ROOT/media"

# Ensure tmp exists
mkdir -p "$ROOT/tmp"
chmod 1777 "$ROOT/tmp"

# Create /var directories needed by services
mkdir -p "$ROOT/var/lib/polkit-1"
chown 102:102 "$ROOT/var/lib/polkit-1" 2>/dev/null || true

# /usr/local -> /var/usrlocal (user additions persist)
rm -rf "$ROOT/usr/local"
mkdir -p "$ROOT/var/usrlocal"
ln -sf ../var/usrlocal "$ROOT/usr/local"

# -----------------------------------------------------------------------------
# 4. OS-RELEASE
# -----------------------------------------------------------------------------
echo ">>> Creating os-release..."

VERSION_DATE="${VYY_VERSION:-$(date +%Y%m%d)}"

sed "s/@VERSION_DATE@/${VERSION_DATE}/g" \
    "$CONFIG_DIR/base-files/os-release.template" > "$ROOT/usr/lib/os-release"

ln -sf ../lib/os-release "$ROOT/usr/etc/os-release" 2>/dev/null || true

# Marker file for scripts to detect vyy
touch "$ROOT/usr/etc/vyy-release"

# Kernel cmdline (used by ostree for boot entries)
mkdir -p "$ROOT/usr/lib/kernel"
cat > "$ROOT/usr/lib/kernel/cmdline" << 'EOF'
lsm=landlock,lockdown,yama,integrity,apparmor,bpf
EOF

# -----------------------------------------------------------------------------
# 5. SYSTEM USERS/GROUPS
# -----------------------------------------------------------------------------
echo ">>> Setting up system users/groups..."

# Packages ship their own /usr/lib/sysusers.d/*.conf files
# systemd-sysusers creates users at boot from these configs
echo "  Using package-provided sysusers.d configs (systemd-sysusers at boot)"

# -----------------------------------------------------------------------------
# 6. PAM CONFIG (fingerprint support)
# -----------------------------------------------------------------------------
echo ">>> Configuring PAM..."

if [[ -d "$CONFIG_DIR/base-files/pam.d" ]]; then
    mkdir -p "$ROOT/usr/etc/pam.d"
    cp -a "$CONFIG_DIR/base-files/pam.d/"* "$ROOT/usr/etc/pam.d/"
    echo "  Installed pam.d configs with fingerprint support"
fi

# nsswitch.conf - needs 'systemd' for DynamicUser lookups (GDM greeter)
if [[ -f "$CONFIG_DIR/base-files/nsswitch.conf" ]]; then
    cp "$CONFIG_DIR/base-files/nsswitch.conf" "$ROOT/usr/etc/nsswitch.conf"
    echo "  Installed nsswitch.conf with systemd NSS support"
fi

# -----------------------------------------------------------------------------
# 7. OSTREE PREPARE-ROOT CONFIG
# -----------------------------------------------------------------------------
echo ">>> Creating ostree prepare-root.conf..."

mkdir -p "$ROOT/usr/lib/ostree"
cat > "$ROOT/usr/lib/ostree/prepare-root.conf" << 'EOF'
[composefs]
enabled = yes

[sysroot]
readonly = true
EOF

# -----------------------------------------------------------------------------
# 8. SYSTEM CONFIG FILES (modules-load, udev rules)
# -----------------------------------------------------------------------------
echo ">>> Installing system config files..."

# modules-load.d (e.g., ntsync for Wine/Proton)
if [[ -d "$CONFIG_DIR/base-files/modules-load.d" ]]; then
    mkdir -p "$ROOT/usr/etc/modules-load.d"
    cp "$CONFIG_DIR/base-files/modules-load.d/"* "$ROOT/usr/etc/modules-load.d/" 2>/dev/null || true
fi

# udev rules
if [[ -d "$CONFIG_DIR/base-files/udev-rules" ]]; then
    mkdir -p "$ROOT/usr/etc/udev/rules.d"
    cp "$CONFIG_DIR/base-files/udev-rules/"* "$ROOT/usr/etc/udev/rules.d/" 2>/dev/null || true
fi

# sudoers.d (enable wheel group)
if [[ -d "$CONFIG_DIR/base-files/sudoers.d" ]]; then
    mkdir -p "$ROOT/usr/etc/sudoers.d"
    cp "$CONFIG_DIR/base-files/sudoers.d/"* "$ROOT/usr/etc/sudoers.d/"
    chmod 440 "$ROOT/usr/etc/sudoers.d/"*
fi

# -----------------------------------------------------------------------------
# 9. KERNEL FILES
# -----------------------------------------------------------------------------
echo ">>> Fixing kernel file locations..."

for kver_dir in "$ROOT"/usr/lib/modules/*/; do
    kver=$(basename "$kver_dir")

    # Move vmlinuz to modules dir if not already there
    if [[ -f "$ROOT/boot/vmlinuz-linux-cachyos" && ! -f "$kver_dir/vmlinuz" ]]; then
        cp "$ROOT/boot/vmlinuz-linux-cachyos" "$kver_dir/vmlinuz"
        echo "  Copied kernel to $kver_dir/vmlinuz"
    elif [[ -f "$ROOT/boot/vmlinuz-$kver" && ! -f "$kver_dir/vmlinuz" ]]; then
        cp "$ROOT/boot/vmlinuz-$kver" "$kver_dir/vmlinuz"
    fi

    # Move initramfs to modules dir
    if [[ -f "$ROOT/boot/initramfs-linux-cachyos.img" && ! -f "$kver_dir/initramfs.img" ]]; then
        mv "$ROOT/boot/initramfs-linux-cachyos.img" "$kver_dir/initramfs.img"
        echo "  Moved initramfs to $kver_dir/initramfs.img"
    elif [[ -f "$ROOT/boot/initramfs-$kver.img" && ! -f "$kver_dir/initramfs.img" ]]; then
        mv "$ROOT/boot/initramfs-$kver.img" "$kver_dir/initramfs.img"
    fi

    # Sign kernel for Secure Boot
    if [[ -f "$kver_dir/vmlinuz" && -f "/keys/vyy-private.key" ]]; then
        sbsign --key "/keys/vyy-private.key" \
               --cert "/keys/vyy.pem" \
               --output "$kver_dir/vmlinuz.signed" \
               "$kver_dir/vmlinuz"
        mv "$kver_dir/vmlinuz.signed" "$kver_dir/vmlinuz"
        echo "  Signed kernel for Secure Boot"
        sbverify --list "$kver_dir/vmlinuz" 2>/dev/null || true
    fi
done

# Copy Secure Boot cert for user enrollment
if [[ -f "/keys/vyy.cer" ]]; then
    mkdir -p "$ROOT/usr/share/vyy"
    cp "/keys/vyy.cer" "$ROOT/usr/share/vyy/secureboot.cer"
    echo "  Installed Secure Boot cert to /usr/share/vyy/secureboot.cer"
fi

# Clear /boot - ostree populates it at deploy time
rm -rf "$ROOT/boot/"*

# -----------------------------------------------------------------------------
# 9. SETUID BINARIES
# -----------------------------------------------------------------------------
echo ">>> Setting up setuid binaries..."

chmod u+s "$ROOT/usr/bin/sudo" 2>/dev/null || true
chmod u+s "$ROOT/usr/bin/su" 2>/dev/null || true
chmod u+s "$ROOT/usr/bin/passwd" 2>/dev/null || true
chmod u+s "$ROOT/usr/bin/newgrp" 2>/dev/null || true
chmod u+s "$ROOT/usr/bin/chsh" 2>/dev/null || true
chmod u+s "$ROOT/usr/bin/chfn" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 10. ENABLE SERVICES
# -----------------------------------------------------------------------------
echo ">>> Enabling default services..."

mkdir -p "$ROOT/usr/etc/systemd/system/multi-user.target.wants"
mkdir -p "$ROOT/usr/etc/systemd/system/network-online.target.wants"
mkdir -p "$ROOT/usr/etc/systemd/system/sockets.target.wants"
mkdir -p "$ROOT/usr/etc/systemd/system/graphical.target.wants"

# NetworkManager
ln -sf /usr/lib/systemd/system/NetworkManager.service \
    "$ROOT/usr/etc/systemd/system/multi-user.target.wants/NetworkManager.service"
ln -sf /usr/lib/systemd/system/NetworkManager-wait-online.service \
    "$ROOT/usr/etc/systemd/system/network-online.target.wants/NetworkManager-wait-online.service"

# GDM (display manager)
if [[ -f "$ROOT/usr/lib/systemd/system/gdm.service" ]]; then
    ln -sf /usr/lib/systemd/system/gdm.service \
        "$ROOT/usr/etc/systemd/system/display-manager.service"
fi

# AppArmor
if [[ -f "$ROOT/usr/lib/systemd/system/apparmor.service" ]]; then
    ln -sf /usr/lib/systemd/system/apparmor.service \
        "$ROOT/usr/etc/systemd/system/multi-user.target.wants/apparmor.service"
fi

# Tuned (power/performance profiles)
if [[ -f "$ROOT/usr/lib/systemd/system/tuned.service" ]]; then
    ln -sf /usr/lib/systemd/system/tuned.service \
        "$ROOT/usr/etc/systemd/system/multi-user.target.wants/tuned.service"
fi
if [[ -f "$ROOT/usr/lib/systemd/system/tuned-ppd.service" ]]; then
    ln -sf /usr/lib/systemd/system/tuned-ppd.service \
        "$ROOT/usr/etc/systemd/system/multi-user.target.wants/tuned-ppd.service"
fi

# Pipewire (user service, but enable socket)
# User services are enabled differently, handled by GNOME session

# Flatpak
if [[ -f "$ROOT/usr/lib/systemd/system/flatpak-system-helper.service" ]]; then
    ln -sf /usr/lib/systemd/system/flatpak-system-helper.service \
        "$ROOT/usr/etc/systemd/system/multi-user.target.wants/flatpak-system-helper.service"
fi

# -----------------------------------------------------------------------------
# 11. REGENERATE LINKER CACHE
# -----------------------------------------------------------------------------
echo ">>> Regenerating ld.so.cache..."

# Create ld.so.conf if missing
if [[ ! -f "$ROOT/usr/etc/ld.so.conf" ]]; then
    cat > "$ROOT/usr/etc/ld.so.conf" << 'EOF'
include /etc/ld.so.conf.d/*.conf
include /usr/etc/ld.so.conf.d/*.conf
EOF
fi

# Symlink for ldconfig
ln -sf ../usr/etc/ld.so.conf "$ROOT/etc/ld.so.conf" 2>/dev/null || true

# Run ldconfig
if [[ -x "$ROOT/usr/sbin/ldconfig" ]]; then
    arch-chroot "$ROOT" /usr/sbin/ldconfig 2>/dev/null || true
fi

# Move cache to /usr/etc
if [[ -f "$ROOT/etc/ld.so.cache" ]]; then
    mv "$ROOT/etc/ld.so.cache" "$ROOT/usr/etc/ld.so.cache"
fi

rm -f "$ROOT/etc/ld.so.conf"

# -----------------------------------------------------------------------------
# 12. FONT CACHE
# -----------------------------------------------------------------------------
echo ">>> Regenerating font cache..."

# Fontconfig needs /etc/fonts to exist with proper config
if [[ -d "$ROOT/usr/etc/fonts" ]]; then
    mkdir -p "$ROOT/etc/fonts"
    # Symlink fonts.conf for fontconfig to find it
    ln -sf ../usr/etc/fonts/fonts.conf "$ROOT/etc/fonts/fonts.conf" 2>/dev/null || true
    ln -sf ../usr/etc/fonts/conf.d "$ROOT/etc/fonts/conf.d" 2>/dev/null || true
fi

# Regenerate font cache
if [[ -x "$ROOT/usr/bin/fc-cache" ]]; then
    arch-chroot "$ROOT" fc-cache -f 2>/dev/null || true
    echo "  Font cache regenerated"
fi

# Clean up temp /etc/fonts (OSTree handles /etc)
rm -rf "$ROOT/etc/fonts"

# -----------------------------------------------------------------------------
# 13. REMOVE SPECIAL FILES
# -----------------------------------------------------------------------------
echo ">>> Removing special files (FIFOs, sockets)..."

find "$ROOT" -type p -delete 2>/dev/null || true
find "$ROOT" -type s -delete 2>/dev/null || true

# -----------------------------------------------------------------------------
# 14. CLEANUP
# -----------------------------------------------------------------------------
echo ">>> Cleaning up..."

# Remove package cache
rm -rf "$ROOT/var/cache/pacman/pkg/"*

# Remove pacman database (not needed in immutable system)
# But keep it for now in case we need to debug
# rm -rf "$ROOT/var/lib/pacman/"

# Remove tmp contents
rm -rf "$ROOT/tmp/"*
rm -rf "$ROOT/var/tmp/"*

# -----------------------------------------------------------------------------
# 15. VERIFY CRITICAL FILES
# -----------------------------------------------------------------------------
echo ">>> Verifying critical files..."

ERRORS=0

# Check package sysusers.d configs exist
if [[ -f "$ROOT/usr/lib/sysusers.d/basic.conf" ]]; then
    SYSUSERS_COUNT=$(ls "$ROOT/usr/lib/sysusers.d/"*.conf 2>/dev/null | wc -l)
    echo "  OK: $SYSUSERS_COUNT sysusers.d configs found (package-provided)"
else
    echo "  WARNING: No sysusers.d configs found - system users may not be created"
fi

# Check /usr/etc/passwd exists and has root
if [[ ! -f "$ROOT/usr/etc/passwd" ]]; then
    echo "  ERROR: /usr/etc/passwd not found"
    ERRORS=$((ERRORS + 1))
elif ! grep -q "^root:" "$ROOT/usr/etc/passwd"; then
    echo "  ERROR: /usr/etc/passwd missing root user"
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: /usr/etc/passwd exists with root user"
fi

# Check critical system users exist (in /usr/etc/passwd from pacstrap)
for user in root gdm polkitd dbus; do
    if ! grep -q "^${user}:" "$ROOT/usr/etc/passwd" 2>/dev/null; then
        echo "  WARNING: System user '$user' not in /usr/etc/passwd (will be created by sysusers)"
    fi
done

# Check critical groups exist
for group in root wheel video audio gdm; do
    if ! grep -q "^${group}:" "$ROOT/usr/etc/group" 2>/dev/null; then
        echo "  WARNING: System group '$group' not in /usr/etc/group (will be created by sysusers)"
    fi
done

# Check kernel exists
if ! ls "$ROOT"/usr/lib/modules/*/vmlinuz &>/dev/null; then
    echo "  ERROR: No kernel (vmlinuz) found in /usr/lib/modules/"
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: Kernel found"
fi

# Regenerate initramfs with proper config paths
echo ">>> Regenerating initramfs with OSTree support..."

# Install custom dracut modules (fix ostree symlink location)
echo "  Installing vyy dracut modules..."
if [[ -d "$CONFIG_DIR/dracut-modules" ]]; then
    for mod_dir in "$CONFIG_DIR/dracut-modules"/*/; do
        mod_name=$(basename "$mod_dir")
        mkdir -p "$ROOT/usr/lib/dracut/modules.d/$mod_name"
        cp -v "$mod_dir"/* "$ROOT/usr/lib/dracut/modules.d/$mod_name/"
        chmod +x "$ROOT/usr/lib/dracut/modules.d/$mod_name/module-setup.sh" 2>/dev/null || true
    done
fi

# Install dracut config permanently (vendor location for bootc regeneration)
echo "  Installing vyy dracut config..."
mkdir -p "$ROOT/usr/lib/dracut/dracut.conf.d"
if [[ -d "$CONFIG_DIR/dracut.conf.d" ]]; then
    cp -v "$CONFIG_DIR/dracut.conf.d/"* "$ROOT/usr/lib/dracut/dracut.conf.d/"
else
    echo "  WARNING: $CONFIG_DIR/dracut.conf.d not found!"
fi

# Temporarily populate /etc for dracut (it expects files there during build)
echo "  Setting up temp /etc for dracut..."
mkdir -p "$ROOT/etc/dracut.conf.d"
cp "$ROOT/usr/lib/dracut/dracut.conf.d/"* "$ROOT/etc/dracut.conf.d/" 2>/dev/null || true
cp "$ROOT/usr/etc/shadow" "$ROOT/etc/shadow"
cp "$ROOT/usr/etc/passwd" "$ROOT/etc/passwd"
cp "$ROOT/usr/etc/group" "$ROOT/etc/group"

# Plymouth config (create default if missing)
mkdir -p "$ROOT/etc/plymouth"
cat > "$ROOT/etc/plymouth/plymouthd.conf" << 'EOF'
[Daemon]
Theme=spinner
ShowDelay=0
EOF

# Ensure /root target exists (it's a symlink to /var/roothome)
mkdir -p "$ROOT/var/roothome"

# Locale config for dracut i18n module
echo "LANG=en_GB.UTF-8" > "$ROOT/etc/locale.conf"

echo "  Temp /etc contents:"
ls -la "$ROOT/etc/dracut.conf.d/"

for kver_dir in "$ROOT"/usr/lib/modules/*/; do
    kver=$(basename "$kver_dir")
    if [[ -f "$kver_dir/vmlinuz" ]]; then
        echo "  Generating initramfs for $kver..."
        arch-chroot "$ROOT" dracut -v --force --kver "$kver" "/usr/lib/modules/$kver/initramfs.img" 2>&1 | grep -E "(Including module|ostree|ERROR)" || true
    fi
done

# Verify initramfs exists (dracut verbose output above shows if ostree included)
if ls "$ROOT"/usr/lib/modules/*/initramfs.img &>/dev/null; then
    echo "  OK: Initramfs generated"
else
    echo "  ERROR: No initramfs generated"
    ERRORS=$((ERRORS + 1))
fi

# Clean up temp /etc files (OSTree will manage /etc)
rm -rf "$ROOT/etc/dracut.conf.d"
rm -f "$ROOT/etc/shadow" "$ROOT/etc/passwd" "$ROOT/etc/group"
rm -f "$ROOT/etc/locale.conf"
rm -rf "$ROOT/etc/plymouth"

# Check os-release
if [[ ! -f "$ROOT/usr/lib/os-release" ]]; then
    echo "  ERROR: /usr/lib/os-release not found"
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: os-release found"
fi

if [[ $ERRORS -gt 0 ]]; then
    echo ""
    echo "  *** $ERRORS error(s) found - boot may fail! ***"
fi

# -----------------------------------------------------------------------------
# DONE
# -----------------------------------------------------------------------------
echo ""
echo "=== Restructure complete ==="
echo ""
du -sh "$ROOT"
echo ""
echo "Run /scripts/publish.sh to commit and push to GHCR"
