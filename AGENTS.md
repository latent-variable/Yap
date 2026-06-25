# Agent guide: Yap

For any agent (build, fix, review, extend) working on this repo. Yap gives a
Mac (and the AI agents you work with) **voice and ears**, fully local. Voice:
highlight text anywhere, press a hotkey, hear it in a local Kokoro or Chatterbox
HD voice. Ears: press a shortcut, speak, and local Parakeet STT types the text
at your cursor in any app. No cloud, no account, no telemetry.

## What it is, and where the source lives

Two processes. Neither works without the other.

- **`app/`** — native SwiftUI menu-bar app (SwiftPM executable, not an Xcode
  project). Owns hotkey, text capture, cleanup, audio (voice), **dictation
  (ears)**, settings, UI. Entry point `Sources/Yap/YapApp.swift`; central
  state + read pipeline in `AppState.swift`; dictation in `Dictation.swift` +
  `DictationController.swift`. Module map: `docs/ARCHITECTURE.md`.
- **`backend/server.py`** — local FastAPI sidecar wrapping `kokoro-onnx`.
  Endpoints `/health`, `/voices`, `/synthesize`. Loads Kokoro once, keeps it
  warm. **Voice only** — the ears (STT) run fully in-app on the Apple Neural
  Engine via FluidAudio/Parakeet, no sidecar, no network. This sidecar is the
  only thing that touches the TTS model.

**The contract between them is not a schema — it lives in the code.** Two
pieces an agent must keep in sync if touching either side:

- **Audio is raw int16 mono PCM at 24 kHz**, streamed as
  `application/octet-stream` from `/synthesize` (default, no `?format`).
  `BackendClient.streamPCM` feeds bytes to `AudioPlayer.feed`, which reinterprets
  little-endian int16 → Float32 buffers and schedules them on an
  `AVAudioPlayerNode`. Change the sample rate, channel count, or sample format on
  one side and you must change the other. `?format=wav` returns a full WAV for
  export only.
- **Backend lifecycle is reuse-first.** `BackendManager` probes `/health`; if a
  server already answers, it reuses it and never spawns one. Only if nothing
  answers does it launch `scripts/run_backend.sh`. Don't assume the app owns the
  process it's talking to.

## Two engines (Kokoro + Chatterbox Turbo HD)

`/synthesize` takes an `engine` param: `kokoro` (default) or `chatterbox`. Both
emit the same int16 PCM @ 24 kHz stream, so the app/audio path is engine-agnostic.

- **Kokoro** — `Engine` in `server.py`, ONNX/CPU, bundled, instant. Voices = the
  54 model voices.
- **Chatterbox Turbo HD** — `chatterbox_engine.py`, PyTorch/MPS, **cloning-only**:
  each "voice" is a ~10s reference WAV in `hd-voices/`. Lazy — no torch import
  until first HD use. Gotchas baked in: a global float64→float32 `.to(mps)` patch
  (Metal has no float64, crashes otherwise), a warmup on load (~8s cold, then
  RTF ~0.7), and the real Perth watermark when available.

Key facts an agent must keep straight:
- HD deps are **not** in `requirements.txt` (too heavy). They install on demand
  into `hd-packages/` via `/engines/chatterbox/install`, which **also** installs
  kokoro-onnx + onnxruntime there so ONE process serves both engines. numpy is
  pinned <2; kokoro-onnx's `>=2` pin is conservative and works on 1.26 (verified).
- `BackendManager` adds `hd-packages` to the backend's `PYTHONPATH` when present,
  so numpy 1.26 is used process-wide. Restart the backend after install to load
  the combined env.
- HD is cloning. **Never source or ship celebrity / non-consented voices.** Audio
  is watermarked; the UI says clone only what you have rights to. Starter voices
  are CMU ARCTIC (free); `fetch_hd_voices.sh` / `/voices/hd/starters` fetch them.
