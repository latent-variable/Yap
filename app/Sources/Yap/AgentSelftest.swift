import Foundation
import Darwin

/// `--selftest` cases for the agent API: the HTTP parser, request validation, the
/// voice resolver and the socket server (file mode, stale-socket handling,
/// malformed input, disconnect). No microphone, backend or audio needed; the
/// end-to-end run against the real pipeline is `--apitest` (AgentProbe.swift).
enum AgentSelftest {
    final class Flag: @unchecked Sendable {
        private let l = NSLock()
        private var v = false
        func set() { l.lock(); v = true; l.unlock() }
        var isSet: Bool { l.lock(); defer { l.unlock() }; return v }
    }

    /// One blocking request: connect, send `bytes`, read to EOF. For tests only.
    static func raw(_ path: String, _ bytes: String, closeEarly: Bool = false, hold: Double = 0, timeout: Int = 5) -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return "" }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { return "CONNECT-FAILED \(errno)" }
        _ = AgentServer.writeAll(fd, Data(bytes.utf8))
        if closeEarly { if hold > 0 { Thread.sleep(forTimeInterval: hold) }; return "" }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func status(_ response: String) -> Int {
        let parts = response.split(separator: " ", maxSplits: 2)
        return parts.count >= 2 ? Int(parts[1]) ?? -1 : -1
    }

    static func mode(_ path: String) -> Int? {
        var st = stat()
        return stat(path, &st) == 0 ? Int(st.st_mode & 0o7777) : nil
    }

    static func run() -> Int {
        var failures = 0
        func ok(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
            if cond { print("  ✓ \(name)") }
            else { failures += 1; print("  ✗ \(name) \(detail())") }
        }
        func headBad(_ s: String) -> APIError? {
            if case .bad(let e) = AgentAPI.parseHead(Array(s.utf8)) { return e }
            return nil
        }

        print("Agent API — HTTP request head")
        let get = "GET /status HTTP/1.1\r\nHost: yap\r\nAccept: */*\r\n\r\n"
        if case .head(let h, let used) = AgentAPI.parseHead(Array(get.utf8)) {
            ok("a plain GET parses", h.method == "GET" && h.target == "/status" && h.contentLength == 0)
            ok("it reports exactly how many bytes the head took", used == get.utf8.count)
        } else { ok("a plain GET parses", false) }
        ok("a head cut short asks for more", AgentAPI.parseHead(Array("GET /status HTTP/1.1\r\nHost: y".utf8)) == .incomplete)
        if case .head(let h, _) = AgentAPI.parseHead(Array("POST /speak HTTP/1.1\r\ncontent-LENGTH: 12\r\nExpect: 100-continue\r\n\r\n".utf8)) {
            ok("header names are case-insensitive", h.contentLength == 12)
            ok("Expect: 100-continue is recognised", h.expectContinue)
        } else { ok("POST head parses", false) }
        ok("bare LF line endings are refused", headBad("GET /status HTTP/1.1\nHost: y\n\r\n\r\n")?.status == 400)
        ok("chunked bodies are refused", headBad("POST /speak HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")?.status == 501)
        ok("conflicting Content-Length headers are refused",
           headBad("POST /speak HTTP/1.1\r\nContent-Length: 4\r\nContent-Length: 5\r\n\r\n")?.status == 400)
        ok("a repeated, agreeing Content-Length is fine",
           AgentAPI.parseHead(Array("POST /speak HTTP/1.1\r\nContent-Length: 4\r\nContent-Length: 4\r\n\r\n".utf8)) != .incomplete
           && headBad("POST /speak HTTP/1.1\r\nContent-Length: 4\r\nContent-Length: 4\r\n\r\n") == nil)
        ok("a body over the cap is refused (413)",
           headBad("POST /speak HTTP/1.1\r\nContent-Length: \(AgentAPI.maxBodyBytes + 1)\r\n\r\n")?.status == 413)
        ok("a non-numeric Content-Length is refused", headBad("POST /speak HTTP/1.1\r\nContent-Length: 1e3\r\n\r\n")?.status == 400)
        ok("a negative Content-Length is refused", headBad("POST /speak HTTP/1.1\r\nContent-Length: -1\r\n\r\n")?.status == 400)
        ok("folded header lines are refused", headBad("GET /status HTTP/1.1\r\nX-A: 1\r\n  continued\r\n\r\n")?.status == 400)
        ok("a header with no colon is refused", headBad("GET /status HTTP/1.1\r\nNonsense\r\n\r\n")?.status == 400)
        ok("garbage is refused", headBad("GARBAGE\r\n\r\n")?.status == 400)
        ok("an absolute-form target is refused", headBad("GET http://x/status HTTP/1.1\r\n\r\n")?.status == 400)
        ok("HTTP/2 is refused (505)", headBad("GET /status HTTP/2\r\n\r\n")?.status == 505)
        ok("a NUL byte is refused", headBad("GET /sta\u{0}tus HTTP/1.1\r\n\r\n")?.status == 400)
        ok("Expect: other is refused (417)", headBad("POST /speak HTTP/1.1\r\nExpect: nope\r\n\r\n")?.status == 417)
        ok("a head with no end is refused once it is too big (431)",
           AgentAPI.parseHead(Array(("GET /status HTTP/1.1\r\nX-A: " + String(repeating: "a", count: AgentAPI.maxHeaderBytes + 10)).utf8))
            == .bad(APIError(431, "headers_too_large", "Request headers are larger than \(AgentAPI.maxHeaderBytes) bytes.")))

        print("Agent API — routes")
        func routed(_ m: String, _ p: String) -> String {
            switch AgentAPI.route(method: m, path: p) {
            case .success(let r): return r.rawValue
            case .failure(let e): return "\(e.status)"
            }
        }
        ok("GET /status", routed("GET", "/status") == "status")
        ok("POST /listen/stop is its own route", routed("POST", "/listen/stop") == "listenStop")
        ok("POST /listen", routed("POST", "/listen") == "listen")
        ok("the wrong method is 405, not 404", routed("GET", "/speak") == "405" && routed("POST", "/status") == "405")
        ok("an unknown path is 404", routed("GET", "/nope") == "404" && routed("GET", "/status/") == "404")
        ok("every route is reachable by its own method and path",
           AgentRoute.allCases.allSatisfy { routed($0.method, $0.path) == $0.rawValue })

        print("Agent API — /speak validation")
        func speak(_ json: String) -> Result<SpeakRequest, APIError> { AgentAPI.parseSpeak(Data(json.utf8)) }
        func code(_ r: Result<some Any, APIError>) -> String {
            if case .failure(let e) = r { return e.code } else { return "ok" }
        }
        if case .success(let r) = speak(#"{"text":"hi"}"#) {
            ok("defaults: interrupt, clean, no wait", r.interrupt && r.clean && !r.wait && r.voice == nil && r.speed == nil)
        } else { ok("minimal request parses", false) }
        if case .success(let r) = speak(#"{"text":"hi","voice":"kokoro:am_puck","engine":"kokoro","speed":1.5,"interrupt":false,"clean":false,"wait":true}"#) {
            ok("every field is read", r.voice == "kokoro:am_puck" && r.speed == 1.5 && !r.interrupt && !r.clean && r.wait)
        } else { ok("full request parses", false) }
        ok("no text is rejected", code(speak("{}")) == "missing_field" && code(speak("")) == "missing_field")
        ok("blank text is rejected", code(speak(#"{"text":"  \n"}"#)) == "empty_text")
        ok("a misspelt field is rejected, not ignored", code(speak(#"{"text":"hi","speeed":2}"#)) == "unknown_field")
        ok("text must be a string", code(speak(#"{"text":5}"#)) == "bad_field")
        ok("speed must be a number, not a string", code(speak(#"{"text":"hi","speed":"2"}"#)) == "bad_field")
        ok("speed above the range is rejected", code(speak(#"{"text":"hi","speed":4.5}"#)) == "bad_field")
        ok("speed below the range is rejected", code(speak(#"{"text":"hi","speed":0.1}"#)) == "bad_field")
        ok("a boolean is not a number", code(speak(#"{"text":"hi","speed":true}"#)) == "bad_field")
        ok("a number is not a boolean", code(speak(#"{"text":"hi","wait":1}"#)) == "bad_field")
        ok("an unknown engine is rejected", code(speak(#"{"text":"hi","engine":"eleven"}"#)) == "bad_field")
        ok("a non-object body is rejected", code(speak("[1,2]")) == "bad_json" && code(speak("not json")) == "bad_json")
        ok("an over-long text is rejected (413)",
           { if case .failure(let e) = speak(#"{"text":""# + String(repeating: "a", count: AgentAPI.maxSpeakChars + 1) + #""}"#) { return e.status == 413 }; return false }())

        print("Agent API — /listen validation")
        func listen(_ json: String) -> Result<ListenRequest, APIError> { AgentAPI.parseListen(Data(json.utf8)) }
        if case .success(let r) = listen("") {
            ok("an empty body takes the defaults (60 s, 1.5 s, no paste)", r == ListenRequest())
        } else { ok("empty listen body parses", false) }
        if case .success(let r) = listen(#"{"max_seconds":5,"silence_seconds":0.8,"insert":true}"#) {
            ok("listen fields are read", r.maxSeconds == 5 && r.silenceSeconds == 0.8 && r.insert)
        } else { ok("full listen request parses", false) }
        ok("max_seconds 0 is rejected", code(listen(#"{"max_seconds":0}"#)) == "bad_field")
        ok("max_seconds past the recorder cap is rejected", code(listen(#"{"max_seconds":171}"#)) == "bad_field")
        ok("silence_seconds under the floor is rejected", code(listen(#"{"silence_seconds":0.1}"#)) == "bad_field")
        ok("insert must be a boolean", code(listen(#"{"insert":"yes"}"#)) == "bad_field")
        ok("a misspelt listen field is rejected", code(listen(#"{"max_second":5}"#)) == "unknown_field")
        ok("an agent dictation pasted into an app is marked as the agent's",
           DictationController.historyDetail(target: "Notes", agent: true) == "Agent API → Notes")
        ok("...and one with no target still says Agent API",
           DictationController.historyDetail(target: "", agent: true) == "Agent API")
        ok("the user's own dictation keeps just the app name",
           DictationController.historyDetail(target: "Notes", agent: false) == "Notes")

        print("Agent API — which voice a request means")
        let list: [EngineVoice] = [
            EngineVoice(engine: "kokoro", voiceId: "am_puck", label: "puck", section: "American"),
            EngineVoice(engine: "kokoro", voiceId: "af_heart", label: "heart", section: "American"),
            EngineVoice(engine: "pocket", voiceId: "eve", label: "eve", section: "Pocket Voices"),
            EngineVoice(engine: "pocket", voiceId: "Philip", label: "Philip", section: "Cloned", available: false),
        ]
        func resolve(_ o: AppState.SpeakOptions, combined: [EngineVoice] = list, hd: Bool = true)
            -> Result<AppState.ReadParams, APIError> {
            AppState.resolveRead(o, combined: combined, hdInstalled: hd, prefsEngine: "kokoro",
                                 prefsVoice: "am_puck", prefsHDVoice: "eve", prefsSpeed: 1.25)
        }
        func params(_ r: Result<AppState.ReadParams, APIError>) -> String {
            switch r {
            case .success(let p): return "\(p.engine)/\(p.voice)/\(p.speed)"
            case .failure(let e): return "\(e.status) \(e.code)"
            }
        }
        ok("no overrides means the user's own selection", params(resolve(.init())) == "kokoro/am_puck/1.25")
        ok("...even before the voice list has loaded", params(resolve(.init(), combined: [])) == "kokoro/am_puck/1.25")
        ok("a speed override changes only the speed", params(resolve(.init(speed: 2))) == "kokoro/am_puck/2.0")
        ok("a bare voice id uses the current engine", params(resolve(.init(voice: "af_heart"))) == "kokoro/af_heart/1.25")
        ok("engine:voice names both", params(resolve(.init(voice: "pocket:eve"))) == "pocket/eve/1.25")
        ok("an engine alone takes that engine's own voice", params(resolve(.init(engine: "pocket"))) == "pocket/eve/1.25")
        ok("a voice from the other engine is rejected",
           params(resolve(.init(engine: "kokoro", voice: "pocket:eve"))) == "400 bad_voice")
        ok("an unknown voice is rejected", params(resolve(.init(voice: "nobody"))) == "400 bad_voice")
        ok("an unknown engine prefix is rejected", params(resolve(.init(voice: "bark:x"))) == "400 bad_voice")
        ok("Pocket is refused when it is not installed", params(resolve(.init(engine: "pocket"), hd: false)) == "400 engine_unavailable")
        ok("a cloned voice that cannot speak yet is 409", params(resolve(.init(voice: "pocket:Philip"))) == "409 voice_unavailable")
        ok("an override before the voice list loads is a retryable 503",
           params(resolve(.init(voice: "af_heart"), combined: [])) == "503 voices_not_loaded")

        print("Agent API — the socket server")
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "yapapi-\(getpid())-\(UInt32.random(in: 0...99999))")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.trashItem(at: dir, resultingItemURL: nil) }
        let sock = dir.appending(path: "t.sock").path
        let cancelled = Flag()
        let server = AgentServer(path: sock) { req in
            if req.path == "/hang" {
                // A wait or listen in miniature: runs until its caller goes away.
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 20_000_000) }
                cancelled.set()
                return HTTPResponse.json(["cancelled": true])
            }
            return HTTPResponse.json(["method": req.method, "path": req.path, "bytes": req.body.count,
                                      "query": req.query])
        }
        do { try server.start() } catch { ok("the server starts", false, "\(error)") ; return failures }
        ok("the socket file is 0600", mode(sock) == 0o600, "mode \(mode(sock).map { String($0, radix: 8) } ?? "none")")
        let r1 = raw(sock, "GET /status?x=1 HTTP/1.1\r\nHost: yap\r\n\r\n")
        ok("a GET is answered 200 with JSON", status(r1) == 200 && r1.contains("\"path\":\"/status\"") && r1.contains("\"query\":\"x=1\""), r1)
        ok("the response says it closes and carries the API version",
           r1.contains("Connection: close") && r1.contains("X-Yap-API: \(AgentAPI.version)"))
        let r2 = raw(sock, "POST /speak HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello")
        ok("a POST body arrives whole", status(r2) == 200 && r2.contains("\"bytes\":5"), r2)
        let r3 = raw(sock, "POST /speak HTTP/1.1\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\nhello")
        ok("Expect: 100-continue gets its interim reply and the real one",
           r3.hasPrefix("HTTP/1.1 100 Continue") && r3.contains("HTTP/1.1 200 OK"), r3)
        ok("garbage gets a 4xx", (400..<500).contains(status(raw(sock, "GARBAGE\r\n\r\n"))))
        ok("an oversized body is refused before it is read",
           status(raw(sock, "POST /speak HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n")) == 413)
        ok("chunked is refused", status(raw(sock, "POST /speak HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")) == 501)
        ok("a request line with no end of head is not answered with a hang",
           status(raw(sock, "GET /status HTTP/1.1\r\n" + String(repeating: "X-A: a\r\n", count: 3000))) == 431)
        ok("the server keeps working after all that", status(raw(sock, "GET /status HTTP/1.1\r\n\r\n")) == 200)

        // A caller that hangs up must cancel its request: that is what keeps a
        // killed `yap listen` from leaving the microphone open.
        _ = raw(sock, "GET /hang HTTP/1.1\r\n\r\n", closeEarly: true)
        let until = Date().addingTimeInterval(3)
        while !cancelled.isSet && Date() < until { Thread.sleep(forTimeInterval: 0.05) }
        ok("a client that hangs up cancels its request", cancelled.isSet)

        print("Agent API — socket hygiene")
        let second = AgentServer(path: sock) { _ in HTTPResponse.json([:]) }
        var refusedLive = false
        do { try second.start() } catch AgentServer.StartError.alreadyServed { refusedLive = true } catch {}
        ok("a second server will not steal a live socket", refusedLive)
        ok("...and the live one still answers", status(raw(sock, "GET /status HTTP/1.1\r\n\r\n")) == 200)

        server.stop()
        ok("stop() removes the socket file", !fm.fileExists(atPath: sock))
        ok("stop() leaves nobody listening", raw(sock, "GET /status HTTP/1.1\r\n\r\n").hasPrefix("CONNECT-FAILED"))

        // A crash leaves the file behind with nothing listening: bind, close, keep the file.
        func leaveStaleSocket(at path: String) {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            close(fd)
        }
        leaveStaleSocket(at: sock)
        ok("a stale socket file is there to be cleared", fm.fileExists(atPath: sock))
        let third = AgentServer(path: sock) { _ in HTTPResponse.json(["fresh": true]) }
        do { try third.start() } catch { ok("a stale socket is replaced", false, "\(error)") }
        ok("a stale socket is replaced and the server answers", status(raw(sock, "GET /status HTTP/1.1\r\n\r\n")) == 200)
        third.stop()

        let plain = dir.appending(path: "notasocket").path
        fm.createFile(atPath: plain, contents: Data("precious".utf8))
        var refusedFile = false
        do { try AgentServer(path: plain) { _ in HTTPResponse.json([:]) }.start() }
        catch AgentServer.StartError.occupied { refusedFile = true } catch {}
        ok("a regular file at the path is refused", refusedFile)
        ok("...and left exactly as it was", (try? String(contentsOfFile: plain, encoding: .utf8)) == "precious")

        var refusedLong = false
        do { try AgentServer(path: dir.appending(path: String(repeating: "x", count: 120)).path) { _ in HTTPResponse.json([:]) }.start() }
        catch AgentServer.StartError.pathTooLong { refusedLong = true } catch {}
        ok("a path too long for a Unix socket is refused", refusedLong)

        var refusedShared = false
        do { try AgentServer.prepareParent(of: "/tmp/yap-selftest.sock") }
        catch AgentServer.StartError.insecureParent { refusedShared = true } catch {}
        ok("a shared directory (/tmp, not ours) is refused as a home for the socket", refusedShared)

        let loose = dir.appending(path: "loose")
        try? fm.createDirectory(at: loose, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        chmod(loose.path, 0o777)   // createDirectory applies the umask; set it for real
        ok("a group/world-writable folder of ours starts out loose", (mode(loose.path) ?? 0) & 0o022 != 0)
        try? AgentServer.prepareParent(of: loose.appending(path: "s.sock").path)
        ok("...and is tightened rather than trusted", (mode(loose.path) ?? 0xFFF) & 0o022 == 0,
           "mode \(mode(loose.path).map { String($0, radix: 8) } ?? "none")")

        print("Agent API — when the speaker is done")
        // 10 ms windows: loud (-20 dB) for `speech` s, then quiet (-60 dB) for `quiet` s.
        func levels(speech: Double, quiet: Double, lead: Double = 0.5) -> (l: [SpeechGate.Level], frames: Int) {
            var out: [SpeechGate.Level] = []
            var frame = 0
            for (secs, db) in [(lead, Float(-60)), (speech, Float(-20)), (quiet, Float(-60))] {
                for _ in 0..<Int(secs * 100) { frame += 480; out.append(.init(endFrame: frame, db: db)) }
            }
            return (out, frame)
        }
        let spoke = levels(speech: 2, quiet: 2)
        ok("speech then 2 s of quiet ends a 1.5 s listen",
           SpeechGate.endedBySilence(spoke.l, frames: spoke.frames, rate: 48_000, silence: 1.5))
        let short = levels(speech: 2, quiet: 0.8)
        ok("0.8 s of quiet does not end a 1.5 s listen",
           !SpeechGate.endedBySilence(short.l, frames: short.frames, rate: 48_000, silence: 1.5))
        let still = levels(speech: 0, quiet: 4)
        ok("a recording that never heard speech never ends on silence",
           !SpeechGate.endedBySilence(still.l, frames: still.frames, rate: 48_000, silence: 1.5))
        let click = levels(speech: 0.04, quiet: 3)
        ok("a 40 ms click is not speech",
           !SpeechGate.endedBySilence(click.l, frames: click.frames, rate: 48_000, silence: 1.5))
        let talking = levels(speech: 3, quiet: 0)
        ok("still talking does not end it",
           !SpeechGate.endedBySilence(talking.l, frames: talking.frames, rate: 48_000, silence: 1.5))
        let flat = (0..<400).map { SpeechGate.Level(endFrame: ($0 + 1) * 480, db: -30) }
        ok("when speech cannot be told from the room, it never guesses",
           !SpeechGate.endedBySilence(flat, frames: 400 * 480, rate: 48_000, silence: 1.5))

        return failures
    }
}
