#!/bin/bash
# Daily build script - run via cron or manually
# Usage: ./daily-build.sh [arch] [feature]
# arch: zen4 (default), zen3, generic
# feature: nvidia (optional)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Parse arguments
ARCH="${1:-zen4}"
FEATURE="${2:-}"

# Load architecture config
ARCH_CONFIG="$PROJECT_DIR/config/architectures/${ARCH}.conf"
if [[ ! -f "$ARCH_CONFIG" ]]; then
    echo "Error: Unknown architecture '$ARCH'"
    echo "Available: zen4, zen3, generic"
    exit 1
fi
source "$ARCH_CONFIG"

# Load feature config if specified
if [[ -n "$FEATURE" ]]; then
    FEATURE_CONFIG="$PROJECT_DIR/config/features/${FEATURE}.conf"
    if [[ ! -f "$FEATURE_CONFIG" ]]; then
        echo "Error: Unknown feature '$FEATURE'"
        echo "Available: nvidia"
        exit 1
    fi
    source "$FEATURE_CONFIG"
fi

# Compute variant name
VARIANT="$ARCH_NAME"
[[ -n "$FEATURE" ]] && VARIANT="$ARCH_NAME-$FEATURE"

IMAGE_NAME="vyy-build:$ARCH_NAME"

cd "$PROJECT_DIR"

echo "=== vyy daily build ($VARIANT) $(date) ==="

# Update repo
echo ">>> Updating repo..."
git pull

# Generate Containerfile from template
sed "s|@BASE_IMAGE@|$BASE_IMAGE|g" \
    "$PROJECT_DIR/Containerfile.template" > "$PROJECT_DIR/Containerfile"

# Always rebuild container with latest base image
echo ">>> Building container image for $ARCH_NAME..."
podman pull "$BASE_IMAGE"
podman build --network=host -t "$IMAGE_NAME" -f Containerfile .

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
    -e VYY_ARCH="$ARCH" \
    -e VYY_FEATURE="$FEATURE" \
    "$IMAGE_NAME" \
    /bin/bash -c '
        export PATH="/bin-cache:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        /scripts/build-vyy-root.sh && /scripts/publish.sh
    '

# Clean up
echo ">>> Cleaning up..."
rm -rf "$PROJECT_DIR/work"/*
rm -f "$PROJECT_DIR/Containerfile"

echo "=== Done ($VARIANT) $(date) ==="
