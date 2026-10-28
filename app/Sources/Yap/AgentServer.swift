import Foundation
import Darwin

/// HTTP/1.1 over a Unix-domain socket, for the agent API (docs/AGENT-API.md).
///
/// Why a Unix socket and not a loopback port: a web page can reach any port on
/// 127.0.0.1 (a plain form POST is enough), but it cannot open a file. And
/// another macOS user cannot connect to a 0600 socket. So the socket's file
/// permissions are the whole access control; there is no token to leak or rotate.
/// What it does NOT stop is another program running as the same user. That is why
/// listening is a separate opt-in (`Prefs.agentListenEnabled`).
///
/// Plain BSD sockets, no dependency: Network.framework cannot set a listening
/// socket's file mode, and the mode is the point. One request per connection,
/// `Connection: close`. Parsing is `AgentAPI.parseHead` (pure, tested); this file
/// is only I/O and lifetimes.
final class AgentServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    enum StartError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case insecureParent(String)
        case occupied(String)
        case alreadyServed(String)
        case sys(String, Int32)

        var description: String {
            switch self {
            case .pathTooLong(let p): return "socket path is longer than a Unix socket allows: \(p)"
            case .insecureParent(let p): return "\(p) is writable by other users; refusing to put the socket there"
            case .occupied(let p): return "\(p) exists and is not a socket of ours; leaving it alone"
            case .alreadyServed(let p): return "another Yap is already answering on \(p)"
            case .sys(let what, let e): return "\(what) failed: \(String(cString: strerror(e)))"
            }
        }
    }

    static let maxConnections = 16
    /// How long a client gets to send a whole request. A stalled one frees its slot.
    static let readTimeout: TimeInterval = 10

    let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "com.yap.agentapi.accept")
    private let connQueue = DispatchQueue(label: "com.yap.agentapi.conn", attributes: .concurrent)
    private let lock = NSLock()
    private var open = 0
    private var inFlight: [UUID: Task<HTTPResponse, Never>] = [:]
    private var boundInode: (dev: dev_t, ino: ino_t)?

    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    // MARK: start / stop

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard listenFD < 0 else { return }
        // A client can hang up before we answer (that is how a cancelled `yap
        // listen` looks), and by then SO_NOSIGPIPE can no longer be set on its
        // socket: setsockopt fails once the peer is gone, and the write that
        // follows would raise SIGPIPE and kill the whole menu-bar app. Measured in
        // --selftest. The write returns EPIPE instead, which writeAll handles.
        signal(SIGPIPE, SIG_IGN)
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw StartError.pathTooLong(path)
        }
        try Self.prepareParent(of: path)
        try Self.clearStale(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.sys("socket", errno) }
        func fail(_ what: String) -> StartError { let e = errno; close(fd); return .sys(what, e) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(path.utf8) + [0]
            raw.copyBytes(from: bytes)
        }
        // Created 0600 from the first instant (umask), then chmod'd anyway: the
        // mode is the access control, so it is set twice rather than assumed.
        let old = umask(0o177)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        guard rc == 0 else { throw fail("bind") }
        guard chmod(path, 0o600) == 0 else { unlink(path); throw fail("chmod") }
        var st = stat()
        if stat(path, &st) == 0 { boundInode = (st.st_dev, st.st_ino) }
        guard listen(fd, 16) == 0 else { unlink(path); throw fail("listen") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        src.setEventHandler { [weak self] in self?.acceptPending(fd) }
        src.setCancelHandler { close(fd) }
        listenFD = fd
        source = src
        src.resume()
    }

    /// Stop accepting, cancel anything in flight (a waiting `/speak`, a `/listen`)
    /// and remove the socket file. Returns once the socket is really gone, so a
    /// toggle off and on never finds its own stale file.
    func stop() {
        lock.lock()
        guard let src = source else { lock.unlock(); return }
        source = nil
        listenFD = -1
        let tasks = Array(inFlight.values)
        let inode = boundInode
        boundInode = nil
        lock.unlock()
        src.cancel()
        // The cancel handler closes the descriptor on the accept queue; wait for it.
        acceptQueue.sync {}
        for t in tasks { t.cancel() }
        // Only our own file: if something replaced it, it is not ours to remove.
        var st = stat()
        if let inode, stat(path, &st) == 0, st.st_dev == inode.dev, st.st_ino == inode.ino { unlink(path) }
    }

    // MARK: socket hygiene

    /// The directory holding the socket must not let another user swap the file.
    /// One we own, under Application Support, is tightened rather than refused: a
    /// group-writable `Yap` folder is a quirk of how it was made, not an attack.
    static func prepareParent(of path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        var st = stat()
        if stat(dir, &st) != 0 {
            guard errno == ENOENT else { throw StartError.sys("stat \(dir)", errno) }
            do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700]) }
            catch { throw StartError.insecureParent(dir) }
            guard stat(dir, &st) == 0 else { throw StartError.sys("stat \(dir)", errno) }
        }
        guard st.st_uid == getuid() else { throw StartError.insecureParent(dir) }
        if st.st_mode & 0o022 != 0 {
            guard chmod(dir, st.st_mode & 0o7755) == 0 else { throw StartError.insecureParent(dir) }
            guard stat(dir, &st) == 0, st.st_mode & 0o022 == 0 else { throw StartError.insecureParent(dir) }
        }
    }

    /// Remove a leftover socket from a crash, but only after proving it is dead:
    /// it must be a socket we own, and nothing may answer on it. A live one means
    /// a second Yap, which must not steal the first one's path.
    static func clearStale(_ path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        guard st.st_mode & S_IFMT == S_IFSOCK, st.st_uid == getuid() else { throw StartError.occupied(path) }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw StartError.sys("socket", errno) }
        defer { close(probe) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc == 0 { throw StartError.alreadyServed(path) }
        // Only a refused connection (or a vanished file) proves it dead. Any other
        // error is "cannot tell", and the answer to that is to leave it alone.
        guard errno == ECONNREFUSED || errno == ENOENT else { throw StartError.sys("probe \(path)", errno) }
        unlink(path)
    }

    // MARK: connections

    private func acceptPending(_ listener: Int32) {
        while true {
            let c = accept(listener, nil, nil)
            if c < 0 { return }   // EAGAIN: drained
            serve(c)
        }
    }

    private func serve(_ fd: Int32) {
        // A same-user process is the threat model's floor, but the check is free.
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { close(fd); return }
        lock.lock()
        let full = open >= Self.maxConnections
        if !full { open += 1 }
        lock.unlock()
        if full {
            // Best effort: a client that is not reading does not hold the accept queue.
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            Self.writeAll(fd, HTTPResponse.error(APIError(503, "busy", "Too many open connections.")).serialized())
            close(fd)
            return
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        connQueue.async { self.handle(fd) }
    }

    /// Closes the descriptor once BOTH the response is written and the
    /// disconnect watcher is cancelled; closing earlier would let the watcher
    /// poll a descriptor number the kernel may already have reused.
    private final class Conn: @unchecked Sendable {
        let fd: Int32
        private let lock = NSLock()
        private var pending: Int
        init(fd: Int32, holders: Int) { self.fd = fd; self.pending = holders }
        func release() {
            lock.lock(); pending -= 1; let done = pending == 0; lock.unlock()
            if done { close(fd) }
        }
    }

    private func forget(_ id: UUID) {
        lock.lock(); inFlight[id] = nil; lock.unlock()
    }

    private func finish(_ fd: Int32) {
        close(fd)
        lock.lock(); open -= 1; lock.unlock()
    }

    private func handle(_ fd: Int32) {
        switch Self.readRequest(fd) {
        case .closed:
            finish(fd)
        case .refused(let e):
            Self.writeAll(fd, HTTPResponse.error(e).serialized())
            finish(fd)
        case .request(let req):
            let conn = Conn(fd: fd, holders: 2)
            let id = UUID()
            let handler = self.handler
            let task = Task { await handler(req) }
            lock.lock(); inFlight[id] = task; lock.unlock()

            // The request is fully read, so anything readable now is the client
            // closing (or half-closing). A pending `wait` or `listen` is cancelled
            // then: a caller that went away must not leave the mic open or the
            // voice talking for nobody.
            let watcher = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
            watcher.setEventHandler {
                var b: UInt8 = 0
                let n = recv(fd, &b, 1, MSG_PEEK | MSG_DONTWAIT)
                if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) { task.cancel() }
                watcher.cancel()   // stray bytes are ignored; either way stop watching
            }
            watcher.setCancelHandler { conn.release() }
            watcher.resume()

            Task {
                let response = await task.value
                self.forget(id)
                self.connQueue.async {
                    Self.writeAll(fd, response.serialized())
                    watcher.cancel()
                    conn.release()
                    self.lock.lock(); self.open -= 1; self.lock.unlock()
                }
            }
        }
    }

    // MARK: blocking I/O (on connQueue, never the cooperative pool)

    enum ReadOutcome {
        case request(HTTPRequest)
        case refused(APIError)
        case closed
    }

    private static func readSome(_ fd: Int32, into buf: inout [UInt8], until deadline: Date) -> Bool {
        let ms = Int32(max(0, min(deadline.timeIntervalSinceNow, 10)) * 1000)
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let r = poll(&p, 1, ms)
        if r <= 0 { return false }
        var chunk = [UInt8](repeating: 0, count: 16384)
        let n = recv(fd, &chunk, chunk.count, 0)
        if n <= 0 { return false }
        buf.append(contentsOf: chunk[0..<n])
        return true
    }

    static func readRequest(_ fd: Int32) -> ReadOutcome {
        let deadline = Date().addingTimeInterval(readTimeout)
        var buf: [UInt8] = []
        var head: HTTPHead?
        var consumed = 0
        while head == nil {
            switch AgentAPI.parseHead(buf) {
            case .bad(let e): return .refused(e)
            case .head(let h, let c): head = h; consumed = c
            case .incomplete:
                if !readSome(fd, into: &buf, until: deadline) {
                    return buf.isEmpty ? .closed : .refused(APIError(408, "timeout", "Request not completed in time."))
                }
            }
        }
        guard let h = head else { return .closed }
        if h.expectContinue && h.contentLength > 0 { writeAll(fd, Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) }
        while buf.count - consumed < h.contentLength {
            if !readSome(fd, into: &buf, until: deadline) {
                return .refused(APIError(408, "timeout", "Request body not completed in time."))
            }
        }
        let body = Data(buf[consumed..<(consumed + h.contentLength)])
        return .request(AgentAPI.request(from: h, body: body))
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            while sent < data.count {
                let n = send(fd, raw.baseAddress! + sent, data.count - sent, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                sent += n
            }
            return true
        }
    }
}
