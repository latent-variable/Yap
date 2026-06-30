# TTS model watchlist

Yap's hard constraints, in priority order:

1. **CPU-only, fast** — must run well on any Apple Silicon Mac with no GPU
   requirement (Kokoro on CPU benchmarks even-to-faster than CoreML; see AGENTS).
2. **Self-contained / ONNX** — no PyTorch/CUDA at runtime, bundles into the app.
3. **Permissive license** — Apache/MIT (this ships in a distributable app).
4. **Multiple natural English voices** out of the box. (Voice cloning was a
   non-goal for the default; the opt-in engine now provides it.)

A replacement has to **beat Kokoro on quality without losing 1–3.** Nothing does
on the CPU axis for the *bundled* path. So instead of replacing Kokoro, we
**added a second, opt-in engine** for when quality matters more than instant/light:

- **Kokoro** stays the default — instant, CPU, bundled, 54 voices.
- **Pocket TTS** (Kyutai) is the opt-in engine — and it upended the assumption
  below that "HD = GPU." It's **CPU**, ~10× realtime on Apple Silicon, ~1 GB
  on-demand download. 26 natural built-in voices (ungated, no account) plus
  **voice cloning** from a ~20s reference (gated model — the user supplies their
  own Hugging Face token + accepts the Pocket terms; no watermark). It replaced
  Chatterbox Turbo HD, which needed the GPU (MPS) and stuttered under contention.
  See AGENTS.md "Two engines" for integration details.

The rest of this file remains the watchlist for future candidates. **Note:**
several sections below predate the Pocket decision and assume an HD engine must
be GPU-class; Pocket disproved that. Kept as historical survey.

## Current

| | |
|---|---|
| Model | **Kokoro-82M** (`kokoro-onnx`, v1.0) |
| Runtime | ONNX, CPU, ~0.2s first-audio, RTF well under 1 |
| License | Apache-2.0 (weights), model code Apache/MIT |
| Voices | 54 across 8 languages, no cloning |
| Why | Best quality-per-CPU-cost with a permissive license and many voices |

## Candidates

### Same class (CPU/ONNX — real swap options)
| Model | Size | License | vs Kokoro | Verdict |
|---|---|---|---|---|
| **Piper** | small | MIT | Faster (RTF ~0.008) but more robotic/flat | Keep as a low-latency fallback, not an upgrade |
| **Kitten TTS** | ~25 MB (int8) | Apache-2.0 | Tiny; slower than Piper, quality ≈ or < Kokoro | **Watch** — promising footprint, immature |
| **MatchaTTS** | small | MIT | CPU ONNX; quality sidegrade | Watch |

### Quality leaders — specs
Reference for the opt-in "HD" engine. We assumed this tier needed a GPU; **Pocket
TTS shipped as the choice and runs on CPU**, so the "GPU-class" label is historical.

| Model | Params | Weights size | Quality | Extras | License |
|---|---|---|---|---|---|
| **Pocket TTS** ✅ *chosen* | ~100M | ~1 GB (torch) | excellent, ~10× RT on CPU | 26 voices + clone; gated cloning model | MIT (catalog); cloning weights gated |
| Kokoro (baseline) | 82M | ~310 MB ONNX | good | 54 voices, no clone | Apache-2.0 |
| **Chatterbox** | 0.5B | ~1–2 GB | SoTA open, expressive | emotion control, zero-shot clone, 23 langs | MIT |
| **Chatterbox-Turbo** | 350M | smaller | high (distilled 1-step decoder) | clone; RTF ~0.5 on RTX 4090 | Resemble |
| **Qwen3-TTS** | 0.6B–1.7B | ~1.5–4 GB | excellent, streaming | voice design + clone, GGUF builds exist | Apache-2.0 |
| **CosyVoice 2/3** | ~0.5B (Qwen2.5-0.5B backbone) | ~1–2 GB | excellent, streaming | clone | Apache-2.0 |
| **F5-TTS** | 336M | ~1.3 GB | strong | DiT diffusion (slower, multi-step), clone | permissive |
| **Sesame CSM-1B** | 1B + 100M decoder | ~2 GB | top realism (conversational) | only the 1B of 3 sizes open-sourced | Apache-2.0 |

VRAM/latency quotes are NVIDIA (e.g. Chatterbox ~2–3 GB VRAM, sub-200ms; Turbo RTF 0.499 on a 4090). **They do not transfer to Mac.**

### Apple Silicon reality (this is our GPU)
- "GPU" on a Mac = Metal. The fast path is **MLX** (`mlx-audio`, Blaizzy) — highest sustained TTS throughput on Apple Silicon; supports Kokoro and others. PyTorch **MPS** works but is memory-constrained and slower; CUDA-only optimizations don't apply.
- These models are PyTorch/transformers, **not ONNX** → can't bundle cleanly, need a multi-GB download, slower cold start. That's why they're "HD mode, opt-in," not the default.
- HD mode shipped: **Pocket TTS** (Kyutai), and it sidesteps this section's GPU framing entirely by running fast on **CPU** (~10× realtime). The earlier prototype shortlist (Chatterbox, Qwen3-TTS) is moot; Pocket won on speed, quality, and packaging (no MPS contention).

## What would make us switch

The "optional higher-quality mode" question is **resolved** — we shipped Pocket
TTS as the opt-in HD engine (CPU, cloning, no watermark). Remaining triggers to
revisit:

- A CPU/ONNX model with a permissive license that clearly out-naturals Kokoro at
  comparable speed (would upgrade the *default*), **or**
- A higher-quality opt-in engine that drops Pocket's cloning gate (no HF token /
  terms) while matching its CPU speed and fidelity.

## How a swap would actually work (low cost)

The backend already isolates the model behind `Engine` in `server.py`, and the
app only speaks the HTTP contract (int16 PCM stream). Adding a model =

1. New `Engine` subclass/branch that loads the candidate and implements
   `synth(text, voice, speed, lang) -> float32 ndarray @ 24 kHz`.
2. A downloader entry for its weights.
3. A provider/engine selector (like the CPU/CoreML one).

No app changes needed beyond a picker. So tracking is cheap and migrating is a
backend-local change — revisit this file when a candidate graduates from "watch."

_Last reviewed: 2026-06-30 (Pocket TTS shipped as the HD engine)._
