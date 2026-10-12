import AppKit

/// `Yap --hudtest [--legacy]` — can the dictation HUD be dragged out of the way?
///
/// Shows the real HUD panel and drags it with synthetic mouse events: by the
/// status row, by the transcript, and while the transcript grows a few lines
/// mid-drag (the panel resizes under the pointer, as it does while you talk).
/// Each time it checks the panel followed the pointer. `--legacy` turns the
/// panel's own drag handling off and leaves only `isMovableByWindowBackground`,
/// the pre-fix behaviour, as the control that must fail.
///
/// Posting events needs the Accessibility grant, which belongs to the signed
/// bundle and not to a terminal, so build the app and launch it through `open`:
///
///     open -n -W dist/Yap.app --stdout /tmp/hudtest.txt --args --hudtest
///
/// It takes the pointer for about four seconds and puts it back. Not headless:
/// it needs a logged-in display.
enum HUDProbe {
    /// How far each drag asks the panel to go: right and up.
    private static let delta = CGSize(width: 140, height: 90)
    /// macOS snaps a dragged window to nearby window edges, so "followed the
    /// pointer" allows for a snap. The control moves 0.
    private static let tolerance: CGFloat = 20

    static func run(legacy: Bool) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            guard CGPreflightPostEventAccess() else {
                print("hudtest SKIPPED: not allowed to post events. Launch the signed bundle through `open`.")
                exit(2)
            }
            let controller = DictationController.shared
            let home = CGEvent(source: nil)?.location
            var failed = false
            // Grab points are offsets from the panel's top-left corner.
            let cases: [(name: String, inset: CGSize, grows: Bool)] = [
                ("by the status row", CGSize(width: 120, height: 22), false),
                ("by the transcript", CGSize(width: 200, height: 52), false),
                ("while the transcript grows", CGSize(width: 120, height: 22), true),
            ]
            for c in cases {
                // Showing it again puts it back at its home position.
                guard let panel = controller.showHUDForProbe() else {
                    print("hudtest FAILED: no HUD panel"); exit(1)
                }
                if legacy {
                    panel.dragsOnPress = false
                    panel.isMovableByWindowBackground = true
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
                let before = panel.frame
                let grab = NSPoint(x: before.minX + c.inset.width, y: before.maxY - c.inset.height)
                // Never press on somebody else's window.
                guard NSWindow.windowNumber(at: grab, belowWindowWithWindowNumber: 0) == panel.windowNumber else {
                    print("hudtest FAILED: the HUD is not the top window at \(grab)"); exit(1)
                }
                await drag(from: grab, by: delta) {
                    guard c.grows else { return }
                    controller.dictation.note(String(repeating: "the transcript grows while the panel is moving ", count: 6))
                }
                let after = panel.frame
                if c.grows, after.height <= before.height {
                    print("hudtest FAILED: the transcript never grew, so that case tested nothing"); exit(1)
                }
                let moved = CGSize(width: after.minX - before.minX, height: after.minY - before.minY)
                let ok = abs(moved.width - delta.width) <= tolerance && abs(moved.height - delta.height) <= tolerance
                print(String(format: "  %@ %@: asked (%.0f, %.0f), panel moved (%.0f, %.0f)",
                             ok ? "PASS" : "FAIL", c.name, delta.width, delta.height, moved.width, moved.height))
                if !ok { failed = true }
                controller.dictation.clearError()
            }
            if let home { CGWarpMouseCursorPosition(home) }
            print(failed ? "hudtest FAILED" : "hudtest PASS")
            exit(failed ? 1 : 0)
        }
        app.run()
        exit(0)
    }

    /// Press, move in steps, release; `midway` runs halfway through the move.
    /// Cocoa points in, Quartz (top-left origin) out.
    @MainActor
    private static func drag(from start: NSPoint, by delta: CGSize, midway: () -> Void) async {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        func post(_ type: CGEventType, _ p: NSPoint) {
            CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type,
                    mouseCursorPosition: CGPoint(x: p.x, y: top - p.y), mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        post(.mouseMoved, start)
        try? await Task.sleep(nanoseconds: 150_000_000)
        post(.leftMouseDown, start)
        let steps = 14
        for i in 1...steps {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if i == steps / 2 { midway() }
            let t = CGFloat(i) / CGFloat(steps)
            post(.leftMouseDragged, NSPoint(x: start.x + delta.width * t, y: start.y + delta.height * t))
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        post(.leftMouseUp, NSPoint(x: start.x + delta.width, y: start.y + delta.height))
        try? await Task.sleep(nanoseconds: 400_000_000)
    }
}
