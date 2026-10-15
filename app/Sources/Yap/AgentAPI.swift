import Foundation

/// The agent API's wire format: a small, strict HTTP/1.1 subset, the route table
/// and request validation. Everything here is pure, so `--selftest` covers it
/// without a socket. The socket is `AgentServer.swift`, the behaviour behind each
/// route is `AgentAPIController.swift`, and the contract for callers is
/// `docs/AGENT-API.md`.
///
/// Strictness is the point. The only clients are programs the user runs, but they
/// are written by agents, and a loose parser turns an agent's typo into silent
/// behaviour ("speeed": 2 reading at normal speed). So: unknown JSON fields are
/// errors, wrong types are errors, and nothing is guessed.

/// A failure that maps to an HTTP status. `code` is stable and meant for programs;
/// `message` is for the human reading a log.
struct APIError: Error, Equatable {
    let status: Int
    let code: String
    let message: String
    init(_ status: Int, _ code: String, _ message: String) {
        self.status = status; self.code = code; self.message = message
    }
}

struct HTTPRequest: Equatable, Sendable {
    let method: String
    /// Path without the query string.
    let path: String
    let query: String
    /// Header names lowercased.
    let headers: [String: String]
    let body: Data
}

struct HTTPResponse: Sendable {
    var status: Int
    var contentType = "application/json"
    var body: Data
    var headers: [String: String] = [:]

    static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        HTTPResponse(status: status, body: AgentAPI.encode(object))
    }

    static func json(_ object: [String: Any]) -> HTTPResponse { json(200, object) }

    static func text(_ s: String, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "text/plain; charset=utf-8", body: Data(s.utf8), headers: headers)
    }

    static func error(_ e: APIError) -> HTTPResponse {
        var r = json(e.status, ["error": e.message, "code": e.code])
        if e.status == 405 { r.headers["Allow"] = "GET, POST" }
        return r
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 417: return "Expectation Failed"
        case 429: return "Too Many Requests"
        case 499: return "Client Closed Request"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        case 505: return "HTTP Version Not Supported"
        default: return "Status"
        }
    }

    /// The bytes written to the socket. Always `Connection: close`: one request
    /// per connection keeps the server free of keep-alive state, and a local
    /// Unix socket has no handshake to amortize.
    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        head += "Connection: close\r\nCache-Control: no-store\r\nX-Yap-API: \(AgentAPI.version)\r\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

struct HTTPHead: Equatable {
    let method: String
    let target: String
    let contentLength: Int
    let expectContinue: Bool
    let headers: [String: String]
}

enum HTTPHeadResult: Equatable {
    case incomplete
    /// `consumed` counts the request line, headers and the blank line.
    case head(HTTPHead, consumed: Int)
    case bad(APIError)
}

enum AgentRoute: String, CaseIterable {
    case status, voices, speak, stop, pause, resume, listen, listenStop

    var method: String {
        switch self {
        case .status, .voices: return "GET"
        default: return "POST"
        }
    }
    var path: String {
        switch self {
        case .status: return "/status"
        case .voices: return "/voices"
        case .speak: return "/speak"
        case .stop: return "/stop"
        case .pause: return "/pause"
        case .resume: return "/resume"
        case .listen: return "/listen"
        case .listenStop: return "/listen/stop"
        }
    }
}

struct SpeakRequest: Equatable {
    var text: String
    var voice: String?
    var engine: String?
    var speed: Double?
    var interrupt = true
    var clean = true
    var wait = false
}

struct ListenRequest: Equatable {
    var maxSeconds = 60.0
    var silenceSeconds = 1.5
    var insert = false
}

enum AgentAPI {
    /// Bumped only for an incompatible change to the routes or their fields.
    static let version = 1

    static let maxHeaderBytes = 16 * 1024
    /// Text for 200k characters is ~200 KB of JSON; a megabyte leaves room for
    /// escaping and refuses anything that is not a request for speech.
    static let maxBodyBytes = 1 << 20
    static let maxSpeakChars = 200_000
    /// The recorder keeps 180 s; a listen has to end before it overflows.
    static let maxListenSeconds = 170.0
    static let speedRange = 0.25...4.0
    static let silenceRange = 0.3...10.0

    // MARK: socket path

