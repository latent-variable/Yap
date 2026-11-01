import Foundation
import Network
import XCTest
@testable import Yap

/// Regression: an impostor bound to the loopback TTS port may answer /verify,
/// but must never receive the bearer token or speech content.
final class BackendAuthenticationTests: XCTestCase {
    private final class Captures: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func add(_ message: String) {
            lock.lock()
            storage.append(message)
            lock.unlock()
        }
        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    func testFakeBackendDoesNotReceiveAuthorization() async throws {
        guard BackendAuth.token != nil else {
            throw XCTSkip("local auth token unavailable in test environment")
        }

        let listening = expectation(description: "fake backend is listening")
        let received = expectation(description: "fake backend received verification")
        let captures = Captures()
        let queue = DispatchQueue(label: "yap.security.mock-backend")
        let listener = try NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }

        listener.stateUpdateHandler = { state in
            if case .ready = state { listening.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                if let data {
                    captures.add(String(decoding: data, as: UTF8.self))
                }
                received.fulfill()
                let body = "{\"proof\":\"not-the-right-HMAC\"}"
                let wire = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(wire.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.start(queue: queue)
        await fulfillment(of: [listening], timeout: 5)

        let port = try XCTUnwrap(listener.port?.rawValue)
        var client = BackendClient()
        client.base = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
        let health = await client.health()
        XCTAssertNil(health, "unverified server must not supply a trusted health response")

        await fulfillment(of: [received], timeout: 5)
        let requests = captures.snapshot()
        XCTAssertEqual(requests.count, 1, "only an unauthenticated /verify request is allowed")
        XCTAssertTrue(requests[0].contains("GET /verify?nonce="))
        XCTAssertFalse(requests[0].lowercased().contains("authorization:"))
        XCTAssertFalse(requests[0].contains("Bearer "))
    }
}
