#!/bin/bash
# vyy dracut module to fix ostree-prepare-root service symlink location

check() {
    # Always include when requested
    return 0
}

depends() {
    echo "ostree"
}

install() {
    # Create the correct systemd wants directory
    mkdir -p "${initdir}/etc/systemd/system/initrd-root-fs.target.wants"

    # Create symlink in the correct location for systemd to find it
    ln -sfn "../../../../usr/lib/systemd/system/ostree-prepare-root.service" \
        "${initdir}/etc/systemd/system/initrd-root-fs.target.wants/ostree-prepare-root.service"

    # Remove the incorrectly placed symlink/directory if it exists
    rm -rf "${initdir}/initrd-root-fs.target.wants"

    dwarn "vyy-ostree-fix: Fixed ostree-prepare-root.service symlink location"
}
