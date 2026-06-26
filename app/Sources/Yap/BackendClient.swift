import Foundation

struct VoiceInfo: Identifiable, Decodable, Hashable {
    let id: String
    let lang: String
    let lang_label: String
    let gender: String
}

struct HealthInfo: Decodable {
    let status: String
    let model_loaded: Bool
    let files_present: Bool
    let models_dir: String
    let error: String?
    let sample_rate: Int
    let provider_mode: String?
    let active_providers: [String]?
    let available_providers: [String]?
}

/// Thin HTTP client for the local Kokoro backend.
struct BackendClient {
    var base = URL(string: "http://127.0.0.1:8766")!
    // One reused session — a computed property would spin up (and leak) a fresh
    // URLSession, with its own connection pool + delegate thread, on every call.
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 600
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// Build a request already carrying the shared-secret Bearer token. Every
    /// call to the backend goes through this — the sidecar rejects anything
    /// without the token (so a website's cross-origin POST can't drive it).
    private func authed(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        if let t = BackendAuth.token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        return req
    }

    func health() async -> HealthInfo? {
        var req = authed(base.appending(path: "health"))
        req.timeoutInterval = 2
        guard let (data, _) = try? await session.data(for: req) else { return nil }
        return try? JSONDecoder().decode(HealthInfo.self, from: data)
    }

    /// Prove a backend we did NOT spawn is genuinely ours before trusting it
    /// with captured text: send a random nonce to /verify and confirm it
    /// returns HMAC(token, nonce). An impostor that can't read the 0600 token
    /// file can't produce a matching proof. /verify is auth-exempt, so this
    /// probe never leaks the token to an unverified listener.
    func verifyAuthentic() async -> Bool {
        let nonce = Data((0..<24).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        // No local token → can't verify. Fail closed: don't trust a backend we
        // can't authenticate.
        guard let expected = BackendAuth.proof(nonce: nonce) else { return false }
        var url = base.appending(path: "verify")
        url.append(queryItems: [URLQueryItem(name: "nonce", value: nonce)])
        // Deliberately UNauthenticated: we're probing a backend we haven't
        // trusted yet, so we must not hand it the token. /verify is auth-exempt
        // and reveals only an HMAC over our nonce, never the token itself.
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        struct Resp: Decodable { let proof: String }
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let r = try? JSONDecoder().decode(Resp.self, from: data) else { return false }
        // Constant-time compare: don't short-circuit on the first mismatching
        // hex digit, so the proof check can't leak per-byte timing (server side
        // already uses hmac.compare_digest).
        let a = Array(r.proof.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    func voices(engine: String = "kokoro") async -> [VoiceInfo] {
        struct Resp: Decodable { let voices: [VoiceInfo] }
        var url = base.appending(path: "voices")
        url.append(queryItems: [URLQueryItem(name: "engine", value: engine)])
        guard let (data, _) = try? await session.data(for: authed(url)),
              let r = try? JSONDecoder().decode(Resp.self, from: data) else { return [] }
        return r.voices
    }

    struct EngineInfo: Decodable { let installed: Bool; let loaded: Bool }
    func engines() async -> (kokoro: EngineInfo?, chatterbox: EngineInfo?) {
        struct Resp: Decodable { let kokoro: EngineInfo; let chatterbox: EngineInfo }
        let req = authed(base.appending(path: "engines"))
        guard let (data, _) = try? await session.data(for: req),
              let r = try? JSONDecoder().decode(Resp.self, from: data) else { return (nil, nil) }
        return (r.kokoro, r.chatterbox)
    }

    /// Stream the HD-deps install, line by line, for a progress view.
    func installChatterbox(onLine: @escaping (String) -> Void) async throws {
        var req = authed(base.appending(path: "engines/chatterbox/install"))
        req.httpMethod = "POST"
        req.timeoutInterval = 1800
        let (bytes, _) = try await session.bytes(for: req)
        for try await line in bytes.lines { onLine(line) }
    }

    /// Pre-load the HD model + a voice so the first read isn't a cold ~8s wait.
    func warmChatterbox(voice: String) async {
        var url = base.appending(path: "engines/chatterbox/warm")
        url.append(queryItems: [URLQueryItem(name: "voice", value: voice)])
        var req = authed(url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        _ = try? await session.data(for: req)
    }

    /// Download the curated starter reference voices.
    func fetchStarterVoices(onLine: @escaping (String) -> Void) async throws {
        var req = authed(base.appending(path: "voices/hd/starters"))
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        let (bytes, _) = try await session.bytes(for: req)
        for try await line in bytes.lines { onLine(line) }
    }

    private func synthRequest(_ text: String, voice: String, speed: Double,
                              pauseScale: Double, engine: String, wav: Bool) -> URLRequest {
        var url = base.appending(path: "synthesize")
        if wav { url.append(queryItems: [URLQueryItem(name: "format", value: "wav")]) }
        var req = authed(url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["text": text, "voice": voice, "speed": speed,
                                   "pause_scale": pauseScale, "engine": engine]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Stream raw int16 PCM. `onChunk` receives bytes as they arrive.
    func streamPCM(text: String, voice: String, speed: Double, pauseScale: Double = 1.0,
                   engine: String = "kokoro", onChunk: @escaping (Data) -> Void) async throws {
        let req = synthRequest(text, voice: voice, speed: speed, pauseScale: pauseScale,
                               engine: engine, wav: false)
        let (bytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "Yap", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "backend HTTP \(http.statusCode)"])
        }
        // Collect into a contiguous [UInt8] (amortized O(1) append, no Data
        // copy-on-write churn) and flush ~0.2s chunks. AsyncBytes already
        // buffers at the transport layer, so this doesn't suspend per byte.
        var buf = [UInt8]()
        buf.reserveCapacity(16384)
        for try await b in bytes {
            buf.append(b)
            if buf.count >= 9600 { // ~0.2s of audio
                onChunk(Data(buf))
                buf.removeAll(keepingCapacity: true)
            }
        }
        if !buf.isEmpty { onChunk(Data(buf)) }
    }

    /// Fetch a complete WAV (for export).
    func wav(text: String, voice: String, speed: Double, pauseScale: Double = 1.0,
             engine: String = "kokoro") async throws -> Data {
        let req = synthRequest(text, voice: voice, speed: speed, pauseScale: pauseScale,
                               engine: engine, wav: true)
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "Yap", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "backend HTTP \(http.statusCode)"])
        }
        return data
    }
}
