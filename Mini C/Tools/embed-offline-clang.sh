#!/bin/sh
set -eu
VENDOR="$SRCROOT/Mini C/OfflineClang/Vendor"
RESOURCES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/OfflineClangToolchain"
FRAMEWORKS="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
if [ ! -f "$VENDOR/usr/lib/wasm32-wasi/libc.a" ]; then
    echo 'error: Offline SDK missing. Run: swift "Mini C/Tools/bootstrap-offline-clang.swift"' >&2
    exit 1
fi
mkdir -p "$RESOURCES/usr" "$FRAMEWORKS"
/usr/bin/rsync -a --delete --exclude='*.temp-archive-*' "$VENDOR/usr/include" "$VENDOR/usr/lib" "$RESOURCES/usr/"
/usr/bin/rsync -a --delete "$SRCROOT/Mini C/OfflineClang/Licenses" "$RESOURCES/"
mkdir -p "$RESOURCES/examples"
/usr/bin/rsync -a --delete "$SRCROOT/Mini C/OfflineClang/Tests/OfflineClangCoreTests/Fixtures/" "$RESOURCES/examples/"
SLICE=ios-arm64
if [ "$PLATFORM_NAME" = iphonesimulator ]; then
    case " $ARCHS " in
        *' x86_64 '*) SLICE=ios-x86_64-simulator ;;
        *)
            for NAME in clang lld libLLVM ios_system; do rm -rf "$FRAMEWORKS/$NAME.framework"; done
            echo 'warning: ARM simulator uses bundled WASM samples; compiler frameworks require iPhone or Intel simulator.'
            exit 0 ;;
    esac
fi
for NAME in ios_system libLLVM clang lld; do
    SELECTED="$SLICE"
    if [ "$NAME" = ios_system ] && [ "$SLICE" = ios-x86_64-simulator ]; then SELECTED=ios-arm64_x86_64-simulator; fi
    SOURCE="$VENDOR/$NAME.xcframework/$SELECTED/$NAME.framework"
    if [ ! -d "$SOURCE" ]; then echo "error: Missing $SOURCE" >&2; exit 1; fi
    /usr/bin/rsync -a --delete --exclude=Headers --exclude=Modules "$SOURCE" "$FRAMEWORKS/"
    if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
        /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --preserve-metadata=identifier "$FRAMEWORKS/$NAME.framework"
    fi
done
