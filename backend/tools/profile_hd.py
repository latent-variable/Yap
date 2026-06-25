"""Profile Chatterbox Turbo stage timings on this machine.

Breaks one generate() into: tokenize, AR prefill+decode (t3), vocode (s3gen),
watermark. Reports per-stage seconds, token count, audio seconds, RTF — across
a range of text lengths — so chunk sizing can be grounded in measurement, not
guesswork.

Run:
  PYTHONPATH="$HOME/Library/Application Support/Yap/hd-packages" \
    python3 backend/tools/profile_hd.py
"""
import os
import sys
import time
from pathlib import Path

HD = Path.home() / "Library/Application Support/Yap/hd-packages"
if str(HD) not in sys.path:
    sys.path.insert(0, str(HD))

import numpy as np
import torch

# Metal has no float64 — downcast on ->mps (same patch the engine uses).
_orig_to = torch.Tensor.to
def _safe_to(self, *a, **k):
    dev = k.get("device")
    if dev is None:
        for x in a:
            if isinstance(x, (str, torch.device)) and "mps" in str(x):
                dev = x
                break
    if dev is not None and "mps" in str(dev) and self.dtype == torch.float64:
        self = _orig_to(self, torch.float32)
    return _orig_to(self, *a, **k)
torch.Tensor.to = _safe_to

from chatterbox.tts_turbo import ChatterboxTurboTTS, punc_norm
from chatterbox.models.s3gen.const import S3GEN_SIL

VOICES = Path.home() / "Library/Application Support/Yap/hd-voices"
_refs = sorted(VOICES.glob("*.wav"))
if not _refs:
    sys.exit(f"no HD reference voices in {VOICES} — add one (or run the starter-voices "
             "fetch) before profiling.")
REF = _refs[0]

dev = "mps" if torch.backends.mps.is_available() else "cpu"
print(f"device={dev}  ref={REF.name}")

t0 = time.time()
m = ChatterboxTurboTTS.from_pretrained(device=dev)
print(f"load: {time.time()-t0:.2f}s")

t0 = time.time()
m.prepare_conditionals(str(REF))
print(f"prepare_conditionals: {time.time()-t0:.2f}s")

def mps_sync():
    if dev == "mps":
        torch.mps.synchronize()

def stage_timed(text):
    """Mirror generate() but time each stage."""
    t = {}
    s = time.time()
    text = punc_norm(text)
    tok = m.tokenizer(text, return_tensors="pt", padding=True, truncation=True)
    tok = tok.input_ids.to(m.device)
    mps_sync()
    t["tokenize"] = time.time() - s

    s = time.time()
    speech_tokens = m.t3.inference_turbo(
        t3_cond=m.conds.t3, text_tokens=tok,
        temperature=0.8, top_k=1000, top_p=0.95, repetition_penalty=1.2,
    )
    mps_sync()
    t["ar_decode"] = time.time() - s
    n_tok = int(speech_tokens.shape[-1])

    speech_tokens = speech_tokens[speech_tokens < 6561].to(m.device)
    sil = torch.tensor([S3GEN_SIL]*3).long().to(m.device)
    speech_tokens = torch.cat([speech_tokens, sil])

    s = time.time()
    wav, _ = m.s3gen.inference(speech_tokens=speech_tokens, ref_dict=m.conds.gen, n_cfm_timesteps=2)
    mps_sync()
    t["vocode"] = time.time() - s
    wav = wav.squeeze(0).detach().cpu().numpy()

    s = time.time()
    m.watermarker.apply_watermark(wav, sample_rate=m.sr)
    t["watermark"] = time.time() - s

    audio_s = len(wav)/m.sr
    return t, n_tok, audio_s

texts = [
    "Yes.",
    "Short one.",
    "This is a medium length sentence with a few clauses in it.",
    "The deep ocean is the largest habitat on Earth, yet we have mapped only a small fraction of it.",
    "The deep ocean is the largest habitat on Earth, yet we have mapped less of it than the surface of Mars. "
    "Below the sunlit zone lies a world of perpetual darkness, crushing pressure, and strange life that needs no sun.",
]

print(f"\n{'chars':>5} {'tokens':>6} {'audio':>6} {'tok':>5} {'ar':>6} {'voc':>6} {'wm':>5} {'total':>6} {'RTF':>5}")
for txt in texts:
    # warm this length once (MPS compiles new shapes), then measure 2nd run
    stage_timed(txt)
    t, n_tok, audio_s = stage_timed(txt)
    total = sum(t.values())
    print(f"{len(txt):>5} {n_tok:>6} {audio_s:>5.1f}s {t['tokenize']:>4.2f} "
          f"{t['ar_decode']:>5.2f} {t['vocode']:>5.2f} {t['watermark']:>4.2f} "
          f"{total:>5.2f} {total/max(audio_s,0.01):>4.2f}")
