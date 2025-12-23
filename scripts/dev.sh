#!/bin/bash
# Development helper - build and enter the vyy build container
# Usage: ./dev.sh [rebuild] [arch]
# arch: zen4 (default), zen3, generic

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Parse arguments
REBUILD=""
ARCH="zen4"
for arg in "$@"; do
    case "$arg" in
        rebuild) REBUILD="1" ;;
        zen4|zen3|generic) ARCH="$arg" ;;
    esac
done

# Load architecture config
ARCH_CONFIG="$PROJECT_DIR/config/architectures/${ARCH}.conf"
if [[ ! -f "$ARCH_CONFIG" ]]; then
    echo "Error: Unknown architecture '$ARCH'"
    echo "Available: zen4, zen3, generic"
    exit 1
fi
source "$ARCH_CONFIG"

IMAGE_NAME="vyy-build:$ARCH_NAME"

cd "$PROJECT_DIR"

# Generate Containerfile from template
generate_containerfile() {
    sed "s|@BASE_IMAGE@|$BASE_IMAGE|g" \
        "$PROJECT_DIR/Containerfile.template" > "$PROJECT_DIR/Containerfile"
}

# Build container image if needed or if 'rebuild' arg passed
if [[ -n "$REBUILD" ]] || ! podman image exists "$IMAGE_NAME"; then
    echo "Building container image for $ARCH_NAME..."
    generate_containerfile
    podman build --network=host -t "$IMAGE_NAME" -f Containerfile .
fi

# Create work directories
mkdir -p "$PROJECT_DIR/work"
mkdir -p "$PROJECT_DIR/.aur-cache"
mkdir -p "$PROJECT_DIR/.bin-cache"
mkdir -p "$PROJECT_DIR/ostree"

# Run container
echo "Starting build container ($ARCH_NAME)..."
podman run -it --rm \
    --privileged \
    --network=host \
    --pid=host \
    -v /proc:/proc \
    -v /sys:/sys \
    -v "$PROJECT_DIR/work:/vyy-root" \
    -v "$PROJECT_DIR/scripts:/scripts:ro" \
    -v "$PROJECT_DIR/config:/config:ro" \
    -v "$PROJECT_DIR/keys:/keys:ro" \
    -v "$PROJECT_DIR/.aur-cache:/aur-cache:rw" \
    -v "$PROJECT_DIR/.bin-cache:/bin-cache:rw" \
    -v "$PROJECT_DIR/ostree:/ostree-repo:rw" \
    -e VYY_AUR_CACHE=/aur-cache \
    -e VYY_ARCH="$ARCH" \
    "$IMAGE_NAME" \
    /bin/bash -c '
        export PATH="/bin-cache:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        echo "=== vyy build container ($VYY_ARCH) ==="
        echo ""
        echo "Available scripts:"
        echo "  /scripts/build-vyy-root.sh  - Build full system to /vyy-root"
        echo "  /scripts/publish.sh         - Commit to OSTree and push to GHCR"
        echo ""
        echo "Target root: /vyy-root"
        echo "Architecture: $VYY_ARCH"
        echo ""
        exec /bin/bash
    '
