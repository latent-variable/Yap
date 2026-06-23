"""End-to-end HD streaming validation against the REAL model.

Runs merge_for_hd on sample texts, generates each chunk for real on MPS, and
replays the streaming timeline with the measured (not modelled) generate times
to confirm: fast first audio + no buffer underrun (gaps).

  PYTHONPATH="$HOME/Library/Application Support/Parley/hd-packages" \
    python3 backend/tools/validate_hd_stream.py
"""
import sys
import time
from pathlib import Path

HD = Path.home() / "Library/Application Support/Parley/hd-packages"
sys.path.insert(0, str(HD))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # backend/ for server

import torch
_orig_to = torch.Tensor.to
def _safe_to(self, *a, **k):
    dev = k.get("device") or next((x for x in a if isinstance(x, (str, torch.device)) and "mps" in str(x)), None)
    if dev is not None and "mps" in str(dev) and self.dtype == torch.float64:
        self = _orig_to(self, torch.float32)
    return _orig_to(self, *a, **k)
torch.Tensor.to = _safe_to

sys.argv = ["x"]
from server import segment_text, merge_for_hd
from chatterbox.tts_turbo import ChatterboxTurboTTS

_refs = sorted((Path.home() / "Library/Application Support/Parley/hd-voices").glob("*.wav"))
if not _refs:
    sys.exit("no HD reference voices in ~/Library/Application Support/Parley/hd-voices — "
             "add one (or run the starter-voices fetch) before profiling.")
REF = _refs[0]
dev = "mps" if torch.backends.mps.is_available() else "cpu"
m = ChatterboxTurboTTS.from_pretrained(device=dev)
m.prepare_conditionals(str(REF))
m.generate("Warm up the graph.")  # compile once

SAMPLES = {
    "readme": "Parley reads selected text aloud. Press the hotkey and it speaks. It "
              "works fully offline. Kokoro is the default engine, fast and light. "
              "Chatterbox Turbo is the optional HD engine, cloning any voice from a "
              "short clip. Both stream as you listen, so you start hearing it fast.",
    "ocean": "The deep ocean is the largest habitat on Earth. Below the sunlit zone "
             "lies a world of perpetual darkness. Yes. Strange life thrives there, "
             "needing no sun at all.\n\nWe have mapped less of it than Mars.",
}

for name, text in SAMPLES.items():
    chunks = merge_for_hd(segment_text(text))
    print(f"\n=== {name}: {len(chunks)} chunks ===")
    real = []
    for txt, gap in chunks:
        t0 = time.time()
        wav = m.generate(txt)
        if dev == "mps":
            torch.mps.synchronize()
        gen = time.time() - t0
        audio = wav.shape[-1] / m.sr + gap   # gap silence streams too
        real.append((len(txt), gen, audio))

    # replay timeline with REAL gen times
    t = play_start = buf_end = 0.0
    first = None
    min_slack = float("inf")
    for i, (chars, gen, audio) in enumerate(real):
        t += gen
        if first is None:
            first = play_start = t
            buf_end = t + audio
        else:
            slack = buf_end - t
            min_slack = min(min_slack, slack)
            buf_end = (t + audio) if slack < 0 else buf_end + audio
        rtf = gen / audio
        print(f"  chunk {i}: {chars:>3}c  gen {gen:4.2f}s  audio {audio:4.2f}s  RTF {rtf:.2f}")
    tag = "NO GAPS" if min_slack >= 0 else f"UNDERRUN {min_slack:.2f}s"
    print(f"  -> first audio {first:.2f}s   min slack {min_slack:+.2f}s   [{tag}]")
