import Darwin
import Foundation
import XCTest
@testable import Yap

final class BackendStartupFailureTests: XCTestCase {
    @MainActor
    func testImmediateOwnedBackendExitFinishesStartupPromptly() async throws {
        // A missing token must fail this test, not pass by refusing to launch.
        _ = try XCTUnwrap(BackendAuth.token, "The startup fixture needs real local authentication")
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory
            .appendingPathComponent("yap-startup-failure-\(UUID().uuidString)")
        let scripts = fixture.appendingPathComponent("scripts")
        try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let launcher = scripts.appendingPathComponent("run_backend.sh")
        try Data("#!/bin/bash\nexit 17\n".utf8).write(to: launcher)

        let manager = BackendManager(port: try unusedLoopbackPort(), repoRootOverride: fixture)
        let finished = expectation(description: "An exited owned backend ends startup promptly")
        let startup = Task { @MainActor in
            await manager.start()
            finished.fulfill()
        }
        defer {
            startup.cancel()
            manager.stop()
        }

        // Regression: the termination handler can clear the Process handle
        // before waitForHealth observes it. A nil handle used to leave startup
        // polling for about 60 seconds, despite the owned child already exiting.
        await fulfillment(of: [finished], timeout: 10)
        startup.cancel()
        await manager.stopAndWait()
        XCTAssertFalse(manager.ready, "An exited fixture must never become ready")
        XCTAssertEqual(manager.lastError, "Backend exited unexpectedly.")
    }

    private func unusedLoopbackPort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
