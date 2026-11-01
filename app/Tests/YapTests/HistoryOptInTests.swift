import Foundation
import XCTest
@testable import Yap

final class HistoryOptInTests: XCTestCase {
    @MainActor
    func testRecordingRequiresOptIn() {
        let prefs = Prefs.shared
        let previous = prefs.historyEnabled
        defer { prefs.historyEnabled = previous }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("yap-history-optin-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = HistoryStore(fileURL: temp)

        prefs.historyEnabled = false
        store.recordSpoken("Private selected text")
        store.recordDictated("Private dictation")
        XCTAssertTrue(store.spoken.isEmpty)
        XCTAssertTrue(store.dictated.isEmpty)

        prefs.historyEnabled = true
        store.recordSpoken("Explicitly saved text")
        store.recordDictated("Explicitly saved words")
        XCTAssertEqual(store.spoken.map(\.text), ["Explicitly saved text"])
        XCTAssertEqual(store.dictated.map(\.text), ["Explicitly saved words"])

        prefs.historyEnabled = false
        store.recordSpoken("Should not be recorded")
        XCTAssertEqual(store.spoken.count, 1)
    }
}
