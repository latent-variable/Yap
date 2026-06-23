import Foundation

/// Tiny file logger so capture/runtime issues are inspectable.
/// Writes to ~/Library/Application Support/Parley/parley.log and stderr.
enum Log {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Parley")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "parley.log")
    }()

    private static let queue = DispatchQueue(label: "parley.log")
    private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    static func write(_ msg: String) {
        let line = "\(fmt.string(from: Date())) \(msg)\n"
        let data = Data(line.utf8)
        try? FileHandle.standardError.write(contentsOf: data)
        queue.async {
            // Throwing FileHandle APIs (seek/write/close were deprecated on
            // macOS 10.15+); deployment target is macOS 14.
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
