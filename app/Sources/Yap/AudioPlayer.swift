import AVFoundation

/// Low-latency streaming player. Accepts int16 mono PCM at 24 kHz, converts to
/// float buffers, and schedules them on an AVAudioPlayerNode as they arrive.
/// Pitch and volume run through an AVAudioUnitTimePitch node.
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pitchUnit = AVAudioUnitTimePitch()
    private let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 24000, channels: 1, interleaved: false)!

    // A single serial queue owns EVERY player-node call (schedule/play/pause/
    // stop/reset) and all the mutable state below. Every entry point hops onto
    // it, so node calls never run concurrently (no data race) and buffer
    // completions dispatch back onto it asynchronously (no lock is held across a
    // node call, so a completion delivered during reset() can't deadlock). The
    // AVAudioEngine itself (start/isRunning) is engine-level, not node-level, and
    // stays on the calling thread.
    private let q = DispatchQueue(label: "com.yap.audioplayer")

    private var leftoverByte: UInt8?
    private var scheduledFrames: AVAudioFrameCount = 0
    // Pre-buffer: hold playback until this much audio is queued, so transient
    // slow chunks (HD generates near real-time) don't cause silence gaps.
    private var primeFrames: AVAudioFrameCount = 8400  // ~0.35s default
    private var primed = false
    // User paused. While set, incoming chunks still buffer but never (re)start
    // the node — otherwise the next streamed chunk silently un-pauses playback.
    private var paused = false
    // Stream finished (flush called). Lets resume() tell "paused mid-stream"
    // (let feed re-prime, preserving the cushion) from "paused after the stream
    // ended" (play the sub-cushion remainder now, since no more audio is coming).
    private var ended = false
    // Bumped on every start()/stop(). A scheduleBuffer completion from a previous
    // session carries the old epoch and is ignored, so it can't decrement (and
    // underflow, since the count is unsigned) the new session's frame counter.
    private var epoch: UInt64 = 0

    var onFinished: (() -> Void)?
    private var configObserver: NSObjectProtocol?

    init() {
        engine.attach(player)
        engine.attach(pitchUnit)
        engine.connect(player, to: pitchUnit, format: inFormat)
        engine.connect(pitchUnit, to: engine.mainMixerNode, format: inFormat)
        // A hardware/route change — e.g. the dictation mic engine starting or
        // stopping — stops this engine AND can tear down its connections. Without
        // recovery the voice goes permanently silent until relaunch. Rebuild the
        // graph and restart on every configuration change.
        // queue: .main so the graph rebuild/restart runs on a consistent thread
        // (the notification can fire on an arbitrary background thread).
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.recoverFromConfigChange() }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    private func recoverFromConfigChange() {
        engine.connect(player, to: pitchUnit, format: inFormat)
        engine.connect(pitchUnit, to: engine.mainMixerNode, format: inFormat)
        if !engine.isRunning { try? engine.start() }
    }

    func set(volume: Float, pitchCents: Float) {
        player.volume = max(0, min(1, volume))
        pitchUnit.pitch = pitchCents   // -2400...2400
    }

    /// Playback speed via time-stretch (pitch preserved). Safe to change live,
    /// even mid-playback — takes effect on the audio currently streaming.
    func setRate(_ rate: Float) {
        pitchUnit.rate = max(0.25, min(4.0, rate))
    }

    /// Begin a fresh playback session. `cushionSeconds` of audio is buffered
    /// before playback starts (larger for slower engines = smoother streaming).
    func start(volume: Float, pitchCents: Float, rate: Float, cushionSeconds: Double = 0.35) {
        set(volume: volume, pitchCents: pitchCents)
        setRate(rate)
        q.sync {
            epoch &+= 1                  // invalidate any in-flight completions
            primed = false
            paused = false
            ended = false
            scheduledFrames = 0
            leftoverByte = nil
            primeFrames = AVAudioFrameCount(max(0.05, cushionSeconds) * 24000)
            player.stop()
            player.reset()
        }
        do {
            if !engine.isRunning { try engine.start() }
            // engine running but the node waits for the cushion (see feed/flush)
        } catch {
            NSLog("audio engine start failed: \(error)")
        }
    }

    /// Start playback now even if the cushion isn't full (call when the stream
    /// ends, so short clips below the cushion still play).
    func flush() {
        q.async {
            self.ended = true
            if !self.paused && !self.primed && self.scheduledFrames > 0 {
                self.primed = true
                self.player.play()
            }
        }
    }

    /// Feed raw int16 little-endian PCM bytes.
    func feed(_ data: Data) {
        q.async {
            var bytes = data
            if let lo = self.leftoverByte {
                // Prepend via a fresh buffer; Data.insert(at: 0) is O(N).
                bytes = Data([lo]) + data
                self.leftoverByte = nil
            }
            if bytes.count % 2 == 1 {
                self.leftoverByte = bytes.last
                bytes.removeLast()
            }
            guard !bytes.isEmpty else { return }
            let sampleCount = bytes.count / 2
            guard let buffer = AVAudioPCMBuffer(pcmFormat: self.inFormat,
                                                frameCapacity: AVAudioFrameCount(sampleCount)) else { return }
            buffer.frameLength = AVAudioFrameCount(sampleCount)
            let dst = buffer.floatChannelData![0]
            bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                // loadUnaligned, not bindMemory: Data's backing bytes aren't
                // guaranteed 2-byte aligned, and binding Int16 to misaligned
                // memory is UB / can crash.
                for i in 0..<sampleCount {
                    let v = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                    dst[i] = Float(Int16(littleEndian: v)) / 32768.0
                }
            }
            let frames = buffer.frameLength
            let myEpoch = self.epoch
            self.scheduledFrames += frames
            self.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.q.async {
                    // ignore completions from a previous session; clamp so the
                    // unsigned counter can never underflow
                    guard myEpoch == self.epoch else { return }
                    self.scheduledFrames = self.scheduledFrames >= frames ? self.scheduledFrames - frames : 0
                }
            }
            // Start once the cushion is full; after that keep the node playing —
            // unless paused, in which case keep buffering but stay stopped.
            if !self.paused {
                if !self.primed {
                    if self.scheduledFrames >= self.primeFrames {
                        self.primed = true
                        self.player.play()
                    }
                } else if !self.player.isPlaying {
                    self.player.play()
                }
            }
        }
    }

    func pause() {
        q.async {
            self.paused = true
            self.player.pause()
        }
    }

    func resume() {
        if !engine.isRunning { try? engine.start() }
        q.async {
            self.paused = false
            if self.primed {
                self.player.play()                       // was playing before pause
            } else if self.ended && self.scheduledFrames > 0 {
                self.primed = true                       // stream done: play remainder
                self.player.play()
            }
            // else paused mid-prime, stream still live: leave unprimed so feed()
            // refills the cushion before starting — avoids an undersized buffer.
        }
    }

    func stop() {
        q.sync {
            epoch &+= 1
            primed = false
            paused = false
            ended = false
            scheduledFrames = 0
            leftoverByte = nil
            player.stop()
            player.reset()
        }
    }

    /// Approximate: is anything still queued?
    var hasQueued: Bool { q.sync { scheduledFrames > 0 } }
}
