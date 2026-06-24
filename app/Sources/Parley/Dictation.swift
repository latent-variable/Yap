import AVFoundation
import Foundation
import FluidAudio

/// The "ears": native streaming Parakeet ASR on the Apple Neural Engine via
/// FluidAudio. Push-to-talk → live partial transcript (for the HUD) → final
/// text the caller inserts at the cursor.
///
/// This mirrors FluidVoice's real-time path: a true streaming decoder whose
/// partial callback returns the **full running transcript** (all tokens so far),
/// so earlier words self-correct as more context arrives — not a per-chunk
/// fragment. English uses Parakeet EOU "Flash" (160 ms chunks, lowest latency);
/// multilingual uses Nemotron streaming. The model loads once and is reused
/// across push-to-talk sessions (reset between them), so there's no per-press
/// reload.
@MainActor
final class Dictation: ObservableObject {

    /// User-facing engine choice → concrete streaming model variant.
    enum EngineChoice: String, CaseIterable, Identifiable {
        case english      // Parakeet EOU Flash — real-time English, 160 ms chunks
        case multilingual // Nemotron streaming — 25 languages, 560 ms chunks
        var id: String { rawValue }
        var label: String { self == .english ? "English" : "Multilingual" }
        var variant: StreamingModelVariant {
            self == .english ? .parakeetEou160ms : .nemotron560ms
        }
        /// High-accuracy batch model for the final re-transcription on stop —
        /// Parakeet TDT v2 (English) / v3 (multilingual). FluidVoice's two-model
        /// design: fast streaming for the live feel, this for the inserted text.
        var finalVersion: AsrModelVersion { self == .english ? .v2 : .v3 }
    }

    enum State: Equatable {
        case idle, loadingModel, listening, transcribing
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var modelReady = false
    @Published var engineChoice: EngineChoice = .english
    /// Live transcript while listening — drives the HUD. Full running transcript,
    /// self-correcting, not a per-chunk fragment.
    @Published private(set) var partial = ""
    @Published private(set) var lastFinal = ""

    private var manager: (any StreamingAsrManager)?
    private let audio = AVAudioEngine()
    private var pump: Task<Void, Never>?
    // Render-thread → actor handoff. nonisolated so the mic tap (any thread)
    // can enqueue without touching main-actor state.
    private nonisolated let pending = BufferQueue()

    // Full-utterance audio kept for the accurate final pass (Parakeet v2/v3
    // batch over everything you said), plus the loaded batch model.
    private nonisolated let recorder = BufferQueue()
    private var captureFormat: AVAudioFormat?
    private var finalASR: AsrManager?
    private var finalVersionLoaded: AsrModelVersion?

    var isListening: Bool { state == .listening }

    /// Download (first time) + load the streaming model for the chosen engine.
    /// Loaded once and reused — startListening only reset()s it.
    func loadModel(_ choice: EngineChoice) async {
        if case .loadingModel = state { return }
        if modelReady, engineChoice == choice, manager != nil { return }
        state = .loadingModel
        engineChoice = choice
        Prefs.shared.dictationEngine = choice.rawValue
        do {
            let mgr = choice.variant.createManager()
            try await mgr.loadModels()
            // The callback fires with the full running transcript on each new
            // token — drive the HUD straight from it.
            await mgr.setPartialTranscriptCallback { [weak self] text in
                Task { @MainActor in self?.partial = text }
            }
            manager = mgr
            modelReady = true
            state = .idle
            // Warm the high-accuracy final-pass model in the background so it's
            // ready by the time you stop talking. Best-effort.
            let fv = choice.finalVersion
            Task { await self.loadFinalModel(fv) }
        } catch {
            modelReady = false
            state = .error("Model load failed: \(error.localizedDescription)")
        }
    }

    /// Load the batch Parakeet v2/v3 model used to re-transcribe the full
    /// utterance accurately on stop. Best-effort — if it isn't ready, the live
    /// streaming transcript is used as-is (no regression).
    private func loadFinalModel(_ version: AsrModelVersion) async {
        if finalVersionLoaded == version, finalASR != nil { return }
        do {
            let models = try await AsrModels.downloadAndLoad(version: version)
            let mgr = AsrManager(config: .default)
            try await mgr.loadModels(models)
            finalASR = mgr
            finalVersionLoaded = version
        } catch {
            finalASR = nil
            finalVersionLoaded = nil
        }
    }

