#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" && "${CODE_SIGN_IDENTITY:--}" == - ]]; then
    echo "Notarization requires CODE_SIGN_IDENTITY (a Developer ID Application certificate)." >&2
    exit 1
fi

bash scripts/build-macos.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' macos/Info.plist)
DMG="dist/qisme-${VERSION}-arm64.dmg"

# Keep packaging dependencies out of the system Python installation.
if [[ ! -x .build/dmg-venv/bin/python ]]; then
    "${PYTHON:-python3}" -m venv .build/dmg-venv
fi
.build/dmg-venv/bin/python -m pip install --disable-pip-version-check -r scripts/dmg-requirements.txt
.build/dmg-venv/bin/dmgbuild -s scripts/dmg-settings.py "qisme" "$DMG"

if [[ "${CODE_SIGN_IDENTITY:--}" != - ]]; then
    codesign --force --timestamp --sign "$CODE_SIGN_IDENTITY" "$DMG"
fi
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
    if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then
        NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
    fi
    xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi
hdiutil verify "$DMG"
(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Built: $PWD/$DMG"
