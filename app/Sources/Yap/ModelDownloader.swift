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
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Reset index: after a prior completed run index == files.count. Without
        // this, a delete-then-redownload would hit the `index < files.count`
        // guard immediately, report "Done", and fetch nothing.
        index = 0
        ui { self.downloading = true; self.error = nil; self.done = false; self.progress = 0 }
        next()
    }

    /// Streamed SHA-256 so a 325 MB model isn't read fully into memory.
    private func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
            index += 1; next(); return
        }
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
        let f = files[index]
        let dest = dir.appending(path: f.name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            // Surface the failure instead of swallowing it — a missed move
            // leaves an incomplete model that silently fails to load later.
            ui { self.error = "Failed to save \(f.name): \(error.localizedDescription)"; self.downloading = false }
            return
        }
        // Integrity gate: reject (and delete) anything that doesn't match the
        // pinned hash before it can be loaded into onnxruntime.
        guard sha256(of: dest) == f.sha256 else {
            try? FileManager.default.removeItem(at: dest)
            ui {
                self.error = "Checksum mismatch for \(f.name) — file rejected, not installed. Try again."
                self.downloading = false
            }
            return
        }
        index += 1
        next()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError err: Error?) {
        guard let err else { return }
        ui { self.error = err.localizedDescription; self.downloading = false }
    }
}
