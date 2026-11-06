#!/usr/bin/env bash
# Build a self-contained Python runtime with Kokoro deps baked in, so the app
# needs NO system Python. Produces dist/python-runtime/ (~270 MB), which
# build_app.sh embeds at Yap.app/Contents/Resources/python.
#
# The interpreter is one pinned python-build-standalone release, checked against
# its SHA-256 (scripts/python_pin.sh), and the packages come from the hash lock
# backend/requirements.txt (backend/DEPENDENCIES.md). The output is cached and
# rebuilt only when the pin or the lock changes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dist/python-runtime"
LOCK="$ROOT/backend/requirements.txt"
# shellcheck source=python_pin.sh
. "$ROOT/scripts/python_pin.sh"

STAMP="python=$PYTHON_SHA256 lock=$(shasum -a 256 "$LOCK" | awk '{print $1}')"
if [ -x "$OUT/bin/python3" ] && [ "${1:-}" != "--force" ] && \
   [ "$(cat "$OUT/.yap-runtime-stamp" 2>/dev/null)" = "$STAMP" ]; then
  echo "[py] $OUT already built from this pin and lock (use --force to rebuild)"
  exit 0
fi

echo "[py] fetching $PYTHON_ASSET"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fetch_pinned_python "$TMP"

rm -rf "$OUT"; mkdir -p "$(dirname "$OUT")"
mv "$TMP/python" "$OUT"

echo "[py] installing backend deps from the hash lock"
# Build in full isolation: python -I ignores env vars + the user site-packages,
# and pip --isolated ignores pip config files. Without this, pip treats deps
# already present in the builder's ~/.local (or pulled via a stray PYTHONPATH)
# as "satisfied" and skips them, producing a runtime that silently depends on
# the build machine (this bit us: csvw's uritemplate/colorama/jsonschema went
# missing). requirements.in also names those three explicitly, belt-and-braces.
# --require-hashes refuses any file whose bytes differ from the lock, and
# --only-binary keeps a source package's build script from running here.
"$OUT/bin/python3" -I -m pip install -q --disable-pip-version-check --isolated \
    --no-cache-dir --require-hashes --only-binary=:all: -r "$LOCK"

# Trim build fat (tests, caches) to shrink the bundle.
find "$OUT/lib" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$OUT/lib" -type d -name "test" -path "*/python3.12/test" -exec rm -rf {} + 2>/dev/null || true

echo "[py] verifying Kokoro loads from the bundled runtime"
"$OUT/bin/python3" -I -c "import kokoro_onnx, onnxruntime, fastapi, soundfile; print('ok', kokoro_onnx.__file__)"
# Stamp last, so a failed install never looks cached.
printf '%s\n' "$STAMP" > "$OUT/.yap-runtime-stamp"
echo "[py] done -> $OUT ($(du -sh "$OUT" | cut -f1))"
