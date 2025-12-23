#!/bin/bash
# publish.sh - Commit to local OSTree repo and push to GHCR
set -euo pipefail

ROOT="${1:-/vyy-root}"
OSTREE_REPO="/ostree-repo"
BIN_CACHE="/bin-cache"
ARCH="${VYY_ARCH:-zen4}"
GHCR_IMAGE="ghcr.io/myyc/vyy-$ARCH"
OSTREE_BRANCH="vyy-$ARCH"
VERSION=$(date +%Y%m%d)

# Build ostree-ext-cli if not cached
if [[ ! -x "$BIN_CACHE/ostree-ext-cli" ]]; then
    echo "=== Building ostree-ext-cli ==="
    TMPDIR=$(mktemp -d)
    cd "$TMPDIR"
    git clone --depth 1 https://github.com/ostreedev/ostree-rs-ext.git
    cd ostree-rs-ext
    cargo build --release
    cp target/release/ostree-ext-cli "$BIN_CACHE/"
    cd /
    rm -rf "$TMPDIR"
    echo "  Cached to $BIN_CACHE/ostree-ext-cli"
fi

# Auth with GitHub token
if [[ -f "/keys/gh-token" ]]; then
    echo "=== Authenticating with GHCR ==="
    GH_TOKEN=$(cat /keys/gh-token)
    echo "$GH_TOKEN" | skopeo login ghcr.io -u myyc --password-stdin
else
    echo "Warning: /keys/gh-token not found, skipping auth"
fi

# Initialize local repo if needed
if [[ ! -d "$OSTREE_REPO/objects" ]]; then
    echo "=== Initializing OSTree repo ==="
    ostree init --repo="$OSTREE_REPO" --mode=bare-user
fi

# Commit to local repo
echo "=== Committing to OSTree ($ARCH) ==="
COMMIT=$(ostree commit --repo="$OSTREE_REPO" --branch="$OSTREE_BRANCH" \
    --skip-list=/config/ostree-skip-list \
    --owner-uid=0 --owner-gid=0 "$ROOT")
echo "  Commit: $COMMIT"

echo "  Version: $VERSION"

# Push to GHCR
echo "=== Pushing to GHCR ==="
"$BIN_CACHE/ostree-ext-cli" container encapsulate \
    --repo="$OSTREE_REPO" \
    --label ostree.bootable=true \
    "$OSTREE_BRANCH" \
    "docker://$GHCR_IMAGE:$VERSION"

# Tag as latest
skopeo copy "docker://$GHCR_IMAGE:$VERSION" "docker://$GHCR_IMAGE:latest"

echo ""
echo "=== Done ==="
echo "Pushed to:"
echo "  $GHCR_IMAGE:latest"
echo "  $GHCR_IMAGE:$VERSION"
