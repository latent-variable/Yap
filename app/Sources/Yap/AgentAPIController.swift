import Combine
import Foundation

/// Owns the agent API's socket server and gives each route its behaviour.
///
/// The routes are thin on purpose. Speaking goes through `AppState.speak` (the
/// same player, so the menu bar's pause and stop govern it), and listening
/// through `DictationController.listenForAgent` (the same capture and the same
/// accurate stop as the hotkey). Nothing here reimplements either.
///
/// `Prefs.agentAPIEnabled` starts and stops the server live. `agentListenEnabled`
/// is checked on every `/listen`, and again while one runs.
@MainActor
final class AgentAPIController {
    static let shared = AgentAPIController(state: .shared, dictation: .shared, prefs: .shared)

    private let state: AppState
    private let dictation: DictationController
    private let prefs: Prefs
    private let socketPath: String
    private var server: AgentServer?
    private var cancellable: AnyCancellable?
    /// Why the server is not running, when the pref says it should be.
    private(set) var startError: String?

    init(state: AppState, dictation: DictationController, prefs: Prefs,
         socketPath: String = AgentAPI.socketPath()) {
        self.state = state
        self.dictation = dictation
        self.prefs = prefs
        self.socketPath = socketPath
    }

    var isRunning: Bool { server?.isRunning ?? false }
    var path: String { socketPath }

    /// Follow the pref: `$agentAPIEnabled` emits its current value on subscribe,
    /// so this also starts the server at launch.
    func bootstrap() {
        cancellable = prefs.$agentAPIEnabled.removeDuplicates().sink { [weak self] on in
            // @Published fires in willSet; hop so `prefs` already holds the new value.
            Task { @MainActor in self?.apply(on) }
        }
    }

