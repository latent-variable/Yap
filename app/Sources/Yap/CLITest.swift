import Foundation

/// Headless exercise of the real Swift pipeline (clean → stream) without UI or
/// audio. Run: `Yap --pipetest <file> [profile]`. Reports per-profile
/// cleaning size, first-byte latency, total PCM, chunking, and any error — the
/// same code paths the app uses, so failures here reproduce app failures.
enum CLITest {
    static func run(path: String, profileName: String?) -> Never {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
            exit(2)
        }
        let profiles: [Profile] = profileName.flatMap { Profile(rawValue: $0) }.map { [$0] }
            ?? Profile.allCases
        var failures = 0
        Task {
            for profile in profiles {
                let cleaned = Preprocess.clean(raw, options: Preprocess.options(for: profile), custom: [])
                print("── profile=\(profile.rawValue)  raw=\(raw.count)  cleaned=\(cleaned.count) chars")
                if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    print("   ✗ cleaned text empty"); failures += 1; continue
                }
                let client = BackendClient()
                let t = Date()
                var firstByte: TimeInterval?
                var total = 0
                do {
                    try await client.streamPCM(text: cleaned, voice: "af_heart", speed: 1.0) { data in
                        if firstByte == nil { firstByte = Date().timeIntervalSince(t) }
                        total += data.count
                    }
                    let dur = Date().timeIntervalSince(t)
                    let secs = Double(total / 2) / 24000.0
                    print(String(format: "   ✓ firstByte=%.2fs  total=%.2fs  audio=%.1fs  pcm=%d bytes",
                                 firstByte ?? -1, dur, secs, total))
                } catch {
                    print("   ✗ stream error: \(error.localizedDescription)"); failures += 1
                }
            }
            print(failures == 0 ? "\nPIPE OK" : "\n\(failures) FAILURE(S)")
            exit(failures == 0 ? 0 : 1)
        }
        // Park the main thread on the dispatch queue (no semaphore) so the async
        // Task can freely hop to the main actor; it ends the process via exit().
        dispatchMain()
    }

    /// Thread-safe high-water mark. The gate and the chunk callback both sample
    /// the queue from different threads.
    private final class Peak: @unchecked Sendable {
        private let lock = NSLock()
        private var v = 0.0
        func note(_ x: Double) { lock.lock(); v = max(v, x); lock.unlock() }
        var value: Double { lock.lock(); defer { lock.unlock() }; return v }
    }

    /// `Yap --backpressure <file> [seconds]` — drives the real player + stream +
    /// `AudioPlayer.gate` against the live backend and asserts the queue stays
    /// bounded.
    ///
    /// This exists because the failure it guards is SILENT: without the gate
    /// nothing errors, the audio just piles onto the node ahead of the listener
    /// (measured before the fix: ~2,950 buffers / 57 MB for an 11-minute read,
    /// ~19,850 / 381 MB for a 46k-character one). Playback is the rate limit once
    /// the gate works, so the probe runs for a fixed window and then abandons —
    /// which also exercises teardown-on-supersede.
    static func runBackpressure(path: String, seconds: Double) -> Never {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
            exit(2)
        }
        let cleaned = Preprocess.clean(raw, options: Preprocess.options(for: .markdown), custom: [])
        let cap = AudioPlayer.maxQueuedSeconds
        print("── backpressure probe  chars=\(cleaned.count)  cap=\(cap)s  window=\(seconds)s")
        Task {
            let player = AudioPlayer()
            do {
                // Silent: this is a headless probe, not a read. The engine still
                // runs and drains in realtime, which is what bounds the queue.
                try player.start(volume: 0, pitchCents: 0, rate: 1, cushionSeconds: 0.35)
            } catch {
                print("   · no audio output device — cannot drain, skipping"); exit(0)
            }
            let peak = Peak(), deadline = Date().addingTimeInterval(seconds)
            var total = 0
            let gate = AudioPlayer.gate { [weak player] in
                let q = player?.queuedSeconds ?? 0
                peak.note(q)
                return (live: Date() < deadline, queued: q)
            }
            do {
                try await BackendClient().streamPCM(text: cleaned, voice: "af_heart", speed: 1.0,
                                                    awaitCapacity: gate) { data in
                    total += data.count
                    player.feed(data)   // the drain the gate measures against
                    peak.note(player.queuedSeconds)
                }
            } catch {
                print("   ✗ stream error: \(error.localizedDescription)"); exit(1)
            }
            let audioSecs = Double(total / 2) / 24000.0
            player.stop()
            var failures = 0
            func want(_ name: String, _ ok: Bool, _ detail: String) {
                if ok { print("   ✓ \(name) — \(detail)") }
                else { failures += 1; print("   ✗ \(name) — \(detail)") }
            }
            // One chunk (0.2s) of slop: the gate is checked *after* a chunk lands.
            want("queue stayed bounded", peak.value <= cap + 0.5,
                 String(format: "peak=%.1fs vs cap=%.1fs", peak.value, cap))
            // Without this the first assert passes trivially if nothing streamed.
            want("stream kept flowing (no deadlock/starvation)", audioSecs > cap,
                 String(format: "received %.1fs of audio in a %.0fs window", audioSecs, seconds))
            // With the gate holding, arrival tracks playback instead of racing to
            // the end of the document.
            want("arrival paced to playback", audioSecs < seconds + cap + 2,
                 String(format: "%.1fs audio for %.0fs elapsed", audioSecs, seconds))
            print(failures == 0 ? "\nBACKPRESSURE OK" : "\n\(failures) FAILURE(S)")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }
}
