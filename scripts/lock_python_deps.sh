#!/usr/bin/env bash
# Regenerate the backend's hash locks from their inputs, resolved by the exact
# CPython the app ships (scripts/python_pin.sh) against PyPI only.
#
#   bash scripts/lock_python_deps.sh            # re-lock, keeping existing pins
#   bash scripts/lock_python_deps.sh --upgrade  # re-lock to the newest allowed
#   bash scripts/lock_python_deps.sh --check    # fail if a lock is out of date
#
# Review the version diff before committing; backend/DEPENDENCIES.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=python_pin.sh
. "$ROOT/scripts/python_pin.sh"
MODE="${1:-}"
case "$MODE" in ""|--upgrade|--check) ;; *) echo "usage: $0 [--upgrade|--check]" >&2; exit 2;; esac

# One cache folder per pin, so changing the pin never has to delete the old one.
TOOLS="$ROOT/dist/lock-python-${PYTHON_SHA256:0:12}"
if [ ! -f "$TOOLS/.ready" ]; then
  if [ -e "$TOOLS/python" ]; then
    echo "[lock] $TOOLS is a half-built cache; trash it and re-run" >&2; exit 1
  fi
  echo "[lock] preparing $PYTHON_ASSET + pip-tools"
  mkdir -p "$TOOLS"
  fetch_pinned_python "$TOOLS"
  "$TOOLS/python/bin/python3" -I -m pip install -q --isolated \
    --disable-pip-version-check pip-tools==7.6.2
  touch "$TOOLS/.ready"
fi

export PIP_CONFIG_FILE=/dev/null PIP_INDEX_URL=https://pypi.org/simple
cd "$ROOT"
status=0
CHECK_DIR="$(mktemp -d)"   # macOS clears its temp folder; nothing here is deleted
for name in requirements requirements-pocket; do
  in="backend/$name.in" out="backend/$name.txt" target="backend/$name.txt"
  if [ "$MODE" = "--check" ]; then
    target="$CHECK_DIR/$name.txt"; cp "$out" "$target"
  fi
  flags=(); [ "$MODE" = "--upgrade" ] && flags+=(--upgrade)
  "$TOOLS/python/bin/pip-compile" -q ${flags[@]+"${flags[@]}"} \
    --generate-hashes --allow-unsafe --strip-extras --no-emit-index-url \
    --pip-args="--only-binary=:all:" --output-file="$target" "$in"
  if [ "$MODE" = "--check" ]; then
    # pip-compile writes the output path into the header; compare the pins.
    if ! diff -q <(grep -v '^#' "$out") <(grep -v '^#' "$target") >/dev/null; then
      echo "[lock] $out is out of date with $in; run scripts/lock_python_deps.sh" >&2
      status=1
    fi
  fi
done
[ "$status" = 0 ] && echo "[lock] ok"
exit "$status"
