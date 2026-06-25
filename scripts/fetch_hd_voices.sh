#!/usr/bin/env bash
# Fetch a few clean, openly-licensed reference voices for the HD (Chatterbox)
# engine and install them into ~/Library/Application Support/Yap/hd-voices.
#
# Source: CMU ARCTIC (festvox.org) — studio-quality single-speaker recordings,
# free to use. Each reference is ~5 utterances concatenated (~15s), resampled to
# mono 24 kHz. Requires ffmpeg.
set -euo pipefail

BASE="http://festvox.org/cmu_arctic/cmu_arctic"
DEST="$HOME/Library/Application Support/Yap/hd-voices"
mkdir -p "$DEST"
command -v ffmpeg >/dev/null || { echo "ffmpeg required (brew install ffmpeg)"; exit 1; }

# voice_id : cmu_speaker : description
VOICES=(
  "Aria|slt|US English, female"
  "Clara|clb|US English, female"
  "Ben|bdl|US English, male"
  "Cole|rms|US English, male"
  "Jake|jmk|Canadian English, male"
  "Angus|awb|Scottish English, male"
  "Ravi|ksp|Indian English, male"
)

for entry in "${VOICES[@]}"; do
  IFS='|' read -r vid spk desc <<< "$entry"
  out="$DEST/$vid.wav"
  if [ -f "$out" ]; then echo "[skip] $vid exists"; continue; fi
  echo "[fetch] $vid ($desc) <- cmu_us_$spk"
  tmp="$(mktemp -d)"; list="$tmp/list.txt"
  ok=1
  for n in 0001 0002 0003 0004 0005; do
    f="$tmp/$n.wav"
    if curl -fsS --max-time 30 -o "$f" "$BASE/cmu_us_${spk}_arctic/wav/arctic_a${n}.wav"; then
      echo "file '$f'" >> "$list"
    else ok=0; fi
  done
  if [ "$ok" = 1 ]; then
    ffmpeg -y -f concat -safe 0 -i "$list" -ar 24000 -ac 1 "$out" >/dev/null 2>&1 \
      && echo "  -> $out" || echo "  ffmpeg failed for $vid"
  else
    echo "  download failed for $vid"
  fi
  rm -rf "$tmp"
done
echo "done. Voices in $DEST:"; ls "$DEST"
