#!/bin/sh
set -eu
OFFLINE_CLANG_ROOT="${OFFLINE_CLANG_ROOT:-$BUILD_DIR/../../SourcePackages/checkouts/miniclang}"
export OFFLINE_CLANG_ROOT
exec "$OFFLINE_CLANG_ROOT/Tools/embed-offline-clang.sh"
