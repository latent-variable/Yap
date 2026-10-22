import XCTest
@testable import Yap

final class SpeakCancellationTests: XCTestCase {
    @MainActor
    func testCancellingActiveSpeakStartsQueuedRequest() throws {
        let state = AppState.shared
        defer { state.stop() }

        // Keep this synchronous on the main actor: exercise the real ticket
        // lifecycle before the stream tasks can start a backend or play audio.
        let first = try state.speak("First request.", options: .init(clean: false), interrupt: true).get()
        let second = try state.speak("Second request.", options: .init(clean: false), interrupt: false).get()
        XCTAssertNil(first.queuePosition)
        XCTAssertEqual(second.queuePosition, 1)
        XCTAssertNil(state.speakOutcome(first.id))
        XCTAssertNil(state.speakOutcome(second.id))

        state.cancelSpeak(first.id)

        XCTAssertEqual(state.speakOutcome(first.id), .stopped)
        XCTAssertNil(state.speakOutcome(second.id), "Cancelling one caller must not stop another caller's ticket")
        XCTAssertEqual(state.speakQueueCount, 0)
        XCTAssertEqual(state.lastCaptured, "Second request.", "The next queued read must start")
    }
}
