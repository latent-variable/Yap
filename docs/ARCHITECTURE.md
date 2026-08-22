# Architecture

Two processes. A native SwiftUI menu-bar app drives a local Python sidecar over
loopback HTTP. The sidecar hosts two interchangeable engines (Kokoro default,
Pocket TTS opt-in) behind one int16-PCM contract.

## Modules

| Concern | File |
|---|---|
| App shell / scenes | `app/Sources/Yap/YapApp.swift` |
| macOS Services provider ("Read with Yap") | `YapApp.swift` (`ServiceProvider`) + `Resources/Info.plist` (`NSServices`) |
| Central state + read pipeline | `AppState.swift` |
| Preferences (UserDefaults) | `Prefs.swift` |
| History log (spoken + dictated, JSON-backed) | `History.swift` + `Views/SettingsView.swift` (History tab) |
| Global hotkey (Carbon) | `HotKey.swift` |
| Text capture (AX + clipboard) | `TextCapture.swift` |
| Accessibility permission | `Permissions.swift` |
| Preprocessing / cleanup | `Preprocess.swift` |
| Backend HTTP client | `BackendClient.swift` |
| Backend process supervisor | `BackendManager.swift` |
| Streaming audio engine (pre-buffer, live speed) | `AudioPlayer.swift` |
| Reference-clip import (→ mono 24k WAV) | `AudioImport.swift` |
| Unified voice picker (both engines) | `Views/VoiceSelector.swift` |
| Model download | `ModelDownloader.swift` (owned by `AppState` so a download survives closing Settings) |
| Model management (size on disk, delete, re-download) | `AppState.swift` + `Views/SettingsView.swift` (Models tab) |
| Launch at login | `LoginItem.swift` |
| Views | `Views/MenuContent.swift`, `Views/SettingsView.swift` |
| Logic self-test / pipe probe | `Selftest.swift`, `CLITest.swift` |
| Inference server (both engines) | `backend/server.py` |
| Pocket TTS engine (catalog + cloning, lazy) | `backend/pocket_engine.py` |
| HF token storage (cloning) | `app/Sources/Yap/Keychain.swift` |

## Read pipeline

```
hotkey ⌘⇧R
  → capture (AX selected-text → clipboard fallback, clipboard restored)
  → preprocess (profile options + custom regex rules)
  → ensure backend warm
  → POST /synthesize (stream)
  → backend: chunk (paragraph → sentence, abbrev-aware) → Kokoro / Pocket → int16 PCM
  → AudioPlayer: int16 → float buffers → AVAudioPlayerNode → TimePitch → mixer
```

A generation counter in `AppState` cancels a stale stream when a new read starts (configurable via "stop on new trigger").

The **Services menu** ("Read with Yap") is a second entry point: macOS hands the selected text straight to `ServiceProvider`, which calls `AppState.readAloud(_:)` — skipping capture, joining the pipeline at preprocess.

## Audio

Raw int16 mono PCM at 24 kHz streams from the backend as `application/octet-stream`. The Swift side converts to `Float32` `AVAudioPCMBuffer`s and schedules them on an `AVAudioPlayerNode` as they arrive — playback begins on the first chunk. Pitch/volume/speed all run through `AVAudioUnitTimePitch` at playback (live-adjustable), so speed is real-time and identical across both engines.

### Pocket pads every utterance, and we trim it

Pocket returns each utterance wrapped in its own silence, and it is per-utterance
overhead rather than anything to do with the line. Measured through both engines on
identical text:

| line | Kokoro lead / trail | Pocket lead / trail |
|---|---|---|
| "Meet Yap." | 0.04s / 0.19s | 0.74s / 0.20s |
| "Stop typing." | 0.04s / 0.17s | 0.86s / 0.21s |
| "No cloud. No account." | 0.05s / 0.09s | 0.77s / 0.30s |
| "See something worth hearing?" | 0.04s / 0.15s | 0.56s / 0.27s |
| a 15-word sentence | 0.05s / 0.17s | 0.96s / 0.34s |

