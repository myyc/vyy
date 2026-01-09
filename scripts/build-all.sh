#!/bin/bash
# Build multiple variants
# Usage: ./build-all.sh [variant...]
# variant: arch or arch-feature (e.g., zen4, zen3-nvidia)
# If no variants specified, builds: zen4 zen3 generic

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default variants if none specified
DEFAULT_VARIANTS=(zen4 zen3 generic)

# Parse arguments
VARIANTS=()
PARALLEL=""
for arg in "$@"; do
    case "$arg" in
        --parallel) PARALLEL="1" ;;
        *) VARIANTS+=("$arg") ;;
    esac
done

# Use defaults if no variants specified
if [[ ${#VARIANTS[@]} -eq 0 ]]; then
    VARIANTS=("${DEFAULT_VARIANTS[@]}")
fi

# Parse variant into arch and feature
parse_variant() {
    local variant="$1"
    if [[ "$variant" == *-nvidia ]]; then
        ARCH="${variant%-nvidia}"
        FEATURE="nvidia"
    else
        ARCH="$variant"
        FEATURE=""
    fi
}

echo "=== vyy multi-variant build $(date) ==="
echo "Variants: ${VARIANTS[*]}"
echo ""

if [[ -n "$PARALLEL" ]]; then
    echo ">>> Building in parallel..."
    pids=()
    for variant in "${VARIANTS[@]}"; do
        (
            parse_variant "$variant"
            echo "[$variant] Starting..."
            if "$SCRIPT_DIR/daily-build.sh" "$ARCH" "$FEATURE" > "/tmp/vyy-build-$variant.log" 2>&1; then
                echo "[$variant] Success"
            else
                echo "[$variant] FAILED - check /tmp/vyy-build-$variant.log"
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
    for variant in "${VARIANTS[@]}"; do
        parse_variant "$variant"
        echo ""
        echo ">>> Building $variant..."
        if "$SCRIPT_DIR/daily-build.sh" "$ARCH" "$FEATURE"; then
            echo "[$variant] Success"
        else
            echo "[$variant] FAILED"
            failed+=("$variant")
        fi
    done

    echo ""
    if [[ ${#failed[@]} -gt 0 ]]; then
        echo "=== Failed: ${failed[*]} ==="
        exit 1
    fi
fi

echo "=== All builds complete $(date) ==="
