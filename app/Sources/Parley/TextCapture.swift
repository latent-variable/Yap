import AppKit
import ApplicationServices

/// Result of a capture attempt: the text plus which method produced it.
struct Capture {
    enum Method: String { case accessibility = "Accessibility", clipboard = "Clipboard", none = "None" }
    var text: String
    var method: Method
}

/// System-wide selected-text capture. Tries the Accessibility API first
/// (no clipboard side effects), falls back to a Cmd+C clipboard round-trip
/// that restores the user's original clipboard.
enum TextCapture {

    /// Async capture on the main actor. NSPasteboard is not thread-safe, so all
    /// pasteboard access stays on the main thread; the clipboard fallback's
    /// up-to-0.8s wait yields the actor between polls (Task.sleep) instead of
    /// blocking it, so a slow or failed ⌘C never freezes the UI.
    @MainActor
    static func capture(mode: CaptureMode) async -> Capture {
        let trusted = Permissions.axTrusted
        Log.write("capture start mode=\(mode.rawValue) axTrusted=\(trusted)")
        let result: Capture
        switch mode {
        case .accessibility:
            result = viaAccessibility().map { Capture(text: $0, method: .accessibility) }
                ?? Capture(text: "", method: .none)
        case .clipboard:
            result = await viaClipboardAsync().map { Capture(text: $0, method: .clipboard) }
                ?? Capture(text: "", method: .none)
        case .auto:
            if let t = viaAccessibility(), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = Capture(text: t, method: .accessibility)
            } else {
                result = await viaClipboardAsync().map { Capture(text: $0, method: .clipboard) }
                    ?? Capture(text: "", method: .none)
            }
        }
        Log.write("capture done method=\(result.method.rawValue) chars=\(result.text.count)")
        return result
    }

    /// Full state dump for the `--diag` CLI and the Diagnostics tab.
    static func diagnose() -> String {
        var s = "Accessibility trusted: \(Permissions.axTrusted)\n"
        let ax = viaAccessibility()
        s += "AX selected text: \(ax.map { "\($0.count) chars" } ?? "nil")\n"
        let clip = viaClipboard()
        s += "Clipboard ⌘C capture: \(clip.map { "\($0.count) chars" } ?? "nil")\n"
        s += "Existing clipboard: \((NSPasteboard.general.string(forType: .string) ?? "").count) chars\n"
        return s
    }

    /// Read currently selected text from the focused UI element via AXUIElement.
    static func viaAccessibility() -> String? {
        guard Permissions.axTrusted else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        let el = element as! AXUIElement

        // Direct selected-text attribute.
        var sel: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &sel) == .success,
           let s = sel as? String, !s.isEmpty {
            return s
        }
        // Some elements expose selection via range + value.
        var rangeVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeVal) == .success,
           let rv = rangeVal, CFGetTypeID(rv) == AXValueGetTypeID() {
            // CFGetTypeID guard above: a buggy app could hand back a String or
            // number for this attribute; force-casting that would crash. Verified
            // it's an AXValue, so the cast is safe.
            var range = CFRange()
            if AXValueGetValue(rv as! AXValue, .cfRange, &range), range.length > 0 {
                var sub: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    el, kAXStringForRangeParameterizedAttribute as CFString,
                    rv, &sub) == .success, let s = sub as? String, !s.isEmpty {
                    return s
                }
            }
        }
        return nil
    }

    /// Clipboard fallback: save pasteboard, send Cmd+C, read the *fresh* copy,
    /// restore the original. Returns nil if Cmd+C produced no new clipboard
    /// content — critically, it never returns the pre-existing clipboard, so a
    /// failed copy can't make Parley read text the user didn't select.
    static func viaClipboard() -> String? {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let beforeCount = pb.changeCount

        sendCopy()

        // Wait for the pasteboard's changeCount to actually advance.
        var changed = false
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline {
            if pb.changeCount != beforeCount { changed = true; break }
            usleep(15_000) // 15 ms
        }

        // Only trust a genuinely fresh copy. No change => no selection => nil.
        let text = changed ? pb.string(forType: .string) : nil
        if !changed {
            Log.write(Permissions.axTrusted
                ? "clipboard: ⌘C produced no change (no selection?)"
                : "clipboard: ⌘C produced no change AND Accessibility NOT granted — synthetic Copy is likely blocked")
        }

        restore(pb, saved)
        if let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t }
        return nil
    }

    // Guards against async re-entrancy: viaClipboardAsync yields the main actor
    // during its wait, so a second trigger (double hotkey) could otherwise
    // interleave save/copy/restore on the single global pasteboard and corrupt
    // the user's clipboard. A concurrent attempt just returns nil. Readable so
    // callers (AppState) can skip re-triggering a read while one is mid-capture.
    @MainActor private(set) static var isCapturing = false

    /// Async twin of `viaClipboard`: identical logic and the same
    /// never-return-the-stale-clipboard guarantee, but the wait yields the main
    /// actor between polls (Task.sleep) instead of busy-waiting with usleep, so
    /// it never freezes the UI. NSPasteboard stays on the main thread.
    @MainActor
    static func viaClipboardAsync() async -> String? {
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        defer { restore(pb, saved) }   // always put the user's clipboard back
        let beforeCount = pb.changeCount

        sendCopy()

        var changed = false
        // Monotonic clock — immune to NTP/manual clock changes and sleep/wake.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        while ProcessInfo.processInfo.systemUptime < deadline {
            if pb.changeCount != beforeCount { changed = true; break }
            // On cancellation, bail immediately (the defers still restore the
            // clipboard and reset the flag) — don't fall through to the
            // "no change" log, and don't spin hot as a swallowed error would.
            do { try await Task.sleep(nanoseconds: 15_000_000) } catch { return nil } // 15 ms
        }

        let text = changed ? pb.string(forType: .string) : nil
        if !changed {
            Log.write(Permissions.axTrusted
                ? "clipboard: ⌘C produced no change (no selection?)"
                : "clipboard: ⌘C produced no change AND Accessibility NOT granted — synthetic Copy is likely blocked")
        }

        // clipboard restored by the defer above
        if let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t }
        return nil
    }

    // MARK: - clipboard plumbing

    private static func snapshot(_ pb: NSPasteboard) -> [[String: Data]] {
        var items: [[String: Data]] = []
        for item in pb.pasteboardItems ?? [] {
            var dict: [String: Data] = [:]
            for type in item.types {
                if let d = item.data(forType: type) { dict[type.rawValue] = d }
            }
            items.append(dict)
        }
        return items
    }

    private static func restore(_ pb: NSPasteboard, _ items: [[String: Data]]) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        var newItems: [NSPasteboardItem] = []
        for dict in items {
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            newItems.append(item)
        }
        pb.writeObjects(newItems)
    }

    private static func sendCopy() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let cKey: CGKeyCode = 8 // 'c'
        let down = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
