import AVFoundation
import Foundation
import FluidAudio

/// Headless dictation probes. Need the English models already downloaded (any
/// prior dictation does it).
///
/// `Yap --dictbench <audio> [v2|v3]` times one batch pass (the call stop makes)
/// at several utterance lengths: "how long does a final pass cost" as a number.
///
/// `Yap --dictstop <audio> [seconds] [--legacy]` runs the real `Dictation`
/// session (queues, pump, preview loop, stop path) fed from the file in real
/// time instead of the mic, then a pause of room noise, then stop. Reports how
/// long stop took, which path it took, and whether the text matches a fresh
/// full pass over the same audio. `--legacy` forces the full final pass, the
/// pre-reuse behaviour, as the control.
enum DictationProbe {
    /// Decode a speech file to the shape the mic tap hands us: 48 kHz mono Float32.
    static func loadMicLike(_ path: String) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let src = file.processingFormat
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "dictbench", code: 1)
        }
        try file.read(into: inBuf)
        let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let conv = AVAudioConverter(from: src, to: dst)!
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * 48_000 / src.sampleRate) + 4096
        let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: cap)!
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        if let err { throw err }
        return out
    }

    static func prefix(_ b: AVAudioPCMBuffer, seconds: Double) -> AVAudioPCMBuffer {
        let n = min(AVAudioFrameCount(seconds * b.format.sampleRate), b.frameLength)
        let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: n)!
        out.frameLength = n
        memcpy(out.floatChannelData![0], b.floatChannelData![0], Int(n) * MemoryLayout<Float>.size)
        return out
    }

    /// Room noise at about -60 dBFS, so the probe's silence looks like a mic's
    /// and not like digital zeros. Deterministic (LCG) so runs are comparable.
    static func addNoise(_ b: AVAudioPCMBuffer, seed: UInt32 = 1) {
        var x = seed
        let p = b.floatChannelData![0]
        for i in 0..<Int(b.frameLength) {
            x = x &* 1_664_525 &+ 1_013_904_223
            p[i] += (Float(x >> 8) / Float(1 << 24) - 0.5) * 0.002
        }
    }

    static func silence(seconds: Double, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let n = AVAudioFrameCount(seconds * format.sampleRate)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(n, 1))!
        b.frameLength = n
        memset(b.floatChannelData![0], 0, Int(n) * MemoryLayout<Float>.size)
        return b
    }

    static func join(_ a: AVAudioPCMBuffer, _ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let out = AVAudioPCMBuffer(pcmFormat: a.format, frameCapacity: a.frameLength + b.frameLength)!
        out.frameLength = a.frameLength + b.frameLength
        let fs = MemoryLayout<Float>.size
        memcpy(out.floatChannelData![0], a.floatChannelData![0], Int(a.frameLength) * fs)
        memcpy(out.floatChannelData![0] + Int(a.frameLength), b.floatChannelData![0], Int(b.frameLength) * fs)
        return out
    }

    static func words(_ s: String) -> [Substring] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
    }

    static func runStop(path: String, seconds: Double, legacy: Bool) -> Never {
        Task { @MainActor in
            do {
                Dictation.forceFinalPass = legacy
                let speech = try loadMicLike(path)
                let d = Dictation()
                await d.loadModelAwaiting(.english)
                await d.awaitFinalModel()
                let ref = AsrManager(config: .default)
                try await ref.loadModels(try await AsrModels.downloadAndLoad(version: .v2))
                print(String(format: "%@ — %.0fs of speech, then a pause, then stop", legacy ? "LEGACY (always final pass)" : "NEW", seconds))
                var mismatches = 0
                for gap in [0.0, 0.3, 0.6, 1.0, 2.0] {
                    let audio = join(prefix(speech, seconds: seconds), silence(seconds: gap, format: speech.format))
                    addNoise(audio)
                    let feed = try await d.startSimulated(format: audio.format)
                    var off: AVAudioFrameCount = 0
                    let t = Date()
                    while off < audio.frameLength {
                        let n = min(4096, audio.frameLength - off)
                        let chunk = AVAudioPCMBuffer(pcmFormat: audio.format, frameCapacity: n)!
                        chunk.frameLength = n
                        memcpy(chunk.floatChannelData![0], audio.floatChannelData![0] + Int(off), Int(n) * 4)
                        feed(chunk)
                        off += n
                        // Real time: the mic hands over a buffer when it's full.
                        let due = t.addingTimeInterval(Double(off) / audio.format.sampleRate)
                        let wait = due.timeIntervalSinceNow
                        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                    }
                    let s0 = Date()
                    let text = await d.stopAndTranscribe() ?? ""
                    let stopMs = Date().timeIntervalSince(s0) * 1000
                    var st = TdtDecoderState.make(decoderLayers: await ref.decoderLayerCount)
                    let raw = try await ref.transcribe(audio, decoderState: &st, language: nil)
                        .text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let full = Prefs.shared.removeFillers ? Fillers.clean(raw) : raw   // as stop does
                    // Words are the contract. The batch model's punctuation shifts
                    // with how much trailing silence it hears (the full pass itself
                    // gains/drops a final period between a 1s and a 2s pause), so a
                    // punctuation-only difference is reported, not failed.
                    let sameWords = words(text) == words(full)
                    if !sameWords { mismatches += 1 }
                    let verdict = text == full ? "identical" : sameWords ? "same words (punctuation differs)" : "WORDS DIFFER"
                    print(String(format: "  pause %.1fs: stop %5.0f ms  %-16@ %@", gap, stopMs,
                                 d.lastStop.components(separatedBy: " in ").first ?? "", verdict))
                    if !sameWords { print("     pasted: …\(text.suffix(90))\n     full:   …\(full.suffix(90))") }
                    try await Task.sleep(nanoseconds: 300_000_000)
                }
                print(mismatches == 0 ? "ALL WORDS MATCH" : "\(mismatches) WORD MISMATCH(ES)")
                exit(mismatches == 0 ? 0 : 1)
            } catch {
                print("dictstop FAILED: \(error)"); exit(1)
            }
        }
        dispatchMain()
    }

    static func runBench(path: String, version: AsrModelVersion) -> Never {
        Task {
            do {
                let audio = try loadMicLike(path)
                let total = Double(audio.frameLength) / 48_000
                print(String(format: "audio: %.1fs  model: %@", total, "\(version)"))
                let models = try await AsrModels.downloadAndLoad(version: version)
                let asr = AsrManager(config: .default)
                try await asr.loadModels(models)
                func pass(_ buf: AVAudioPCMBuffer) async throws -> (Double, String) {
                    var st = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
                    let t = Date()
                    let r = try await asr.transcribe(buf, decoderState: &st, language: nil)
                    return (Date().timeIntervalSince(t), r.text)
                }
                _ = try await pass(prefix(audio, seconds: 5))   // warm-up
                for secs in [5.0, 15, 30, 60, 120, 180] where secs <= total + 0.01 {
                    let b = prefix(audio, seconds: secs)
                    var times: [Double] = []
                    for _ in 0..<3 { times.append(try await pass(b).0) }
                    times.sort()
                    print(String(format: "  %5.0fs utterance: pass median %4.0f ms  (min %4.0f, max %4.0f)",
                                 secs, times[1] * 1000, times[0] * 1000, times[2] * 1000))
                }
                exit(0)
            } catch {
                print("dictbench FAILED: \(error)"); exit(1)
            }
        }
        dispatchMain()
    }
}
