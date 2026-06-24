import AppKit
import Carbon.HIToolbox

/// Inserts dictated text into the frontmost app at the cursor — the inverse of
/// `TextCapture`. Puts the text on the pasteboard, synthesizes ⌘V, then restores
/// the user's previous clipboard. Needs Accessibility (synthetic keystrokes).
enum TextInsert {
    /// Paste `text` at the current cursor. Returns false if the text was empty.
    @discardableResult
    @MainActor
    static func insertAtCursor(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)   // best-effort save (string only)
        pb.clearContents()
        pb.setString(trimmed, forType: .string)

        // Let the pasteboard write propagate before synthesizing the paste — some
        // apps read a stale pasteboard if ⌘V fires the same instant we set it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            sendCmdV()
            // Restore the user's clipboard only AFTER the paste is delivered.
            // Too-early restore clobbers our text mid-paste, so a slow app pastes
            // the old clipboard (or nothing) and the user has to retry. 0.6s is a
            // safe margin across slow/Electron targets.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                pb.clearContents()
                if let saved { pb.setString(saved, forType: .string) }
            }
        }
        return true
    }

    private static func sendCmdV() {
        let vKey = CGKeyCode(kVK_ANSI_V)
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
