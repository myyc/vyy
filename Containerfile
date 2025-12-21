# vyy build container
# Arch Linux with CachyOS repos for Zen 4 optimized packages

FROM docker.io/cachyos/cachyos-v4:latest

# Refresh keyrings and install build tools
RUN pacman-key --init && \
    pacman-key --populate archlinux cachyos && \
    pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
        arch-install-scripts \
        ostree \
        dosfstools \
        e2fsprogs \
        dracut \
        sbsigntools \
        sudo \
        git \
        base-devel \
        skopeo \
        rust

# Create build user (makepkg doesn't run as root)
RUN useradd -m builder && \
    echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

WORKDIR /vyy

CMD ["/bin/bash"]
