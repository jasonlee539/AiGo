#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
DIST_DIR="$PROJECT_ROOT/Dist"
APP_PATH="$DIST_DIR/AiGo.app"
DMG_PATH="$DIST_DIR/AiGo-0.1.4-AppleSilicon.dmg"

"$SCRIPT_DIR/build-app.sh"

STAGE_ROOT="$(mktemp -d /private/tmp/aigo-dmg-stage.XXXXXX)"
MOUNT_ROOT="$(mktemp -d /private/tmp/aigo-dmg-mount.XXXXXX)"
IS_MOUNTED=0
cleanup() {
    if [[ "$IS_MOUNTED" -eq 1 ]]; then
        /usr/bin/hdiutil detach "$MOUNT_ROOT" >/dev/null 2>&1 || true
    fi
    /bin/rm -rf "$STAGE_ROOT" "$MOUNT_ROOT"
}
trap cleanup EXIT INT TERM

/usr/bin/ditto "$APP_PATH" "$STAGE_ROOT/AiGo.app"
/bin/ln -s /Applications "$STAGE_ROOT/Applications"

if [[ -e "$DMG_PATH" ]]; then
    /bin/rm -f "$DMG_PATH"
fi

/usr/bin/hdiutil create \
    -volname "AiGo 0.1.4" \
    -srcfolder "$STAGE_ROOT" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

/usr/bin/hdiutil verify "$DMG_PATH"
/usr/bin/hdiutil attach \
    -readonly \
    -nobrowse \
    -noautoopen \
    -mountpoint "$MOUNT_ROOT" \
    "$DMG_PATH" >/dev/null
IS_MOUNTED=1

/usr/bin/codesign --verify --deep --strict --verbose=2 "$MOUNT_ROOT/AiGo.app"
ARCHS="$(/usr/bin/lipo -archs "$MOUNT_ROOT/AiGo.app/Contents/MacOS/AiGo")"
if [[ "$ARCHS" != "arm64" ]]; then
    print -u2 "Unexpected DMG application architecture: $ARCHS"
    exit 1
fi

/usr/bin/hdiutil detach "$MOUNT_ROOT" >/dev/null
IS_MOUNTED=0

SHA256="$(/usr/bin/shasum -a 256 "$DMG_PATH" | /usr/bin/awk '{print $1}')"
print "Packaged: $DMG_PATH"
print "Architecture: $ARCHS"
print "SHA-256: $SHA256"
