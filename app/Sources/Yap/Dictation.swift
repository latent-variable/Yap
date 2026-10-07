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
        case idle, loadingModel, listening, finishing, transcribing
        case error(String)
    }

    /// May a model load write `state`?
    ///
    /// No, while a capture session owns it. An engine switch is one click away
    /// in the menu bar and in Settings, and nothing disables it mid-dictation,
    /// so a load can land at any point in a session. Letting it commit
    /// `state = .idle` over a live `.listening` made `stopAndTranscribe`'s
    /// `guard state == .listening` fail, and the user's speech was dropped with
    /// no error shown. `starting` covers the async mic-permission window, where
    /// state is still `.idle` but a session is already coming up.
    ///
    /// Pure and internal so `--selftest` can cover it: the rest of the path
    /// needs a mic and a loaded model.
    /// May the loaded batch model re-transcribe this session's audio?
    ///
    /// Only when it is the version the session was captured under. Both guards
    /// used to compare against the live `engineChoice`, which moves when the
    /// picker does: switching multilingual→English mid-utterance loaded the
    /// English batch model, passed the guard, and ran it over Spanish audio. The
    /// garbage it returned then *overrode* the correct live transcript, because
    /// a non-empty accurate pass always wins. Refusing falls back to the live
    /// text, which is the degradation this path already documents.
    ///
    /// Pure and nonisolated so `--selftest` can cover it.
    nonisolated static func batchModelUsable(loaded: AsrModelVersion?,
                                             session: AsrModelVersion?) -> Bool {
        guard let loaded, let session else { return false }
        return loaded == session
    }

    nonisolated static func loadMayWriteState(starting: Bool, state: State) -> Bool {
        if starting { return false }
        switch state {
        case .listening, .finishing, .transcribing: return false
        case .idle, .loadingModel, .error: return true
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var modelReady = false
    @Published var engineChoice: EngineChoice = .english
    /// Live transcript while listening — drives the HUD. Full running transcript,
    /// self-correcting, not a per-chunk fragment.
    @Published private(set) var partial = ""
    /// Rolling high-accuracy preview: the batch model (same one used for the final
    /// pass) re-transcribed over everything captured so far, refreshed ~1/sec while
    /// you talk. The fast streaming `partial` cuts/misses words; this reads at
    /// final-pass quality, so the preview converges to exactly the inserted text.
    /// The HUD prefers this when present, falling back to `partial` otherwise.
    @Published private(set) var refined = ""
    @Published private(set) var lastFinal = ""

    private var manager: (any StreamingAsrManager)?
    /// The manager ONE capture session is bound to, held for its whole life.
    /// `manager` is a slot the engine picker can swap at any moment; the pump,
    /// the reset and the final flush must all be the same instance, so the
    /// session captures it once at `beginCapture` and `stopAndTranscribe` reads
    /// it back from here rather than re-reading the slot.
    private var sessionManager: (any StreamingAsrManager)?
    /// The batch-model version this session's audio belongs to, captured with
    /// `sessionManager`. `engineChoice` is live and moves under a session, so the
    /// batch guards key on this instead.
    private var sessionFinalVersion: AsrModelVersion?
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
    private var finalTask: Task<Void, Never>?   // tracked final-pass (v2/v3) warm-up
    private var refineTask: Task<Void, Never>?  // rolling accurate-preview loop
    /// Bumped per capture session to reject stale preview writes.
    private var session = 0
    /// A finished preview plus token times. Token times locate an overlapping
    /// final segment; loudness never decides whether the ending is complete.
    private var settled: (text: String, frames: Int, timings: [TokenTiming])?
    /// How the last stop got its text, and how long it took. For the log and
    /// `--dictstop`.
    private(set) var lastStop = ""
    /// Probe control: always run the full final pass (the pre-reuse behaviour).
    static var forceFinalPass = false
    /// A probe session feeds audio itself; there is no mic tap to tear down.
    private var simulated = false
    /// A short post-press window catches a word still reaching the mic tap.
    /// Bounded independently of ASR latency; the mic is closed before decoding.
    static let captureFinishSeconds = 0.6
    /// Probe control: reproduce the immediate mic cutoff.
    static var immediateStop = false
    private var captureGate: DictationCaptureGate?
    private(set) var lastStopCapturedFrames = 0

    var isListening: Bool { state == .listening }

    /// Switch/load the dictation engine, superseding any in-flight load so the
    /// LAST selection wins. Use this from the UI (picker, retry, download) rather
    /// than spawning ad-hoc `Task { await loadModel(...) }`, which would race.
    func requestLoad(_ choice: EngineChoice) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.loadModel(choice) }
    }

    /// Like `requestLoad` but awaits completion — for callers that must wait
    /// (bootstrap warm-up, toggle's lazy load). Still tracked in `loadTask`, so a
    /// model delete can cancel it.
    func loadModelAwaiting(_ choice: EngineChoice) async {
        loadTask?.cancel()
        let task: Task<Void, Never> = Task { [weak self] in await self?.loadModel(choice) }
        loadTask = task
        await task.value
    }

    /// Download (first time) + load the streaming model for the chosen engine.
    /// Loaded once and reused — startListening only reset()s it. Concurrent calls
    /// for different engines are safe: `engineChoice` records the latest request,
    /// and a load only commits if it still matches it (else it's stale, discarded).
    /// Private: external callers use `requestLoad` (fire-and-forget) or
    /// `loadModelAwaiting` (tracked + awaited) so every load lands in `loadTask`.
    private func loadModel(_ choice: EngineChoice) async {
        // Already loading this same engine — don't kick off a duplicate concurrent
        // load (e.g. startListening fires while a load is mid-flight). A switch to a
        // *different* engine still proceeds (engineChoice differs).
        if state == .loadingModel, engineChoice == choice { return }
        if modelReady, engineChoice == choice, manager != nil { return }
        // Record the latest request up front so a superseding switch is detectable
        // after each await; the picker also reflects the new selection immediately.
        engineChoice = choice
        Prefs.shared.dictationEngine = choice.rawValue
        if Dictation.loadMayWriteState(starting: starting, state: state) { state = .loadingModel }
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
            // Re-check cancellation too: a model delete during the await above
            // cancels this task, and without this guard the resumed task would
            // re-install a manager for files that were just deleted.
            guard !Task.isCancelled, engineChoice == choice else { return }
            manager = mgr
            modelReady = true
            // Swapping the slot mid-session is harmless — the session holds its
            // own instance in `sessionManager` — but the state must not move.
            if Dictation.loadMayWriteState(starting: starting, state: state) { state = .idle }
            // Warm the high-accuracy final-pass model in the background so it's
            // ready by the time you stop talking. Best-effort, and tracked so a
            // later engine switch or a model delete can cancel it.
            let fv = choice.finalVersion
            finalTask?.cancel()
            finalTask = Task { [weak self] in await self?.loadFinalModel(fv) }
        } catch is CancellationError {
            return   // superseded by a newer switch — not a real failure
        } catch {
            // A cancelled URLSession/load can surface as a non-CancellationError;
            // ignore it too, and only surface a failure for the live selection so
            // a stale load can't stamp a false error over the new engine's state.
            guard !Task.isCancelled, engineChoice == choice else { return }
            modelReady = false
            if Dictation.loadMayWriteState(starting: starting, state: state) {
                state = .error("Model load failed: \(error.localizedDescription)")
            }
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
            // The user may have switched engines (or this task was cancelled by a
            // delete) while it loaded — don't install a now-stale model.
            guard !Task.isCancelled, engineChoice.finalVersion == version else { return }
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
        // Bind the choice HERE, with the manager, not after the await below. The
        // picker stays live through the permission window, so reading it in the
        // callback could pair the new engine's batch model with the old engine's
        // streaming manager — the wrong-language final pass this whole change
        // exists to prevent.
        let choice = engineChoice
        starting = true
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                defer { self.starting = false }
                guard granted else { self.state = .error("Microphone access denied"); return }
                do {
                    try await manager.reset()
                    self.beginSession()
                    try self.beginCapture(into: manager)
                    self.sessionManager = manager   // bind for the whole session
                    self.sessionFinalVersion = choice.finalVersion
                    self.state = .listening
                    self.startRefineLoop()      // accurate preview, layered over streaming
                } catch {
                    self.state = .error("Mic start failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Stop capture, flush, and return the final transcript (nil if empty).
    ///
    /// Keep the accurate head and decode an overlapping final segment, including
    /// every captured frame through stop. Never infer final coverage from
    /// loudness: a quiet word or a short syllable can look like noise/a key click.
    /// With no safe boundary (or no preview), decode the full recording.
    @discardableResult
    func stopAndTranscribe() async -> String? {
        // The session's own instance, not the slot: an engine switch during the
        // read may already have replaced `manager` with one that never saw this
        // audio, which flushed an empty transcript over real speech.
        guard state == .listening, let manager = sessionManager else { return nil }
        defer { sessionManager = nil; sessionFinalVersion = nil }
        let t0 = Date()
        // Flip state first: a second press during the awaits below must not start
        // another stop, and a preview pass finishing now must not publish.
        state = .finishing
        captureGate?.finish(until: .now.advanced(by: .seconds(Self.immediateStop ? 0 : Self.captureFinishSeconds)))
        // Stop scheduling preview passes while keeping capture + streaming alive
        // briefly. An already-running preview can finish during this window.
        refineTask?.cancel()
        if !Self.immediateStop {
            try? await Task.sleep(nanoseconds: UInt64(Self.captureFinishSeconds * 1e9))
        }
        // Close admission atomically with queue writes. No late tap callback may
        // change the recording after we snapshot it or enter the next session.
        captureGate?.close()
        state = .transcribing
        if !simulated {
            audio.inputNode.removeTap(onBus: 0)
            audio.stop()
        }
        // Await the pump's actual termination — cancel() alone doesn't wait, and
        // a still-running append/process would race finish() on the same actor.
        pump?.cancel()
        await pump?.value
        pump = nil

        let overflowed = recorder.overflowed
        let total = recorder.frameCount
        lastStopCapturedFrames = total
        let rate = captureFormat?.sampleRate ?? 16_000
        // Cancel the loop, but let its active decode finish before using finalASR.
        // Its result may give us a newer, shorter final segment.
        refineTask?.cancel()
        await refineTask?.value
        refineTask = nil
        let recorded = recorder.drain()
        var accurate: String?
        var path = "final pass"
        if !overflowed {
            if !Dictation.forceFinalPass, let s = settled,
               let plan = DictationTail.plan(text: s.text, timings: s.timings,
                                               covered: Double(s.frames) / rate),
               let tail = await runFinalPass(recorded, from: Int(plan.start * rate)),
               let joined = plan.finish(tail) {
                accurate = joined
                path = "final segment"
            }
            if accurate == nil { accurate = await runFinalPass(recorded) }
        }
        do {
            var text: String
            if let accurate, !accurate.isEmpty {
                _ = pending.drain()   // the live stream isn't needed; don't leak it into the next session
                text = accurate
            } else {
                // Feed anything still queued, then finish the live stream.
                for b in pending.drain() { try? await manager.appendAudio(b) }
                try? await manager.processBufferedAudio()
                text = try await manager.finish().trimmingCharacters(in: .whitespacesAndNewlines)
                path = "live stream"
            }
            if Prefs.shared.removeFillers { text = Fillers.clean(text) }
            lastStop = String(format: "%@ in %.0f ms (%.1fs of audio)",
                              path, Date().timeIntervalSince(t0) * 1000, Double(total) / rate)
            Log.write("dictation stop: \(lastStop)")
            lastFinal = text
            partial = ""
            refined = ""
            state = .idle
            return text.isEmpty ? nil : text
        } catch {
            state = .error("Transcription failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Decode a recording or its final slice with the high-accuracy batch model.
    /// Returns nil (→ caller keeps the live text) if the model isn't loaded, the
    /// audio is empty, or anything throws.
    private func runFinalPass(_ buffers: [AVAudioPCMBuffer], from frame: Int = 0) async -> String? {
        // Only trust the batch model if it is the one THIS session was captured
        // under — not merely the currently-selected engine, which the picker can
        // move mid-session.
        guard let finalASR,
              Dictation.batchModelUsable(loaded: finalVersionLoaded, session: sessionFinalVersion),
              !buffers.isEmpty else { return nil }
        let combined = await Task.detached(priority: .userInitiated) {
            BufferQueue.concat(buffers, from: frame).map(SendableBufferBox.init)
        }.value
        guard let combined = combined?.buffer else { return nil }
        do {
            var decoderState = TdtDecoderState.make(decoderLayers: await finalASR.decoderLayerCount)
            let result = try await finalASR.transcribe(combined, decoderState: &decoderState, language: nil)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // MARK: - rolling accurate preview

    /// Start the loop that publishes `refined` while listening. Cancelled on stop.
    private func startRefineLoop() {
        // Chain on any previous task: two passes must never share `finalASR`.
        let prior = refineTask
        prior?.cancel()
        refineTask = Task { [weak self] in
            await prior?.value
            await self?.refineLoop()
        }
    }

    /// Periodically re-transcribe everything captured so far with the high-accuracy
    /// batch model and publish it as `refined`, so the HUD reads at final-pass
    /// quality instead of the lossy streaming `partial`. Sequential — each pass
    /// awaits the previous, so it self-throttles: short utterances refresh ~1/sec,
    /// longer ones as fast as the decode allows (no overlap, no pile-up).
    ///
    /// Two rules make the last pass usable as the final text on stop:
    /// - A pause (`SpeechGate.pause` of trailing silence) starts a pass right away
    ///   instead of at the next 0.8s tick, so the pass that hears your last word is
    ///   usually done by the time you press stop.
    /// - Silence alone never starts a pass: the previous one already holds every
    ///   word, and an idle model is one stop never has to wait for.
    private func refineLoop() async {
        let mySession = session
        var lastFrames = 0               // frames the previous pass heard
        var nextDue = Date().addingTimeInterval(0.8)
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { break }
            guard state == .listening, session == mySession else { break }
            // Past the 180s recorder cap (a very long hold) we can't re-transcribe
            // the whole utterance any more — drop `refined` so the HUD falls back to
            // the live streaming `partial` for the tail instead of freezing on stale
            // text. (The final pass on stop is skipped past the cap too.)
            // Overflow latches on for the rest of the session, so stop the loop
            // (don't spin) — the HUD falls back to the live partial.
            if recorder.overflowed { if !refined.isEmpty { refined = "" }; break }
            // Need the accurate model, matching the engine THIS session started on.
            // Otherwise leave the streaming `partial` to drive the HUD.
            guard let finalASR,
                  Dictation.batchModelUsable(loaded: finalVersionLoaded, session: sessionFinalVersion)
            else { continue }
            // Cheap frame count on the main actor for the gates; the expensive
            // snapshot + concat (a memcpy of the whole utterance) runs off-main so a
            // long hold can't stutter the UI.
            let frames = recorder.frameCount
            let rate = captureFormat?.sampleRate ?? 16_000
            // Skip until there's roughly a sentence's worth, and only when new audio
            // has arrived since the last pass.
            guard Double(frames) / rate >= 0.8, frames > lastFrames else { continue }
            let levels = recorder.levels
            let th = SpeechGate.threshold(levels)   // nil: can't tell, treat as speech
            if let th, lastFrames > 0,
               SpeechGate.silent(levels, from: lastFrames - Int(SpeechGate.edgeMargin * rate),
                                 to: frames, threshold: th) { continue }
            let paused = th.map {
                SpeechGate.silent(levels, from: frames - Int(SpeechGate.pause * rate), to: frames, threshold: $0)
            } ?? false
            guard paused || Date() >= nextDue else { continue }
            let rec = recorder
            // The result is a freshly-allocated, unshared buffer; wrap it so the
            // unchecked-Sendable assertion stays contained to this handoff instead
            // of retroactively conforming the framework type.
            let snap = await Task.detached(priority: .userInitiated) { () -> (SendableBufferBox?, Int) in
                let s = rec.snapshot()
                return (BufferQueue.concat(s.buffers).map(SendableBufferBox.init), s.frames)
            }.value
            guard let combined = snap.0?.buffer, session == mySession else { continue }
            var decoderState = TdtDecoderState.make(decoderLayers: await finalASR.decoderLayerCount)
            let result = try? await finalASR.transcribe(combined, decoderState: &decoderState, language: nil)
            // This pass may finish after stop, even after the next session began:
            // only its own session may use it.
            guard session == mySession else { break }
            lastFrames = snap.1
            nextDue = Date().addingTimeInterval(0.8)
            guard let result else { continue }
            let txt = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Recorded even when stop landed during the decode: stop may be waiting
            // on exactly this pass.
            settled = (txt, snap.1, result.tokenTimings ?? [])
            guard !Task.isCancelled, state == .listening else { break }
            if !txt.isEmpty { refined = txt }
        }
    }

    func clearError() { if case .error = state { state = .idle } }

    /// Surface a transient message in the HUD (reuses the error display channel,
    /// e.g. "copied — grant Accessibility to paste"). Cleared by `clearError`.
    func note(_ message: String) { state = .error(message) }

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
        // Cancel any in-flight loads first (streaming + final-pass), or one could
        // finish and re-create the models right after we delete them.
        loadTask?.cancel()
        loadTask = nil
        finalTask?.cancel()
        finalTask = nil
        refineTask?.cancel()
        refineTask = nil
        manager = nil
        finalASR = nil
        finalVersionLoaded = nil
        modelReady = false
        if case .error = state {} else { state = .idle }
        // The models are hundreds of MB — remove them off the main thread so the
        // UI doesn't freeze. In-memory refs are already released above.
        let dir = Self.modelsDirOnDisk
        Task.detached { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: - capture

    /// Reset everything one capture session owns.
    private func beginSession() {
        session += 1
        settled = nil
        captureGate?.close()
        captureGate = nil
        partial = ""
        refined = ""
        _ = recorder.drain()   // clear last session's audio
        _ = pending.drain()
    }

    /// Where captured audio goes: the live stream and the recorder. Called from
    /// the mic tap's thread, so it touches only the thread-safe queues.
    private func makeFeed(format: AVAudioFormat) -> @Sendable (AVAudioPCMBuffer) -> Void {
        let queue = pending
        let rec = recorder
        // Cap the kept-for-final-pass audio at ~3 minutes so an accidental long
        // hold can't exhaust memory. Past the cap the live transcript still works;
        // only the optional accurate re-pass is skipped.
        let maxRecFrames = Int(format.sampleRate * 180)
        let gate = DictationCaptureGate()
        captureGate = gate
        return { buf in
            // Copy once: the tap's buffer is only valid for this callback. The
            // same copy feeds the live stream (drained continuously) and the
            // recorder (kept whole, bounded, for the final pass) — both read-only.
            if let copy = BufferQueue.copy(buf) {
                gate.whileOpen { queue.push(copy); rec.pushCapped(copy, maxFrames: maxRecFrames) }
            }
        }
    }

    /// Probe-only (`--dictstop`): a session fed by the caller instead of the mic,
    /// through the same queues, pump, preview loop and stop path.
    func startSimulated(format: AVAudioFormat) async throws -> @Sendable (AVAudioPCMBuffer) -> Void {
        guard modelReady, state == .idle, let manager else { throw CancellationError() }
        try await manager.reset()
        beginSession()
        simulated = true
        captureFormat = format
        startPump(into: manager)
        sessionManager = manager
        sessionFinalVersion = engineChoice.finalVersion
        state = .listening
        startRefineLoop()
        return makeFeed(format: format)
    }

    /// Probe-only: wait for the batch model's background load.
    func awaitFinalModel() async { await finalTask?.value }

    private func beginCapture(into manager: any StreamingAsrManager) throws {
        simulated = false
        let input = audio.inputNode
        // Clear any tap left behind by a previous failed start — installing a
        // second tap on the same bus crashes.
        input.removeTap(onBus: 0)
        let format = input.inputFormat(forBus: 0)
        captureFormat = format
        let feed = makeFeed(format: format)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buf, _ in feed(buf) }
        audio.prepare()
        try audio.start()
        startPump(into: manager)
    }

    private func startPump(into manager: any StreamingAsrManager) {
        let queue = pending
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

/// Wraps a freshly-allocated, unshared `AVAudioPCMBuffer` so it can be returned
/// from a detached task to the main actor without retroactively conforming the
/// non-Sendable framework type. The buffer is read-only after creation.
private struct SendableBufferBox: @unchecked Sendable { let buffer: AVAudioPCMBuffer }

/// Thread-safe FIFO handoff of mic buffers from the render thread to the ASR
/// pump task.
final class BufferQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AVAudioPCMBuffer] = []
    private var frames = 0
    private var overflowedFlag = false
    private var levelLog: [SpeechGate.Level] = []

    func push(_ b: AVAudioPCMBuffer) { lock.lock(); items.append(b); lock.unlock() }

    /// Push only while under a frame budget. Past it, set the overflow flag and
    /// stop accumulating — bounds memory for the (optional) final pass on a very
    /// long hold; the live transcript is unaffected.
    func pushCapped(_ b: AVAudioPCMBuffer, maxFrames: Int) {
        let dbs = SpeechGate.windowDBs(b)   // outside the lock: it reads every sample
        let win = max(Int(b.format.sampleRate / 100), 1)
        lock.lock()
        if frames >= maxFrames { overflowedFlag = true }
        else {
            for (k, db) in dbs.enumerated() {
                levelLog.append(.init(endFrame: frames + min((k + 1) * win, Int(b.frameLength)), db: db))
            }
            items.append(b); frames += Int(b.frameLength)
        }
        lock.unlock()
    }

    /// 10 ms loudness of everything pushed with `pushCapped`, in order.
    var levels: [SpeechGate.Level] { lock.lock(); defer { lock.unlock() }; return levelLog }

    var overflowed: Bool { lock.lock(); defer { lock.unlock() }; return overflowedFlag }

    /// Current frame count alone — cheap gate for the preview loop, so it can read
    /// length on the main actor without copying the buffer array.
    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return frames }

    /// Copy the current buffers + frame count WITHOUT draining — for the rolling
    /// accurate preview, which re-reads the growing audio while capture keeps
    /// appending. Buffers are already immutable deep-copies, so sharing refs is safe.
    func snapshot() -> (buffers: [AVAudioPCMBuffer], frames: Int) {
        lock.lock(); defer { lock.unlock() }
        return (items, frames)
    }

    func drain() -> [AVAudioPCMBuffer] {
        lock.lock()
        let out = items; items.removeAll(keepingCapacity: true)
        frames = 0; overflowedFlag = false; levelLog.removeAll(keepingCapacity: true)
        lock.unlock()
        return out
    }

    /// Concatenate same-format buffers into one (for the batch final pass).
    static func concat(_ bufs: [AVAudioPCMBuffer], from frame: Int = 0) -> AVAudioPCMBuffer? {
        guard let first = bufs.first else { return nil }
        let format = first.format
        let available = bufs.reduce(0) { $0 + Int($1.frameLength) }
        guard frame >= 0, frame < available else { return nil }
        let total = AVAudioFrameCount(available - frame)
        var skip = frame
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
            let drop = min(skip, Int(b.frameLength))
            skip -= drop
            let count = Int(b.frameLength) - drop
            if count == 0 { continue }
            let sourceOffset = interleaved ? drop * channels : drop
            let perPlane = interleaved ? count * channels : count
            if let s = b.floatChannelData, let d = dst.floatChannelData {
                for p in 0..<planes { memcpy(d[p] + offset, s[p] + sourceOffset, perPlane * MemoryLayout<Float>.size) }
            } else if let s = b.int16ChannelData, let d = dst.int16ChannelData {
                for p in 0..<planes { memcpy(d[p] + offset, s[p] + sourceOffset, perPlane * MemoryLayout<Int16>.size) }
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

/// Loudness only schedules preview work while listening. It never decides
/// whether the final transcript is complete: quiet speech can resemble noise.
enum SpeechGate {
    /// One entry per 10 ms of captured audio: the recorder frame it ends at, and
    /// its RMS in dBFS. 10 ms is fine enough to tell a key click (tens of ms)
    /// from a spoken word (a hundred ms and more of voicing).
    struct Level: Equatable { let endFrame: Int; let db: Float }

    /// A word cut by a preview's snapshot edge sits just before it, so coverage
    /// is checked from this far back.
    static let edgeMargin = 0.25
    /// Trailing silence that counts as "you paused" for the preview loop.
    static let pause = 0.3

    /// Loudness above which a buffer is speech, or nil when this recording does
    /// not separate speech from noise (too short, or under 12 dB of range).
    /// Floor = 5th percentile; threshold sits 6–15 dB above it, a quarter of the
    /// way to the loudest buffer. The 15 dB cap keeps one loud click from lifting
    /// it over a quietly spoken word.
    static func threshold(_ levels: [Level]) -> Float? {
        guard levels.count >= 80 else { return nil }   // under ~0.8s: can't judge
        let dbs = levels.map(\.db).sorted()
        let floor = dbs[dbs.count / 20]
        guard let top = dbs.last, top - floor >= 12 else { return nil }
        return floor + min(max(0.25 * (top - floor), 6), 15)
    }

    /// How many windows overlapping frames `from...to` are at or above `threshold`.
    static func loudWindows(_ levels: [Level], from: Int, to: Int, threshold: Float) -> Int {
        var start = 0, n = 0
        for l in levels {
            defer { start = l.endFrame }
            if l.endFrame <= from { continue }
            if start > max(to, from) { break }
            if l.db >= threshold { n += 1 }
        }
        return n
    }

    /// True when every window overlapping frames `from...to` is below `threshold`.
    static func silent(_ levels: [Level], from: Int, to: Int, threshold: Float) -> Bool {
        loudWindows(levels, from: from, to: to, threshold: threshold) == 0
    }

    /// RMS of each 10 ms window of a buffer's first channel, in dBFS. A format we
    /// can't read reports one full-scale (0 dB) window, i.e. speech: the safe answer.
    static func windowDBs(_ b: AVAudioPCMBuffer) -> [Float] {
        guard let ch = b.floatChannelData, b.frameLength > 0 else { return [0] }
        let n = Int(b.frameLength)
        let stride = b.format.isInterleaved ? Int(b.format.channelCount) : 1
        let win = max(Int(b.format.sampleRate / 100), 1)
        var out: [Float] = []
        out.reserveCapacity(n / win + 1)
        var i = 0
        while i < n {
            let end = min(i + win, n)
            var sum: Float = 0
            for j in i..<end { let s = ch[0][j * stride]; sum += s * s }
            out.append(10 * log10(max(sum / Float(end - i), 1e-12)))
            i = end
        }
        return out
    }
}

/// Each feed closure owns its own gate, so a late callback from an old session
/// cannot enter a new session. Closing waits for any admitted write to finish.
final class DictationCaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    private var deadline: ContinuousClock.Instant?

    /// The callback enforces the deadline even if the main actor is busy when
    /// the stop task's sleep ends. ASR load must not extend capture indefinitely.
    func finish(until deadline: ContinuousClock.Instant) {
        lock.lock(); defer { lock.unlock() }
        self.deadline = deadline
    }

    @discardableResult
    func whileOpen(_ write: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard open else { return false }
        if let deadline, ContinuousClock.now >= deadline { open = false; return false }
        write()
        return true
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        open = false
    }
}
