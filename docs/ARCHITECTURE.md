# Architecture

Two processes. A native SwiftUI menu-bar app drives a local Python sidecar over
loopback HTTP. The sidecar hosts two interchangeable engines (Kokoro default,
Chatterbox Turbo HD opt-in) behind one int16-PCM contract.

## Modules

| Concern | File |
|---|---|
| App shell / scenes | `app/Sources/Parley/ParleyApp.swift` |
| macOS Services provider ("Read with Parley") | `ParleyApp.swift` (`ServiceProvider`) + `Resources/Info.plist` (`NSServices`) |
| Central state + read pipeline | `AppState.swift` |
| Preferences (UserDefaults) | `Prefs.swift` |
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
| HD engine (Chatterbox Turbo, lazy) | `backend/chatterbox_engine.py` |

## Read pipeline

```
hotkey ⌘⇧R
  → capture (AX selected-text → clipboard fallback, clipboard restored)
  → preprocess (profile options + custom regex rules)
  → ensure backend warm
  → POST /synthesize (stream)
  → backend: chunk (paragraph → sentence, abbrev-aware) → Kokoro → int16 PCM
  → AudioPlayer: int16 → float buffers → AVAudioPlayerNode → TimePitch → mixer
```

A generation counter in `AppState` cancels a stale stream when a new read starts (configurable via "stop on new trigger").

The **Services menu** ("Read with Parley") is a second entry point: macOS hands the selected text straight to `ServiceProvider`, which calls `AppState.readAloud(_:)` — skipping capture, joining the pipeline at preprocess.

## Audio

Raw int16 mono PCM at 24 kHz streams from the backend as `application/octet-stream`. The Swift side converts to `Float32` `AVAudioPCMBuffer`s and schedules them on an `AVAudioPlayerNode` as they arrive — playback begins on the first chunk. Pitch/volume run through `AVAudioUnitTimePitch`. Speed is applied upstream by Kokoro for better quality.

## Backend lifecycle

`BackendManager` first probes `/health`. If a backend is already running it reuses it (and records `ownsProcess = false`); otherwise it spawns one — the bundled self-contained Python runtime directly in a shipped app, or `scripts/run_backend.sh` (venv) in a dev checkout — loads Kokoro, warms it, and serves.

`ready` means the backend can serve *some* engine: Kokoro loaded **or** the HD engine present on disk. So deleting one model doesn't make the backend look dead, and `waitForHealth()` fails fast (instead of polling 60s) when a model will never load. Kokoro presence is tracked separately as `kokoroFilesPresent`.

Model management (Models tab) leans on this: delete is only offered when `ownsProcess` is true (the app can't safely replace a backend it didn't spawn), and a delete does `stopAndWait()` → remove files → `start()` so disk is freed and the relaunched process reflects the change.
