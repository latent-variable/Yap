# Agent guide: Yap

For any agent (build, fix, review, extend) working on this repo. Yap gives a
Mac (and the AI agents you work with) **voice and ears**, fully local. Voice:
highlight text anywhere, press a hotkey, hear it in a local Kokoro or Pocket TTS
voice. Ears: press a shortcut, speak, and local Parakeet STT types the text
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
- **A completed PCM stream ends with `STREAM_FOOTER` (`b"YEND"`) — the read's
  verdict, not audio.** The client strips it and throws when it is missing, but
  only when the response carries `X-Stream-Footer` (an older sidecar doesn't, and
  must still work). Withhold it on any failure; never let a truncated read finish
  clean. Why a footer and not an abort: `docs/ARCHITECTURE.md`.
- **Backend lifecycle is reuse-first, but a responding backend is not always
  left alone.** `BackendManager` reuses one that answers `/health` *and* proves
  itself via `/verify`; an unverified Yap orphan or a verified-but-not-ready one
  gets stopped and relaunched, and an unverified foreign listener is refused
  outright. `ownsProcess` means "we may end this process", not "we started it".
  The full decision table: `docs/ARCHITECTURE.md`.

## Two engines (Kokoro + Pocket TTS)

`/synthesize` takes an `engine` param: `kokoro` (default) or `pocket`. Both emit
the same int16 PCM @ 24 kHz stream, so the app/audio path is engine-agnostic.

- **Kokoro** — `Engine` in `server.py`, ONNX/CPU, bundled, instant. Voices = the
  54 model voices.