- Speed is applied at **playback** (AVAudioUnitTimePitch rate, live-adjustable),
  not the backend — Chatterbox has no speed knob, and this makes speed real-time
  for both engines. The player pre-buffers a cushion (0.35s Kokoro, 0.8s HD)
  before starting, so generation jitter doesn't underrun into silence.
- HD chunking is buffer-aware, not fixed-size. `merge_for_hd` in `server.py` sizes
  each Chatterbox chunk from a measured cost model — `generate(T sec audio) ≈
  0.8 + 0.49·T` on MPS — so its generate time can't outrun the audio already
  queued. The first chunk is small (first audio ~2.2s); later chunks grow as the
  buffer banks, keeping every chunk RTF < 1. This is what makes HD latency
  consistent; if you touch the cost model, re-run `backend/tools/validate_hd_stream.py`
  (real model) and the `TestHDChunking` suite. Profile with `tools/profile_hd.py`.
- @Published writes from the audio-stream callback **must** hop to the main actor
  (`Task { @MainActor in … }`) — doing it off-main updates the menu bar off-main
  and SIGABRTs. This bit us once.

## Ears (dictation — STT, in-app, no backend)

Push-to-talk dictation lives entirely in the app, off the ANE via
[FluidAudio](https://github.com/FluidInference/FluidAudio) — `server.py` is not
involved. `Dictation.swift` owns the mic + models; `DictationController.swift`
owns the hotkey, the floating HUD, and paste-at-cursor.

Two-model design (mirrors FluidVoice), an agent must keep these straight:

- **Streaming model** (Parakeet EOU Flash English / Nemotron multilingual) drives
  the *instant* live transcript — low latency, but lossy (cuts/misses words).
- **Accurate batch model** (Parakeet TDT v2 English / v3 multilingual) does the
  authoritative final pass on stop, and also powers a **rolling preview**:
  `refineLoop` re-transcribes everything-so-far ~1/sec while you talk, published
  as `Dictation.refined`. Sequential passes self-throttle (no pile-up); past the
  180s recorder cap it falls back to the live partial. The concat runs off the
  main actor (`Task.detached`, result wrapped in `SendableBufferBox`); only a
  cheap `frameCount` is read on main.
- **HUD display** = `TranscriptStitch.merge(refined:partial:)`: accurate head +
  live streaming tail, anchored on refined's last two words so the two models'
  differing tokenization doesn't dup/drop at the seam. Pure + unit-tested in
  `--selftest`.
- **Stop serializes the ASR engine:** `stopAndTranscribe` awaits `refineTask`
  before the final pass — both use the same `finalASR` (`AsrManager`), which
  isn't thread-safe.

Gotchas: `@Published` writes from the streaming callback / refine loop must hop
to the main actor. Models download on first dictation into the FluidAudio cache
(`~/Library/Application Support/FluidAudio/Models`), managed from Settings ▸
Models like the TTS engines. Dictation needs Microphone permission.

## Packaging / deployment

The app ships a **self-contained Python runtime** so end users need nothing
installed. `scripts/bundle_python.sh` downloads a relocatable
python-build-standalone CPython, pip-installs `backend/requirements.txt` into it,
and writes `dist/python-runtime/`. `build_app.sh` embeds that at
`Yap.app/Contents/Resources/python`. `BackendManager.bundledPython` prefers it
and spawns `server.py` directly; only a dev checkout with no embedded runtime
falls back to `run_backend.sh` (venv from system Python).

Gatekeeper reality: ad-hoc signed + downloaded-from-browser = quarantine →
"damaged and can't be opened." The app self-strips its own quarantine on launch
(`BackendManager.stripQuarantine`) so the nested Python can spawn, but the main
app still needs `xattr -cr` or notarization. True double-click distribution
requires `scripts/notarize.sh` + a paid Apple Developer ID. Don't claim
"download and run" works frictionless until it's notarized.

## Where state lives (not in the repo)

- venv: `~/Library/Application Support/Yap/venv`
- models: `~/Library/Application Support/Yap/models` (~340 MB, downloaded at
  runtime)

Both are gitignored and machine-local. `scripts/run_backend.sh` builds the venv
on first run (uses `uv` if present, else `python3 -m venv`). Never commit
models, the venv, `.build/`, or `dist/`.

## Build, run, validate

```bash
# backend alone (auto-builds venv first run, then serves on :8766)
bash scripts/run_backend.sh

# build the app bundle and launch it
bash scripts/build_app.sh && open dist/Yap.app

# Swift headless tests: preprocessing + clipboard-restore
cd app && swift build && "$(swift build --show-bin-path)/Yap" --selftest
# Swift full-pipeline probe (clean -> stream) on any file, all profiles:
"$(swift build --show-bin-path)/Yap" --pipetest ../README.md

# backend robustness suite (chunking, synth edges, long docs, providers, export)
cd backend && "$HOME/Library/Application Support/Yap/venv/bin/python" -m pytest tests/ -v

# package a release DMG
bash scripts/make_dmg.sh        # -> dist/Yap-<version>.dmg
```

The pytest suite (`backend/tests/test_tts.py`) is the robustness net: short /
long (10x README ~44k chars) / huge-single-paragraph / unicode+emoji / code /
URLs / punctuation-only / multi-voice / WAV export / provider load. Synthesis
tests skip automatically if model files are absent. The full run is slow
(~8 min) because every case actually synthesizes.

What "validated" means here, in order of confidence:

1. `swift build` (and `-c release`) compiles clean — no warnings.
2. `--selftest` prints `ALL PASS` (covers the cleanup pipeline + profiles).
3. Backend endpoints answer: `curl localhost:8766/health` reports
   `model_loaded: true`; `/synthesize` streams non-empty PCM; `?format=wav`
   produces a playable file (`ffprobe` the duration).
4. The bundled app cold-starts: wipe the venv, launch `/Applications/Yap.app`,
   confirm it spawns its backend and `/health` goes green.

**Audio output and GUI interactions (hotkey, capture, the Settings window) can't
be verified headlessly.** State that plainly in any summary — don't claim a
read-aloud works end to end when only the byte path was checked. Capture needs
Accessibility permission and a real focused app; audio needs an output device.

## Contributing / PRs

Workflow, commit style, and the review/merge cycle follow the user-scope **`review-cycle`** skill (`~/.agents/skills/review-cycle/`) — branch off `main`, validate + test, PR, automated review (`/gemini review` first), severity-gated loop, merge per the gating tiers. Project-specific only:

- If you change the backend payload shape, update `BackendClient` and `AudioPlayer` together and re-run the validation list above.
- Keep the README ~100 lines; long design prose goes in `docs/`. Don't hand-maintain lists `/voices` can print live.

## Releases

Versioned in `app/Resources/Info.plist` (`CFBundleShortVersionString`).
`make_dmg.sh` reads it for the DMG name. Cut a release with the DMG attached:

```bash
gh release create vX.Y.Z dist/Yap-X.Y.Z.dmg --title "..." --notes "..."
# refresh an existing release's binary in place:
gh release upload vX.Y.Z dist/Yap-X.Y.Z.dmg --clobber
```

App is ad-hoc signed, not notarized. Three install paths exist (see README):
Homebrew cask, DMG + `xattr -cr`, build-from-source.

**After every release, bump the Homebrew cask** in the separate
`latent-variable/homebrew-tap` repo (`Casks/yap.rb`): update `version` and
`sha256` (`shasum -a 256 dist/Yap-<v>.dmg`), commit, push. The cask's
`postflight` runs `xattr -cr` so `brew install --cask latent-variable/tap/yap`
installs with no Gatekeeper prompt. Forgetting this leaves brew users on the old
version.

## Acceleration (measured, not assumed)

Provider is selectable: `auto` | `cpu` | `coreml` (Settings ▸ Diagnostics ▸
Acceleration, or `MURMUR_PROVIDER` env → `server.py --provider`). `/health`
reports `active_providers` / `available_providers`.

`auto` resolves to **CPU on purpose.** Kokoro is 82M params; benchmarked on
Apple Silicon the CoreML EP (GPU/ANE) is ~even-to-slightly-slower than the
vectorized CPU EP because most ops fall back to CPU and CoreML adds conversion
overhead (CPU ~1.92s vs CoreML ~1.96s for a one-chunk synth). CPU is the right
"accelerator" here. CoreML stays available as a toggle; CPU is always appended
as the implicit fallback so a CoreML session failure never hard-fails. If you
"enable the GPU," benchmark first — don't assume it's faster.

## Capture (the reliability gotcha)

Default capture mode is **clipboard**, not Accessibility — AX selected-text is
inconsistent across apps. The clipboard path saves the pasteboard, sends ⌘C,
and **only accepts text if `changeCount` actually advanced**, then restores the
original clipboard. It must never return the pre-existing clipboard on a failed
copy — that's what made Yap "read text I didn't select." The
clipboard-restore invariant is covered by `--selftest`; keep it green.

## Services menu ("Read with Yap")

A second entry point besides the hotkey: `NSServices` in `Info.plist` +
`NSApp.servicesProvider = ServiceProvider()` in `YapApp.swift`. macOS hands
the pasteboard text to `ServiceProvider.readWithYap(...)`, which calls
`AppState.readAloud(_:)` — joins the read pipeline at preprocess, no capture.
Gotchas: the provider and `AppDelegate` are `@MainActor` (Services dispatch on
main), the error pointer is optional (never force-deref), and after install you
must refresh the Services DB (`lsregister -f` + `pbs -update`) or the menu item
won't appear.

## Model management (Models tab)

Users can delete/re-download each engine from Settings ▸ Models. Two invariants
an agent must keep:

- **Ownership.** Delete is only safe when the app spawned the backend
  (`BackendManager.ownsProcess`). It can't replace a *reused* server, so deletion
  is hidden/guarded otherwise. Deletes `stopAndWait()` the process (release file
  handles) → remove files → `start()`.
- **Readiness ≠ Kokoro.** `ready` = Kokoro loaded **or** HD on disk, so deleting
  one model doesn't make the backend look dead and `waitForHealth()` doesn't spin
  60s. Kokoro presence is `kokoroFilesPresent` (from `/health`), tracked
  separately from `ready`. After re-downloading Kokoro the running (model-less)
  sidecar must be **restarted**, not just `start()`ed, to load the new files.
- Deleting HD removes `hd-packages` only — **cloned voices (`hd-voices`) are
  kept** — and falls back to the Kokoro engine.

## Standing constraints

- **Fully local. No cloud TTS, no accounts, no analytics, ever.** That's the
  product. Any network call besides the one-time model download is a regression.
- Destructive shell: `trash`, never `rm -rf`/`rm -r`/`rm -f`.
- Default model IDs for any AI work: Opus `claude-opus-4-8`, Sonnet
  `claude-sonnet-4-6`, Haiku `claude-haiku-4-5-20251001`.
- macOS 14+, Apple Silicon. Prefer native APIs (AVFoundation, Carbon hotkey,
  AXUIElement) over adding dependencies.

## Agent context (scope + memory)
<!-- BEGIN agent-context (managed by ~/.agents/bin/project-sync.sh) -->
- You are in **PROJECT scope** (this repo). User-scope canon = `~/.agents` and transcends projects — don't conflate them. `.claude`/`.agents` here may be symlinks; verify with `readlink` before claiming a write landed.
- Project memory + shared skills: `.agents/` (gitignored). Read `.agents/memory/MEMORY.md` first.
- **Commit proactively** (canon doctrine): finished+tested chunk → commit. Commits are free and revertible.
- **Why: nightly audit.** `latent-git-agents` audits only **committed code on the default branch**. Uncommitted / branch-stranded work is invisible to it — no review, no fixes. Finishing work without committing drops it out of coverage; if you leave any uncommitted, flag it to Lino.
- Refresh infra: `~/.agents/bin/project-sync.sh .`
<!-- END agent-context -->
