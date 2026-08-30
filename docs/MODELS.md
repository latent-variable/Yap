# TTS engine decision record

Yap's hard constraints for the **bundled default**, in priority order:

1. **CPU-only, fast** — must run well on any Apple Silicon Mac with no GPU
   requirement (Kokoro on CPU benchmarks even-to-faster than CoreML; see AGENTS).
2. **Self-contained / ONNX** — no PyTorch/CUDA at runtime, bundles into the app.
3. **Permissive license** — Apache/MIT (this ships in a distributable app).
4. **Multiple natural English voices** out of the box.

Nothing beats Kokoro on that set. So rather than replace it, Yap ships a second,
**opt-in** engine for when quality matters more than instant-and-light.

## What shipped

| | Kokoro (default) | Pocket TTS (opt-in) |
|---|---|---|
| Runtime | ONNX, CPU, bundled | PyTorch, **CPU**, ~10× realtime |
| Size | ~310 MB, ships with the app | ~1 GB, on-demand download |
| Voices | 54 across 8 languages | 26 built-in (ungated) |
| Cloning | no | yes, from a ~20s reference |
| License | Apache-2.0 | MIT catalog; cloning weights gated |
| First audio | ~0.2s | cold load, then fast |

Pocket cloning needs one extra model file (209 MB). Yap fetches it from its own
CC-BY-4.0 mirror of Kyutai's weights and verifies the pinned SHA256 before use,
so there is no account, no token and no terms click. Kyutai's acceptable-use
terms still apply: clone only voices you have the right to use.

## Why Pocket, and what it settled

Pocket replaced a Chatterbox Turbo HD prototype that needed the GPU (MPS) and
stuttered under contention. It won on speed, quality and packaging at once.

It also killed the assumption the earlier survey was built on — that a
higher-quality engine has to be GPU-class. On a Mac "GPU" means Metal, the fast
path is MLX, and PyTorch MPS is both slower and memory-constrained. Pocket
sidesteps all of it by being fast enough on CPU, which is why the GPU-tier
shortlist (Chatterbox, Qwen3-TTS, CosyVoice, F5-TTS, Sesame CSM) is moot and no
longer tracked here. NVIDIA latency and VRAM numbers never transferred to a Mac
anyway.

## What would make us revisit

- A CPU/ONNX model with a permissive license that clearly out-naturals Kokoro at
  comparable speed → would upgrade the **default**. Piper (faster, flatter),
  Kitten TTS and MatchaTTS were the closest and none of them qualified.
- An opt-in engine matching Pocket's CPU speed and fidelity **without** the
  cloning gate → would replace Pocket.

Adding one is backend-local: an `Engine` branch in `server.py` implementing
`synth(text, voice, speed, lang) -> float32 ndarray @ 24 kHz`, a downloader entry
for its weights, and a selector entry. The app only speaks the HTTP contract
(int16 PCM stream), so it needs no change beyond the picker.

_Last reviewed: 2026-08-22._
