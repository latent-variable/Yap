import AVFoundation
import Foundation
import FluidAudio

/// The "ears": native Parakeet ASR on the Apple Neural Engine via FluidAudio.
/// Push-to-talk → live partial transcript (for the HUD) → final text the caller
/// inserts at the cursor.
///
/// Uses `SlidingWindowAsrManager` with the real Parakeet TDT models —
/// **v2 (English)** and **v3 (multilingual, 25 languages)**, the same family
/// FluidVoice uses. Overlapping windows give pseudo-streaming: partial updates
/// arrive *while you speak*, and `finish()` returns the authoritative transcript
/// built from all accumulated tokens (so the inserted text is correct even if a
/// mid-stream partial looked rough).
///
/// The weights download once per version and are cached; a manager is single-use
/// (its input stream can't be reopened after `finish()`), so each push-to-talk
/// session spins a fresh manager over the already-loaded models — cheap.
@MainActor
final class Dictation: ObservableObject {

    /// User-facing engine choice → concrete Parakeet model version.
    enum EngineChoice: String, CaseIterable, Identifiable {
        case english      // Parakeet TDT 0.6B v2 — English
        case multilingual // Parakeet TDT 0.6B v3 — 25 languages
        var id: String { rawValue }
        // Same model family, same speed. English (v2) is more accurate for
        // English; multilingual (v3) trades a little English precision for 25
        // languages.
        var label: String { self == .english ? "English" : "Multilingual" }
        var version: AsrModelVersion { self == .english ? .v2 : .v3 }
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

    // Downloaded weights, kept across sessions (re-downloaded only on engine
    // switch). The per-session manager is built from these.
    private var models: AsrModels?
    private var loadedVersion: AsrModelVersion?
    private var manager: SlidingWindowAsrManager?
    private var updatesTask: Task<Void, Never>?

    private let audio = AVAudioEngine()
    private var pump: Task<Void, Never>?
    // Render-thread → actor handoff. nonisolated so the mic tap (any thread)
    // can enqueue without touching main-actor state.
    private nonisolated let pending = BufferQueue()

    var isListening: Bool { state == .listening }

    /// Low-latency sliding-window layout for live dictation. Small chunk → an
    /// update roughly every second; small right-context → first text in ~1.5s
    /// instead of ~13s. Left context keeps accuracy. Total window
    /// (left+chunk+right = 3.5s) stays well under the model's 15s max input.
    /// Tune chunk/right down further if it should feel even snappier.
    private static let lowLatencyConfig = SlidingWindowAsrConfig(
        chunkSeconds: 1.0,
        hypothesisChunkSeconds: 1.0,
        leftContextSeconds: 2.0,
        rightContextSeconds: 0.5,
        minContextForConfirmation: 1.5,
        confirmationThreshold: 0.80
    )

    /// Download (first time) + cache the Parakeet weights for the chosen engine.
    func loadModel(_ choice: EngineChoice) async {
        if case .loadingModel = state { return }
        if modelReady, engineChoice == choice, models != nil { return }
        state = .loadingModel
        engineChoice = choice
        Prefs.shared.dictationEngine = choice.rawValue
        do {
            let m = try await AsrModels.downloadAndLoad(version: choice.version)
            models = m
            loadedVersion = choice.version
            modelReady = true
            state = .idle
        } catch {
            modelReady = false
            state = .error("Model load failed: \(error.localizedDescription)")
        }
    }

    /// Start mic capture and live streaming (asks Microphone permission once).
    func startListening() {
        guard modelReady, state == .idle, let models else { return }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard granted else { self.state = .error("Microphone access denied"); return }
                do {
                    // Fresh single-use manager over the already-loaded weights,
                    // with a LOW-LATENCY window so partials stream as you speak.
                    // SlidingWindowAsrManager emits one update per `chunkSeconds`
                    // and won't emit the first until `chunkSeconds + rightContext`
                    // of audio exists — the stock 11+2 means ~13s before any text,
                    // then every 11s. A ~1s chunk with minimal right-context lookahead
                    // (left context preserves accuracy) makes words pop ~1s apart.
                    // finish() still returns the authoritative full transcript.
                    let mgr = SlidingWindowAsrManager(config: Self.lowLatencyConfig)
                    try await mgr.loadModels(models)
                    self.manager = mgr
                    self.partial = ""
                    // Consume live partials (access the stream ONCE — it stores a
                    // single continuation).
                    self.updatesTask = Task { [weak self] in
                        for await update in await mgr.transcriptionUpdates {
                            await MainActor.run { self?.partial = update.text }
                        }
                    }
                    try await mgr.startStreaming(source: .microphone)
                    self.beginCapture(into: mgr)
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
            // Feed anything still queued, then finish (finish() closes the input
            // stream and drains the recognizer).
            for b in pending.drain() { await manager.streamAudio(b) }
            let text = try await manager.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            updatesTask?.cancel(); updatesTask = nil
            self.manager = nil
            lastFinal = text
            partial = ""
            state = .idle
            return text.isEmpty ? nil : text
        } catch {
            updatesTask?.cancel(); updatesTask = nil
            await manager.cancel()
            self.manager = nil
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
        models = nil
        loadedVersion = nil
        modelReady = false
        if case .error = state {} else { state = .idle }
    }

    // MARK: - capture

    private func beginCapture(into manager: SlidingWindowAsrManager) {
        let input = audio.inputNode
        let format = input.inputFormat(forBus: 0)
        let queue = pending
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buf, _ in
            // Copy: the tap's buffer is only valid for this callback.
            if let copy = BufferQueue.copy(buf) { queue.push(copy) }
        }
        audio.prepare()
        do { try audio.start() } catch {
            state = .error("Mic start failed: \(error.localizedDescription)")
            return
        }
        // Pump loop: drain copied buffers into the actor. The manager's recognizer
        // task converts to 16 kHz and processes windows on its own, emitting
        // partials through transcriptionUpdates.
        pump = Task.detached {
            while !Task.isCancelled {
                for b in queue.drain() { await manager.streamAudio(b) }
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
