import Foundation

/// Downloads the Kokoro ONNX model + voices into the models dir with progress.
/// Published properties are mutated on the main queue for SwiftUI.
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var downloading = false
    @Published var done = false
    @Published var error: String?

    private static let base = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
    private let files: [(name: String, url: String)] = [
        ("kokoro-v1.0.onnx", "\(ModelDownloader.base)/kokoro-v1.0.onnx"),
        ("voices-v1.0.bin", "\(ModelDownloader.base)/voices-v1.0.bin"),
    ]
    private var index = 0
    private let dir: URL
    private var session: URLSession!

    init(modelsDir: URL) {
        self.dir = modelsDir
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    private func ui(_ block: @escaping () -> Void) { DispatchQueue.main.async(execute: block) }

    func start() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ui { self.downloading = true; self.error = nil; self.done = false }
        next()
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
        let dest = dir.appending(path: files[index].name)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: location, to: dest)
        index += 1
        next()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError err: Error?) {
        guard let err else { return }
        ui { self.error = err.localizedDescription; self.downloading = false }
    }
}
