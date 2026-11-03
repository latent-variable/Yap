#!/usr/bin/env bash
# Build Yap's self-contained Python runtime from a pinned, SHA-256-verified
# python-build-standalone release. The package installation remains separately
# governed by backend/requirements.txt (dependency locking is future work).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dist/python-runtime"
REQ="$ROOT/backend/requirements.in"
LOCK="$ROOT/backend/requirements.txt"

# A fixed GitHub release + pinned asset digest, published by astral-sh.
# Update both deliberately after reviewing the new release. NEVER resolve
# "latest" during a release build: that silently changes the shipped binary.
PYTHON_ASSET="cpython-3.12.16+20261026-aarch64-apple-darwin-install_only.tar.gz"
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20261026/cpython-3.12.16%2B20261026-aarch64-apple-darwin-install_only.tar.gz"
PYTHON_SHA256="fbf4afef53c2a6b72bb741bc06d5671a9dfaf87bd84e5aa73ac9b3d0d589f14e"

# Prior versions of the script always shipped the arm64 runtime.
if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "[py] this bundle script requires an Apple Silicon Mac" >&2
  exit 1
fi

REQ_SHA256="$(shasum -a 256 "$REQ" | awk '{print $1}')"
LOCK_SHA256="$(shasum -a 256 "$LOCK" | awk '{print $1}')"
STAMP="source=$PYTHON_ASSET sha256=$PYTHON_SHA256 requirements=$REQ_SHA256 lock=$LOCK_SHA256"
if [ -x "$OUT/bin/python3" ] && [ "${1:-}" != "--force" ] && \
   [ -f "$OUT/.yap-runtime-source" ] && \
   [ "$(cat "$OUT/.yap-runtime-source")" = "$STAMP" ]; then
  echo "[py] verified-source build already cached at $OUT (use --force to rebuild)"
  exit 0
fi

echo "[py] downloading pinned runtime $PYTHON_ASSET"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl --fail --location --silent --show-error --retry 3 \
  --output "$TMP/py.tar.gz" "$PYTHON_URL"
echo "$PYTHON_SHA256  $TMP/py.tar.gz" | shasum -a 256 -c -

mkdir -p "$TMP/x"
tar -xzf "$TMP/py.tar.gz" -C "$TMP/x"
[ -x "$TMP/x/python/bin/python3" ] || {
  echo "[py] downloaded archive did not contain the expected interpreter" >&2
  exit 1
}

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
mv "$TMP/x/python" "$OUT"

echo "[py] installing backend dependencies"
# Keep pip detached from the builder's user/system package context.
"$OUT/bin/python3" -I -m pip install -q --disable-pip-version-check --isolated \
    --require-hashes --only-binary=:all: -r "$LOCK"

# Trim build fat.
find "$OUT/lib" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$OUT/lib" -type d -name "test" -path "*/python3.12/test" -exec rm -rf {} + 2>/dev/null || true

echo "[py] verifying bundled imports"
"$OUT/bin/python3" -I -c "import kokoro_onnx, onnxruntime, fastapi, soundfile; print('ok', kokoro_onnx.__file__)"
# Set the cache marker only after dependency installation and validation.
printf '%s\n' "$STAMP" > "$OUT/.yap-runtime-source"
echo "[py] done -> $OUT ($(du -sh "$OUT" | cut -f1))"
