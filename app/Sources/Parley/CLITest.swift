import Foundation

/// Headless exercise of the real Swift pipeline (clean → stream) without UI or
/// audio. Run: `Parley --pipetest <file> [profile]`. Reports per-profile
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
}
