#!/bin/sh
set -eu
OFFLINE_CLANG_ROOT="${OFFLINE_CLANG_ROOT:-$SRCROOT/../MiniClang}"
export OFFLINE_CLANG_ROOT
exec "$OFFLINE_CLANG_ROOT/Tools/embed-offline-clang.sh"
