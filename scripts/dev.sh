#!/bin/bash
# Development helper - build and enter the vyy build container
# Usage: ./dev.sh [rebuild]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_NAME="vyy-build:cachyos"

cd "$PROJECT_DIR"

# Build container image if needed or if 'rebuild' arg passed
if [[ "${1:-}" == "rebuild" ]] || ! podman image exists "$IMAGE_NAME"; then
    echo "Building container image..."
    podman build --network=host -t "$IMAGE_NAME" -f Containerfile .
fi

# Create work directories
mkdir -p "$PROJECT_DIR/work"
mkdir -p "$PROJECT_DIR/.aur-cache"
mkdir -p "$PROJECT_DIR/.bin-cache"
mkdir -p "$PROJECT_DIR/ostree"

# Run container
echo "Starting build container..."
podman run -it --rm \
    --privileged \
    --network=host \
    -v "$PROJECT_DIR/work:/vyy-root" \
    -v "$PROJECT_DIR/scripts:/scripts:ro" \
    -v "$PROJECT_DIR/config:/config:ro" \
    -v "$PROJECT_DIR/keys:/keys:ro" \
    -v "$PROJECT_DIR/.aur-cache:/aur-cache:rw" \
    -v "$PROJECT_DIR/.bin-cache:/bin-cache:rw" \
    -v "$PROJECT_DIR/ostree:/ostree-repo:rw" \
    -e VYY_AUR_CACHE=/aur-cache \
    "$IMAGE_NAME" \
    /bin/bash -c '
        export PATH="/bin-cache:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        echo "=== vyy build container ==="
        echo ""
        echo "Available scripts:"
        echo "  /scripts/build-vyy-root.sh  - Build full system to /vyy-root"
        echo "  /scripts/publish.sh         - Commit to OSTree and push to GHCR"
        echo ""
        echo "Target root: /vyy-root"
        echo ""
        exec /bin/bash
    '
