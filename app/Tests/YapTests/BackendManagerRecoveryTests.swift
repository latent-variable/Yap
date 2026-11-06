import Foundation
import XCTest

final class BackendManagerRecoveryTests: XCTestCase {
    func testDeadOwnedBackendIsRelaunchedBeforeNextRead() throws {
        let executable = try yapExecutable()
        let port = Int.random(in: 20_000...55_000)
        let child = Process()
        // Drain to a file instead of an unread pipe: verbose CFNetwork errors
        // can fill the pipe and block a child before its termination handler runs.
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yap-recovery-output-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: logURL)
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: logURL)
        }
        let finished = DispatchSemaphore(value: 0)

        child.executableURL = executable
        child.arguments = ["--backendrecoverytest", String(port)]
        child.standardOutput = output
        child.standardError = output
        child.terminationHandler = { _ in finished.signal() }
        try child.run()

        guard finished.wait(timeout: .now() + 30) == .success else {
            child.terminate()
            _ = finished.wait(timeout: .now() + 3)
            let probeLog = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "(no child output)"
            let backendLogURL = FileManager.default.temporaryDirectory.appendingPathComponent("yap_backend.log")
            let backendLog = (try? String(contentsOf: backendLogURL, encoding: .utf8)) ?? "(no backend log)"
            XCTFail("backend recovery probe did not finish within 30 seconds\nPROBE:\n\(probeLog)\nBACKEND:\n\(backendLog)")
            return
        }

        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "(no child output)"
        XCTAssertEqual(child.terminationStatus, 0, log)
        XCTAssertTrue(log.contains("BACKEND RECOVERY OK"), log)
    }

    private func yapExecutable() throws -> URL {
        let fm = FileManager.default
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildRoot = packageRoot.appending(path: ".build")
        let platforms = (try? fm.contentsOfDirectory(atPath: buildRoot.path)) ?? []
        for platform in platforms + [""] {
            let base = platform.isEmpty ? buildRoot : buildRoot.appending(path: platform)
            for configuration in ["debug", "release"] {
                let candidate = base.appending(path: configuration).appending(path: "Yap")
                if fm.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        throw NSError(domain: "YapTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not locate the built Yap executable"])
    }
}
