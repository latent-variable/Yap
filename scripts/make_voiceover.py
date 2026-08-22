#!/usr/bin/env python3
"""Render the README/hero demo voiceover in Yap's default HD voice (Pocket "Eve").

Single source of truth for the narration is docs/demo-script.md (the "## Script"
section), so the audio can't drift from the written script. Chunks + natural
pauses go through the same server helpers the app uses, then Pocket/Eve synth,
concatenated to one WAV at docs/demo-voiceover.wav.

Every chunk is trimmed before the pause is added — see trim_silence(). Pocket
returns each utterance padded with its own leading/trailing silence, and stacking
our gap on top of that is what made the first take drag.

Run via scripts/make_voiceover.sh (it wires the venv + hd-packages PYTHONPATH).
"""
import math
import os
import re
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
SCRIPT_MD = ROOT / "docs" / "demo-script.md"
# Voice and output are overridable so alternate takes can be auditioned without
# touching the committed defaults.
# The take that ships is Lino's cloned "Philip", so that is the default here —
# a script whose output is the committed audio should render the committed audio.
# It is a local reference clip (~/Library/Application Support/Yap/hd-voices), not
# something in the repo, so anyone else renders with a catalog voice:
#   YAP_VOICEOVER_VOICE=eve scripts/make_voiceover.sh
VOICE = os.environ.get("YAP_VOICEOVER_VOICE") or "Philip"
VOICE_EXPLICIT = bool(os.environ.get("YAP_VOICEOVER_VOICE"))
FALLBACK_VOICE = "eve"   # catalog, ships with the model, always resolvable
OUT_WAV = Path(os.environ.get("YAP_VOICEOVER_OUT") or ROOT / "docs" / "demo-voiceover.wav")
GAP_SCALE = float(os.environ.get("YAP_VOICEOVER_GAP") or 1.0)  # multiplier on inter-chunk pauses
# Yap applies speed at PLAYBACK, never in the engine (Pocket ignores its `speed`
# argument entirely — see PocketEngine.synth). So rendering the raw model output
# gives you a take nobody actually hears: it is the 1.0x version of a product
# most people run faster. Reproduce playback with a pitch-preserving stretch over
# the finished file, which is what AVAudioUnitTimePitch does live.
SPEED = float(os.environ.get("YAP_VOICEOVER_SPEED") or 1.25)
# Finite as well as positive: the atempo chain halves until it lands in range, so
# inf would loop forever and nan would never satisfy either bound.
if not math.isfinite(SPEED) or SPEED <= 0:
    raise SystemExit(f"YAP_VOICEOVER_SPEED must be a positive finite number, got {SPEED}")


def narration() -> str:
    """Pull the spoken lines from the '## Script' section of demo-script.md."""
    text = SCRIPT_MD.read_text(encoding="utf-8")
    m = re.search(r"^##\s+Script.*?$(.*)", text, re.MULTILINE | re.DOTALL)
    body = m.group(1) if m else text
    # Keep prose paragraphs; drop headings, blockquotes, and code fences.
    lines = [ln.strip() for ln in body.splitlines()
             if ln.strip() and not ln.lstrip().startswith(("#", ">", "`", "-", "*"))]
    return "\n".join(lines).strip()


