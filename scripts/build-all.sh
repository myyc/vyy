#!/bin/bash
# Build all architectures
# Usage: ./build-all.sh [--parallel]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHITECTURES=(zen4 zen3 generic)

# Check for parallel flag
PARALLEL=""
if [[ "${1:-}" == "--parallel" ]]; then
    PARALLEL="1"
fi

echo "=== vyy multi-arch build $(date) ==="
echo "Architectures: ${ARCHITECTURES[*]}"
echo ""

if [[ -n "$PARALLEL" ]]; then
    echo ">>> Building in parallel..."
    pids=()
    for arch in "${ARCHITECTURES[@]}"; do
        (
            echo "[$arch] Starting..."
            if "$SCRIPT_DIR/daily-build.sh" "$arch" > "/tmp/vyy-build-$arch.log" 2>&1; then
                echo "[$arch] Success"
            else
                echo "[$arch] FAILED - check /tmp/vyy-build-$arch.log"
            fi
        ) &
        pids+=($!)
    done

    # Wait for all builds
    failed=0
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            ((failed++))
        fi
    done

    echo ""
    if [[ $failed -gt 0 ]]; then
        echo "=== $failed build(s) failed ==="
        exit 1
    fi
else
    echo ">>> Building sequentially..."
    failed=()
    for arch in "${ARCHITECTURES[@]}"; do
        echo ""
        echo ">>> Building $arch..."
        if "$SCRIPT_DIR/daily-build.sh" "$arch"; then
            echo "[$arch] Success"
        else
            echo "[$arch] FAILED"
            failed+=("$arch")
        fi
    done

    echo ""
    if [[ ${#failed[@]} -gt 0 ]]; then
        echo "=== Failed: ${failed[*]} ==="
        exit 1
    fi
fi

echo "=== All builds complete $(date) ==="
