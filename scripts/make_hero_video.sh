#!/usr/bin/env bash
# Build the README/hero video: the static hero image with the HD-voice demo
# narration (Pocket "Eve") playing over it. No screen recording — just a mux.
# Renders the voiceover first if it's missing. Output: docs/yap-readme.mp4
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="$ROOT/docs/yap-hero.png"
WAV="$ROOT/docs/demo-voiceover.wav"
OUT="$ROOT/docs/yap-readme.mp4"

command -v ffmpeg >/dev/null || { echo "ffmpeg required (brew install ffmpeg)" >&2; exit 1; }
[ -f "$IMG" ] || { echo "missing hero image: $IMG" >&2; exit 1; }
[ -f "$WAV" ] || { echo "[hero] rendering voiceover first"; bash "$ROOT/scripts/make_voiceover.sh"; }

echo "[hero] muxing $IMG + $(basename "$WAV") -> $(basename "$OUT")"
# Pin the output to the audio length so the still image can't run past it
# (a bare -shortest can overshoot by a GOP, leaving a few silent seconds).
ADUR="$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$WAV")"
ffmpeg -y -loop 1 -i "$IMG" -i "$WAV" -t "$ADUR" \
  -c:v libx264 -tune stillimage -pix_fmt yuv420p -r 10 \
  -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
  -c:a aac -b:a 192k -movflags +faststart \
  "$OUT" >/dev/null 2>&1

DUR="$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$OUT" 2>/dev/null || echo '?')"
SIZE="$(ls -lh "$OUT" | awk '{print $5}')"
echo "[hero] wrote $OUT  (${DUR}s, $SIZE)"
