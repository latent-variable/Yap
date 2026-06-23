import AppKit
import Combine
import SwiftUI

enum Status: Equatable {
    case idle, loadingModel, capturing, reading, paused, error(String)

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .loadingModel: return "Loading model…"
        case .capturing: return "Capturing…"
        case .reading: return "Reading"
        case .paused: return "Paused"
        case .error(let m): return "Error: \(m)"
        }
    }
    var symbol: String {
        switch self {
        case .idle: return "waveform"
        case .loadingModel: return "arrow.down.circle"
        case .capturing: return "text.viewfinder"
        case .reading: return "waveform.circle.fill"
        case .paused: return "pause.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var status: Status = .idle
    @Published var voices: [VoiceInfo] = []
    @Published var lastCaptured: String = ""
    @Published var lastCleaned: String = ""
    @Published var lastMethod: Capture.Method = .none
    @Published var modelsPresent = false
    @Published var deletingKokoro = false   // delete in flight — block re-trigger/download
    @Published var deletingHD = false
    @Published var installingHD = false     // HD install in flight — block concurrent installs
    @Published var axTrusted = Permissions.axTrusted
    @Published var hdVoices: [VoiceInfo] = []
    @Published var hdInstalled = false
    @Published var preparing = false   // synth requested, first audio not yet playing
    @Published var preparingDetail = "Preparing voice…"
    private var hdWarm = false          // HD model loaded since backend start

    /// The voice id for the currently selected engine.
    var activeVoice: String { prefs.engine == "chatterbox" ? prefs.hdVoice : prefs.voice }

    /// One id space across engines for the unified voice picker.
    var currentVoiceId: String { "\(prefs.engine):\(activeVoice)" }

    /// Kokoro voices (grouped by language) + HD voices (own section), as one
    /// list. HD voices appear only once the HD engine is installed.
    var combinedVoices: [EngineVoice] {
        var out: [EngineVoice] = voices.map {
            EngineVoice(engine: "kokoro", voiceId: $0.id, label: $0.shortName, section: $0.lang_label)
        }
        if hdInstalled {
            out += hdVoices.map {
                EngineVoice(engine: "chatterbox", voiceId: $0.id, label: $0.id, section: "✨ HD Engine")
            }
        }
        return out
    }

    /// Pick a voice from the unified list — sets the engine and its voice.
    func selectVoice(_ v: EngineVoice) {
        prefs.engine = v.engine
        if v.engine == "chatterbox" { prefs.hdVoice = v.voiceId } else { prefs.voice = v.voiceId }
    }

    let prefs = Prefs.shared
    let backend = BackendManager()
    let audio = AudioPlayer()
    let hotkey = HotKeyManager()
    /// Owned here (not in the Settings view) so a Kokoro download keeps running
    /// even if the user closes the Settings window mid-download.
    let downloader: ModelDownloader

    private var generation = 0   // cancels stale streams
    private var playingText = "" // text currently being read (for the smart toggle)
    private var cancellables = Set<AnyCancellable>()

    private init() {
        downloader = ModelDownloader(modelsDir: backend.modelsDir)
        hotkey.onFire = { [weak self] in self?.triggerRead() }
        audio.onFinished = { [weak self] in self?.finishIfDone() }
        // Live transport: dragging speed/pitch/volume affects audio immediately,
        // including whatever is currently streaming.
        prefs.$speed.sink { [weak self] in self?.audio.setRate(Float($0)) }.store(in: &cancellables)
        prefs.$pitch.sink { [weak self] in self?.audio.set(volume: Float(self?.prefs.volume ?? 1),
                                                           pitchCents: Float($0)) }.store(in: &cancellables)
        prefs.$volume.sink { [weak self] in self?.audio.set(volume: Float($0),
                                                            pitchCents: Float(self?.prefs.pitch ?? 0)) }.store(in: &cancellables)
        // Pre-warm the HD model when the user switches to it / changes voice, so
        // the first read isn't a cold ~8s wait.
        prefs.$engine.dropFirst().sink { [weak self] in if $0 == "chatterbox" { self?.warmHD() } }.store(in: &cancellables)
        prefs.$hdVoice.dropFirst().sink { [weak self] _ in
            if self?.prefs.engine == "chatterbox" { self?.warmHD() }
        }.store(in: &cancellables)
    }

    private var warming = false
    func warmHD() {
        // Don't warm during playback — the backend serializes model access, but
        // warming mid-read would just stall the read behind a throwaway generate.
        guard hdInstalled, !warming, status != .reading, status != .paused else { return }
        warming = true
        let voice = prefs.hdVoice
        Task {
            await backend.client.warmChatterbox(voice: voice)
            warming = false
            hdWarm = true
        }
    }

    /// On first run, copy the bundled open starter voices into the writable
    /// hd-voices dir so HD has voices out of the box. Never overwrites existing.
    private func seedStarterVoices() {
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(at: hdVoicesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }) ?? []
        guard existing.isEmpty,
              let bundled = Bundle.main.resourceURL?.appending(path: "hd-voices"),
              let clips = try? fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil) else { return }
        for clip in clips where clip.pathExtension == "wav" {
            try? fm.copyItem(at: clip, to: hdVoicesDir.appending(path: clip.lastPathComponent))
        }
    }

    func bootstrap() {
        seedStarterVoices()
        hotkey.register(prefs.hotKey)
        Log.write("bootstrap: axTrusted=\(Permissions.axTrusted) readSource=\(prefs.readSource.rawValue) captureMode=\(prefs.captureMode.rawValue)")
        // Selection capture needs Accessibility. Prompt up front so the user
        // isn't met with a silent "No text captured" later.
        if prefs.readSource == .selection && !Permissions.axTrusted {
            Permissions.requestAX()
        }
        // Keep the published trust flag fresh (granting happens out of process).
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop; assert that isolation instead of
            // spinning up a fresh Task every 2s.
            MainActor.assumeIsolated { self?.axTrusted = Permissions.axTrusted }
        }
        Task {
            status = .loadingModel
            await backend.start()
            let health = await backend.client.health()
            // Kokoro presence is its own files — NOT backend.ready, which is true
            // whenever any engine (incl. HD) can serve.
            modelsPresent = health?.files_present ?? backend.kokoroFilesPresent
            voices = await backend.client.voices()
            refreshHD()
            status = backend.ready ? .idle : .error(backend.lastError ?? "Backend not ready")
        }
    }

    func reapplyHotKey() { hotkey.register(prefs.hotKey) }

    // MARK: - read pipeline

    func triggerRead() { Task { await runRead() } }

    private func runRead() async {
        // Ignore a re-trigger fired during the (now async) capture window — the
        // first capture is still in flight; a second would just race it. Checks
        // TextCapture.isCapturing too: a trigger while already reading keeps
        // status == .reading, so the status check alone would miss it.
        if status == .capturing || TextCapture.isCapturing { return }
        if deletingKokoro || deletingHD { return }  // backend is bouncing for a delete
        let wasPlaying = (status == .reading || status == .paused)
        // Honor the "ignore re-trigger" preference if the user turned it off.
        if wasPlaying && !prefs.stopOnNewTrigger { return }

        generation += 1
        let gen = generation
        if !wasPlaying { status = .capturing }

        let capture: Capture
        if prefs.readSource == .clipboard {
            let pb = NSPasteboard.general.string(forType: .string) ?? ""
            capture = Capture(text: pb, method: .clipboard)
        } else {
            capture = await TextCapture.capture(mode: prefs.captureMode)
        }
        // A newer trigger may have superseded us during the await — bail so we
        // don't desync state (the stale run would set .reading but its stream is
        // discarded by the generation check, leaving the app stuck).
        guard gen == generation else { return }
        lastCaptured = capture.text
        lastMethod = capture.method

        let cleaned = cleanedText(capture.text)
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Smart toggle: pressing the shortcut while audio is playing either
        // switches to freshly-selected text, or — if nothing new is selected —
        // just stops. No need to reach for the Stop button.
        if wasPlaying {
            if trimmed.isEmpty || cleaned == playingText {
                Log.write("trigger while playing, no new text -> stop")
                stop()
                return
            }
            Log.write("trigger while playing, new text -> switch")
            audio.stop()   // generation already advanced; old stream is now stale
        }

        lastCleaned = cleaned
        guard !trimmed.isEmpty else {
            // Distinguish "nothing selected" from "can't capture because no permission".
            if prefs.readSource == .selection && !Permissions.axTrusted {
                Log.write("read aborted: no capture and Accessibility not granted")
                status = .error("Grant Accessibility to capture")
                Permissions.requestAX()
            } else {
                Log.write("read aborted: no text captured (source=\(prefs.readSource.rawValue))")
                status = .error("No text captured")
            }
            resetToIdle(after: 3)
            return
        }

        await stream(cleaned, gen: gen)
    }

    /// Read a specific string directly (e.g. from the macOS Services menu),
    /// bypassing capture. Supersedes any current read.
    func readAloud(_ raw: String) {
        if deletingKokoro || deletingHD { return }  // backend is bouncing for a delete
        let cleaned = cleanedText(raw)
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        generation += 1
        let gen = generation
        audio.stop()
        lastCaptured = raw
        lastCleaned = cleaned
        lastMethod = .none
        // Reflect "starting" now — stream() runs on the next loop cycle, and we
        // just stopped audio, so without this the UI would briefly show the old
        // (e.g. .reading) state with nothing playing.
        status = .loadingModel
        preparing = true
        Task { await stream(cleaned, gen: gen) }
    }

    /// Shared synth + playback path: ensure the backend is up, then stream the
    /// cleaned text for this generation. Used by both the hotkey and Services.
    private func stream(_ cleaned: String, gen: Int) async {
        // readAloud() hops through a Task before calling us, so a newer trigger
        // may have bumped generation already — bail before touching shared state.
        guard gen == generation else { return }
        if !backend.ready {
            status = .loadingModel
            await backend.start()
            guard gen == generation else { return }
            if !backend.ready {
                status = .error(backend.lastError ?? "Backend not ready")
                return
            }
        }

        playingText = cleaned
        status = .reading
        preparing = true   // first audio not here yet (HD can take a few seconds)
        preparingDetail = prepDetail()
        audio.start(volume: Float(prefs.volume), pitchCents: Float(prefs.pitch), rate: Float(prefs.speed),
                    cushionSeconds: prefs.engine == "chatterbox" ? 0.8 : 0.35)
        do {
            // Speed is applied at playback (real-time, both engines), so the
            // backend synthesizes at 1.0 and pauses stretch along with it.
            try await backend.client.streamPCM(text: cleaned, voice: activeVoice,
                                                speed: 1.0, pauseScale: prefs.pauseScale,
                                                engine: prefs.engine) { [weak self] data in
                guard let self, gen == self.generation else { return }
                self.audio.feed(data)   // scheduling is thread-safe
                // @Published writes MUST be on the main actor (the stream
                // callback runs off-main); doing it here crashed the menu bar.
                Task { @MainActor in
                    if self.preparing { self.preparing = false }
                    if self.prefs.engine == "chatterbox" { self.hdWarm = true }
                }
            }
            audio.flush()   // stream ended — play any sub-cushion remainder
            // drain
            // Include .paused: pausing flips status away from .reading, and if the
            // loop exited there'd be no task left to move to .idle when the
            // resumed playback finishes (state would stick in .reading/.paused).
            while gen == generation && audio.hasQueued && (status == .reading || status == .paused) {
                // do/catch (not try?) so a cancellation breaks the drain instead
                // of being swallowed and spinning to the generation check.
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { break }
            }
            if gen == generation && (status == .reading || status == .paused) {
                status = .idle; playingText = ""; preparing = false
            }
        } catch {
            if gen == generation { preparing = false; status = .error(error.localizedDescription); resetToIdle(after: 3) }
        }
    }

    /// Language-appropriate preview line so non-English voices phonemize
    /// real text in their own language instead of mangled English.
    static func sampleText(for voice: String) -> String {
        switch voice.prefix(2) {
        case "ef", "em": return "Hola, esta es una prueba de la voz."
        case "ff":       return "Bonjour, ceci est un test de la voix."
        case "hf", "hm": return "नमस्ते, यह आवाज़ का एक परीक्षण है।"
        case "if", "im": return "Ciao, questa è una prova della voce."
        case "jf", "jm": return "こんにちは、これは音声のテストです。"
        case "pf", "pm": return "Olá, este é um teste da voz."
        case "zf", "zm": return "你好，这是语音测试。"
        default:         return "This is a preview of the selected voice."
        }
    }

    func cleanedText(_ raw: String) -> String {
        Preprocess.clean(raw, options: Preprocess.options(for: prefs.profile), custom: prefs.customRules)
    }

    /// What to show while waiting for first audio — flags the slow HD cold-load.
    private func prepDetail() -> String {
        if prefs.engine == "chatterbox" {
            return hdWarm ? "Generating HD audio…" : "Loading HD voice — first use, ~10 sec…"
        }
        return "Preparing voice…"
    }

    // MARK: - transport

    func pause() { if status == .reading { audio.pause(); status = .paused } }
    func resume() { if status == .paused { audio.resume(); status = .reading } }
    func togglePlayPause() { status == .paused ? resume() : pause() }

    func stop() {
        generation += 1
        audio.stop()
        playingText = ""
        preparing = false
        status = .idle
    }

    func testVoice() {
        if deletingKokoro || deletingHD { return }  // backend is bouncing for a delete
        Task {
            if !backend.ready { await backend.start() }
            guard backend.ready else { status = .error("Backend not ready"); return }
            generation += 1
            let gen = generation
            status = .reading
            preparing = true
            preparingDetail = prepDetail()
            audio.start(volume: Float(prefs.volume), pitchCents: Float(prefs.pitch), rate: Float(prefs.speed),
                        cushionSeconds: prefs.engine == "chatterbox" ? 0.8 : 0.35)
            let sample = prefs.engine == "chatterbox"
                ? "This is a preview of the selected high definition voice."
                : Self.sampleText(for: prefs.voice)
            try? await backend.client.streamPCM(text: sample, voice: activeVoice, speed: 1.0,
                                                pauseScale: prefs.pauseScale, engine: prefs.engine) { [weak self] d in
                guard let self, gen == self.generation else { return }
                self.audio.feed(d)
                Task { @MainActor in if self.preparing { self.preparing = false } }
            }
            audio.flush()
            while gen == generation && audio.hasQueued {
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { break }
            }
            if gen == generation { preparing = false; status = .idle }
        }
    }

    // MARK: - HD engine (Chatterbox)

    var hdVoicesDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Parley/hd-voices")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// On-demand HD engine + weights (torch, chatterbox-tts, model files) — not
    /// bundled; installed here via the Engine tab. Used by the Models tab to
    /// report HD status alongside Kokoro. Sibling of hd-voices, so derive it from
    /// hdVoicesDir to reuse that base (no duplicate Application Support lookup).
    var hdPackagesDir: URL {
        hdVoicesDir.deletingLastPathComponent().appending(path: "hd-packages")
    }

    func refreshHD() {
        Task {
            let e = await backend.client.engines()
            hdInstalled = e.chatterbox?.installed ?? false
            hdWarm = e.chatterbox?.loaded ?? false
            hdVoices = await backend.client.voices(engine: "chatterbox")
            if prefs.hdVoice.isEmpty, let first = hdVoices.first { prefs.hdVoice = first.id }
            // Auto pre-load the HD model so the first HD read isn't a cold ~10s
            // wait. Fires once per backend session (until loaded) when HD is
            // installed and either it's the active engine or auto-load is on.
            if hdInstalled && !hdWarm && (prefs.autoLoadHD || prefs.engine == "chatterbox") {
                warmHD()
            }
        }
    }

    /// Install HD deps (streams progress), then restart the backend into the
    /// combined env so both engines are live.
    /// Total on-disk size of a directory, in bytes (0 if missing). static + pure
    /// FileManager so callers run it off the main actor without capturing any
    /// @MainActor state (it walks the whole tree — never call it from a body).
    nonisolated static func dirSizeBytes(_ url: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey])
            if v?.isDirectory == true { continue }  // count files only
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }

    /// Delete the Kokoro model files to reclaim disk. The app can't speak with
    /// Kokoro until it's re-downloaded; callers should confirm first. Bounces the
    /// backend so its in-memory state matches disk.
    func deleteKokoroModel() {
        guard backend.ownsProcess else { return }  // unsafe against a reused backend
        guard !deletingKokoro, !deletingHD else { return }  // one delete at a time
        stop()                  // stop playback
        deletingKokoro = true   // block download/re-trigger until the bounce finishes
        modelsPresent = false   // reflect immediately
        let dir = backend.modelsDir
        Task {
            // Terminate the backend PROCESS and wait for it to exit so it isn't
            // holding the model files open, then delete and relaunch against the
            // now-empty dir. (stop() above only stops playback.)
            await backend.stopAndWait()
            await Task.detached(priority: .background) {
                do { try FileManager.default.removeItem(at: dir) }
                catch { Log.write("delete Kokoro model failed: \(error)") }
            }.value
            await backend.start()
            modelsPresent = backend.kokoroFilesPresent
            status = backend.ready ? .idle : .error(backend.lastError ?? "Backend not ready")
            deletingKokoro = false
        }
    }

    /// After (re)downloading the Kokoro model, the already-running sidecar won't
    /// pick up the new files on its own — restart it so it loads them, then sync
    /// UI state. (Codex P1: start() would just reuse the running, model-less
    /// process.)
    func reloadAfterKokoroDownload() {
        Task {
            await backend.restart()
            modelsPresent = backend.kokoroFilesPresent
            status = backend.ready ? .idle : .error(backend.lastError ?? "Backend not ready")
        }
    }

    /// Delete the on-demand HD engine + weights (~1.3 GB) to reclaim disk. Falls
    /// back to Kokoro if HD was the active engine. Re-installable from this tab or
    /// the Engine tab. Callers should confirm first.
    func deleteHDModel() {
        guard backend.ownsProcess else { return }  // unsafe against a reused backend
        guard !deletingKokoro, !deletingHD else { return }  // one delete at a time
        stop()                  // stop playback
        deletingHD = true       // block install/re-trigger until the bounce finishes
        hdInstalled = false     // reflect immediately
        if prefs.engine == "chatterbox" { prefs.engine = "kokoro" }
        let dir = hdPackagesDir
        Task {
            // Terminate the backend PROCESS and wait for it to exit so it isn't
            // importing torch from hd-packages while we delete it, then relaunch in
            // the Kokoro-only env.
            await backend.stopAndWait()
            await Task.detached(priority: .background) {
                do { try FileManager.default.removeItem(at: dir) }
                catch { Log.write("delete HD model failed: \(error)") }
            }.value
            await backend.start()
            refreshHD()
            status = backend.ready ? .idle : .error(backend.lastError ?? "Backend not ready")
            deletingHD = false
        }
    }

    /// Install the HD engine, streaming progress via `onLine`. Awaitable so
    /// callers can flip their own UI flags on completion instead of scraping the
    /// log text.
    func installHD(onLine: @escaping (String) -> Void) async {
        guard !installingHD else { return }   // one install at a time
        installingHD = true
        defer { installingHD = false }
        do {
            try await backend.client.installChatterbox { line in
                Task { @MainActor in onLine(line) }
            }
        } catch {
            onLine("install error: \(error.localizedDescription)")
        }
        onLine("restarting engine…")
        await backend.restart()
        refreshHD()
        onLine("HD ready: \(hdInstalled)")
    }

    /// Import an audio file as a Chatterbox reference voice (converted to a
    /// mono 24 kHz WAV, trimmed to ~20s).
    func addHDVoice(from src: URL, name: String) {
        let safe = name.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespaces)
        guard !safe.isEmpty else { return }
        let dest = hdVoicesDir.appending(path: "\(safe).wav")
        // Security-scoped access has thread affinity: start AND stop must be on
        // the same thread, else the sandbox token leaks. So hold the scope only
        // here on the main actor — copy the picked file to a temp path (fast),
        // release the scope on this same thread — then do the heavy decode off
        // the main actor from the temp copy, which needs no scope.
        let scoped = src.startAccessingSecurityScopedResource()
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "parley-import-\(UUID().uuidString).bin")
        do {
            try FileManager.default.copyItem(at: src, to: tmp)
        } catch {
            if scoped { src.stopAccessingSecurityScopedResource() }
            status = .error("Voice import failed")
            return
        }
        if scoped { src.stopAccessingSecurityScopedResource() }
        Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                try AudioImport.toReferenceWAV(src: tmp, dest: dest, maxSeconds: 20)
                await MainActor.run {
                    AppState.shared.refreshHD()
                    AppState.shared.prefs.hdVoice = safe
                }
            } catch {
                await MainActor.run { AppState.shared.status = .error("Voice import failed") }
            }
        }
    }

    func fetchStarterVoices(onLine: @escaping (String) -> Void) {
        Task {
            do { try await backend.client.fetchStarterVoices { l in Task { @MainActor in onLine(l) } } }
            catch { onLine("error: \(error.localizedDescription)") }
            refreshHD()
            onLine("[refreshed]")
        }
    }

    func deleteHDVoice(_ id: String) {
        try? FileManager.default.removeItem(at: hdVoicesDir.appending(path: "\(id).wav"))
        refreshHD()
    }

    func exportWAV() {
        let text = lastCleaned.isEmpty ? cleanedText(lastCaptured) : lastCleaned
        guard !text.isEmpty else { return }
        Task {
            guard let data = try? await backend.client.wav(text: text, voice: activeVoice, speed: prefs.speed,
                                                           pauseScale: prefs.pauseScale, engine: prefs.engine) else {
                status = .error("Export failed"); return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "parley.wav"
            panel.allowedContentTypes = [.wav]
            if panel.runModal() == .OK, let url = panel.url {
                try? data.write(to: url)
            }
        }
    }

    private func finishIfDone() {}

    private func resetToIdle(after seconds: Double) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            if case .error = status { status = .idle }
        }
    }
}
