#!/usr/bin/env bash
# Build a self-contained Python runtime with Kokoro deps baked in, so the app
# needs NO system Python. Produces dist/python-runtime/ (~270 MB), which
# build_app.sh embeds at Parley.app/Contents/Resources/python.
#
# Uses astral-sh/python-build-standalone (a relocatable CPython). Re-run only
# when deps or the Python version change; the output is cached.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dist/python-runtime"
PYVER_PREFIX="3.12"

if [ -x "$OUT/bin/python3" ] && [ "${1:-}" != "--force" ]; then
  echo "[py] $OUT already built (use --force to rebuild)"
  exit 0
fi

echo "[py] resolving latest python-build-standalone $PYVER_PREFIX (arm64 macOS)"
URL=$(curl -s "https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest" \
  | python3 -c "import sys,json,re;d=json.load(sys.stdin);a=[x['browser_download_url'] for x in d['assets'] if re.search(r'cpython-${PYVER_PREFIX//./\\.}\.\d+\+.*aarch64-apple-darwin-install_only\.tar\.gz\$', x['name'])];print(a[0] if a else '')")
[ -z "$URL" ] && { echo "[py] no matching asset"; exit 1; }
echo "[py] $URL"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -sL -o "$TMP/py.tar.gz" "$URL"
mkdir -p "$TMP/x"
tar -xzf "$TMP/py.tar.gz" -C "$TMP/x"

rm -rf "$OUT"; mkdir -p "$(dirname "$OUT")"
mv "$TMP/x/python" "$OUT"

echo "[py] installing backend deps"
# Build in full isolation: python -I ignores env vars + the user site-packages,
# and pip --isolated ignores pip config files. Without this, pip treats deps
# already present in the builder's ~/.local (or pulled via a stray PYTHONPATH)
# as "satisfied" and skips them, producing a runtime that silently depends on
# the build machine (this bit us: csvw's uritemplate/colorama/jsonschema went
# missing). requirements.txt also pins those three explicitly, belt-and-braces.
"$OUT/bin/python3" -I -m pip install -q --disable-pip-version-check --isolated \
    -r "$ROOT/backend/requirements.txt"

# Trim build fat (tests, caches) to shrink the bundle.
find "$OUT/lib" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$OUT/lib" -type d -name "test" -path "*/python3.12/test" -exec rm -rf {} + 2>/dev/null || true

echo "[py] verifying Kokoro loads from the bundled runtime"
"$OUT/bin/python3" -c "import kokoro_onnx, onnxruntime, fastapi, soundfile; print('ok', kokoro_onnx.__file__)"
echo "[py] done -> $OUT ($(du -sh "$OUT" | cut -f1))"
