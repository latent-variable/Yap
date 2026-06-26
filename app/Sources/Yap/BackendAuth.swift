import Foundation
import CryptoKit

/// Shared secret between the app and its local backend (server.py). The sidecar
/// binds 127.0.0.1, reachable by every local process and by `fetch()` from any
/// website. The token closes two holes: a website CSRFing a mutating POST, and
/// the app reusing an impostor that squatted port 8766 and then receiving
/// captured selected text. Both sides read-or-create the same 0600 file, so a
/// cross-user process can't read it and can't forge the token. Same-user
/// attackers are out of scope (they already own the user's data + grants).
enum BackendAuth {
    /// Canonical token path. The backend defaults to this same location, and we
    /// also pass it explicitly via `YAP_AUTH_TOKEN_FILE` when spawning.
    static var tokenFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Yap/auth-token")
    }

    /// Cached so repeated requests don't hit disk; the file is stable per machine.
    private static let cached: String? = loadOrCreate()

    /// The shared token, or nil if the file couldn't be read/created. nil means
    /// requests go out without a Bearer header (the backend fails open on auth
    /// in that case too), so TTS still works rather than bricking.
    static var token: String? { cached }

    private static func loadOrCreate() -> String? {
        let url = tokenFileURL
        let fm = FileManager.default
        if let data = try? Data(contentsOf: url),
           let tok = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tok.isEmpty {
            return tok
        }
        // Generate 32 random bytes, base64url (no padding) — matches the
        // backend's secrets.token_urlsafe shape closely enough; only equality
        // across the two readers of the file matters.
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let tok = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Write with owner-only perms (0600) from the start — don't create
            // world-readable then chmod (a race window where another process
            // could read it).
            try tok.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAt: url)
        } catch {
            Log.write("auth: could not create token file: \(error.localizedDescription)")
            return nil
        }
        return tok
    }

    /// HMAC-SHA256(token, nonce) as lowercase hex — must match the backend's
    /// /verify computation byte-for-byte.
    static func proof(nonce: String) -> String? {
        guard let token else { return nil }
        let key = SymmetricKey(data: Data(token.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

extension FileManager {
    fileprivate func setAttributes(_ attrs: [FileAttributeKey: Any], ofItemAt url: URL) throws {
        try setAttributes(attrs, ofItemAtPath: url.path)
    }
}
