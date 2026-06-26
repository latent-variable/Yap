import Foundation
import CryptoKit

/// Downloads the Kokoro ONNX model + voices into the models dir with progress.
/// The URLSession delivers its delegate callbacks on the main queue (see init),
/// so `index` and the @Published state are only ever touched on main — no race
/// between `start()`/`next()` and the download delegate methods.
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var downloading = false
    @Published var done = false
    @Published var error: String?

    private static let base = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
    // SHA-256 pinned per file: a third-party release is a supply-chain surface,
    // and onnxruntime executes model operators, so a swapped asset is native-code
    // input. Verified after download; mismatch deletes the file and errors out.
    // Bump these when the model version changes.
    private let files: [(name: String, url: String, sha256: String)] = [
        ("kokoro-v1.0.onnx", "\(ModelDownloader.base)/kokoro-v1.0.onnx",
         "7d5df8ecf7d4b1878015a32686053fd0eebe2bc377234608764cc0ef3636a6c5"),
        ("voices-v1.0.bin", "\(ModelDownloader.base)/voices-v1.0.bin",
         "bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d"),
    ]
    private var index = 0
    private let dir: URL
    private var session: URLSession!

    init(modelsDir: URL) {
        self.dir = modelsDir
        super.init()
        // delegateQueue = .main: keep delegate callbacks (which mutate `index`)
        // on the same thread as start()/next(), eliminating the data race.
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    private func ui(_ block: @escaping () -> Void) { DispatchQueue.main.async(execute: block) }

    func start() {
        // All state (downloading/index/@Published) is main-thread-only — the
        // delegate queue is .main and verify() hops back to main. Run start on
        // main too (serialized) so a background caller can't race the guard or
        // index reset against an in-flight delegate/verify callback.
        ui {
            // Re-entrancy guard: a second tap while a download is live would
            // reset index under an in-flight task and spawn a concurrent one,
            // racing on index. Serialized on main, so the first run flips
            // downloading=true before the second sees the guard.
            guard !self.downloading else { return }
            try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
            // Reset index: after a prior completed run index == files.count.
            // Without this a delete-then-redownload would hit the
            // `index < files.count` guard immediately, report "Done", fetch nothing.
            self.index = 0
            self.downloading = true
            self.error = nil
            self.done = false
            self.progress = 0
            self.next()
        }
    }

    /// Streamed SHA-256 so a 325 MB model isn't read fully into memory.
    /// A mid-file read error returns nil (not a partial hash) so the caller
    /// treats a hashing failure as "unverified", never as a silent mismatch.
    private func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Hash a 325 MB model off the main thread (the delegate queue is .main, and
    /// next() runs on main), then deliver the verdict back on main so `index`
    /// and @Published state stay single-threaded. Keeps the UI responsive during
    /// the ~1.5s-per-file verify instead of freezing it.
    private func verify(_ dest: URL, against expected: String, then done: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }   // gone: drop it, don't fire the callback
            let ok = self.sha256(of: dest) == expected
            DispatchQueue.main.async { done(ok) }
        }
    }

    private func next() {
        guard index < files.count else {
            ui { self.downloading = false; self.done = true; self.statusText = "Done"; self.progress = 1 }
            return
        }
        let f = files[index]
        let dest = dir.appending(path: f.name)
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if FileManager.default.fileExists(atPath: dest.path), size > 0 {
            // Verify pre-existing files too — the download-time gate alone leaves
            // a bypass: a file from old (pre-pin) code, a stalled partial, or one
            // tampered after a prior good download would otherwise be skipped and
            // loaded unchecked. Match → skip; mismatch/unreadable → delete and
            // fall through to re-download. Hash off-main so the UI doesn't freeze.
            ui { self.statusText = "Verifying \(f.name)…" }
            verify(dest, against: f.sha256) { [weak self] ok in
                guard let self else { return }
                if ok { self.index += 1; self.next(); return }
                try? FileManager.default.removeItem(at: dest)
                self.startDownload(f)
            }
            return
        }
        startDownload(f)
    }

    /// Kick off the URLSession download for one file (already verified absent or
    /// rejected). On main per the delegate-queue contract.
    private func startDownload(_ f: (name: String, url: String, sha256: String)) {
        ui { self.statusText = "Downloading \(f.name)…" }
        session.downloadTask(with: URL(string: f.url)!).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten written: Int64,
                    totalBytesExpectedToWrite total: Int64) {
        guard total > 0 else { return }
        let span = 1.0 / Double(files.count)
        let p = (Double(index) * span) + (Double(written) / Double(total)) * span
        ui { self.progress = p }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Ignore a callback that doesn't belong to the current run: a stale or
        // out-of-order task (e.g. one finishing after the index was reset) must
        // not write the wrong file or mis-advance index.
        guard downloading, index < files.count else { return }
        let f = files[index]
        guard downloadTask.originalRequest?.url?.absoluteString == f.url else { return }
        let dest = dir.appending(path: f.name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            // Surface the failure instead of swallowing it — a missed move
            // leaves an incomplete model that silently fails to load later.
            // Pull the message out first: the closure escapes across the actor
            // hop, and `error` here shadows the @Published `error` property.
            let message = error.localizedDescription
            ui { self.error = "Failed to save \(f.name): \(message)"; self.downloading = false }
            return
        }
        // Integrity gate: reject (and delete) anything that doesn't match the
        // pinned hash before it can be loaded into onnxruntime. Hash off-main.
        ui { self.statusText = "Verifying \(f.name)…" }
        verify(dest, against: f.sha256) { [weak self] ok in
            guard let self else { return }
            guard ok else {
                try? FileManager.default.removeItem(at: dest)
                self.ui {
                    self.error = "Checksum mismatch for \(f.name) — file rejected, not installed. Try again."
                    self.downloading = false
                }
                return
            }
            self.index += 1
            self.next()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError err: Error?) {
        guard let err else { return }
        ui { self.error = err.localizedDescription; self.downloading = false }
    }
}
