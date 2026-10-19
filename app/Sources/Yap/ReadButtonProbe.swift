import AppKit

/// `Yap --readbuttontest [--legacy]` — does a Clipboard-mode capture started
/// while Yap is frontmost (the menu's Read button) read the selection in the app
/// behind it?
///
/// Opens a scratch file in TextEdit, selects it all, then brings Yap forward by
/// clicking a window of its own, exactly as a click on the menu does, and runs
/// the clipboard capture the Read button runs. `--legacy` skips handing focus
/// back, the pre-fix behaviour, as the control that must fail.
///
/// Posting ⌘A/⌘C needs the Accessibility grant of the signed bundle, so:
///
///     open -n -W dist/Yap.app --stdout /tmp/readbutton.txt --args --readbuttontest
///
/// Takes the keyboard focus for a few seconds. Closes only its own document (and
/// TextEdit, if it was not already running); the clipboard is restored as usual.
enum ReadButtonProbe {
    static func run(legacy: Bool) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in exit(await probe(legacy: legacy)) }
        app.run()
        exit(1)
    }

    @MainActor
    private static func until(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return cond()
    }

    private static func key(_ code: CGKeyCode, cmd: Bool = true) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            if cmd { e?.flags = .maskCommand }
            e?.post(tap: .cghidEventTap)
        }
    }

    @MainActor
    private static func probe(legacy: Bool) async -> Int32 {
        guard CGPreflightPostEventAccess() else {
            print("readbuttontest SKIPPED: not allowed to post events. Launch the signed bundle through `open`.")
            return 2
        }
        let fm = FileManager.default
        let marker = "Yap read button probe \(UUID().uuidString.prefix(8))"
        let file = fm.temporaryDirectory.appending(path: "yap-readbutton-\(getpid()).txt")
        try? Data((marker + "\n").utf8).write(to: file)
        defer {
            if file.lastPathComponent.hasPrefix("yap-readbutton-") { try? fm.trashItem(at: file, resultingItemURL: nil) }
        }

        let editID = "com.apple.TextEdit"
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: editID).isEmpty
        guard let editURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editID) else {
            print("readbuttontest SKIPPED: no TextEdit"); return 2
        }
        TextCapture.trackFrontApp()
        TextCapture.returnsFocusForCopy = !legacy
        // macOS 14 activation is cooperative: only the active app can hand it on.
        NSApp.activate()
        _ = await until(2) { NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier }
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: editID)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        guard let edit = try? await NSWorkspace.shared.open([file], withApplicationAt: editURL, configuration: config) else {
            print("readbuttontest FAILED: could not open TextEdit"); return 1
        }
        /// Close only what the probe opened: its document, and TextEdit itself if
        /// it was not running before. Runs on every exit once TextEdit is up.
        @MainActor func closeDocument() async {
            NSApp.yieldActivation(to: edit)
            edit.activate(from: NSRunningApplication.current, options: [])
            if await until(3, { NSWorkspace.shared.frontmostApplication?.processIdentifier == edit.processIdentifier }) {
                try? await Task.sleep(for: .milliseconds(200))
                key(13)   // ⌘W, the unmodified scratch file closes without a prompt
                try? await Task.sleep(for: .milliseconds(400))
            }
            if !wasRunning { edit.terminate() }
        }
        let editFront = await until(5) { NSWorkspace.shared.frontmostApplication?.processIdentifier == edit.processIdentifier }
        guard editFront else {
            print("readbuttontest FAILED: TextEdit never came forward (front: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))")
            await closeDocument(); return 1
        }
        try? await Task.sleep(for: .milliseconds(600))   // the document window settles
        key(0)   // ⌘A: select the marker line

        // Bring Yap forward with a real click on a window of its own, as a click
        // on the menu-bar popover does.
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "Yap probe"
        win.level = .floating
        // On the primary display, the one CG coordinates are measured from; center()
        // picks the display with keyboard focus, which may be another one.
        if let primary = NSScreen.screens.first?.visibleFrame {
            win.setFrameOrigin(NSPoint(x: primary.midX - 120, y: primary.midY - 60))
        }
        win.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(300))
        let f = win.frame
        let main = NSScreen.screens.first?.frame.height ?? 0
        let pt = CGPoint(x: f.midX, y: main - f.midY)   // AppKit → CG coordinates
        // A synthetic click lands on whatever is on top there. Never click unless it
        // is this window, or the click goes into the user's own app.
        guard NSWindow.windowNumber(at: NSPoint(x: f.midX, y: f.midY), belowWindowWithWindowNumber: 0) == win.windowNumber else {
            print("readbuttontest FAILED: the probe window is not on top at its click point, refusing to click")
            win.close(); await closeDocument(); return 1
        }
        let saved = CGEvent(source: nil)?.location
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        if let saved { CGWarpMouseCursorPosition(saved) }
        let me = ProcessInfo.processInfo.processIdentifier
        let yapFront = await until(3) { NSWorkspace.shared.frontmostApplication?.processIdentifier == me }

        var failures = 0
        func ok(_ name: String, _ cond: Bool, _ detail: String = "") {
            print("  \(cond ? "PASS" : "FAIL") \(name) \(detail)")
            if !cond { failures += 1 }
        }
        ok("Yap is frontmost before the capture, as after a menu click", yapFront)
        let before = NSPasteboard.general.string(forType: .string)
        let got = yapFront ? (await TextCapture.capture(mode: .clipboard)).text : ""
        ok("the clipboard capture read TextEdit's selection", got.contains(marker), "(got \(got.count) chars)")
        ok("the clipboard is restored", NSPasteboard.general.string(forType: .string) == before)
        win.close()

        await closeDocument()

        print(failures == 0 ? "readbuttontest PASS" : "readbuttontest FAIL (\(failures))")
        return failures == 0 ? 0 : 1
    }
}
