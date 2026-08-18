#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
SDK_FALLBACK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"

if [[ -d "$SDK_FALLBACK" ]]; then
    SDK_PATH="${AIGO_SDK_PATH:-$SDK_FALLBACK}"
else
    SDK_PATH="${AIGO_SDK_PATH:-$(xcrun --show-sdk-path)}"
fi

WORK_ROOT="$(mktemp -d /private/tmp/aigo-tests.XXXXXX)"
cleanup() {
    /bin/rm -rf "$WORK_ROOT"
}
trap cleanup EXIT INT TERM

env \
    CLANG_MODULE_CACHE_PATH="$WORK_ROOT/clang-cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$WORK_ROOT/swiftpm-module-cache" \
    swift run \
        --disable-sandbox \
        --package-path "$PROJECT_ROOT" \
        --scratch-path "$WORK_ROOT/build" \
        --sdk "$SDK_PATH" \
        --configuration debug \
        --arch arm64 \
        AiGoSelfTests
