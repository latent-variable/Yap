import AVFoundation
import Foundation

/// `Yap --apitest [backendPort] [speech.aiff]` — the agent API against the real
/// pipeline, end to end, without touching a running Yap.
///
/// What is real: the socket server, the routes, `AppState`'s read pipeline, the
/// `AudioPlayer`, a sidecar launched on its own spare port (so the one the app
/// owns is never a party), `DictationController.listenForAgent` and the actual
/// `Dictation` session, fed from a speech file instead of the mic.
///
/// What is not: the microphone (nobody speaks), the HUD (kept off the screen with
/// `headless`), and audible output (volume is 0). Run it with `YAP_REPO` set to
/// the repo root so the sidecar can be found:
///
///     YAP_REPO=$PWD/.. "$(swift build --show-bin-path)/Yap" --apitest
///
/// The probe has its own UserDefaults domain (the bare executable has no bundle
/// id), its own history file and its own socket in a private temp directory.
enum AgentProbe {
    static func run(port: Int, speechPath: String?) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            let failures = await Runner(port: port, speechPath: speechPath).run()
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }


    /// What a mic would hand over: the clip, then `tail` seconds of room noise,
    /// delivered in real time through the same feed the tap uses.
    @MainActor
    static func simulatedFeeder(clip: AVAudioPCMBuffer, clipSeconds: Double, tail: Double) -> (Dictation) async throws -> Void {
        return { d in
            let speech = DictationProbe.prefix(clip, seconds: clipSeconds)
            let audio = DictationProbe.join(speech, DictationProbe.silence(seconds: tail, format: clip.format))
            DictationProbe.addNoise(audio)
            let feed = try await d.startSimulated(format: audio.format)
            Task.detached {
                var off: AVAudioFrameCount = 0
                let began = Date()
                while off < audio.frameLength {
                    let n = min(4096, audio.frameLength - off)
                    let chunk = AVAudioPCMBuffer(pcmFormat: audio.format, frameCapacity: n)!
                    chunk.frameLength = n
                    memcpy(chunk.floatChannelData![0], audio.floatChannelData![0] + Int(off), Int(n) * 4)
                    feed(chunk)
                    off += n
                    let wait = began.addingTimeInterval(Double(off) / audio.format.sampleRate).timeIntervalSinceNow
                    if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                }
            }
        }
    }

    /// `Yap --apiserve [port] [speech.aiff]`: the same silent, isolated server the
    /// probe uses, kept running so `scripts/yap` and other clients can be tried
    /// against it. Socket: `YAP_API_SOCKET` (required). With a speech file, `/listen`
    /// hears that file.
    @MainActor static var served: AgentAPIController?

    static func serve(port: Int, speechPath: String?) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            guard let sock = ProcessInfo.processInfo.environment["YAP_API_SOCKET"], !sock.isEmpty else {
                print("set YAP_API_SOCKET to a socket path (in a private directory)"); exit(2)
            }
            AppState.probeBackendPort = port
            HistoryStore.probeFileURL = URL(fileURLWithPath: sock).deletingLastPathComponent().appending(path: "history.json")
            let prefs = Prefs.shared
            prefs.volume = 0
            prefs.muteAllSounds = true
            let state = AppState.shared
            await state.backend.start()
            guard state.backend.ready else { print("sidecar did not start: \(state.backend.lastError ?? "?")"); exit(1) }
            state.voices = await state.backend.client.voices()
            let dictation = DictationController.shared
            dictation.headless = true
            if let speechPath, let clip = try? DictationProbe.loadMicLike(speechPath) {
                prefs.agentListenEnabled = true
                dictation.simulatedCapture = simulatedFeeder(clip: clip, clipSeconds: Double(clip.frameLength) / clip.format.sampleRate, tail: 6)
            }
            let controller = AgentAPIController(state: state, dictation: dictation, prefs: prefs, socketPath: sock)
            served = controller   // the server holds the controller weakly; keep it alive
            controller.start()
            print("serving on \(sock) (listen \(prefs.agentListenEnabled ? "on, hears \(speechPath ?? "")" : "off"))")
        }
        dispatchMain()
    }

    @MainActor
    final class Runner {
        let port: Int
        let speechPath: String?
        var failures = 0
        var sock = ""

        init(port: Int, speechPath: String?) { self.port = port; self.speechPath = speechPath }

        func ok(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
            if cond { print("  ✓ \(name)") }
            else { failures += 1; print("  ✗ \(name) \(detail())") }
        }

        struct Reply { var status: Int; var json: [String: Any]; var raw: String }

        func call(_ method: String, _ path: String, _ body: String? = nil, accept: String? = nil,
                  timeout: Int = 60) async -> Reply {
            let b = body ?? ""
            var req = "\(method) \(path) HTTP/1.1\r\nHost: yap\r\n"
            if let accept { req += "Accept: \(accept)\r\n" }
            if body != nil { req += "Content-Type: application/json\r\nContent-Length: \(b.utf8.count)\r\n" }
            req += "\r\n" + b
            let sock = self.sock
            let raw = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
                DispatchQueue.global().async { c.resume(returning: AgentSelftest.raw(sock, req, timeout: timeout)) }
            }
            let parts = raw.components(separatedBy: "\r\n\r\n")
            let json = parts.count > 1
                ? (try? JSONSerialization.jsonObject(with: Data(parts[1...].joined(separator: "\r\n\r\n").utf8))) as? [String: Any] ?? [:]
                : [:]
            return Reply(status: AgentSelftest.status(raw), json: json, raw: raw)
        }

        func until(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if cond() { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return cond()
        }

        func voiceState(_ r: Reply) -> String { (r.json["voice"] as? [String: Any])?["state"] as? String ?? "?" }

        func run() async -> Int {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appending(path: "yapapitest-\(getpid())")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? fm.trashItem(at: dir, resultingItemURL: nil) }
            sock = dir.appending(path: "yap.sock").path

            print("Agent API probe — own socket \(sock), own sidecar on :\(port)")
            HistoryStore.probeFileURL = dir.appending(path: "history.json")
            AppState.probeBackendPort = port
            let prefs = Prefs.shared
            prefs.volume = 0
            prefs.muteAllSounds = true
            prefs.engine = "kokoro"
            prefs.voice = "am_puck"
            prefs.speed = 1.0
            prefs.agentAPIEnabled = true
            prefs.agentListenEnabled = false
            let baseline = (prefs.engine, prefs.voice, prefs.hdVoice, prefs.speed, prefs.pitch, prefs.volume)

            ok("YAP_API_SOCKET overrides the socket path",
               AgentAPI.socketPath(env: ["YAP_API_SOCKET": "/x/y.sock"]) == "/x/y.sock")
            ok("the default path is in Application Support/Yap",
               AgentAPI.socketPath(env: [:]).hasSuffix("/Library/Application Support/Yap/yap.sock"))

            let state = AppState.shared
            guard state.backend.repoRoot() != nil else {
                print("  ✗ no repo root: set YAP_REPO to the Yap checkout"); return 1
            }
            await state.backend.start()
            guard state.backend.ready else {
                print("  ✗ the probe's own sidecar did not start: \(state.backend.lastError ?? "?")"); return 1
            }
            ok("the probe's sidecar is not the app's port", state.backend.port == port && port != 8766)
            state.voices = await state.backend.client.voices()
            ok("kokoro voices loaded", !state.voices.isEmpty)

            let dictation = DictationController.shared
            dictation.headless = true
            let controller = AgentAPIController(state: state, dictation: dictation, prefs: prefs, socketPath: sock)
            controller.bootstrap()
            ok("the server comes up", await until(2) { fm.fileExists(atPath: self.sock) })

            // MARK: the socket
            print("  socket")
            var st = stat()
            stat(sock, &st)
            ok("the socket is 0600", st.st_mode & 0o7777 == 0o600, String(st.st_mode & 0o7777, radix: 8))
            stat(dir.path, &st)
            ok("its folder is not group/world writable", st.st_mode & 0o022 == 0)

            // MARK: status, voices, bad input
            print("  status, voices, bad input")
            let s = await call("GET", "/status")
            ok("GET /status", s.status == 200 && voiceState(s) == "idle" && s.json["version"] as? String == UpdateChecker.currentVersion
               && s.json["api_version"] as? Int == AgentAPI.version, s.raw)
            ok("listening is reported as not allowed", s.json["listen_allowed"] as? Bool == false)
            let v = await call("GET", "/voices")
            let vlist = v.json["voices"] as? [[String: Any]] ?? []
            ok("GET /voices lists voices with id, name, engine",
               v.status == 200 && vlist.contains { $0["id"] as? String == "kokoro:am_puck" && $0["engine"] as? String == "kokoro" && $0["name"] != nil })
            ok("the current voice is flagged", vlist.contains { $0["id"] as? String == "kokoro:am_puck" && $0["current"] as? Bool == true })
            ok("malformed JSON is a 400", (await call("POST", "/speak", "{nope")).status == 400)
            ok("an unknown field is a 400", (await call("POST", "/speak", #"{"text":"hi","speeed":2}"#)).status == 400)
            ok("an unknown voice is a 400", (await call("POST", "/speak", #"{"text":"hi","voice":"nobody"}"#)).status == 400)
            ok("an unknown path is a 404", (await call("GET", "/nope")).status == 404)
            ok("the wrong method is a 405", (await call("GET", "/speak")).status == 405)
            ok("raw garbage is a 4xx", (400..<500).contains(AgentSelftest.status(AgentSelftest.raw(sock, "GARBAGE\r\n\r\n"))))
            ok("nothing was spoken by any of that", state.status == .idle)

            // MARK: listen is off by default
            print("  listen is off by default")
            let denied = await call("POST", "/listen", "{}")
            ok("POST /listen is 403 while listening is off", denied.status == 403 && denied.json["code"] as? String == "listen_disabled", denied.raw)
            ok("...and the microphone was never opened", dictation.dictation.state == .idle && dictation.agentSession == nil)

            // MARK: speak
            print("  speak")
            let sentence = "This is a test of the Yap agent interface, speaking one clear sentence."
            let t0 = Date()
            let w = await call("POST", "/speak", #"{"text":"\#(sentence)","wait":true}"#)
            ok("speak with wait reports finished", w.status == 200 && w.json["outcome"] as? String == "finished", w.raw)
            ok("...after real playback time, not instantly", Date().timeIntervalSince(t0) > 1.5, "\(Date().timeIntervalSince(t0))s")
            ok("...and the player is parked afterwards", await until(2) { !state.audio.hasQueued && state.status == .idle })

            // Per-request speed and voice: applied to that read, never to the user's choice.
            let fastTask = Task { await self.call("POST", "/speak", #"{"text":"\#(sentence) \#(sentence)","speed":3.0,"voice":"af_heart","wait":true}"#) }
            let sawFast = await until(30) { state.status == .reading && state.audio.currentRate == 3.0 }
            ok("a per-request speed reaches the player", sawFast, "rate \(state.audio.currentRate)")
            ok("...while the user's speed setting is untouched", prefs.speed == baseline.3 && prefs.voice == baseline.1)
            let fast = await fastTask.value
            ok("that read finished", fast.json["outcome"] as? String == "finished", fast.raw)
            ok("it spoke the requested voice (History says so)",
               HistoryStore.shared.spoken.first?.detail.contains("af_heart") == true,
               HistoryStore.shared.spoken.first?.detail ?? "none")
            state.readAloud("A normal read after an API read.")
            ok("the next ordinary read is back at the user's speed", await until(30) { state.status == .reading && state.audio.currentRate == Float(baseline.3) },
               "rate \(state.audio.currentRate)")
            state.stop()

            // MARK: stop, pause, resume
            print("  stop, pause, resume")
            let long = String(repeating: sentence + " ", count: 12)
            let stopped = Task { await self.call("POST", "/speak", #"{"text":"\#(long)","wait":true}"#) }
            ok("a long read starts", await until(30) { state.status == .reading })
            let p = await call("POST", "/pause")
            ok("POST /pause pauses it", p.status == 200 && p.json["state"] as? String == "paused" && p.json["changed"] as? Bool == true, p.raw)
            ok("GET /status says paused", voiceState(await call("GET", "/status")) == "paused")
            let r = await call("POST", "/resume")
            ok("POST /resume resumes it", r.json["state"] as? String == "reading" && r.json["changed"] as? Bool == true, r.raw)
            try? await Task.sleep(nanoseconds: 800_000_000)
            let x = await call("POST", "/stop")
            ok("POST /stop stops it", x.status == 200 && x.json["state"] as? String == "idle", x.raw)
            let stoppedReply = await stopped.value
            ok("the waiting speak reports stopped, not finished", stoppedReply.json["outcome"] as? String == "stopped", stoppedReply.raw)
            ok("the player really emptied", !state.audio.hasQueued)
            ok("pause with nothing playing changes nothing", (await call("POST", "/pause")).json["changed"] as? Bool == false)

            // MARK: queue and interrupt
            print("  queue and interrupt")
            let a = await call("POST", "/speak", #"{"text":"\#(long)"}"#)
            let aID = Int(a.json["id"] as? String ?? "") ?? -1
            ok("a speak returns an id and is not queued", a.status == 200 && aID > 0 && a.json["queued"] as? Bool == false, a.raw)
            ok("it is reading", await until(30) { state.status == .reading })
            let b = await call("POST", "/speak", #"{"text":"Second.","interrupt":false}"#)
            ok("interrupt:false waits its turn", b.json["queued"] as? Bool == true && b.json["position"] as? Int == 1, b.raw)
            ok("GET /status shows the line", ((await call("GET", "/status")).json["voice"] as? [String: Any])?["queued"] as? Int == 1)
            let c = await call("POST", "/speak", #"{"text":"Third, interrupting.","wait":true}"#)
            ok("interrupt (the default) replaces the read and empties the line", c.json["outcome"] as? String == "finished", c.raw)
            ok("the replaced read was stopped", state.speakOutcome(aID) == .stopped)
            let bID = Int(b.json["id"] as? String ?? "") ?? -1
            ok("the request that was waiting was dropped, not spoken later", state.speakOutcome(bID) == .stopped && state.speakQueueCount == 0)

            let first = await call("POST", "/speak", #"{"text":"First in line."}"#)
            let second = await call("POST", "/speak", #"{"text":"Second in line.","interrupt":false,"wait":true}"#)
            ok("a queued request plays after the one before it and reports finished",
               second.json["outcome"] as? String == "finished" && state.speakOutcome(Int(first.json["id"] as? String ?? "") ?? -1) == .finished, second.raw)
            let order = HistoryStore.shared.spoken.prefix(2).map(\.text)
            ok("...in order", order.count == 2 && order[0].contains("Second") && order[1].contains("First"), "\(order)")

            // MARK: a caller that hangs up
            print("  a caller that hangs up")
            let sockCopy = sock
            let hangText = long
            DispatchQueue.global().async {
                let body = #"{"text":"\#(hangText)","wait":true}"#
                _ = AgentSelftest.raw(sockCopy, "POST /speak HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)", closeEarly: true, hold: 3)
            }
            ok("the read starts", await until(30) { state.status == .reading })
            ok("closing the connection stops a read nobody is waiting for", await until(5) { state.status == .idle && !state.audio.hasQueued })

            // MARK: settings untouched
            print("  the user's settings")
            let after = (prefs.engine, prefs.voice, prefs.hdVoice, prefs.speed, prefs.pitch, prefs.volume)
            ok("no request changed the user's engine, voice, speed, pitch or volume", after == baseline, "\(after)")
            ok("...nor what is stored on disk", UserDefaults.standard.double(forKey: "speed") == 1.0
               && UserDefaults.standard.string(forKey: "voice") == "am_puck")

            // MARK: listen (simulated capture)
            await listenChecks(dictation: dictation, prefs: prefs, dir: dir)

            // MARK: live toggle
            print("  the live switch")
            prefs.agentAPIEnabled = false
            ok("turning the API off removes the socket", await until(3) { !fm.fileExists(atPath: self.sock) })
            ok("...and nothing answers", (await call("GET", "/status", timeout: 2)).raw.hasPrefix("CONNECT-FAILED"))
            prefs.agentAPIEnabled = true
            ok("turning it on brings it back", await until(3) { fm.fileExists(atPath: self.sock) })
            ok("...answering again", (await call("GET", "/status")).status == 200)

            controller.stop()
            state.stop()
            state.backend.stop()
            print(failures == 0 ? "\nAGENT API OK" : "\n\(failures) FAILURE(S)")
            return failures
        }

        // MARK: - listen

        func listenChecks(dictation: DictationController, prefs: Prefs, dir: URL) async {
            print("  listen (speech from a file, no microphone)")
            let fm = FileManager.default
            let speech = dir.appending(path: "speech.aiff").path
            if let speechPath, fm.fileExists(atPath: speechPath) {
                try? fm.copyItem(atPath: speechPath, toPath: speech)
            } else {
                let say = Process()
                say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                say.arguments = ["-o", speech, "The quick brown fox jumps over the lazy dog near the river bank."]
                try? say.run(); say.waitUntilExit()
            }
            guard let clip = try? DictationProbe.loadMicLike(speech) else {
                ok("a speech file to feed", false); return
            }
            let engineReady = await { () -> Bool in
                await dictation.dictation.loadModelAwaiting(.english)
                await dictation.dictation.awaitFinalModel()
                return dictation.dictation.modelReady
            }()
            guard engineReady else { ok("the dictation models are available", false, "download them by dictating once"); return }

            let feeder = { (clipSeconds: Double, tail: Double) in AgentProbe.simulatedFeeder(clip: clip, clipSeconds: clipSeconds, tail: tail) }
            let clipSecs = Double(clip.frameLength) / clip.format.sampleRate

            prefs.agentListenEnabled = true
            ok("listening is now reported as allowed", (await call("GET", "/status")).json["listen_allowed"] as? Bool == true)
            ok("POST /listen/stop with no listen is a 409", (await call("POST", "/listen/stop")).status == 409)
            ok("a bad listen request is a 400", (await call("POST", "/listen", #"{"max_seconds":0}"#)).status == 400)

            dictation.simulatedCapture = feeder(clipSecs, 6)
            let t0 = Date()
            let l = await call("POST", "/listen", #"{"max_seconds":30,"silence_seconds":1.2}"#)
            let text = (l.json["text"] as? String ?? "").lowercased()
            ok("it ends on the trailing silence", l.status == 200 && l.json["reason"] as? String == "silence", l.raw)
            ok("...and returns the transcript", text.contains("quick brown fox") && text.contains("river"), text)
            ok("...before the max, soon after the silence began",
               Date().timeIntervalSince(t0) < clipSecs + 1.2 + 6, "\(Date().timeIntervalSince(t0))s")
            ok("...without pasting", l.json["inserted"] as? Bool == false)
            ok("...the mic is closed again", dictation.dictation.state == .idle && dictation.agentSession == nil)
            ok("...and it is in History as an agent dictation",
               HistoryStore.shared.dictated.first?.detail == "Agent API" && HistoryStore.shared.dictated.first?.text.lowercased().contains("fox") == true)

            let plain = await call("POST", "/listen", #"{"max_seconds":30,"silence_seconds":1.2}"#, accept: "text/plain")
            ok("Accept: text/plain returns just the words",
               plain.raw.contains("Content-Type: text/plain") && plain.raw.lowercased().contains("quick brown fox")
               && plain.raw.contains("X-Yap-Reason: silence"), plain.raw)

            // The time limit: speech that never stops.
            dictation.simulatedCapture = feeder(clipSecs, 0)
            let m = await call("POST", "/listen", #"{"max_seconds":2,"silence_seconds":5}"#)
            ok("it ends at max_seconds when nothing quiet follows", m.json["reason"] as? String == "max_seconds", m.raw)
            ok("...with the words heard so far", (m.json["text"] as? String ?? "").lowercased().contains("quick"), m.raw)

            // A second listen while one runs, and an early stop.
            dictation.simulatedCapture = feeder(clipSecs, 20)
            let running = Task { await self.call("POST", "/listen", #"{"max_seconds":60,"silence_seconds":10}"#) }
            ok("a listen is running", await until(30) { dictation.dictation.state == .listening })
            let busy = await call("POST", "/listen", "{}")
            ok("a second POST /listen is a 409", busy.status == 409 && busy.json["code"] as? String == "already_listening", busy.raw)
            try? await Task.sleep(nanoseconds: UInt64((clipSecs + 0.5) * 1e9))
            let stop = await call("POST", "/listen/stop")
            ok("POST /listen/stop is accepted", stop.status == 200, stop.raw)
            let early = await running.value
            ok("the running listen returns with reason stopped and the words so far",
               early.json["reason"] as? String == "stopped" && (early.json["text"] as? String ?? "").lowercased().contains("fox"), early.raw)

            // The shortcut ends an agent's listen too, and does not start a second session.
            let again = Task { await self.call("POST", "/listen", #"{"max_seconds":60,"silence_seconds":10}"#) }
            ok("another listen is running", await until(30) { dictation.dictation.state == .listening })
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            dictation.toggle()
            let viaKey = await again.value
            ok("the dictation shortcut ends it (reason stopped)", viaKey.json["reason"] as? String == "stopped", viaKey.raw)

            // A caller that hangs up discards the session.
            dictation.simulatedCapture = feeder(clipSecs, 20)
            let sockCopy = sock
            DispatchQueue.global().async {
                let body = #"{"max_seconds":60,"silence_seconds":10}"#
                _ = AgentSelftest.raw(sockCopy, "POST /listen HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)", closeEarly: true, hold: 5)
            }
            ok("a listen starts", await until(30) { dictation.dictation.state == .listening })
            let hung = Date()
            let closed = await until(15) { dictation.dictation.state == .idle && dictation.agentSession == nil }
            ok("hanging up closes the microphone", closed, "state \(dictation.dictation.state), session \(dictation.agentSession != nil)")
            print(String(format: "     (idle %.1fs after the check began; the client hangs up at 5 s)", Date().timeIntervalSince(hung)))

            // Revoking listening mid-session closes the mic too.
            dictation.simulatedCapture = feeder(clipSecs, 20)
            let revoked = Task { await self.call("POST", "/listen", #"{"max_seconds":60,"silence_seconds":10}"#) }
            ok("a listen starts again", await until(30) { dictation.dictation.state == .listening })
            prefs.agentListenEnabled = false
            let rv = await revoked.value
            ok("turning listening off ends it and returns nothing", (rv.json["text"] as? String ?? "x").isEmpty, rv.raw)
            ok("...and the mic is closed", dictation.dictation.state == .idle)
            ok("...and /listen is 403 again", (await call("POST", "/listen", "{}")).status == 403)
            dictation.simulatedCapture = nil
        }
    }
}
