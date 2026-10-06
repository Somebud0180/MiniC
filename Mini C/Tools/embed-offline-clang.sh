#!/bin/sh
set -eu
if [ -z "${OFFLINE_CLANG_ROOT:-}" ]; then
    # Archive BUILD_DIR is nested below ArchiveIntermediates; normal builds
    # use Build/Products. Find the checkout in their shared Derived Data root.
    SEARCH_DIR="${BUILD_DIR:?Xcode must provide BUILD_DIR}"
    while :; do
        CANDIDATE="$SEARCH_DIR/SourcePackages/checkouts/miniclang"
        if [ -f "$CANDIDATE/Tools/embed-offline-clang.sh" ]; then
            OFFLINE_CLANG_ROOT="$CANDIDATE"
            break
        fi
        if [ "$SEARCH_DIR" = / ]; then
            echo 'error: MiniClang checkout not found. Resolve package dependencies or set OFFLINE_CLANG_ROOT to the checkout path.' >&2
            exit 1
        fi
        SEARCH_DIR=$(dirname "$SEARCH_DIR")
    done
fi
if [ ! -f "$OFFLINE_CLANG_ROOT/Tools/embed-offline-clang.sh" ]; then
    echo "error: MiniClang embedding script missing at $OFFLINE_CLANG_ROOT/Tools/embed-offline-clang.sh. Check OFFLINE_CLANG_ROOT." >&2
    exit 1
fi
export OFFLINE_CLANG_ROOT
exec "$OFFLINE_CLANG_ROOT/Tools/embed-offline-clang.sh"
