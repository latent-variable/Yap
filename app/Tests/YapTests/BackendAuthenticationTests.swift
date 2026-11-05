import Foundation
import Network
import XCTest
@testable import Yap

/// Port squatters cannot impersonate a local backend after the switch to HTTPS:
/// TLS pins the backend certificate ON THE SAME CONNECTION that would carry
/// the authorization header or speech text. No HTTP is sent before TLS trust.
final class BackendAuthenticationTests: XCTestCase {
    private final class Captures: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Data] = []
        func add(_ message: Data) -> Bool {
            lock.lock()
            storage.append(message)
            let first = storage.count == 1
            lock.unlock()
            return first
        }
        func snapshot() -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    func testUnpinnedHTTPOriginFailsWithoutSendingSpeech() async throws {
        var client = BackendClient()
        client.base = try XCTUnwrap(URL(string: "http://127.0.0.1:8766"))
        let trusted = await client.verifyAuthentic()
        XCTAssertFalse(trusted)
        do {
            _ = try await client.wav(text: "HTTP-LEAK-CANARY", voice: "af_heart", speed: 1)
            XCTFail("No speech request may be sent over cleartext HTTP")
        } catch {
            // Must fail before any socket request or bearer header is created.
        }
    }

    func testPortSquatterCannotReceiveBearerOrCapturedText() async throws {
        guard BackendAuth.token != nil else {
            throw XCTSkip("auth token unavailable")
        }

        let listening = expectation(description: "impostor is listening")
        let received = expectation(description: "impostor sees only TLS handshake")
        let captures = Captures()
        let queue = DispatchQueue(label: "yap.security.impostor")
        let listener = try NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }

        listener.stateUpdateHandler = { state in
            if case .ready = state { listening.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                if let data, captures.add(data) { received.fulfill() }
                // Deliberately plain HTTP. An old client leaks an HTTP /verify
                // request here; a pinned-TLS client sends only ClientHello.
                let reply = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)
                connection.send(content: reply, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.start(queue: queue)
        await fulfillment(of: [listening], timeout: 5)
        let port = try XCTUnwrap(listener.port?.rawValue)
        var client = BackendClient()
        client.base = try XCTUnwrap(URL(string: "https://127.0.0.1:\(port)"))

        // An unauthorized listener on this port must neither be accepted as a
        // healthy backend nor receive any privileged headers / sensitive text.
        let health = await client.health()
        XCTAssertNil(health)
        await fulfillment(of: [received], timeout: 5)

        let raw = captures.snapshot()
        XCTAssertFalse(raw.isEmpty)
        for packet in raw {
            let message = String(decoding: packet, as: UTF8.self)
            XCTAssertFalse(message.contains("GET /verify"))
            XCTAssertFalse(message.contains("Authorization:"))
            XCTAssertFalse(message.contains("Bearer "))
            XCTAssertFalse(message.contains("POST /synthesize"))
            XCTAssertFalse(message.contains("PRIVATE-SPOKEN-CANARY"))
            XCTAssertFalse(message.contains(BackendAuth.token ?? "NOT-SET"))
        }

        do {
            _ = try await client.wav(text: "PRIVATE-SPOKEN-CANARY",
                                     voice: "af_heart", speed: 1)
            XCTFail("Impostor should never complete a speech request")
        } catch { /* handshake or auth refusal is required */ }
        for packet in captures.snapshot() {
            let msg = String(decoding: packet, as: UTF8.self)
            XCTAssertFalse(msg.contains("PRIVATE-SPOKEN-CANARY"))
            XCTAssertFalse(msg.contains("Authorization:"))
            XCTAssertFalse(msg.contains(BackendAuth.token ?? "NOT-SET"))
        }
    }
}
