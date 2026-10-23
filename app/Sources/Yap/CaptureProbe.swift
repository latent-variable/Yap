import AppKit

/// `Yap --capturetest [--legacy]`: in an app where a synthetic ⌘C copies
/// nothing, does a read with a fresh clipboard skip the doomed ⌘C, and does the
/// app come off that list the moment a ⌘C works there?
///
/// TextEdit with nothing selected stands in for Claude Code's fullscreen view,
/// where the highlight is drawn by Claude Code, so ⌘C finds nothing, while
/// Claude Code copies the highlight to the clipboard itself. The probe makes
/// that copy by writing the clipboard. `--legacy` runs the Auto read with the
/// skip off, the pre-fix behaviour, as the control that must fail.
///
/// Posting ⌘C needs the Accessibility grant of the signed bundle, so:
///
///     open -n -W dist/Yap.app --stdout /tmp/capturetest.txt --args --capturetest
///
/// Takes the keyboard focus for a few seconds. Closes only its own document (and
/// TextEdit, if it was not already running) and puts the clipboard back.
enum CaptureProbe {
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
            e?.flags = cmd ? .maskCommand : []
            e?.post(tap: .cghidEventTap)
        }
    }

    @MainActor
    private static func probe(legacy: Bool) async -> Int32 {
        guard CGPreflightPostEventAccess() else {
            print("capturetest SKIPPED: not allowed to post events. Launch the signed bundle through `open`.")
            return 2
        }
        let fm = FileManager.default
        let pb = NSPasteboard.general
        // The user's clipboard, every type, put back on every exit.
        let saved: [[String: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [String: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t.rawValue] = v } }
            return d
        }
        defer {
            pb.clearContents()
            pb.writeObjects(saved.map { d in
                let item = NSPasteboardItem()
                for (t, v) in d { item.setData(v, forType: NSPasteboard.PasteboardType(t)) }
                return item
            })
        }

        let marker = "Yap capture probe \(UUID().uuidString.prefix(8))"
        let file = fm.temporaryDirectory.appending(path: "yap-capture-\(getpid()).txt")
        try? Data((marker + "\n").utf8).write(to: file)
        defer {
            if file.lastPathComponent.hasPrefix("yap-capture-") { try? fm.trashItem(at: file, resultingItemURL: nil) }
        }

        let editID = "com.apple.TextEdit"
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: editID).isEmpty
        guard let editURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editID) else {
            print("capturetest SKIPPED: no TextEdit"); return 2
        }
        TextCapture.trackFrontApp()
        NSApp.activate()
        _ = await until(2) { NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier }
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: editID)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        guard let edit = try? await NSWorkspace.shared.open([file], withApplicationAt: editURL, configuration: config) else {
            print("capturetest FAILED: could not open TextEdit"); return 1
        }
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
        guard await until(5, { NSWorkspace.shared.frontmostApplication?.processIdentifier == edit.processIdentifier }) else {
            print("capturetest FAILED: TextEdit never came forward (front: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))")
            await closeDocument(); return 1
        }
        try? await Task.sleep(for: .milliseconds(600))   // the document window settles
        key(125, cmd: true)   // ⌘↓: caret to the end, nothing selected

        var failures = 0
        func ok(_ name: String, _ cond: Bool, _ detail: String = "") {
            print("  \(cond ? "PASS" : "FAIL") \(name) \(detail)")
            if !cond { failures += 1 }
        }
        /// One press as the Auto read source makes it. "Copied" stands in for
        /// Claude Code's copy-on-select landing before the press.
        func press(copied: String?, mode: CaptureMode = .auto) async -> (text: String, ms: Int, clipboard: String) {
            if let copied { pb.clearContents(); pb.setString(copied, forType: .string) }
            let t0 = ProcessInfo.processInfo.systemUptime
            let c = await TextCapture.capture(mode: mode, allowCopySkip: !legacy)
            let ms = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
            return (c.text, ms, pb.string(forType: .string) ?? "")
        }

        // The first misses still try ⌘C: an app is not judged on one press.
        _ = await press(copied: "warm-up")   // gives the capture its clipboard baseline
        for n in 1...2 {
            let r = await press(copied: "copy \(n)")
            ok("press \(n + 1): ⌘C is still tried while the app is unknown", r.ms >= 200, "(\(r.ms) ms)")
        }
        // Three misses, and a fresh copy is waiting: read it now.
        let fresh = "Claude Code copied this \(UUID().uuidString.prefix(6))"
        let skipped = await press(copied: fresh)
        ok("a fresh copy in an app where ⌘C never works skips the ⌘C", skipped.ms < 150, "(\(skipped.ms) ms)")
        ok("and leaves that copy on the clipboard for the read", skipped.clipboard == fresh)
        // Nothing new on the clipboard: nothing fresh to read, so try ⌘C.
        let unchanged = await press(copied: nil)
        ok("an unchanged clipboard still tries ⌘C", unchanged.ms >= 200, "(\(unchanged.ms) ms)")
        // The user selects text in it after all: the ⌘C works and clears its record.
        key(0)   // ⌘A
        try? await Task.sleep(for: .milliseconds(250))
        let copiedSel = await press(copied: nil, mode: .clipboard)
        ok("a ⌘C that works still reads the selection", copiedSel.text.contains(marker), "(got \(copiedSel.text.count) chars)")
        key(125, cmd: true)   // deselect
        try? await Task.sleep(for: .milliseconds(250))
        let after = await press(copied: "copy after a success")
        ok("after one success the app is never skipped again", after.ms >= 200, "(\(after.ms) ms)")

        // A refused press shows a notice next to the pointer, and focus stays
        // in the user's app, or the next press would copy from Yap.
        Notice.show("Same text as last read", detail: "Press again to replay it.", seconds: 2)
        try? await Task.sleep(for: .milliseconds(300))
        let f = Notice.panel?.frame ?? .zero
        let onAScreen = NSScreen.screens.contains { $0.frame.contains(f) }
        ok("the notice is on screen at a real size", Notice.panel?.isVisible == true && f.width > 100 && f.height > 30 && onAScreen,
           "(\(Int(f.width))x\(Int(f.height)) at \(Int(f.minX)),\(Int(f.minY)))")
        ok("and the app behind keeps focus", NSWorkspace.shared.frontmostApplication?.processIdentifier == edit.processIdentifier,
           "(front: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))")
        try? await Task.sleep(for: .milliseconds(2400))
        ok("and it goes away by itself", Notice.panel?.isVisible != true)

        await closeDocument()
        print(failures == 0 ? "capturetest PASS" : "capturetest FAIL (\(failures))")
        return failures == 0 ? 0 : 1
    }
}
