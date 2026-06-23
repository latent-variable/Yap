#!/usr/bin/env bash
# Sign + notarize Parley for friction-free distribution (double-click to open,
# no "damaged"/"unidentified developer" warnings).
#
# Requires a paid Apple Developer account ($99/yr) and, one time:
#   1. A "Developer ID Application" certificate in your keychain.
#   2. A notarytool keychain profile:
#        xcrun notarytool store-credentials parley-notary \
#          --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PW
#
# Then: bash scripts/notarize.sh "Developer ID Application: Your Name (TEAMID)"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="${1:?pass the Developer ID Application identity}"
PROFILE="${PARLEY_NOTARY_PROFILE:-parley-notary}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/app/Resources/Info.plist")"
APP="$ROOT/dist/Parley.app"
DMG="$ROOT/dist/Parley-$VERSION.dmg"

echo "[notarize] building app (with bundled Python)"
bash "$ROOT/scripts/build_app.sh" release >/dev/null

echo "[notarize] signing with hardened runtime: $IDENTITY"
# Sign nested code first (Python dylibs/binaries), then the app, with the
# hardened runtime + a timestamp — both required for notarization.
# Don't suppress codesign errors — a silent signing failure here surfaces much
# later as an opaque notarization rejection.
find "$APP/Contents/Resources/python" -type f \( -name "*.dylib" -o -name "*.so" -o -perm -111 \) \
  -exec codesign --force --timestamp --options runtime --sign "$IDENTITY" {} +
codesign --force --deep --timestamp --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP" && echo "[notarize] signature OK"

echo "[notarize] packaging DMG"
bash "$ROOT/scripts/make_dmg.sh" "$VERSION" >/dev/null

echo "[notarize] submitting to Apple (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "[notarize] stapling ticket"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG" && echo "[notarize] done -> $DMG (notarized, double-click installable)"
