#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"

for path in \
    "$PROJECT_ROOT/.build" \
    "$PROJECT_ROOT/.build-release" \
    "$PROJECT_ROOT/.swiftpm"; do
    if [[ -e "$path" ]]; then
        /bin/rm -rf "$path"
    fi
done

/usr/bin/find /private/tmp \
    -maxdepth 1 \
    -type d \
    \( -name 'aigo-*-build' -o -name 'aigo-*-cache' -o -name 'aigo-*-clang' -o -name 'aigo-*-swiftpm' -o -name 'aigo-probe-*' -o -name 'aigo-release.*' -o -name 'aigo-tests.*' -o -name 'aigo-dmg-stage.*' -o -name 'aigo-dmg-mount.*' \) \
    -exec /bin/rm -rf {} +

print "AiGo build caches cleaned. Dist artifacts were preserved."
