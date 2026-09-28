#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache
HELPER_SOURCE=$(mktemp -d "$PWD/.build/m1ddc-tests.XXXXXX")
trap 'rm -rf "$HELPER_SOURCE"' EXIT
python3 scripts/prepare_m1ddc.py "$HELPER_SOURCE"
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" \
    macos/Sources/Switcher.swift macos/Sources/Shortcuts.swift macos/Tests/main.swift -o .build/switcher-tests
.build/switcher-tests
xcrun clang -Wall -Wextra -Werror -fmodules -Dusleep=captest_sleep \
    -fmodules-cache-path="$PWD/.build/module-cache" -I "$HELPER_SOURCE/headers" \
    -I macos/DisplayDiscovery \
    macos/Tests/CapabilitiesTests.m macos/DisplayDiscovery/capabilities.m \
    -framework Foundation -framework IOKit -framework CoreGraphics \
    -o .build/capabilities-tests
.build/capabilities-tests
