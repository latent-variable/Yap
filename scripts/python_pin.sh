# The one CPython Yap ships and locks its dependencies against. Sourced by
# bundle_python.sh and lock_python_deps.sh. Change all three values together,
# after checking the digest against the release's own SHA256SUMS.
PYTHON_ASSET="cpython-3.12.16+20261026-aarch64-apple-darwin-install_only.tar.gz"
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20261026/cpython-3.12.16%2B20261026-aarch64-apple-darwin-install_only.tar.gz"
PYTHON_SHA256="fbf4afef53c2a6b72bb741bc06d5671a9dfaf87bd84e5aa73ac9b3d0d589f14e"

# fetch_pinned_python <dest-dir>: download, verify, extract to <dest-dir>/python.
# <dest-dir> must exist and must not already hold a python/.
fetch_pinned_python() {
  local dest="$1" tmp
  if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "[py] the pinned runtime is Apple Silicon only" >&2
    return 1
  fi
  # Work inside dest, so the caller's own cleanup (or cache) owns the download.
  tmp="$dest/.fetch"
  mkdir -p "$tmp"
  curl --fail --location --silent --show-error --retry 3 \
    --output "$tmp/py.tar.gz" "$PYTHON_URL"
  echo "$PYTHON_SHA256  $tmp/py.tar.gz" | shasum -a 256 -c - >/dev/null || {
    echo "[py] SHA-256 mismatch for $PYTHON_ASSET" >&2; return 1; }
  mkdir -p "$tmp/x"
  tar -xzf "$tmp/py.tar.gz" -C "$tmp/x"
  [ -x "$tmp/x/python/bin/python3" ] || {
    echo "[py] archive did not contain bin/python3" >&2; return 1; }
  mv "$tmp/x/python" "$dest/python"
}
