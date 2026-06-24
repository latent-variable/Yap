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
    private var loadTask: Task<Void, Never>?   // supersedable engine load (last wins)
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

    /// Switch/load the dictation engine, superseding any in-flight load so the
    /// LAST selection wins. Use this from the UI (picker, retry, download) rather
    /// than spawning ad-hoc `Task { await loadModel(...) }`, which would race.
    func requestLoad(_ choice: EngineChoice) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.loadModel(choice) }
    }

    /// Download (first time) + load the streaming model for the chosen engine.
    /// Loaded once and reused — startListening only reset()s it. Concurrent calls
    /// for different engines are safe: `engineChoice` records the latest request,
    /// and a load only commits if it still matches it (else it's stale, discarded).
    func loadModel(_ choice: EngineChoice) async {
        if modelReady, engineChoice == choice, manager != nil { return }
        // Record the latest request up front so a superseding switch is detectable
        // after each await; the picker also reflects the new selection immediately.
        engineChoice = choice
        Prefs.shared.dictationEngine = choice.rawValue
        state = .loadingModel
        do {
            let mgr = choice.variant.createManager()
            try await mgr.loadModels()
            // A newer switch superseded this load while it ran — discard it.
            guard !Task.isCancelled, engineChoice == choice else { return }
            // The callback fires with the full running transcript on each new
            // token — drive the HUD straight from it.
            await mgr.setPartialTranscriptCallback { [weak self] text in
                Task { @MainActor in self?.partial = text }
            }
            guard engineChoice == choice else { return }
            manager = mgr
            modelReady = true
            state = .idle
            // Warm the high-accuracy final-pass model in the background so it's
            // ready by the time you stop talking. Best-effort.
            let fv = choice.finalVersion
            Task { await self.loadFinalModel(fv) }
        } catch is CancellationError {
            return   // superseded by a newer switch — not a real failure
        } catch {
            // A cancelled URLSession/load can surface as a non-CancellationError;
            // ignore it too, and only surface a failure for the live selection so
            // a stale load can't stamp a false error over the new engine's state.
            guard !Task.isCancelled, engineChoice == choice else { return }
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
            // The user may have switched engines while this loaded — don't
            // install a now-stale model over the current selection.
            guard engineChoice.finalVersion == version else { return }
            finalASR = mgr
            finalVersionLoaded = version
        } catch {
            if finalVersionLoaded == version { finalASR = nil; finalVersionLoaded = nil }
        }
    }

    /// Start mic capture and live streaming (asks Microphone permission once).
    private var starting = false

    func startListening() {
        // `starting` blocks a second press during the async permission window —
        // state stays .idle until the callback, so without this two quick presses
        // would each begin capture and orphan a pump.
        guard !starting, modelReady, state == .idle, let manager else { return }
        starting = true
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                defer { self.starting = false }
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
            // transcript if the batch model isn't ready, fails, or the recording
            // exceeded the memory budget (very long hold).
            let overflowed = recorder.overflowed
            let recorded = recorder.drain()
            let accurate = overflowed ? nil : await runFinalPass(recorded)
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
        // Only trust the batch model if it matches the currently-selected engine
        // (a language switch may have left a stale model loaded).
        guard let finalASR, finalVersionLoaded == engineChoice.finalVersion,
              let combined = BufferQueue.concat(buffers) else { return nil }
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
        // Cap the kept-for-final-pass audio at ~3 minutes so an accidental long
        // hold can't exhaust memory. Past the cap the live transcript still works;
        // only the optional accurate re-pass is skipped.
        let maxRecFrames = Int(format.sampleRate * 180)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buf, _ in
            // Copy once: the tap's buffer is only valid for this callback. The
            // same copy feeds the live stream (drained continuously) and the
            // recorder (kept whole, bounded, for the final pass) — both read-only.
            if let copy = BufferQueue.copy(buf) { queue.push(copy); rec.pushCapped(copy, maxFrames: maxRecFrames) }
        }
        audio.prepare()
        try audio.start()
        pump?.cancel()   // never leave a prior pump running on a new capture
        // Pump loop: drain copied buffers into the actor and process chunks so
        // partials keep flowing. appendAudio accepts any format (resamples to
        // 16 kHz internally).
        pump = Task.detached {
            while !Task.isCancelled {
                let bufs = queue.drain()
                for b in bufs { try? await manager.appendAudio(b) }
                if !bufs.isEmpty { try? await manager.processBufferedAudio() }
                // do/catch (not try?) so cancellation breaks the loop immediately
                // instead of running one more full iteration after cancel.
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { break }
            }
        }
    }
}

/// Thread-safe FIFO handoff of mic buffers from the render thread to the ASR
/// pump task.
private final class BufferQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AVAudioPCMBuffer] = []
    private var frames = 0
    private var overflowedFlag = false

    func push(_ b: AVAudioPCMBuffer) { lock.lock(); items.append(b); lock.unlock() }

    /// Push only while under a frame budget. Past it, set the overflow flag and
    /// stop accumulating — bounds memory for the (optional) final pass on a very
    /// long hold; the live transcript is unaffected.
    func pushCapped(_ b: AVAudioPCMBuffer, maxFrames: Int) {
        lock.lock()
        if frames >= maxFrames { overflowedFlag = true }
        else { items.append(b); frames += Int(b.frameLength) }
        lock.unlock()
    }

    var overflowed: Bool { lock.lock(); defer { lock.unlock() }; return overflowedFlag }

    func drain() -> [AVAudioPCMBuffer] {
        lock.lock()
        let out = items; items.removeAll(keepingCapacity: true)
        frames = 0; overflowedFlag = false
        lock.unlock()
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