    /// Start mic capture and live streaming (asks Microphone permission once).
    func startListening() {
        guard modelReady, state == .idle, let manager else { return }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard granted else { self.state = .error("Microphone access denied"); return }
                do {
                    try await manager.reset()
                    self.partial = ""
                    _ = self.recorder.drain()   // clear last session's audio
                    try self.beginCapture(into: manager)
                    self.state = .listening
                } catch {
                    self.state = .error("Mic start failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Stop capture, flush, and return the final transcript (nil if empty).
    @discardableResult
    func stopAndTranscribe() async -> String? {
        guard state == .listening, let manager else { return nil }
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        // Await the pump's actual termination — cancel() alone doesn't wait, and
        // a still-running append/process would race finish() on the same actor.
        pump?.cancel()
        await pump?.value
        pump = nil
        state = .transcribing
        do {
            // Feed anything still queued, then finish the live stream.
            for b in pending.drain() { try? await manager.appendAudio(b) }
            try? await manager.processBufferedAudio()
            let liveText = try await manager.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            // Accurate final pass over the whole utterance; fall back to the live
            // transcript if the batch model isn't ready or fails.
            let accurate = await runFinalPass(recorder.drain())
            var text = (accurate?.isEmpty == false) ? accurate! : liveText
            if Prefs.shared.removeFillers { text = Fillers.clean(text) }
            lastFinal = text
            partial = ""
            state = .idle
            return text.isEmpty ? nil : text
        } catch {
            state = .error("Transcription failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Re-transcribe the full utterance with the high-accuracy batch model.
    /// Returns nil (→ caller keeps the live text) if the model isn't loaded, the
    /// audio is empty, or anything throws.
    private func runFinalPass(_ buffers: [AVAudioPCMBuffer]) async -> String? {
        guard let finalASR, let combined = BufferQueue.concat(buffers) else { return nil }
        do {
            var decoderState = TdtDecoderState.make(decoderLayers: await finalASR.decoderLayerCount)
            let result = try await finalASR.transcribe(combined, decoderState: &decoderState, language: nil)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    func clearError() { if case .error = state { state = .idle } }

    // MARK: - on-disk model management (for the Models settings tab)

    /// Where FluidAudio caches downloaded ASR models.
    nonisolated static var modelsDirOnDisk: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    nonisolated static var modelsPresentOnDisk: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: modelsDirOnDisk.path))?.isEmpty == false
    }

    /// Remove the on-disk models and unload — next dictation re-downloads.
    func deleteModelsFromDisk() {
        try? FileManager.default.removeItem(at: Self.modelsDirOnDisk)
        manager = nil
        finalASR = nil
        finalVersionLoaded = nil
        modelReady = false
        if case .error = state {} else { state = .idle }
    }

    // MARK: - capture

    private func beginCapture(into manager: any StreamingAsrManager) throws {
        let input = audio.inputNode
        // Clear any tap left behind by a previous failed start — installing a
        // second tap on the same bus crashes.
        input.removeTap(onBus: 0)
        let format = input.inputFormat(forBus: 0)
        captureFormat = format
        let queue = pending
        let rec = recorder
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buf, _ in
            // Copy once: the tap's buffer is only valid for this callback. The
            // same copy feeds the live stream (drained continuously) and the
            // recorder (kept whole for the final pass) — both read-only.
            if let copy = BufferQueue.copy(buf) { queue.push(copy); rec.push(copy) }
        }
        audio.prepare()
        try audio.start()
        // Pump loop: drain copied buffers into the actor and process chunks so
        // partials keep flowing. appendAudio accepts any format (resamples to
        // 16 kHz internally).
        pump = Task.detached {
            while !Task.isCancelled {
                let bufs = queue.drain()
                for b in bufs { try? await manager.appendAudio(b) }
                if !bufs.isEmpty { try? await manager.processBufferedAudio() }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}

/// Thread-safe FIFO handoff of mic buffers from the render thread to the ASR
/// pump task.
private final class BufferQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AVAudioPCMBuffer] = []

    func push(_ b: AVAudioPCMBuffer) { lock.lock(); items.append(b); lock.unlock() }
    func drain() -> [AVAudioPCMBuffer] {
        lock.lock(); let out = items; items.removeAll(keepingCapacity: true); lock.unlock()
        return out
    }

    /// Concatenate same-format buffers into one (for the batch final pass).
    static func concat(_ bufs: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = bufs.first else { return nil }
        let format = first.format
        let total = bufs.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard total > 0, let dst = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else { return nil }
        let channels = Int(format.channelCount)
        // Interleaved formats expose a single plane holding frames*channels
        // samples; non-interleaved expose one plane per channel. Copy per plane
        // so we never index a channel pointer that doesn't exist.
        let interleaved = format.isInterleaved
        let planes = interleaved ? 1 : channels
        var offset = 0   // per-plane sample offset
        for b in bufs {
            guard b.format == format else { return nil }   // mismatched layout → bail, don't OOB
            let perPlane = interleaved ? Int(b.frameLength) * channels : Int(b.frameLength)
            if let s = b.floatChannelData, let d = dst.floatChannelData {
                for p in 0..<planes { memcpy(d[p] + offset, s[p], perPlane * MemoryLayout<Float>.size) }
            } else if let s = b.int16ChannelData, let d = dst.int16ChannelData {
                for p in 0..<planes { memcpy(d[p] + offset, s[p], perPlane * MemoryLayout<Int16>.size) }
            } else {
                return nil
            }
            offset += perPlane
        }
        dst.frameLength = total
        return dst
    }

    /// Deep-copy a tap buffer so it stays valid past the callback.
    static func copy(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let dst = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: src.frameLength) else { return nil }
        dst.frameLength = src.frameLength
        let frames = Int(src.frameLength)
        let channels = Int(src.format.channelCount)
        // See concat: one plane (interleaved) vs one per channel.
        let interleaved = src.format.isInterleaved
        let planes = interleaved ? 1 : channels
        let perPlane = interleaved ? frames * channels : frames
        if let s = src.floatChannelData, let d = dst.floatChannelData {
            for p in 0..<planes { memcpy(d[p], s[p], perPlane * MemoryLayout<Float>.size) }
        } else if let s = src.int16ChannelData, let d = dst.int16ChannelData {
            for p in 0..<planes { memcpy(d[p], s[p], perPlane * MemoryLayout<Int16>.size) }
        } else {
            return nil
        }
        return dst
    }
}
