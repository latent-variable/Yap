#!/usr/bin/env python3
"""Render the README/hero demo voiceover in Yap's default HD voice (Pocket "Eve").

Single source of truth for the narration is docs/demo-script.md (the "## Script"
section), so the audio can't drift from the written script. Chunks + natural
pauses go through the same server helpers the app uses, then Pocket/Eve synth,
concatenated to one WAV at docs/demo-voiceover.wav.

Run via scripts/make_voiceover.sh (it wires the venv + hd-packages PYTHONPATH).
"""
import os
import re
import sys
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
SCRIPT_MD = ROOT / "docs" / "demo-script.md"
OUT_WAV = ROOT / "docs" / "demo-voiceover.wav"
VOICE = "eve"          # Yap's default Pocket (HD) voice
GAP_SCALE = 1.0        # multiplier on the inter-chunk pauses


def narration() -> str:
    """Pull the spoken lines from the '## Script' section of demo-script.md."""
    text = SCRIPT_MD.read_text(encoding="utf-8")
    m = re.search(r"^##\s+Script.*?$(.*)", text, re.MULTILINE | re.DOTALL)
    body = m.group(1) if m else text
    # Keep prose paragraphs; drop headings, blockquotes, and code fences.
    lines = [ln.strip() for ln in body.splitlines()
             if ln.strip() and not ln.lstrip().startswith(("#", ">", "`", "-", "*"))]
    return "\n".join(lines).strip()


def main() -> int:
    from server import segment_text, SAMPLE_RATE  # noqa: E402
    from pocket_engine import PocketEngine        # noqa: E402

    text = narration()
    if not text:
        print("no narration text found in", SCRIPT_MD, file=sys.stderr)
        return 1
    print(f"[voiceover] {len(text)} chars -> {VOICE} @ {SAMPLE_RATE} Hz")

    eng = PocketEngine()
    if not eng.load():
        print("[voiceover] Pocket load failed:", eng.error, file=sys.stderr)
        return 1

    pieces: list[np.ndarray] = []
    for chunk, pause in segment_text(text):
        if chunk.strip():
            pieces.append(eng.synth(chunk, VOICE, 1.0).astype(np.float32))
        if pause > 0:
            pieces.append(np.zeros(int(pause * GAP_SCALE * SAMPLE_RATE), np.float32))
    if not pieces:
        print("[voiceover] nothing synthesized", file=sys.stderr)
        return 1

    audio = np.concatenate(pieces)
    peak = float(np.max(np.abs(audio))) or 1.0
    pcm = (np.clip(audio / peak * 0.97, -1.0, 1.0) * 32767).astype("<i2")
    OUT_WAV.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUT_WAV), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm.tobytes())
    print(f"[voiceover] wrote {OUT_WAV}  ({len(audio)/SAMPLE_RATE:.1f}s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