    /// `YAP_API_SOCKET` overrides the default (tests, and anyone running two builds).
    static func socketPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let p = env["YAP_API_SOCKET"], !p.isEmpty { return p }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Yap/yap.sock").path
    }

    // MARK: encoding

    /// A double as JSON prints it: `4.2`, not `4.2000000000000002`.
    static func decimal(_ d: Double, places: Int = 2) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.\(places)f", d))
    }

    static func encode(_ object: [String: Any]) -> Data {
        // Without escaping slashes: "\/" is valid JSON but makes a shell script's
        // sed extraction (see scripts/yap) needlessly fragile.
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
    }

    // MARK: routing

    static func route(method: String, path: String) -> Result<AgentRoute, APIError> {
        let matches = AgentRoute.allCases.filter { $0.path == path }
        guard !matches.isEmpty else {
            return .failure(APIError(404, "not_found", "No such endpoint: \(path)"))
        }
        guard let r = matches.first(where: { $0.method == method }) else {
            return .failure(APIError(405, "method_not_allowed", "\(path) takes \(matches[0].method), not \(method)."))
        }
        return .success(r)
    }

    // MARK: request head

    private static func isToken(_ s: Substring) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                || "!#$%&'*+-.^_`|~".utf8.contains(c)
        }
    }

    /// Parse as much of a request head as `bytes` holds.
    ///
    /// Anything unusual is refused rather than interpreted: bare LF line endings,
    /// obsolete header folding, chunked bodies, conflicting Content-Length
    /// headers. A parser that guesses is a request-smuggling parser; this one has
    /// no proxy in front of it, but the habit costs nothing.
    static func parseHead(_ bytes: [UInt8]) -> HTTPHeadResult {
        let crlf2: [UInt8] = [13, 10, 13, 10]
        var end: Int?
        if bytes.count >= 4 {
            var i = 0
            let limit = min(bytes.count - 4, maxHeaderBytes)
            while i <= limit {
                if bytes[i] == 13, Array(bytes[i..<i + 4]) == crlf2 { end = i; break }
                i += 1
            }
        }
        guard let end else {
            if bytes.count > maxHeaderBytes {
                return .bad(APIError(431, "headers_too_large", "Request headers are larger than \(maxHeaderBytes) bytes."))
            }
            return .incomplete
        }
        let consumed = end + 4
        guard !bytes[0..<end].contains(0) else {
            return .bad(APIError(400, "bad_request", "NUL byte in request head."))
        }
        let text = String(decoding: bytes[0..<end], as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        // A lone CR or LF inside a line means a bare-LF client or an injection try.
        for l in lines where l.contains("\n") || l.contains("\r") {
            return .bad(APIError(400, "bad_request", "Lines must end with CRLF."))
        }
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, isToken(parts[0]), parts[1].hasPrefix("/"),
              !parts[1].contains(where: { $0.isWhitespace || $0.asciiValue.map { $0 < 0x20 || $0 == 0x7F } == true })
        else { return .bad(APIError(400, "bad_request", "Malformed request line.")) }
        guard parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            return .bad(APIError(505, "bad_version", "Only HTTP/1.1 and HTTP/1.0 are supported."))
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.first == " " || line.first == "\t" {
                return .bad(APIError(400, "bad_request", "Folded header lines are not supported."))
            }
            guard let colon = line.firstIndex(of: ":"), isToken(line[..<colon]) else {
                return .bad(APIError(400, "bad_request", "Malformed header line."))
            }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if let prior = headers[name] {
                // A repeated Content-Length that disagrees is how smuggling starts.
                if name == "content-length", prior != value {
                    return .bad(APIError(400, "bad_request", "Conflicting Content-Length headers."))
                }
                if name != "content-length" { headers[name] = prior + ", " + value }
            } else {
                headers[name] = value
            }
        }
        if headers["transfer-encoding"] != nil {
            return .bad(APIError(501, "not_implemented", "Transfer-Encoding is not supported; send a Content-Length body."))
        }
        var length = 0
        if let cl = headers["content-length"] {
            guard !cl.isEmpty, cl.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), cl.count <= 9, let n = Int(cl) else {
                return .bad(APIError(400, "bad_request", "Content-Length must be a non-negative integer."))
            }
            guard n <= maxBodyBytes else {
                return .bad(APIError(413, "body_too_large", "Request body is larger than \(maxBodyBytes) bytes."))
            }
            length = n
        }
        var expect = false
        if let e = headers["expect"] {
            guard e.lowercased() == "100-continue" else {
                return .bad(APIError(417, "expectation_failed", "Only Expect: 100-continue is supported."))
            }
            expect = true
        }
        return .head(HTTPHead(method: String(parts[0]), target: String(parts[1]), contentLength: length,
                              expectContinue: expect, headers: headers), consumed: consumed)
    }

    /// Split `/path?query` and refuse a path that tries to be something else.
    static func request(from head: HTTPHead, body: Data) -> HTTPRequest {
        let t = head.target
        if let q = t.firstIndex(of: "?") {
            return HTTPRequest(method: head.method, path: String(t[..<q]), query: String(t[t.index(after: q)...]),
                               headers: head.headers, body: body)
        }
        return HTTPRequest(method: head.method, path: t, query: "", headers: head.headers, body: body)
    }

    // MARK: JSON bodies

    /// An empty body is `{}`; anything else must be one JSON object whose keys are
    /// all in `allowed`.
    static func jsonObject(_ body: Data, allowed: Set<String>) -> Result<[String: Any], APIError> {
        let trimmed = body.drop(while: { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 })
        if trimmed.isEmpty { return .success([:]) }
        guard let any = try? JSONSerialization.jsonObject(with: body),
              let obj = any as? [String: Any] else {
            return .failure(APIError(400, "bad_json", "Body must be one JSON object."))
        }
        if let extra = obj.keys.filter({ !allowed.contains($0) }).sorted().first {
            return .failure(APIError(400, "unknown_field",
                                     "Unknown field '\(extra)'. Allowed: \(allowed.sorted().joined(separator: ", "))."))
        }
        return .success(obj)
    }

    private static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    private static func string(_ o: [String: Any], _ k: String) -> Result<String?, APIError> {
        guard let v = o[k] else { return .success(nil) }
        if v is NSNull { return .success(nil) }
        guard let s = v as? String else { return .failure(APIError(400, "bad_field", "\"\(k)\" must be a string.")) }
        return .success(s)
    }

    private static func bool(_ o: [String: Any], _ k: String) -> Result<Bool?, APIError> {
        guard let v = o[k] else { return .success(nil) }
        if v is NSNull { return .success(nil) }
        guard let n = v as? NSNumber, isBool(n) else {
            return .failure(APIError(400, "bad_field", "\"\(k)\" must be true or false."))
        }
        return .success(n.boolValue)
    }

    private static func number(_ o: [String: Any], _ k: String, _ range: ClosedRange<Double>) -> Result<Double?, APIError> {
        guard let v = o[k] else { return .success(nil) }
        if v is NSNull { return .success(nil) }
        guard let n = v as? NSNumber, !isBool(n) else {
            return .failure(APIError(400, "bad_field", "\"\(k)\" must be a number."))
        }
        let d = n.doubleValue
        guard d.isFinite, range.contains(d) else {
            return .failure(APIError(400, "bad_field", "\"\(k)\" must be between \(range.lowerBound) and \(range.upperBound)."))
        }
        return .success(d)
    }

    static func parseSpeak(_ body: Data) -> Result<SpeakRequest, APIError> {
        let obj: [String: Any]
        switch jsonObject(body, allowed: ["text", "voice", "engine", "speed", "interrupt", "clean", "wait"]) {
        case .failure(let e): return .failure(e)
        case .success(let o): obj = o
        }
        var r = SpeakRequest(text: "")
        do {
            guard let text = try string(obj, "text").get() else {
                return .failure(APIError(400, "missing_field", "\"text\" is required."))
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(APIError(400, "empty_text", "\"text\" is empty."))
            }
            guard text.count <= maxSpeakChars else {
                return .failure(APIError(413, "text_too_long", "\"text\" is longer than \(maxSpeakChars) characters."))
            }
            r.text = text
            r.voice = try string(obj, "voice").get().flatMap { $0.isEmpty ? nil : $0 }
            r.engine = try string(obj, "engine").get()
            if let e = r.engine, e != "kokoro", e != "pocket" {
                return .failure(APIError(400, "bad_field", "\"engine\" must be \"kokoro\" or \"pocket\"."))
            }
            r.speed = try number(obj, "speed", speedRange).get()
            r.interrupt = try bool(obj, "interrupt").get() ?? true
            r.clean = try bool(obj, "clean").get() ?? true
            r.wait = try bool(obj, "wait").get() ?? false
        } catch {
            return .failure(error)
        }
        return .success(r)
    }

    static func parseListen(_ body: Data) -> Result<ListenRequest, APIError> {
        let obj: [String: Any]
        switch jsonObject(body, allowed: ["max_seconds", "silence_seconds", "insert"]) {
        case .failure(let e): return .failure(e)
        case .success(let o): obj = o
        }
        var r = ListenRequest()
        do {
            r.maxSeconds = try number(obj, "max_seconds", 1...maxListenSeconds).get() ?? r.maxSeconds
            r.silenceSeconds = try number(obj, "silence_seconds", silenceRange).get() ?? r.silenceSeconds
            r.insert = try bool(obj, "insert").get() ?? false
        } catch {
            return .failure(error)
        }
        return .success(r)
    }
}
