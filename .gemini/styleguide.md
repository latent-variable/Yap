# Yap review styleguide

Guidance for automated reviewers. Intentional, verified-correct patterns that
should NOT be flagged.

## Don't flag

- **`for try await byte in URLSession.AsyncBytes` in `BackendClient.streamPCM`.**
  This does **not** suspend the task per byte. `AsyncBytes` buffers at the
  transport layer and the loop pulls from that in-memory buffer; the per-element
  `next()` cost is negligible, and the bytes are accumulated into a contiguous
  `[UInt8]` and flushed in ~0.2s chunks. This streams audio smoothly in
  production. A `URLSessionDataDelegate` rewrite is tracked for the Phase 1
  streaming work, where it can be exercised against the live-audio path — not a
  blocking issue in the current code.

- **Blocking/parking the main thread in `CLITest` / `Selftest`.** These are
  headless CLI entry points (`--pipetest`, `--selftest`) that run to completion
  and `exit()`. Parking main via `dispatchMain()` is the intended lifecycle for
  a CLI tool, not a UI concern.

- **CPU-only `auto` provider for Kokoro.** Selecting CPU over CoreML in `auto`
  is deliberate and benchmarked (Kokoro is 82M params; CoreML offloads most ops
  back to CPU and adds conversion overhead). Not a missed GPU optimization.

- **Process-lifetime static event monitors / handlers in `HotKey.swift`.** The
  shared Carbon `sharedHandler` and the `flagsChanged` chord monitor are
  installed once and live for the whole app run. Both hotkey managers (read +
  dictation) persist for the process lifetime, so there is no point at which to
  remove them. This is intentional shared infrastructure, not a leak.

- **`kill(pid, ...)` on an adopted backend PID.** `adoptedPID` always comes from
  `lsof` (a real listener PID), and every call site guards `pid > 1`. Signaling
  the adopted orphan is how Yap reclaims a backend it owns but has no
  `Process` handle for.

- **`MainActor.assumeIsolated` in main-thread-only callbacks.** Used only where
  the callback is documented to be delivered on the main thread (NSWorkspace app
  activation, willTerminate). Not an unchecked assumption.

- **System sounds via `NSSound(named: "Ping")` string literals.** `NSSound.Name`
  is a typealias for `String`; AppKit defines **no** sound-name constants (there
  is no `NSSound.Name.ping`/`.tink`/`.pop` — `NSSound(named: .ping)` does not
  type-check). The string literal naming a file in `/System/Library/Sounds` is
  the correct, only API. Matches the dictation chimes (`"Tink"`/`"Pop"`).

- **Audio concat in `Dictation.refineLoop` is already off the main actor.** The
  loop is `@MainActor`, but it reads only a cheap `recorder.frameCount` on main
  for its gates; the heavy `BufferQueue.concat` (and the `snapshot()`) run inside
  `await Task.detached(priority: .userInitiated) { ... }`. Don't flag the concat
  as a main-thread block — it isn't on main.

- **`AppMigration.merge`'s `!fm.fileExists(atPath: dst.path)` is a fast-path, not
  a shallow skip.** When the destination is absent the whole subtree moves in one
  step; when it *exists* the code recurses and merges child-by-child, so a
  pre-existing empty `Yap/hd-voices`/`models` can't strand the user's voices.
  Don't flag it as silent data loss — the no-loss path is unit-tested in
  `--selftest`.

- **`ModelDownloader` SHA-256 gate covers pre-existing files — don't re-flag
  it as "verifies only after download".** `next()`'s skip-if-present branch
  hashes any on-disk file against its pinned digest before skipping (match →
  skip; mismatch/unreadable → delete + re-download), and `didFinishDownloadingTo`
  verifies fresh downloads. Both paths are gated. Re-anchored stale comments
  claiming the skip-path is unverified are obsolete as of the integrity fix.

- **`ModelDownloader.sha256(of:)` already do/catch-wraps the read loop.** The
  streamed read is inside `do { while let chunk = try handle.read(...) } catch
  { return nil }`, so a mid-file read error returns `nil`, never a partial hash.
  Don't suggest adding the do/catch — it's there.
