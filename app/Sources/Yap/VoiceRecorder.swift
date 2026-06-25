import AVFoundation

/// Records a short mic clip (mono 24 kHz WAV) to use as a cloning reference.
/// Auto-stops at `maxSeconds`. macOS prompts for Microphone access on first use.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    @Published var recording = false
    @Published var elapsed: Double = 0
    @Published var denied = false

    let maxSeconds: Double = 20
    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    // Timer.invalidate must run on the thread that scheduled it (main); deinit
    // can fire on any thread, so hop to main. Timer isn't Sendable, but handing
    // this one reference to the main queue and invalidating it there is safe.
    deinit {
        if let t = timer {
            nonisolated(unsafe) let timerRef = t
            DispatchQueue.main.async { timerRef.invalidate() }
        }
    }
    private(set) var outputURL: URL?

    func toggle(_ onFinish: @escaping (URL?) -> Void) {
        recording ? finish(onFinish) : start(onFinish)
    }

    private func start(_ onFinish: @escaping (URL?) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard granted else { self.denied = true; onFinish(nil); return }
                self.beginRecording(onFinish)
            }
        }
    }

    private func beginRecording(_ onFinish: @escaping (URL?) -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "yap_rec_\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 24000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.record()
            recorder = r
            outputURL = url
            recording = true
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.recording else { return }
                    self.elapsed += 0.1
                    if self.elapsed >= self.maxSeconds { self.finish(onFinish) }
                }
            }
        } catch {
            recording = false
            onFinish(nil)
        }
    }

    private func finish(_ onFinish: @escaping (URL?) -> Void) {
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        recording = false
        onFinish(elapsed >= 1.0 ? outputURL : nil)  // ignore accidental taps
    }
}
