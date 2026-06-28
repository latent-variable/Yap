#!/usr/bin/env bash
# Assemble Yap.app from the SwiftPM build. Bundles the Python backend
# sources (not the venv/models — those live in Application Support).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPDIR="$ROOT/app"
CONFIG="${1:-release}"
OUT="$ROOT/dist"
APP="$OUT/Yap.app"

echo "[build] swift build -c $CONFIG"
( cd "$APPDIR" && swift build -c "$CONFIG" )
BIN="$(cd "$APPDIR" && swift build -c "$CONFIG" --show-bin-path)/Yap"

echo "[build] assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/repo"

cp "$BIN" "$APP/Contents/MacOS/Yap"
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

# Prefer a stable self-signed identity. macOS ties the Accessibility (and Mic)
# grant to the signature's DESIGNATED REQUIREMENT — i.e. the certificate —
# instead of the binary's cdhash. So every rebuild keeps the same identity and
# the grant survives. Ad-hoc signing (the fallback) is cdhash-bound, so each
# rebuild looks like a brand-new app to TCC and the grant is lost — that's what
# made axTrusted flap. Set the identity up once with scripts/setup_signing.sh.
SIGN_ID="Yap Local Signing"
SIGN_KC="$HOME/Library/Keychains/yap-signing.keychain-db"
SIGN_KCPW="yap-local"
if [ -f "$SIGN_KC" ] && security find-certificate -c "$SIGN_ID" "$SIGN_KC" >/dev/null 2>&1; then
  echo "[build] signing with '$SIGN_ID' (stable identity — Accessibility grant persists)"
  # codesign needs the key reachable non-interactively: just UNLOCK the keychain.
  # Do NOT re-run set-key-partition-list here — that's a one-time setup step
  # (setup_signing.sh), and re-applying it right before signing leaves codesign
  # unable to reach the private key, silently yielding an ad-hoc signature (the
  # exact bug that broke grant persistence). Unlock-then-sign is the working path.
  security unlock-keychain -p "$SIGN_KCPW" "$SIGN_KC" 2>/dev/null || true
  # Gate on codesign's OWN exit code, not a follow-up `codesign -dvv` read:
  # codesign --sign <identity> either succeeds with that identity (exit 0) or
  # errors (non-zero) — it never silently ad-hocs (only `--sign -` does that).
  # A separate -dvv check can read a stale signature from the kernel's code-sign
  # cache right after re-signing and false-negative, which is misleading.
  CODESIGN_ERR="$(mktemp)"   # unique temp file — no predictable /tmp symlink target
  if codesign --force --deep --sign "$SIGN_ID" --keychain "$SIGN_KC" "$APP" 2>"$CODESIGN_ERR"; then
    echo "[build] signed with stable identity (Accessibility grant persists across rebuilds)"
  else
    echo "[build] ERROR: codesign with '$SIGN_ID' failed — grant will NOT persist:" >&2
    sed 's/^/[build]   /' "$CODESIGN_ERR" >&2
    echo "[build]        Re-run: bash scripts/setup_signing.sh   then rebuild." >&2
    rm -f "$CODESIGN_ERR"; exit 1
  fi
  rm -f "$CODESIGN_ERR"
else
  echo "[build] ad-hoc signing (no stable identity; run scripts/setup_signing.sh)"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "[build] codesign skipped"
fi

echo "[build] done -> $APP"