    func apply(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    func start() {
        guard server == nil else { return }
        let s = AgentServer(path: socketPath) { [weak self] req in
            guard let self else { return HTTPResponse.error(APIError(503, "shutting_down", "Yap is quitting.")) }
            return await self.handle(req)
        }
        do {
            try s.start()
            server = s
            startError = nil
            Log.write("agent API listening on \(socketPath)")
        } catch {
            startError = "\(error)"
            Log.write("agent API did not start: \(error)")
        }
    }

    func stop() {
        guard let s = server else { return }
        server = nil
        s.stop()
        dictation.stopAgentListen()
        Log.write("agent API stopped")
    }

    // MARK: routes

    func handle(_ req: HTTPRequest) async -> HTTPResponse {
        let route: AgentRoute
        switch AgentAPI.route(method: req.method, path: req.path) {
        case .failure(let e): return .error(e)
        case .success(let r): route = r
        }
        switch route {
        case .status: return .json(statusObject())
        case .voices: return .json(voicesObject())
        case .speak: return await speak(req)
        case .stop:
            let was = state.status
            state.stop()
            return .json(["state": voiceState(), "was": voiceStateName(was)])
        case .pause:
            let before = state.status
            state.pause()
            return .json(["state": voiceState(), "changed": before == .reading && state.status == .paused])
        case .resume:
            let before = state.status
            state.resume()
            return .json(["state": voiceState(), "changed": before == .paused && state.status == .reading])
        case .listen: return await listen(req)
        case .listenStop:
            guard dictation.stopAgentListen() else {
                return .error(APIError(409, "not_listening", "No listen is in progress."))
            }
            return .json(["stopping": true])
        }
    }

    private func speak(_ req: HTTPRequest) async -> HTTPResponse {
        guard prefs.voiceEnabled else {
            return .error(APIError(403, "voice_disabled", "Reading aloud is turned off in Yap's settings."))
        }
        let r: SpeakRequest
        switch AgentAPI.parseSpeak(req.body) {
        case .failure(let e): return .error(e)
        case .success(let v): r = v
        }
        let options = AppState.SpeakOptions(engine: r.engine, voice: r.voice, speed: r.speed, clean: r.clean)
        let ticket: AppState.SpeakTicket
        switch state.speak(r.text, options: options, interrupt: r.interrupt) {
        case .failure(let e): return .error(e)
        case .success(let t): ticket = t
        }
        var out: [String: Any] = ["id": String(ticket.id), "queued": ticket.queuePosition != nil]
        if let p = ticket.queuePosition { out["position"] = p }
        guard r.wait else { return .json(out) }

        // Poll rather than park a continuation: a hung-up client cancels this task,
        // and cancellation has to reach a loop that can act on it.
        while state.speakOutcome(ticket.id) == nil {
            if Task.isCancelled {
                state.cancelSpeak(ticket.id)
                return .error(APIError(499, "client_closed", "The client went away; the read was stopped."))
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let outcome = state.speakOutcome(ticket.id) ?? .stopped
        out["outcome"] = outcome.name
        if case .error(let m) = outcome { out["error"] = m }
        return .json(out)
    }

    private func listen(_ req: HTTPRequest) async -> HTTPResponse {
        guard prefs.agentListenEnabled else {
            return .error(APIError(403, "listen_disabled",
                "Listening through the agent API is off. It is off by default because it lets any program running as you use Yap's microphone access. Turn it on in Yap's Settings (Agents)."))
        }
        let r: ListenRequest
        switch AgentAPI.parseListen(req.body) {
        case .failure(let e): return .error(e)
        case .success(let v): r = v
        }
        switch await dictation.listenForAgent(maxSeconds: r.maxSeconds, silenceSeconds: r.silenceSeconds, insert: r.insert) {
        case .failure(let e): return .error(e)
        case .success(let res):
            if req.headers["accept"]?.lowercased().hasPrefix("text/plain") == true {
                return .text(res.text + "\n", headers: ["X-Yap-Reason": res.reason])
            }
            return .json(["text": res.text, "reason": res.reason,
                          "seconds": AgentAPI.decimal(res.seconds, places: 1), "inserted": res.inserted])
        }
    }

    // MARK: state

    private func voiceStateName(_ s: Status) -> String {
        switch s {
        case .idle: return "idle"
        case .reading: return "reading"
        case .paused: return "paused"
        case .loadingModel, .capturing: return "loading"
        case .error: return "error"
        }
    }

    private func voiceState() -> String { voiceStateName(state.status) }

    private func dictationStateName() -> String {
        switch dictation.dictation.state {
        case .idle: return "idle"
        case .loadingModel: return "loading_model"
        case .listening: return "listening"
        case .finishing: return "finishing"
        case .transcribing: return "transcribing"
        case .error: return "error"
        }
    }

    func statusObject() -> [String: Any] {
        var voice: [String: Any] = [
            "state": voiceState(),
            "engine": prefs.engine,
            "voice": state.activeVoice,
            "id": state.currentVoiceId,
            "speed": AgentAPI.decimal(prefs.speed),
            "queued": state.speakQueueCount,
            "enabled": prefs.voiceEnabled,
            "backend_ready": state.backend.ready,
        ]
        if case .error(let m) = state.status { voice["error"] = m }
        var ears: [String: Any] = [
            "state": dictationStateName(),
            "enabled": prefs.dictationEnabled,
            "model_ready": dictation.dictation.modelReady,
            "api_session": dictation.agentSession != nil,
        ]
        if case .error(let m) = dictation.dictation.state { ears["error"] = m }
        return [
            "app": "Yap",
            "version": UpdateChecker.currentVersion,
            "api_version": AgentAPI.version,
            "voice": voice,
            "dictation": ears,
            "listen_allowed": prefs.agentListenEnabled && prefs.dictationEnabled,
        ]
    }

    func voicesObject() -> [String: Any] {
        let current = state.currentVoiceId
        let list: [[String: Any]] = state.combinedVoices.map { v in
            ["id": v.id, "name": v.label, "engine": v.engine, "voice": v.voiceId,
             "group": v.section, "available": v.available, "current": v.id == current]
        }
        return ["voices": list, "current": current]
    }
}