def trim_silence(a: np.ndarray, sr: int, pad: float = 0.04) -> np.ndarray:
    """Strip the padding Pocket puts around every utterance.

    The model returns each chunk with its own lead-in and tail — measured at
    0.66-0.91s leading and up to 0.40s trailing, i.e. more dead air than speech
    on a short line like "Meet Yap." Concatenating 20 of those and *then* adding
    the script's own 0.18-0.50s pauses is what turned a 40s script into 61s that
    was 57% silence. Trim first, then the pause you hear is the one the script
    asked for.

    `pad` keeps a few frames of the natural onset/decay so words don't sound
    clipped or butted together.
    """
    if a.size == 0:
        return a
    fl = max(1, int(0.01 * sr))                      # 10 ms frames
    f = a[: len(a) // fl * fl].reshape(-1, fl)
    rms = np.sqrt((f ** 2).mean(axis=1))
    peak = float(np.abs(a).max())
    # Relative to this chunk so a quiet line isn't trimmed to nothing, with an
    # absolute floor so a chunk that is *only* noise doesn't keep all of it.
    thr = max(0.005, peak * 0.02)
    loud = np.flatnonzero(rms >= thr)
    if loud.size == 0:
        return a[:0]
    p = int(pad * sr)
    start = max(0, loud[0] * fl - p)
    end = min(len(a), (loud[-1] + 1) * fl + p)
    return a[start:end]


def main() -> int:
    from server import segment_text, hd_voice_path, SAMPLE_RATE   # noqa: E402
    from pocket_engine import PocketEngine, CATALOG_NAMES         # noqa: E402

    text = narration()
    if not text:
        print("no narration text found in", SCRIPT_MD, file=sys.stderr)
        return 1

    eng = PocketEngine()
    if not eng.load():
        print("[voiceover] Pocket load failed:", eng.error, file=sys.stderr)
        return 1

    # Resolve in the SAME order as _segment_synth, or this renders a different
    # voice than the app speaks: an explicit clone beats a same-named catalog
    # voice while cloning is usable, and the catalog is the fallback otherwise —
    # so a clone called "jane" is the user's jane, not the model's.
    voice, target = VOICE, None
    ref = hd_voice_path(VOICE)
    if ref is not None and eng.has_cloning:
        target = str(ref)
    elif VOICE in CATALOG_NAMES:
        target = VOICE
    else:
        why = ("cloning is not available in this install" if ref is not None
               else f"no reference clip {VOICE}.wav in the hd-voices dir")
        if VOICE_EXPLICIT:
            # Asked for by name — say so instead of quietly speaking as somebody
            # else. Only the *default* falls back.
            print(f"[voiceover] can't use {VOICE!r}: {why}. Catalog voices: "
                  f"{', '.join(sorted(CATALOG_NAMES))}", file=sys.stderr)
            return 1
        # The default is a clone that lives on one machine and is not in the
        # repo, so on any other checkout it simply isn't there. Falling back
        # keeps make_hero_video.sh (which renders the voiceover itself when the
        # WAV is missing) working everywhere — loudly, so nobody ships a
        # different voice than they meant to.
        print(f"[voiceover] {VOICE!r} unavailable ({why}); falling back to "
              f"{FALLBACK_VOICE!r}. The committed take uses {VOICE!r} — set "
              f"YAP_VOICEOVER_VOICE to choose deliberately.", file=sys.stderr)
        voice = target = FALLBACK_VOICE

    print(f"[voiceover] {len(text)} chars -> {voice} @ {SAMPLE_RATE} Hz, {SPEED}x")

    pieces: list[np.ndarray] = []
    spoken = 0.0
    for chunk, pause in segment_text(text):
        if chunk.strip():
            clip = trim_silence(eng.synth(chunk, target, 1.0).astype(np.float32), SAMPLE_RATE)
            spoken += len(clip) / SAMPLE_RATE
            pieces.append(clip)
        if pause > 0:
            pieces.append(np.zeros(int(pause * GAP_SCALE * SAMPLE_RATE), np.float32))
    if not pieces:
        print("[voiceover] nothing synthesized", file=sys.stderr)
        return 1

    audio = np.concatenate(pieces)
    peak = float(np.max(np.abs(audio))) or 1.0
    pcm = (np.clip(audio / peak * 0.97, -1.0, 1.0) * 32767).astype("<i2")
    OUT_WAV.parent.mkdir(parents=True, exist_ok=True)
    # A name derived from OUT_WAV (foo.wav -> foo.raw.wav) is a path we do not own:
    # if something of that name already exists we would overwrite it and then
    # delete it in the finally below. mkstemp gives us a path nothing else holds,
    # in the destination dir so the ffmpeg pass stays on one filesystem.
    if SPEED != 1.0:
        fd, tmp = tempfile.mkstemp(dir=OUT_WAV.parent, suffix=".raw.wav")
        os.close(fd)
        raw = Path(tmp)
    else:
        raw = OUT_WAV
    with wave.open(str(raw), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm.tobytes())
    if SPEED != 1.0:
        # atempo preserves pitch, same as the playback path. One instance only
        # spans 0.5-2.0, so chain them at BOTH ends — a slow take (0.4x) is as
        # out of range as a fast one.
        n, chain = SPEED, []
        while n > 2.0:
            chain.append("atempo=2.0"); n /= 2.0
        while n < 0.5:
            chain.append("atempo=0.5"); n /= 0.5
        chain.append(f"atempo={n:.6f}")
        cmd = ["ffmpeg", "-y", "-loglevel", "error", "-i", str(raw),
               "-filter:a", ",".join(chain), str(OUT_WAV)]
        try:
            subprocess.run(cmd, check=True)
        except (OSError, subprocess.CalledProcessError) as e:
            print(f"[voiceover] speed pass failed ({e}); ffmpeg is required for "
                  f"SPEED != 1.0", file=sys.stderr)
            return 1
        finally:
            raw.unlink(missing_ok=True)   # ours by construction, see mkstemp above
        spoken /= SPEED
    with wave.open(str(OUT_WAV), "rb") as w:
        total = w.getnframes() / w.getframerate()
    print(f"[voiceover] wrote {OUT_WAV}  ({total:.1f}s: {spoken:.1f}s speech, "
          f"{total - spoken:.1f}s pause = {(total - spoken) / total * 100:.0f}%)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