Streamed verbatim that put roughly a second of dead air in front of every sentence,
*on top of* the `GAP_*` pause `server.py` already inserts between segments — so a
Pocket read of the demo script ran 63.8s against 42.6s of speech, and `GAP_SENTENCE`
meant one thing on Kokoro and another on Pocket even though the gap constants are
supposed to be engine-agnostic. `PocketEngine.trim_padding` cuts it back to Kokoro's
range at the engine, so the streaming read and the WAV export both get it.

**The detector uses two thresholds, and that is the whole trick.** A single "is this
speech" level high enough to ignore the model's noise floor also sits above a quiet
onset — the `/s/` in "See" — and trimming to it lops the front off the word. So one
threshold finds a frame that is confidently speech, then it walks outward while
frames stay above a second, much lower floor; the word's quiet edges live inside
that walk. It only ever removes: an already-tight clip comes back untouched, and one
with no detectable speech comes back whole rather than emptied, because dropping
audio is a far worse failure than leaving silence on it.

Covered by `TestPocketPadding`, including a synthetic quiet-fricative-then-vowel case
that asserts the consonant's *energy* survives in front of the vowel — a length
assertion passes even when the onset was cut, because the trailing pad makes up the
difference.

### Telling a finished read from a truncated one

A synthesis failure partway through a read has no honest way to reach the client. The 200 went out with the first chunk and can't be retracted, and **aborting isn't detectable either**: uvicorn terminates the chunked body with a clean `0\r\n\r\n` even when the generator raises — verified on a raw socket — so a truncated body is byte-identical to a complete one. Skipping the segment (the original behaviour) was worse still: the read finished as a clean 200 having spoken a document with holes in it, and if every segment failed the app played nothing and announced success.

Two mechanisms cover the two halves:

- **Segment 0 is synthesized before the response starts.** Failures there are systemic — model unloaded, unknown voice, cloning unavailable — and are still a real HTTP 500 the app reports normally.
- **A complete stream ends with `STREAM_FOOTER` (`b"YEND"`).** A later segment failure aborts the generator, withholding it. `BackendClient.streamPCM` holds back the trailing bytes so the footer never reaches the player, and throws `"Synthesis stopped partway"` when the stream ends without it.

The `X-Stream-Footer` response header advertises the marker. `BackendManager` reuses a backend it finds already running, so a newer app can end up talking to an older sidecar; no header means no check, i.e. the old behaviour, rather than every read failing.

Covered by `TestStreamIntegrity` (live uvicorn, raw socket, plus a control that restores skip-and-continue) and end-to-end by `--tailtest` against a fault-injecting backend.

## Backend lifecycle

`BackendManager` first probes `/health`. Nothing answering means it spawns one — the bundled self-contained Python runtime directly in a shipped app, or `scripts/run_backend.sh` (venv) in a dev checkout — loads Kokoro, warms it, and serves.

Something already answering is not automatically reused. `start()` decides:

- **Unverified** (`verifyAuthentic()` fails — it can't prove it knows the shared secret). An identifiable Yap orphan (a `server.py` reparented to launchd, ppid 1) is almost always a stale pre-auth backend left over from an upgrade, so it's killed and a fresh authenticated one launched. Anything else is a foreign listener squatting the port: refused with an error, never handed captured text.
- **Verified and ready** — reused.
- **Verified but not ready** (responding, no model it can serve). If it's an adopted orphan, it's stopped and relaunched; if it's external, it's left alone and `start()` bails rather than racing a second process onto the same port.

A verified reuse also splits on **who started it**:

- **Orphaned Yap backend** — **adopted**: `ownsProcess = true`. The app can stop and relaunch it, so model management keeps working across an app restart.
- **Hand-started external server** (a dev backend in a terminal, ppid != 1) — left external: `ownsProcess = false`. It isn't ours to kill.

So `ownsProcess` means "we may end this process", not "we spawned it".

`ready` means the backend can serve *some* engine: Kokoro loaded **or** the Pocket engine present on disk. So deleting one model doesn't make the backend look dead, and `waitForHealth()` fails fast (instead of polling 60s) when a model will never load. Kokoro presence is tracked separately as `kokoroFilesPresent`.

Model management (Models tab) leans on both: delete is only offered when `ownsProcess` is true (an external backend can't be stopped to release the model files), and a delete does `stopAndWait()` → remove files → `start()` so disk is freed and the relaunched process reflects the change.
