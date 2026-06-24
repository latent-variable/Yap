import AVFoundation
import Foundation
import FluidAudio

/// The "ears": native streaming Parakeet ASR on the Apple Neural Engine via
/// FluidAudio. Push-to-talk → live partial transcript (for the HUD) → final
/// text the caller inserts at the cursor.
///
/// Streaming (not record-then-transcribe) so text appears *as you speak*:
/// FluidAudio emits partial-transcript updates through a callback while audio
/// is fed in chunks.
@MainActor
final class Dictation: ObservableObject {

    /// User-facing engine choice → concrete streaming model.
    enum EngineChoice: String, CaseIterable, Identifiable {
        case english      // Parakeet EOU 120M, low latency
        case multilingual // Nemotron 0.6B, 25 languages
        var id: String { rawValue }
        // Same model family, same speed. English is more accurate for English;
        // multilingual trades a little English precision for 25 languages.
        var label: String { self == .english ? "English" : "Multilingual" }
        var variant: StreamingModelVariant { self == .english ? .parakeetEou320ms : .nemotron1120ms }
    }

    enum State: Equatable {
        case idle, loadingModel, listening, transcribing
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var modelReady = false
    @Published var engineChoice: EngineChoice = .english
    /// Live transcript while listening — drives the HUD.
    @Published private(set) var partial = ""
    @Published private(set) var lastFinal = ""

    private var manager: (any StreamingAsrManager)?
    private let audio = AVAudioEngine()
    private var pump: Task<Void, Never>?
    // Render-thread → actor handoff. nonisolated so the mic tap (any thread)
    // can enqueue without touching main-actor state.
    private nonisolated let pending = BufferQueue()

    var isListening: Bool { state == .listening }

    /// Download (first time) + load the streaming model for the chosen engine.
    func loadModel(_ choice: EngineChoice) async {
        if case .loadingModel = state { return }
        if modelReady, engineChoice == choice, manager != nil { return }
        state = .loadingModel
        engineChoice = choice
        Prefs.shared.dictationEngine = choice.rawValue
        do {
            let mgr = choice.variant.createManager()
            try await mgr.loadModels()
            await mgr.setPartialTranscriptCallback { [weak self] text in
                Task { @MainActor in self?.partial = text }
            }
            manager = mgr
            modelReady = true
            state = .idle
        } catch {
            modelReady = false
            state = .error("Model load failed: \(error.localizedDescription)")
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
        pump?.cancel(); pump = nil
        state = .transcribing
        do {
            // Feed anything still queued, then finish.
            for b in pending.drain() { try? await manager.appendAudio(b) }
            try? await manager.processBufferedAudio()
            let text = try await manager.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            lastFinal = text
            partial = ""
            state = .idle
            return text.isEmpty ? nil : text
        } catch {
            state = .error("Transcription failed: \(error.localizedDescription)")
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
        modelReady = false
        if case .error = state {} else { state = .idle }
    }

    // MARK: - capture

    private func beginCapture(into manager: any StreamingAsrManager) throws {
        let input = audio.inputNode
        let format = input.inputFormat(forBus: 0)
        let queue = pending
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buf, _ in
            // Copy: the tap's buffer is only valid for this callback.
            if let copy = BufferQueue.copy(buf) { queue.push(copy) }
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

    /// Deep-copy a tap buffer so it stays valid past the callback.
    static func copy(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let dst = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: src.frameLength) else { return nil }
        dst.frameLength = src.frameLength
        let frames = Int(src.frameLength)
        let channels = Int(src.format.channelCount)
        if let s = src.floatChannelData, let d = dst.floatChannelData {
            for ch in 0..<channels { memcpy(d[ch], s[ch], frames * MemoryLayout<Float>.size) }
        } else if let s = src.int16ChannelData, let d = dst.int16ChannelData {
            for ch in 0..<channels { memcpy(d[ch], s[ch], frames * MemoryLayout<Int16>.size) }
        } else {
            return nil
        }
        return dst
    }
}
