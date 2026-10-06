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
"$OFFLINE_CLANG_ROOT/Tools/embed-offline-clang.sh"

# WASI link inputs are compiler data, but App Store validation rejects raw
# archives in app resources. Encode them for restoration in the app sandbox.
RESOURCES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/OfflineClangToolchain"
find "$RESOURCES/usr" -type f \( -name '*.a' -o -name '*.o' \) -exec /bin/sh -eu -c '
    for input do
        /usr/bin/base64 -i "$input" -o "$input.base64"
        rm "$input"
    done
' sh {} +
# A new payload identity prevents stale caches even when the version is unchanged.
/usr/bin/uuidgen > "$RESOURCES/payload-id"

# Preserve genuine vendor symbols; stripped LLVM binaries cannot supply dSYMs.
if [ -n "${DWARF_DSYM_FOLDER_PATH:-}" ] && [ "$PLATFORM_NAME" = iphoneos ]; then
    for name in ios_system libLLVM clang lld; do
        symbols="$OFFLINE_CLANG_ROOT/Vendor/$name.xcframework/ios-arm64/dSYMs/$name.framework.dSYM"
        if [ -d "$symbols" ]; then
            mkdir -p "$DWARF_DSYM_FOLDER_PATH"
            /usr/bin/rsync -a --delete "$symbols" "$DWARF_DSYM_FOLDER_PATH/"
        else
            echo "warning: Vendor does not supply $name.framework.dSYM; symbol upload may warn."
        fi
    done
fi
