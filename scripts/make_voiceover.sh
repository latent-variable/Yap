#!/usr/bin/env bash
# Render the demo voiceover in the HD voice the README ships (Pocket "Philip").
# Wraps make_voiceover.py with the venv + hd-packages on PYTHONPATH so the
# Pocket engine (torch) imports. Output: docs/demo-voiceover.wav
# Override with YAP_VOICEOVER_VOICE / _SPEED / _GAP / _OUT.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/Yap"
PY="$SUPPORT/venv/bin/python"
HD="$SUPPORT/hd-packages"
[ -x "$PY" ] || PY="python3"
[ -d "$HD" ] || { echo "Pocket engine not installed (no $HD). Enable Pocket TTS in Yap once, then retry." >&2; exit 1; }
export PYTHONPATH="$HD:$ROOT/backend"
exec "$PY" "$ROOT/scripts/make_voiceover.py"
