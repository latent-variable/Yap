#!/usr/bin/env bash
# Launch the Parley Kokoro backend. Used by the app and for manual dev runs.
# Creates the venv + installs deps on first run, then serves.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND="$HERE/backend"
SUPPORT="$HOME/Library/Application Support/Parley"
VENV="${PARLEY_VENV:-$SUPPORT/venv}"
PORT="${PARLEY_PORT:-8766}"
MODELS_DIR="${PARLEY_MODELS_DIR:-$SUPPORT/models}"
mkdir -p "$SUPPORT"

if [ ! -x "$VENV/bin/python" ]; then
  echo "[parley] creating venv..."
  if command -v uv >/dev/null 2>&1; then
    uv venv --python 3.12 "$VENV"
    # shellcheck disable=SC1091
    source "$VENV/bin/activate"
    uv pip install -r "$BACKEND/requirements.txt"
  else
    python3 -m venv "$VENV"
    # shellcheck disable=SC1091
    source "$VENV/bin/activate"
    pip install -r "$BACKEND/requirements.txt"
  fi
else
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
fi

export PARLEY_MODELS_DIR="$MODELS_DIR"
exec python "$BACKEND/server.py" --port "$PORT" --models-dir "$MODELS_DIR" \
     --provider "${PARLEY_PROVIDER:-auto}" "$@"
