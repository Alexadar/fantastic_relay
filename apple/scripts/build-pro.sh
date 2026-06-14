#!/usr/bin/env bash
# build-pro.sh — Build, sign, notarize, staple, and package Fantastic Relay as a
# Developer-ID DMG ready for distribution.
#
# Prereqs (one-time):
#   1. Developer ID Application cert in the login keychain.
#   2. Notarytool credentials stored: ./scripts/setup-notarize.sh
#
# No nested binaries are bundled (cloudflared is found on PATH, never shipped),
# so there is no re-sign-the-nested-Mach-O step — Xcode signs the single
# statically-linked executable correctly.
#
# Usage:
#   ./scripts/build-pro.sh                  # full: build, notarize, staple, dmg
#   ./scripts/build-pro.sh --skip-notarize  # local dry-run, no Apple upload
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="FantasticRelay.xcodeproj"
SCHEME="Fantastic Relay"
CONFIG=Release
ARCHIVE_PATH="build/FantasticRelay.xcarchive"
EXPORT_PATH="build/Relay-export"
APP_NAME="Fantastic Relay"
APP_PATH="$EXPORT_PATH/$APP_NAME.app"
DMG_PATH="build/FantasticRelay-$(date +%Y%m%d-%H%M%S).dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-FantasticNotarize}"
SIGN_IDENTITY="Developer ID Application: Koreniuk Oleksandr (LSKNNBG94G)"

SKIP_NOTARIZE=0
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

H() { printf "\n\033[1;36m▶ %s\033[0m\n" "$1"; }

# Regenerate the project from project.yml so the build matches source.
H "0/6  xcodegen generate"
xcodegen generate

# ─── 1. Clean + archive ───────────────────────────────────────────────────
H "1/6  Archiving $SCHEME ($CONFIG)"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    archive

# ─── 2. Export with Developer ID method ───────────────────────────────────
H "2/6  Exporting to $EXPORT_PATH"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist scripts/ExportOptions-Pro.plist \
    -allowProvisioningUpdates

# ─── 3. Verify signing (Gatekeeper-equivalent local check) ────────────────
H "3/6  Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dvvv "$APP_PATH" 2>&1 | grep -E "Authority|TeamIdentifier|Identifier|Format"
echo "✓ Signature valid."

# ─── 4. Notarize (uploads to Apple, waits up to ~10 min) ──────────────────
if [[ $SKIP_NOTARIZE -eq 1 ]]; then
    H "4/6  Skipping notarization (--skip-notarize)"
else
    H "4/6  Notarizing (this can take a few minutes)"
    ZIP_FOR_NOTARY="build/FantasticRelay-for-notary.zip"
    /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ZIP_FOR_NOTARY"
    xcrun notarytool submit "$ZIP_FOR_NOTARY" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    rm "$ZIP_FOR_NOTARY"
fi

# ─── 5. Staple the notarization ticket onto the .app ──────────────────────
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    H "5/6  Stapling notarization ticket"
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
fi

# ─── 6. Final Gatekeeper assessment + DMG package ─────────────────────────
H "6/6  Gatekeeper assessment + DMG"
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    spctl --assess --type execute --verbose=4 "$APP_PATH"
fi

DMG_DIR="build/dmg-staging"
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "$APP_PATH" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"
rm -rf "$DMG_DIR"

codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    H "Notarizing the DMG"
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    xcrun stapler staple "$DMG_PATH"
fi

echo
echo "╭───────────────────────────────────────────────────────────"
echo "│  ✓ Fantastic Relay release built and ready"
echo "│    .app: $APP_PATH"
echo "│    .dmg: $DMG_PATH"
echo "╰───────────────────────────────────────────────────────────"
