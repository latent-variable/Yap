import Foundation
import CryptoKit
import Darwin

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

    /// The shared token, or nil if the file couldn't be read/created.
    /// Both the client and backend fail closed when the token is unavailable.
    static var token: String? { cached }

    private static func loadOrCreate() -> String? {
        let url = tokenFileURL
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            Log.write("auth: could not create token directory: \(error.localizedDescription)")
            return nil
        }
        // Both the directory and file are private and owned by this user.
        // Do not follow an injected symlink, even if its target has mode 0600.
        var dirInfo = stat()
        guard lstat(parent.path, &dirInfo) == 0,
              (dirInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              dirInfo.st_uid == geteuid() else {
            Log.write("auth: token directory must be a real directory owned by the user")
            return nil
        }
        do {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        } catch {
            Log.write("auth: could not secure token directory: \(error.localizedDescription)")
            return nil
        }

        func readExisting() -> String? {
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  info.st_uid == geteuid(), (info.st_mode & 0o077) == 0 else {
                Log.write("auth: token file is not a private regular file owned by this user")
                return nil
            }
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { return nil }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            guard let data = try? file.readToEnd(),
                  let token = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else { return nil }
            return token
        }

        var info = stat()
        if lstat(url.path, &info) == 0 { return readExisting() }
        guard errno == ENOENT else {
            Log.write("auth: could not inspect token file")
            return nil
        }
        // Generate a 32-byte random token, encoded as base64url without padding.
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            return nil
        }
        let token = Data(random).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        // O_EXCL ensures that an intervening file or symlink cannot be
        // truncated. The Python side also creates its token with O_EXCL.
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else {
            if errno == EEXIST { return readExisting() }  // competing Yap instance
            Log.write("auth: could not create token file")
            return nil
        }
        let bytes = [UInt8](token.utf8)
        let complete = bytes.withUnsafeBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, base.advanced(by: offset), buf.count - offset)
                if n > 0 { offset += n; continue }
                if n == -1 && errno == EINTR { continue }
                return false
            }
            return true
        }
        _ = close(fd)
        if !complete {
            try? fm.removeItem(at: url)
            Log.write("auth: token creation was incomplete")
            return nil
        }
        return token
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
