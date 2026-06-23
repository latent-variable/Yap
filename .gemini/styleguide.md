# Parley review styleguide

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
