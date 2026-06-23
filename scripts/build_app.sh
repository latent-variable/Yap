#!/usr/bin/env bash
# Assemble Parley.app from the SwiftPM build. Bundles the Python backend
# sources (not the venv/models — those live in Application Support).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPDIR="$ROOT/app"
CONFIG="${1:-release}"
OUT="$ROOT/dist"
APP="$OUT/Parley.app"

echo "[build] swift build -c $CONFIG"
( cd "$APPDIR" && swift build -c "$CONFIG" )
BIN="$(cd "$APPDIR" && swift build -c "$CONFIG" --show-bin-path)/Parley"

echo "[build] assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/repo"

cp "$BIN" "$APP/Contents/MacOS/Parley"
cp "$ROOT/app/Resources/Info.plist" "$APP/Contents/Info.plist"

# App icon (regenerate if the generator is newer than the icns).
if [ ! -f "$ROOT/app/Resources/AppIcon.icns" ] || \
   [ "$ROOT/scripts/make_icon.swift" -nt "$ROOT/app/Resources/AppIcon.icns" ]; then
  echo "[build] rendering app icon"
  swift "$ROOT/scripts/make_icon.swift" >/dev/null
  iconutil -c icns "$ROOT/dist/AppIcon.iconset" -o "$ROOT/app/Resources/AppIcon.icns"
fi
cp "$ROOT/app/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Bundle the openly-licensed HD starter voices (CMU ARCTIC) so every install
# has them out of the box; the app seeds them into Application Support on first
# run. Personal clones are NOT here (no redistribution rights).
if [ -d "$ROOT/app/Resources/hd-voices" ]; then
  mkdir -p "$APP/Contents/Resources/hd-voices"
  cp "$ROOT/app/Resources/hd-voices/"*.wav "$APP/Contents/Resources/hd-voices/" 2>/dev/null || true
fi

# Bundle backend sources + launcher so a packaged app can run self-contained.
# Copy every .py + requirements so new modules (e.g. chatterbox_engine) ship too.
mkdir -p "$APP/Contents/Resources/repo/backend" "$APP/Contents/Resources/repo/scripts"
cp "$ROOT/backend/"*.py "$ROOT/backend/"requirements*.txt "$APP/Contents/Resources/repo/backend/"
cp "$ROOT/scripts/run_backend.sh" "$APP/Contents/Resources/repo/scripts/"
chmod +x "$APP/Contents/Resources/repo/scripts/run_backend.sh"

# Embed the self-contained Python runtime so the app needs no system Python.
# Built by scripts/bundle_python.sh (cached). Without it, the app falls back to
# building a venv from system Python (dev machines only).
if [ "${PARLEY_BUNDLE_PYTHON:-1}" = "1" ]; then
  if [ ! -x "$ROOT/dist/python-runtime/bin/python3" ]; then
    bash "$ROOT/scripts/bundle_python.sh"
  fi
  echo "[build] embedding Python runtime"
  ditto "$ROOT/dist/python-runtime" "$APP/Contents/Resources/python"
fi

# Prefer a stable self-signed identity (survives reinstalls → Accessibility
# grant persists). Falls back to ad-hoc. Set one up with scripts/setup_signing.sh.
SIGN_ID="Parley Local Signing"
SIGN_KC="$HOME/Library/Keychains/parley-signing.keychain-db"
[ -f "$SIGN_KC" ] && security unlock-keychain -p "parley-local" "$SIGN_KC" 2>/dev/null || true
if [ -f "$SIGN_KC" ] && security find-certificate -c "$SIGN_ID" "$SIGN_KC" >/dev/null 2>&1; then
  echo "[build] signing with '$SIGN_ID' (stable identity — Accessibility grant persists)"
  if ! codesign --force --deep --sign "$SIGN_ID" --keychain "$SIGN_KC" "$APP" >/dev/null 2>&1; then
    echo "[build] stable signing failed, falling back to ad-hoc"
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1
  fi
else
  echo "[build] ad-hoc signing (run scripts/setup_signing.sh for a persistent identity)"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "[build] codesign skipped"
fi

echo "[build] done -> $APP"
