import AppKit

/// `Yap --hudtest [--legacy]` — can the dictation HUD be dragged out of the
/// way, and does it stay where it was put without ever leaving the screen?
///
/// Shows the real HUD panel and drags it with synthetic mouse events: by the
/// status row, by the transcript, and while the transcript grows a few lines
/// mid-drag (the panel resizes under the pointer, as it does while you talk).
/// Each time it checks the panel followed the pointer. Then placement: at rest
/// it sits exactly at home, hidden and shown again it is where it was left,
/// dropped past the bottom edge it comes back on screen, and a remembered spot
/// off every screen is not trusted.
///
/// `--legacy` turns the panel's own drag handling off and leaves only
/// `isMovableByWindowBackground`, the pre-fix behaviour, as the control that
/// must fail. It runs the three drags only.
///
/// Posting events needs the Accessibility grant, which belongs to the signed
/// bundle and not to a terminal, so build the app and launch it through `open`:
///
///     open -n -W dist/Yap.app --stdout /tmp/hudtest.txt --args --hudtest
///
/// It takes the pointer for about eight seconds and puts it back. Not headless:
/// it needs a logged-in display. The remembered spot it writes goes to its own
/// defaults suite, so the user's HUD stays where they left it.
enum HUDProbe {
    /// How far each drag asks the panel to go: right and up.
    private static let delta = CGSize(width: 140, height: 90)
    /// macOS snaps a dragged window to nearby window edges, so "followed the
    /// pointer" allows for a snap. The control moves 0.
    private static let tolerance: CGFloat = 20
    private static let suite = "yap.hudtest"
    /// Offsets from the panel's top-left corner.
    private static let statusRow = CGSize(width: 120, height: 22)
    private static let transcript = CGSize(width: 200, height: 52)

    static func run(legacy: Bool) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            guard CGPreflightPostEventAccess() else {
                print("hudtest SKIPPED: not allowed to post events. Launch the signed bundle through `open`.")
                exit(2)
            }
            guard let store = UserDefaults(suiteName: suite) else {
                print("hudtest FAILED: no defaults suite"); exit(1)
            }
            let controller = DictationController.shared
            controller.hudDefaults = store
            let home = CGEvent(source: nil)?.location
            var failed = false
            func report(_ ok: Bool, _ line: String) {
                print("  \(ok ? "PASS" : "FAIL") \(line)")
                if !ok { failed = true }
            }
            /// A fresh HUD at its home position, nothing remembered.
            @MainActor func freshHUD() async -> HUDPanel {
                controller.hideHUDForProbe()
                store.removePersistentDomain(forName: suite)
                return await shown()
            }
            @MainActor func shown() async -> HUDPanel {
                guard let panel = controller.showHUDForProbe() else {
                    print("hudtest FAILED: no HUD panel"); exit(1)
                }
                if legacy {
                    panel.dragsOnPress = false
                    panel.isMovableByWindowBackground = true
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
                return panel
            }
            @MainActor func onAScreen(_ panel: NSPanel) -> Bool {
                NSScreen.screens.contains { $0.visibleFrame.contains(panel.frame) }
            }

            let drags: [(name: String, inset: CGSize, grows: Bool)] = [
                ("by the status row", statusRow, false),
                ("by the transcript", transcript, false),
                ("while the transcript grows", statusRow, true),
            ]
            for c in drags {
                let panel = await freshHUD()
                let before = panel.frame
                await drag(panel, at: c.inset, by: delta) {
                    guard c.grows else { return }
                    controller.dictation.note(String(repeating: "the transcript grows while the panel is moving ", count: 6))
                }
                let after = panel.frame
                if c.grows, after.height <= before.height {
                    print("hudtest FAILED: the transcript never grew, so that case tested nothing"); exit(1)
                }
                let moved = CGSize(width: after.minX - before.minX, height: after.minY - before.minY)
                report(abs(moved.width - delta.width) <= tolerance && abs(moved.height - delta.height) <= tolerance,
                       String(format: "%@: asked (%.0f, %.0f), panel moved (%.0f, %.0f)",
                              c.name, delta.width, delta.height, moved.width, moved.height))
                controller.dictation.clearError()
            }

            if !legacy {
                var panel = await freshHUD()
                let start = panel.frame.origin
                let want = NSScreen.main.map { HUDPlacement.home(size: panel.frame.size, in: $0.visibleFrame) }
                report(start == want, "at rest it sits exactly at home: home is \(want.map(fmt) ?? "unknown"), panel is at \(fmt(start))")
                await drag(panel, at: statusRow, by: delta) {}
                let left = panel.frame.origin
                controller.hideHUDForProbe()
                panel = await shown()
                let back = panel.frame.origin
                report(back == left && abs(left.x - start.x) > 100,
                       "shown again where it was left: left at \(fmt(left)), came back at \(fmt(back)), home is \(fmt(start))")

                panel = await freshHUD()
                let before = panel.frame
                await drag(panel, at: statusRow, by: CGSize(width: 0, height: -160)) {}
                report(onAScreen(panel) && panel.frame.minY < before.minY - 100,
                       "dropped past the bottom edge it comes back on screen: asked \(fmt(CGPoint(x: before.minX, y: before.minY - 160))), rests at \(fmt(panel.frame.origin))")

                controller.hideHUDForProbe()
                store.set(NSStringFromPoint(NSPoint(x: 90_000, y: -90_000)), forKey: DictationController.hudOriginKey)
                panel = await shown()
                report(onAScreen(panel),
                       "a remembered spot off every screen is not trusted: remembered (90000, -90000), shown at \(fmt(panel.frame.origin))")
            }

            controller.hideHUDForProbe()
            store.removePersistentDomain(forName: suite)
            if let home { CGWarpMouseCursorPosition(home) }
            print(failed ? "hudtest FAILED" : "hudtest PASS")
            exit(failed ? 1 : 0)
        }
        app.run()
        exit(0)
    }

    private static func fmt(_ p: CGPoint) -> String { String(format: "(%.0f, %.0f)", p.x, p.y) }

    /// Press on the panel `inset` from its top-left, move in steps, release;
    /// `midway` runs halfway through the move. Cocoa points in, Quartz
    /// (top-left origin) out.
    @MainActor
    private static func drag(_ panel: NSPanel, at inset: CGSize, by delta: CGSize, midway: () -> Void) async {
        let start = NSPoint(x: panel.frame.minX + inset.width, y: panel.frame.maxY - inset.height)
        // Never press on somebody else's window.
        guard NSWindow.windowNumber(at: start, belowWindowWithWindowNumber: 0) == panel.windowNumber else {
            print("hudtest FAILED: the HUD is not the top window at \(start)"); exit(1)
        }
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
