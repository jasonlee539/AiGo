#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
DIST_DIR="$PROJECT_ROOT/Dist"
APP_PATH="$DIST_DIR/AiGo.app"
SDK_FALLBACK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"

if [[ -d "$SDK_FALLBACK" ]]; then
    SDK_PATH="${AIGO_SDK_PATH:-$SDK_FALLBACK}"
else
    SDK_PATH="${AIGO_SDK_PATH:-$(xcrun --show-sdk-path)}"
fi

WORK_ROOT="$(mktemp -d /private/tmp/aigo-release.XXXXXX)"
cleanup() {
    /bin/rm -rf "$WORK_ROOT"
}
trap cleanup EXIT INT TERM

mkdir -p "$DIST_DIR"
if [[ -e "$APP_PATH" ]]; then
    /bin/rm -rf "$APP_PATH"
fi

env \
    CLANG_MODULE_CACHE_PATH="$WORK_ROOT/clang-cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$WORK_ROOT/swiftpm-module-cache" \
    swift build \
        --disable-sandbox \
        --package-path "$PROJECT_ROOT" \
        --scratch-path "$WORK_ROOT/build" \
        --sdk "$SDK_PATH" \
        --configuration release \
        --arch arm64 \
        --product AiGo

BINARY_PATH="$WORK_ROOT/build/arm64-apple-macosx/release/AiGo"
if [[ ! -x "$BINARY_PATH" ]]; then
    print -u2 "Release binary not found: $BINARY_PATH"
    exit 1
fi

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
/usr/bin/ditto "$BINARY_PATH" "$APP_PATH/Contents/MacOS/AiGo"
/bin/cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
/bin/cp "$PROJECT_ROOT/src/tray-icon.png" "$APP_PATH/Contents/Resources/tray-icon.png"
/bin/chmod 755 "$APP_PATH/Contents/MacOS/AiGo"

/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"
/usr/bin/codesign \
    --force \
    --sign - \
    --timestamp=none \
    --entitlements "$PROJECT_ROOT/Resources/AiGo.entitlements" \
    "$APP_PATH"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
ARCHS="$(/usr/bin/lipo -archs "$APP_PATH/Contents/MacOS/AiGo")"
if [[ "$ARCHS" != "arm64" ]]; then
    print -u2 "Unexpected application architecture: $ARCHS"
    exit 1
fi

print "Built: $APP_PATH"
print "Architecture: $ARCHS"
print "Signing: ad-hoc (local development build)"
