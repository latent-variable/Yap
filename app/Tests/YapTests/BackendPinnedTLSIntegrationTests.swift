import Darwin
import Foundation
import XCTest
@testable import Yap

/// Exercises the production BackendClient/URLSession delegate, not a replacement
/// trust evaluator. A child XCTest process gives BackendAuth a private home
/// before its process-lifetime token and Foundation paths can be initialized.
final class BackendPinnedTLSIntegrationTests: XCTestCase {
    private static let childFlag = "YAP_TLS_INTEGRATION_CHILD"
    private static let homeKey = "YAP_TLS_INTEGRATION_HOME"

    func testPinnedTLSRuntimeBoundary() async throws {
        if ProcessInfo.processInfo.environment[Self.childFlag] == "1" {
            try await checkRuntimeBoundary()
        } else {
            try runIsolatedChild()
        }
    }

    private func runIsolatedChild() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "yap-tls-xctest-\(UUID().uuidString)")
        let home = root.appending(path: "home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let bundle = Bundle(for: Self.self).bundleURL
        guard bundle.pathExtension == "xctest" else {
            throw failure("Could not locate the XCTest bundle: \(bundle.path)")
        }
        var environment = ProcessInfo.processInfo.environment
        environment[Self.childFlag] = "1"
        environment[Self.homeKey] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        let child = try LoggedProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["xctest", "-XCTest",
                        "YapTests.BackendPinnedTLSIntegrationTests/testPinnedTLSRuntimeBoundary",
                        bundle.path],
            environment: environment, log: root.appending(path: "xctest.log")
        )
        defer { child.stop() }
        guard child.finished.wait(timeout: .now() + 90) == .success else {
            child.stop()
            throw failure("Pinned TLS child exceeded 90 seconds\n\(child.output)")
        }
        let output = child.output
        print(output)
        XCTAssertEqual(child.process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("PINNED TLS RUNTIME PASS"), output)
    }

    private func checkRuntimeBoundary() async throws {
        let fm = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let home = try XCTUnwrap(environment[Self.homeKey])
        let tokenURL = BackendAuth.tokenFileURL
        // Fail before touching auth state if a platform ever stops respecting
        // CFFIXED_USER_HOME. Never overwrite a developer's own identity.
        let canonicalHome = URL(fileURLWithPath: home)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalToken = tokenURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard canonicalToken.hasPrefix(canonicalHome + "/") else {
            throw failure("BackendAuth did not resolve inside the isolated test home")
        }
        _ = try XCTUnwrap(BackendAuth.token, "The isolated test token must be available")
        let fixturesRoot = URL(fileURLWithPath: home).appending(path: "tls-fixtures")
        try fm.createDirectory(at: fixturesRoot, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])

        // A single BackendClient/session carries overlapping requests. The
        // server closes every HTTP connection, so each request needs fresh TLS.
        do {
            let fixture = try await Fixture(mode: "trusted", root: fixturesRoot, token: tokenURL)
            defer { fixture.stop() }
            XCTAssertNotNil(BackendAuth.pinnedTLSCertificateDER)
            let client = fixture.client()
            let requestCount = 12
            let completed = try await withThrowingTaskGroup(of: Data.self) { group in
                for index in 0..<requestCount {
                    group.addTask {
                        try await client.wav(text: "YAP-TLS-PRIVATE-CANARY:\(index)",
                                             voice: "af_heart", speed: 1)
                    }
                }
                var count = 0
                for try await data in group {
                    XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
                    count += 1
                }
                return count
            }
            let receipt = try fixture.snapshot()
            XCTAssertEqual(completed, requestCount)
            XCTAssertEqual(receipt.verifyRequests, requestCount)
            XCTAssertEqual(receipt.protectedRequests, requestCount)
            XCTAssertEqual(receipt.authorizationHeaders, requestCount)
            XCTAssertEqual(receipt.validAuthorizationHeaders, requestCount)
            XCTAssertEqual(receipt.sensitiveBodies, requestCount)
            XCTAssertGreaterThanOrEqual(receipt.trustedConnections, requestCount * 2)
            XCTAssertGreaterThanOrEqual(receipt.maxConcurrentProtected, 2)
            XCTAssertEqual(receipt.impostorHttpRequests, 0)
            print("PASS: production URLSession completed \(completed) pinned requests; " +
                  "\(receipt.trustedConnections) TLS connections; " +
                  "\(receipt.maxConcurrentProtected) overlapping protected requests")
        }

        // A self-signed certificate with the same IP/SAN but a different key
        // must be refused before even /verify, bearer headers, or text arrive.
        do {
            let fixture = try await Fixture(mode: "wrong", root: fixturesRoot, token: tokenURL)
            defer { fixture.stop() }
            let client = fixture.client()
            let verified = await client.verifyAuthentic()
            XCTAssertFalse(verified)
            do {
                _ = try await client.wav(text: "YAP-TLS-PRIVATE-CANARY:wrong-certificate",
                                         voice: "af_heart", speed: 1)
                XCTFail("An unpinned TLS listener must not receive speech")
            } catch { /* Expected trust/authentication failure. */ }
            let receipt = try fixture.snapshot()
            XCTAssertTrue(receipt.certificatesDiffer)
            XCTAssertGreaterThanOrEqual(receipt.impostorConnections, 1)
            XCTAssertEqual(receipt.verifyRequests, 0)
            assertNoLeak(receipt)
            print("PASS: different certificate rejected before any HTTP, bearer token, or text")
        }

        // The fixture returns a genuine HMAC but first closes its listener and
        // binds an impostor to the same port. Only the original accepted TLS
        // connection remains long enough to finish /verify.
        do {
            let fixture = try await Fixture(mode: "replace", root: fixturesRoot, token: tokenURL)
            defer { fixture.stop() }
            let client = fixture.client()
            do {
                _ = try await client.wav(text: "YAP-TLS-PRIVATE-CANARY:listener-replacement",
                                         voice: "af_heart", speed: 1)
                XCTFail("Replacing a verified listener must not expose speech or its bearer token")
            } catch {
                // authed() turns a failed /verify into its own AuthError.
                // A URLSession error here therefore proves the genuine HMAC
                // was accepted and the subsequent protected TLS request failed.
                XCTAssertEqual((error as NSError).domain, NSURLErrorDomain,
                               "Expected rejection on the protected connection after valid proof")
            }
            let receipt = try fixture.snapshot()
            XCTAssertTrue(receipt.replacementBound, "A real same-port replacement must occur")
            XCTAssertEqual(receipt.verifyRequests, 1, "The genuine listener must return its proof")
            XCTAssertGreaterThanOrEqual(receipt.trustedConnections, 1)
            XCTAssertGreaterThanOrEqual(receipt.impostorConnections, 1)
            assertNoLeak(receipt)
            print("PASS: same-port listener replaced after genuine verification; no bearer/text leak")
        }
        print("PINNED TLS RUNTIME PASS")
    }

    private func assertNoLeak(_ receipt: Snapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(receipt.impostorHttpRequests, 0, file: file, line: line)
        XCTAssertEqual(receipt.protectedRequests, 0, file: file, line: line)
        XCTAssertEqual(receipt.authorizationHeaders, 0, file: file, line: line)
        XCTAssertEqual(receipt.sensitiveBodies, 0, file: file, line: line)
    }

    private struct Snapshot: Decodable {
        let trustedConnections: Int
        let impostorConnections: Int
        let verifyRequests: Int
        let protectedRequests: Int
        let authorizationHeaders: Int
        let validAuthorizationHeaders: Int
        let sensitiveBodies: Int
        let impostorHttpRequests: Int
        let maxConcurrentProtected: Int
        let replacementBound: Bool
        let certificatesDiffer: Bool
    }

    private final class Fixture {
        let directory: URL
        let process: LoggedProcess
        let port: Int

        init(mode: String, root: URL, token: URL) async throws {
            let fm = FileManager.default
            directory = root.appending(path: mode)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
            let repository = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let script = repository.appending(path: "scripts/ci/fixtures/pinned_tls_server.py")
            guard fm.fileExists(atPath: script.path) else {
                throw failure("TLS fixture missing from the source checkout: \(script.path)")
            }
            process = try LoggedProcess(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["python3", "-B", script.path, "--token-file", token.path,
                            "--state-dir", directory.path, "--mode", mode],
                environment: ProcessInfo.processInfo.environment,
                log: directory.appending(path: "fixture.log")
            )
            let ready = directory.appending(path: "ready.json")
            var chosenPort: Int?
            for _ in 0..<300 {
                if let data = try? Data(contentsOf: ready),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
                   let value = object["port"] {
                    chosenPort = value
                    break
                }
                if !process.process.isRunning { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let chosenPort else {
                process.stop()
                throw failure("TLS fixture did not start (\(mode))\n\(process.output)")
            }
            port = chosenPort
        }

        func client() -> BackendClient {
            var result = BackendClient()
            result.base = URL(string: "https://127.0.0.1:\(port)")!
            return result
        }

        func snapshot() throws -> Snapshot {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Snapshot.self,
                from: Data(contentsOf: directory.appending(path: "snapshot.json")))
        }

        func stop() { process.stop() }
        deinit { stop() }
    }

    private final class LoggedProcess {
        let process = Process()
        let finished = DispatchSemaphore(value: 0)
        private let log: URL
        private let handle: FileHandle

        init(executable: URL, arguments: [String], environment: [String: String], log: URL) throws {
            self.log = log
            FileManager.default.createFile(atPath: log.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
            handle = try FileHandle(forWritingTo: log)
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = handle
            process.standardError = handle
            let completion = finished
            process.terminationHandler = { _ in completion.signal() }
            try process.run()
        }

        var output: String { (try? String(contentsOf: log, encoding: .utf8)) ?? "(no process output)" }

        func stop() {
            guard process.isRunning else { return }
            process.terminate()
            if finished.wait(timeout: .now() + 3) != .success, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 3)
            }
        }

        deinit {
            stop()
            try? handle.close()
        }
    }
}

private func failure(_ message: String) -> NSError {
    NSError(domain: "YapPinnedTLSIntegrationTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
}
