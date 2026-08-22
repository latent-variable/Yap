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
    // Cumulative frames the node reported as PLAYED BACK this session. Unlike
    // `scheduledFrames` (a level, which drains to 0 whether the audio was heard
    // or discarded) this only ever goes up, and only on a real completion — so a
    // probe can assert that audio actually rendered rather than that wall-clock
    // time passed. Test-only reader: `playedSeconds`.
    private var playedFrames: UInt64 = 0
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
    // Is a playback session live? The engine's render thread + its
    // AUScheduledParameterRefresher spin continuously while the engine runs, so we
    // STOP the engine when idle (see stop()) to stop burning CPU/energy between
    // reads. `active` guards the config-change recovery from restarting a parked
    // engine on a route change while nothing is playing.
    // Main-thread-confined, like the engine calls it guards: start()/stop()/
    // resume() are invoked from @MainActor AppState, and the config observer runs
    // on queue:.main. It is deliberately NOT `q`-owned (that queue owns node/buffer
    // state); there is no cross-thread access, so no lock is needed.
    private var active = false
    // Bumped on every start()/stop(). A scheduleBuffer completion from a previous
    // session carries the old epoch and is ignored, so it can't decrement (and
    // underflow, since the count is unsigned) the new session's frame counter.
    private var epoch: UInt64 = 0

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
        // Only restart if we're actually mid-playback. Restarting a parked engine
        // on an idle route change would put its render thread right back to
        // spinning — the very drain we stop the engine to avoid.
        if active && !engine.isRunning { try? engine.start() }
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
    func start(volume: Float, pitchCents: Float, rate: Float, cushionSeconds: Double = 0.35) throws {
        set(volume: volume, pitchCents: pitchCents)
        setRate(rate)
        q.sync {
            epoch &+= 1                  // invalidate any in-flight completions
            primed = false
            paused = false
            ended = false
            scheduledFrames = 0
            playedFrames = 0
            leftoverByte = nil
            primeFrames = AVAudioFrameCount(max(0.05, cushionSeconds) * 24000)
            player.stop()
            player.reset()
        }
        active = true
        if !engine.isRunning {
            do { try engine.start() }
            catch {
                // Surface the failure instead of swallowing it: with the engine
                // dead, scheduled buffers never play, so scheduledFrames never
                // decrements and the caller's drain loop would spin forever. Let the
                // caller park + show an error instead.
                active = false
                throw error
            }
        }
        // engine running but the node waits for the cushion (see feed/flush)
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
                    self.playedFrames &+= UInt64(frames)
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

    /// Returns whether playback actually resumed — `false` if the engine couldn't
    /// restart, so the caller can avoid showing a "reading" state with no audio.
    @discardableResult
    func resume() -> Bool {
        active = true
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            // Don't unpause the node behind a dead engine — leave it consistent.
            active = false
            NSLog("audio engine resume failed: \(error)")
            return false
        }
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
        return true
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
        // Park the engine so its render thread stops spinning while idle. start()/
        // resume() restart it for the next read (the cushion hides the ~ms restart
        // latency). Engine calls stay off `q`, on the calling thread, per the graph
        // ownership contract above.
        active = false
        if engine.isRunning { engine.stop() }
    }

    /// Approximate: is anything still queued?
    var hasQueued: Bool { q.sync { scheduledFrames > 0 } }

    /// Seconds of audio scheduled but not yet played back.
    ///
    /// Drives stream backpressure. Both backends generate far faster than
    /// realtime (measured on a README-sized read: Kokoro 9.1x, Pocket 14.4x), and
    /// nothing in the read path used to wait for playback — so a long document
    /// queued *the whole thing* onto the node ahead of the listener: ~2,950
    /// buffers / 57 MB for 11 minutes of audio, and ~19,850 buffers / 381 MB for
    /// a 46k-character document. `AppState.stream` stalls the reader while this
    /// is over `maxQueuedSeconds`, which bounds the node to ~50 buffers / ~1 MB
    /// no matter how long the text is.
    var queuedSeconds: Double { q.sync { Double(scheduledFrames) / 24000.0 } }

    /// How far ahead of the listener we let the stream run. Far above the 0.35s
    /// prime cushion, so a stalled reader can never starve playback: at the
    /// slowest measured generation rate the backend refills this in a fraction of
    /// the time it takes to play.
    static let maxQueuedSeconds: Double = 10.0

    /// The backpressure policy, shared by the app (`AppState.streamGate`) and the
    /// `--backpressure` probe so both exercise the same loop rather than a copy.
    ///
    /// `sample` reports whether the read is still current and how much audio is
    /// queued; the returned closure is what `BackendClient.streamPCM` awaits after
    /// each chunk. Polling beats a continuation: the two conditions it waits on —
    /// playback draining and the read being superseded — share no signal to
    /// resume from, and at 10 Hz against a 10s budget the latency is irrelevant.
    static func gate(sample: @escaping @Sendable () async -> (live: Bool, queued: Double))
        -> @Sendable () async -> Bool {
        {
            while true {
                let s = await sample()
                if !s.live { return false }
                if s.queued <= maxQueuedSeconds { return true }
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return false }
            }
        }
    }

    /// Test hook (`--tailtest`): seconds of audio the node reported as played back
    /// this session. Cumulative, so it survives the queue draining to empty.
    var playedSeconds: Double { q.sync { Double(playedFrames) / 24000.0 } }

    /// Test hook (`--selftest`): observe engine run state to verify idle-parking.
    var isEngineRunning: Bool { engine.isRunning }
}