- **Pocket TTS** (Kyutai) — `pocket_engine.py`, PyTorch/**CPU**, ~10x realtime.
  Replaced Chatterbox. One model family, two modes:
  - **Catalog voices** (built-in, no account): 26 predefined speakers from the
    *ungated* `kyutai/pocket-tts-without-voice-cloning` weights. A catalog name
    (e.g. `michael`) is passed straight to `get_state_for_audio_prompt`.
  - **Cloning** (opt-in, no account): clone any ~20s reference WAV in `hd-voices/`.
    Kyutai's cloning weights are CC-BY-4.0, so Yap fetches a byte-identical mirror
    (`CLONING_WEIGHTS_URL`) and checks the pinned SHA256 before use. **No HF
    account, no token, no Keychain** — that path is gone, `Keychain.swift` with it.
    A cloned-voice request with cloning off still returns **403**.
  - **Don't remove `_restore_language_origin()`.** Loading through our own config
    silently breaks all 26 catalog voices while cloning keeps working. Mechanism
    and the rest of the weights pipeline: `docs/ARCHITECTURE.md`. Test:
    `test_catalog_voices_survive_a_custom_config`.
  Lazy — no torch import until first Pocket use; per-voice conditioning cached;
  inference serialized by a lock.

Key facts an agent must keep straight:
- Pocket deps are **not** in `requirements.txt` (too heavy, pulls torch ~1 GB).
  They install on demand into `hd-packages/` via `/engines/pocket/install`, which
  **also** installs kokoro-onnx + onnxruntime there so ONE process serves both
  engines, and fetches the cloning weights (+209 MB) into `pocket-weights/`.
  `/engines/pocket/cloning/install` does the weights alone, for a retry or for
  someone who installed Pocket before they existed. Pocket pulls numpy ≥2; kokoro-onnx imports fine on it (verified).
- `BackendManager` adds `hd-packages` to the backend's `PYTHONPATH` when present
  (FIRST, so its torch/numpy win). It injects no credentials of any kind. Restart
  the backend after installing the engine or the cloning weights: Pocket resolves
  its config once at load.
- Cloning. **Never source or ship celebrity / non-consented voices.** The UI says
  clone only what you have rights to (Pocket has no built-in watermark, unlike the
  old Chatterbox). Starter voices are CMU ARCTIC (free); `/voices/hd/starters`
  fetches them. (Internal Swift identifiers still use the `hd*` prefix — `hdVoice`,
  `hdInstalled`, `installHD` — they now denote the Pocket engine.)
- **A selected cloned voice must survive restart.** `refreshHD` demotes a cloned
  `hdVoice` to a catalog default ONLY when cloning is *genuinely* unavailable —
  the model **loaded** and `cloning` still came back off (weights absent + no
  weights not installed). It keys on the loaded `cloning` verdict, **NOT**
  `cloning_installed`: the engine is lazy, so the weights are on disk before they
  are loaded (`cloning_installed=true` yet `cloning=false`), and a disk check would
  wrongly demote a working clone. It must NOT demote during the lazy warm-up
  window (Pocket loads on first use, so `cloning` reads false before `warmHD`
  loads it) — that silently reset the user's clone on every launch.
- **Pocket output is trimmed before it leaves the engine** (`trim_padding`): the
  model pads every utterance with its own silence, and playing that is what makes
  the `GAP_*` constants mean different things on the two engines. It only ever
  removes, and never empties a clip it can't read. Measurements and the detector:
  `docs/ARCHITECTURE.md`.
- Speed is applied at **playback** (AVAudioUnitTimePitch rate, live-adjustable),
  not the backend — parity across engines. The player pre-buffers a 0.35s cushion
  (both engines now; Pocket is fast enough not to need the old HD buffer logic).
- Pocket is fast enough for the plain per-segment pipeline — the Chatterbox
  buffer-aware HD chunking (`merge_for_hd` + cost model) and its tools/tests were
  removed.
- **Memory: only the active engine stays resident.** Both engines used to sit
  loaded at once (~1 GB with Pocket/torch). `POST /engines/{name}/unload` frees
  one; the app offloads the *inactive* engine when you switch (but never mid-read —
  it guards on `status`). Both synth paths lazily reload on the next read, so
  offload is safe. The "Pre-load Pocket at launch" pref keeps Pocket hot even on
  Kokoro (memory-for-latency opt-in), so offload skips it then.
- **The audio engine is parked when idle.** `AudioPlayer.stop()` (and read
  completion + the error path) call `engine.stop()`, not just `player.stop()` —
  otherwise the `AVAudioEngine` render thread + its `AUScheduledParameterRefresher`
  spin **continuously at ~7-8% CPU** after the first read, forever. `start()`/
  `resume()` restart it (the 0.35s cushion hides the latency); `start()` **throws**
  on engine-start failure so a dead engine can't schedule buffers that never play
  and hang the drain loop in "Reading". `active` stops a route change from waking a
  parked engine. Regression test: `--selftest` "engine parks when idle".
- **The read stream is backpressured; keep it that way.** Both engines generate
  far faster than realtime (measured on the README: Kokoro 9.1x, Pocket 14.4x), so
  an ungated read queues the *whole document* onto the player node ahead of the
  listener — 2,950 buffers / 57 MB for 11 minutes of audio, ~19,850 / 381 MB at
  46k chars. `AppState.streamGate` → `AudioPlayer.gate` stalls the reader above
  `AudioPlayer.maxQueuedSeconds` (10s), which also makes the gate the **only**
  place a superseded read is torn down: returning `false` abandons the
  `AsyncBytes` sequence, cancelling the URLSession task so the backend stops
  synthesizing (verified: 767% → 0% CPU within 3s). `generation` alone only
  *ignores* arriving bytes. Regression test: `--backpressure`.
- **Backpressure makes the connection outlive the response, so the server must
  hold it open for the whole read.** Reading at playback rate means a body the
  backend finished writing is still draining out of the socket for as long as it
  takes to *hear* it; uvicorn's 5s `timeout_keep_alive` closes it mid-drain and
  the app silently loses the tail. `server.py` sets `KEEP_ALIVE`, and the comment
  there carries the measurement — don't restore the default. Tests: `--tailtest`
  end-to-end, `TestKeepAlive` for the setting.
- @Published writes from the audio-stream callback **must** hop to the main actor
  (`Task { @MainActor in … }`) — doing it off-main updates the menu bar off-main
  and SIGABRTs. This bit us once.
- **CLI probes that park the run loop run from `YapMain`, not the app delegate.**
  `--pipetest` / `--backpressure` / `--tailtest` end in `dispatchMain()`; started from
  `applicationDidFinishLaunching` they SIGTRAP on
  `NSViewIsCurrentlyBuildingLayerTreeForDisplay` because the MenuBarExtra's layer
  tree is mid-build. Flags that just print and `exit(0)` are fine where they are.

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
# Streaming backpressure probe (real player + gate vs the live backend, 25s):
"$(swift build --show-bin-path)/Yap" --backpressure ../README.md
# Does a read survive to its LAST word? (runs in realtime — 1500 chars ≈ 2 min)
"$(swift build --show-bin-path)/Yap" --tailtest ../README.md 1500 [port]

# backend robustness suite — fast set (every code path, one cheap case each)
cd backend && "$HOME/Library/Application Support/Yap/venv/bin/python" -m pytest tests/ -q
# ...and the full net, incl. scale synthesis + Pocket/torch + CoreML (~17 min, pegs the CPU)
cd backend && "$HOME/Library/Application Support/Yap/venv/bin/python" -m pytest tests/ -q --runslow

# package a release DMG
bash scripts/make_dmg.sh        # -> dist/Yap-<version>.dmg
```

The pytest suite (`backend/tests/test_tts.py`) is the robustness net: short /
long (10x README ~44k chars) / huge-single-paragraph / unicode+emoji / code /
URLs / punctuation-only / multi-voice / WAV export / provider load. Synthesis
tests skip automatically if model files are absent.

**The heaviest cases are marked `slow` and are OFF by default.** The default set
covers the pure logic, single- and multi-chunk Kokoro synthesis, WAV export and
the stream contract. It does **not** touch the Pocket engine, the CoreML
provider, or the non-English voice families — `--runslow` is the only thing that
runs those, so treat a green default run as silence about them, not a pass. Run
it before cutting a release, and whenever you touch synthesis, chunking, the
Pocket engine or the provider path. Which cases, and why each:
`backend/conftest.py`.

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

Review/merge follows the user-scope **`review-cycle`** skill. Project-specific only:

- If you change the backend payload shape, update `BackendClient` and `AudioPlayer` together and re-run the validation list above.
- Keep the README ~100 lines; long design prose goes in `docs/`. Don't hand-maintain lists `/voices` can print live.

**Don't flag (reviewers): `Task {}` inside `AppState` is already on the main actor.** `AppState` is a `@MainActor` class, so every method is main-actor-isolated and a plain `Task { … }` created inside one **inherits main-actor isolation** — its body, including `@Published` reads/writes (`prefs.*`, `hdWarm`, `cloningReady`, `warming`), runs on the main actor. This is **not** the off-main audio-stream callback the "hop to `@MainActor`" note in the Pocket section warns about (that's a real-time AVFoundation thread). Shipped precedent: `refreshHD`. So "off-main `@Published` access / data race" on such a `Task {}` is a false positive — don't raise it.

## Local test builds (after every merge — standing)

A merged code change is invisible to Lino until it's a running build on his Mac.
So **after merging any code change, cut a fresh local build and install it** so
he can test the actual behavior — don't leave him on the old bundle. This is the
default, not a thing to ask about. (A public release — DMG + Homebrew — stays a
separate, gated step; this is only the local install for testing.)

**Use `scripts/install_local.sh` — do NOT hand-run build + ditto + open.** The
naive recipe silently installs stale code and litters Launchpad with duplicate
icons, because:

- **`open` re-focuses a still-running old instance** instead of launching the new
  bundle. `ditto`/`trash` swap the bundle on disk, but the old *process* keeps
  running the old binary, so `open` (which matches by bundle id) just activates
  it. You test 3-day-old code and wonder why your change isn't there. (This
  actually bit us — a Jul-3 process survived under a replaced Jul-6 bundle.)
- **The old backend keeps `:8766`**, so the new app reuses a stale sidecar.
- **Every build leaves LaunchServices registrations** (the Trash copy, `dist/`,
  `dist/dmg-stage/`), and Launchpad renders each as its own Yap icon.

The script fixes all three deterministically: quit every running instance
(SIGTERM → SIGKILL), free the backend port (only if it's our `server.py`), trash
the old bundle, install + register the new one, launch it, then — as the final
step, so nothing re-registers them — unregister every non-`/Applications` bundle
and refresh the Dock. It verifies the running process is actually the new build.

```bash
bash scripts/install_local.sh              # build (release) + clean install + relaunch + verify
bash scripts/install_local.sh --no-build   # reinstall the existing dist/Yap.app (skip the build)
```

**Do NOT bump the version for interim test builds** — only bump
`CFBundleShortVersionString` + `CFBundleVersion` when cutting a public
release/deploy. Burning a version number per throwaway build is churn; keep test
builds on the current dev version and tell Lino verbally that it's fresh.

Yap reads no Keychain items at all, so a re-signed build prompts for nothing.
(TCC Accessibility/Mic grants bind to the stable "Yap Local Signing" cert, so those
persist across rebuilds.)

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
inconsistent across apps. The clipboard path saves the pasteboard, sends ⌘C
(retried up to 3× with modifiers re-cleared, ~8ms key-hold — a single synthetic
Copy is unreliable), and **only accepts text if `changeCount` actually
advanced**, then restores the original clipboard. It must never return the
pre-existing clipboard on a failed copy — that's what made Yap "read text I
didn't select." The clipboard-restore invariant is covered by `--selftest`; keep
it green.

**`readSource` has three modes** (`Prefs.ReadSource`): `selection` (AX + ⌘C
only, strict — keeps the no-stale-clipboard invariant), `clipboard` (reads the
current clipboard directly, the no-Accessibility path), and **`auto`** (try the
live selection, and if it comes back empty fall back to reading the clipboard).
Auto exists for apps that expose **no** AX selection **and** block the synthetic
⌘C — **iTerm and other terminals**. Retries can't help there (the Copy never
lands), but iTerm's copy-on-select means the selection is already on the
clipboard, so the fallback reads it. Tradeoff, documented in the UI + PRIVACY:
in Auto, a read with nothing selected can speak a stale clipboard. `auto` and
`selection` both need Accessibility; only `clipboard` needs none.

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
<!-- canon-override: destructive filesystem commands (use trash, not rm) — a user
     pressing Delete in Settings to reclaim ~1.2 GB gets nothing back if it goes to
     the Trash, and every byte is re-downloadable. Applies ONLY to the model/engine
     deletes below, never to how an agent deletes files. (Lino, 2026-08-30) -->
- **Model deletes are REAL deletes, not the Trash**, and the paths are validated
  first (`AppState.isDeletableAppSupportDir`). Guarding stops the mistake;
  recoverability was deliberately traded away because the button exists to free
  disk. Don't "fix" this back to `trashItem`.
- Deleting HD removes `hd-packages` **and `pocket-weights/`** (the cloning weights
  are engine data, and leaving 209 MB behind is the disk the user was reclaiming).
  **Cloned voices (`hd-voices`) are kept** — those are the user's own recordings,
  and nothing can re-download them. Falls back to the Kokoro engine.

## Menu-bar UI (the layout-loop gotcha)

The menu is a `MenuBarExtra` with `.menuBarExtraStyle(.window)` — a real SwiftUI
view tree (`MenuContent`), not an `NSMenu`. That style **auto-sizes the popover
window to its content**, and if any subview reports a size that never settles,
CoreAnimation re-lays-the-whole-menu-out every display cycle in a self-sustaining
loop (`MenuBarExtraLayout.sizeThatFits` back-to-back). It pins the main thread —
seen as sustained idle CPU + a laggy menu-bar icon that worsens with use — even
with the popover closed, once it's been opened once. Diagnose with
`sample <pid>`; the tell is `DriverCore::continueProcessing → CA::Transaction::commit
→ NSHostingView.layout → MenuBarExtraLayout.sizeThatFits`.

Rules for `MenuContent` and anything it shows:
- **No `ScrollView` and no `.textSelection(.enabled)` in the menu content.** Those
  are the documented offenders — they renegotiate size and never converge here.
  `LastResultCard` deliberately uses a fixed-height, line-limited, truncated
  `Text` (Copy button for the full text) for exactly this reason. Don't "restore"
  scroll/selection.
- Keep subview sizes deterministic; a fixed `.frame(height:)` beats a
  content-dependent `maxHeight` when in doubt.
- Don't fire `@Published` writes on a timer unconditionally — assigning even an
  unchanged value triggers `objectWillChange` and re-renders the whole menu. The
  `axTrusted` poll guards on an actual change for this reason.

## Standing constraints

- **Fully local. No cloud TTS, no accounts, no analytics, ever.** That's the
  product. Any network call besides the one-time model download is a regression.
- Default model IDs for any AI work: Opus `claude-opus-5`, Sonnet
  `claude-sonnet-5`, Haiku `claude-haiku-4-5-20251001`.
- macOS 14+, Apple Silicon. Prefer native APIs (AVFoundation, Carbon hotkey,
  AXUIElement) over adding dependencies.

## Review

**Reviewing a PR here? Read `docs/agent/review-guidance.md` before filing
anything** — it lists the verified-correct patterns reviewers have already
flagged once, with the mechanism that settles each.

## Agent context (scope + memory)
<!-- BEGIN agent-context (managed by ~/.agents/bin/project-sync.sh) -->
- You are in **PROJECT scope** (this repo). Everything that is true across projects lives in user-scope canon (`~/.agents/AGENTS.md` + skills) and is NOT repeated here; this file holds only what is true of THIS repo.
- Project memory + shared skills: `.agents/` (gitignored). Read `.agents/memory/MEMORY.md` first.
- `.claude`/`.agents` here may be symlinks; verify with `readlink` before claiming a write landed.
- This file holds project facts only. Check with `~/.agents/bin/canon-echo.sh .`; a real exception is marked `<!-- canon-override: <rule> — <why> (date) -->`.
- Refresh infra: `~/.agents/bin/project-sync.sh .`
<!-- END agent-context -->
