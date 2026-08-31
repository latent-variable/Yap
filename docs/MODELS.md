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
| Runtime | ONNX, CPU | PyTorch, **CPU**, ~10× realtime |
| Size | ~340 MB, first-launch download | ~1 GB, on-demand download |
| Voices | 54 across 8 languages | 26 built-in, no account |
| Cloning | no | yes, from a ~20s reference |
| License | Apache-2.0 | CC-BY-4.0 (Kyutai), catalog + cloning |
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
- An opt-in engine matching Pocket's CPU speed and fidelity on a permissive
  license → would replace Pocket. (Pocket's own cloning gate is no longer a
  reason: the weights are CC-BY-4.0 and Yap mirrors them, so no account is
  involved.)

Adding one starts in the backend: an `Engine` branch in `server.py` implementing
`synth(text, voice, speed, lang) -> float32 ndarray @ 24 kHz`, a downloader entry
for its weights, and a selector entry. The audio path needs nothing, because every
engine speaks the same HTTP contract (int16 PCM stream). The Swift side is where
the rest of the work is: `Prefs.engine` persists `"kokoro" | "pocket"` against a
separate voice slot per engine (`voice` / `hdVoice`), and `AppState` branches on
`"pocket"` by name throughout (`activeVoice`, `selectVoice`, `combinedVoices`, and
the install / warm / offload paths). A third engine means generalizing that
routing first.

_Last reviewed: 2026-08-31._
