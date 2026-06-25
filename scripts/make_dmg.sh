#!/usr/bin/env bash
# Build Yap.app and wrap it in a compressed, drag-to-install DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/app/Resources/Info.plist")}"
OUT="$ROOT/dist"
APP="$OUT/Yap.app"
DMG="$OUT/Yap-$VERSION.dmg"
STAGE="$OUT/dmg-stage"
VOL="Yap"

echo "[dmg] building app bundle"
bash "$ROOT/scripts/build_app.sh" release >/dev/null

echo "[dmg] staging"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# strip quarantine so right-click-Open friction is minimal locally
xattr -cr "$STAGE/Yap.app" 2>/dev/null || true

echo "[dmg] creating compressed image"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
rm -rf "$STAGE"

SIZE="$(du -h "$DMG" | cut -f1)"
echo "[dmg] done -> $DMG ($SIZE)"
