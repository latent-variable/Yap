import AVFoundation
import Foundation
import FluidAudio

/// The "ears": native Parakeet ASR on the Apple Neural Engine via FluidAudio.
/// Push-to-talk → capture mic → transcribe → (caller inserts the text).
///
/// Two halves:
///  - `MicCapture` records the mic and resamples to the 16 kHz mono Float that
///    Parakeet expects, off the main actor (the tap runs on a render thread).
///  - `Dictation` (@MainActor) owns the model lifecycle + UI state.
@MainActor
final class Dictation: ObservableObject {
    enum State: Equatable {
        case idle, loadingModel, listening, transcribing
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var modelReady = false
    @Published private(set) var version: AsrModelVersion = .v3
    @Published var lastText = ""

    private var asr: AsrManager?
    private let mic = MicCapture()

    var isListening: Bool { state == .listening }

    /// Download (first time) + load the chosen Parakeet model. v3 = 25-language
    /// multilingual, v2 = English-only. Idempotent for a given version.
    func loadModel(_ v: AsrModelVersion) async {
        if case .loadingModel = state { return }
        if modelReady, version == v { return }
        state = .loadingModel
        version = v
        do {
            let models = try await AsrModels.downloadAndLoad(version: v)
            let manager = AsrManager()
            try await manager.loadModels(models)
            asr = manager
            modelReady = true
            state = .idle
        } catch {
            modelReady = false
            state = .error("Model load failed: \(error.localizedDescription)")
        }
    }

    /// Begin capturing the mic (asks for Microphone permission on first use).
    func startListening() {
        guard modelReady, state == .idle else { return }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard granted else { self.state = .error("Microphone access denied"); return }
                do {
                    try self.mic.start()
                    self.state = .listening
                } catch {
                    self.state = .error("Mic start failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Stop capturing and transcribe what was said. Returns the trimmed text
    /// (nil if nothing usable was captured).
    @discardableResult
    func stopAndTranscribe() async -> String? {
        guard state == .listening, let asr else { return nil }
        let samples = mic.stop()
        // Under ~0.1s of audio — treat as an accidental tap, not speech.
        guard samples.count > 1600 else { state = .idle; return nil }
        state = .transcribing
        do {
            var decoderState = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
            let result = try await asr.transcribe(samples, decoderState: &decoderState)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            lastText = text
            state = .idle
            return text.isEmpty ? nil : text
        } catch {
            state = .error("Transcription failed: \(error.localizedDescription)")
            return nil
        }
    }

    func clearError() {
        if case .error = state { state = .idle }
    }
}

/// Records the microphone and resamples to 16 kHz mono Float32 (Parakeet's input
/// format). Lives off the main actor — the input tap fires on a render thread.
private final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 16_000, channels: 1, interleaved: false)!

    func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: target)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, _ in
            self?.append(buf)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stop capture and hand back everything recorded (clearing the buffer).
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); let out = samples; samples.removeAll(); lock.unlock()
        return out
    }

    private func append(_ buf: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var err: NSError?
        var fed = false
        converter.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buf
        }
        guard err == nil, let ch = outBuf.floatChannelData, outBuf.frameLength > 0 else { return }
        let n = Int(outBuf.frameLength)
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
        lock.unlock()
    }
}
