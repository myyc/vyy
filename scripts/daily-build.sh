#!/bin/bash
# Daily build script - run via cron
# Updates repo, builds, publishes, cleans up

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_NAME="vyy-build:cachyos"

cd "$PROJECT_DIR"

echo "=== vyy daily build $(date) ==="

# Update repo
echo ">>> Updating repo..."
git pull

# Build container image if needed
if ! podman image exists "$IMAGE_NAME"; then
    echo ">>> Building container image..."
    podman build --network=host -t "$IMAGE_NAME" -f Containerfile .
fi

# Create work directories
mkdir -p "$PROJECT_DIR/work"
mkdir -p "$PROJECT_DIR/.aur-cache"
mkdir -p "$PROJECT_DIR/.bin-cache"
mkdir -p "$PROJECT_DIR/ostree"

# Run build and publish
echo ">>> Starting build..."
podman run --rm \
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
    "$IMAGE_NAME" \
    /bin/bash -c '
        export PATH="/bin-cache:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        /scripts/build-vyy-root.sh && /scripts/publish.sh
    '

# Clean work dir
echo ">>> Cleaning up..."
rm -rf "$PROJECT_DIR/work"/*

echo "=== Done $(date) ==="
