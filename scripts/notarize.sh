#!/usr/bin/env bash
# Sign + notarize Yap for friction-free distribution (double-click to open,
# no "damaged"/"unidentified developer" warnings).
#
# Requires a paid Apple Developer account ($99/yr) and, one time:
#   1. A "Developer ID Application" certificate in your keychain.
#   2. A notarytool keychain profile:
#        xcrun notarytool store-credentials yap-notary \
#          --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PW
#
# Then: bash scripts/notarize.sh "Developer ID Application: Your Name (TEAMID)"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="${1:?pass the Developer ID Application identity}"
PROFILE="${YAP_NOTARY_PROFILE:-${PARLEY_NOTARY_PROFILE:-yap-notary}}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/app/Resources/Info.plist")"
APP="$ROOT/dist/Yap.app"
DMG="$ROOT/dist/Yap-$VERSION.dmg"

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
# --no-build is load-bearing: without it make_dmg.sh runs build_app.sh, which
# rm -rf's dist/Yap.app and re-signs it ad-hoc, discarding the Developer ID
# signature applied above and guaranteeing a notarization rejection.
bash "$ROOT/scripts/make_dmg.sh" "$VERSION" --no-build >/dev/null

# Verify the bundle INSIDE the DMG, not $APP. Apple judges the copy that was
# staged, xattr-stripped and compressed, and that copy is the whole reason this
# step exists: make_dmg.sh used to rebuild over the signed bundle, and the only
# symptom was an opaque rejection minutes later. Check the artifact, not a proxy.
MNT="$(mktemp -d)"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" >/dev/null
# Detach on any exit, or a failed check leaves the volume mounted.
trap 'hdiutil detach "$MNT" >/dev/null 2>&1 || true; rmdir "$MNT" 2>/dev/null || true' EXIT
codesign --verify --deep --strict "$MNT/Yap.app" \
  || { echo "[notarize] the DMG's bundle is not validly signed — aborting" >&2; exit 1; }
# --deep --strict passes on an ad-hoc signature too, so also require that the
# identity actually made it in. That is the failure #66 was: a correctly signed
# bundle carrying the WRONG signature.
codesign -dvv "$MNT/Yap.app" 2>&1 | grep -q "^Authority=Developer ID Application" \
  || { echo "[notarize] the DMG's bundle is not Developer ID signed — make_dmg.sh rebuilt it" >&2
       codesign -dvv "$MNT/Yap.app" 2>&1 | grep -E "^Authority=|^Signature=" >&2
       exit 1; }
# Detach BEFORE submitting: stapler writes the ticket into this DMG, and doing
# that under a live read-only mount of the same file is asking for trouble. The
# trap stays armed as a safety net for the failure paths above.
hdiutil detach "$MNT" >/dev/null; rmdir "$MNT" 2>/dev/null || true
trap - EXIT
echo "[notarize] DMG contents verified: Developer ID signature intact"

echo "[notarize] submitting to Apple (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "[notarize] stapling ticket"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG" && echo "[notarize] done -> $DMG (notarized, double-click installable)"
