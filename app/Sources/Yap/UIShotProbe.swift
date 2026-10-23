import AppKit
import SwiftUI

/// `Yap --uishot <dir>` — render the menu popover (both halves) and every
/// Settings pane to PNGs, in light and dark, without opening the menu bar.
///
/// For reviewing the UI from a terminal or handing it to a critic: the real
/// views, the real environment objects, laid out in an off-screen window and
/// drawn with `cacheDisplay`. Seeded with a sample "last read" so the cards
/// show. Blur materials draw flat here, so the popover sits on a plain
/// background that stands in for the menu material.
///
/// Run the bare `swift build` binary, not the bundle: its preferences live in
/// the executable's own defaults domain, so the two keys it sets (which menu
/// half and which pane is showing) never touch the installed app's settings.
enum UIShotProbe {
    static func run(dir: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Sample history, set before anything touches HistoryStore.shared: the
        // History pane must never photograph the user's real dictation.
        let sample = FileManager.default.temporaryDirectory.appending(path: "yap-uishot-history-\(getpid()).json")
        try? sampleHistory().write(to: sample)
        setenv("YAP_HISTORY_FILE", sample.path, 1)
        Task { @MainActor in
            let state = AppState.shared
            let prefs = Prefs.shared
            state.modelsPresent = true
            state.lastCleaned = "The nav card is closed with your reasons and moved to done. The market fix is live, and I tested it on our own report. Next up, the software comparison page."
            state.lastMethod = .clipboard
            seed(state)
            state.axTrusted = true   // the unsigned probe has no grant; users who see this do
            let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appending(path: "../../Resources/Info.plist")
            UpdateChecker.probeVersion = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String)
            // Playback as a real user has it (this is the probe's own defaults domain).
            prefs.hdVoice = "Sam"; prefs.speed = 1.25; prefs.volume = 1; prefs.pitch = 0; prefs.pauseScale = 1
            prefs.hotKey = HotKeyCombo.defaultCombo; prefs.dictationHotKey = HotKeyCombo.dictationDefault
            var written = 0
            for dark in [false, true] {
                let look = NSAppearance(named: dark ? .darkAqua : .aqua)
                let suffix = dark ? "dark" : "light"
                for tab in [MenuTab.ears, .voice] {
                    UserDefaults.standard.set(tab.rawValue, forKey: "menuTab")
                    let view = MenuContent().environmentObject(state).environmentObject(prefs)
                        .background(Color(nsColor: dark ? NSColor(white: 0.13, alpha: 1)
                                                         : NSColor(white: 0.96, alpha: 1)))
                    if await shoot(view, width: MenuContent.width, height: nil, look: look,
                                   to: out.appending(path: "menu-\(tab.rawValue)-\(suffix).png")) { written += 1 }
                }
                let notice = NoticeView(title: "Same text as last read")
                    .padding(20).background(Color(nsColor: .windowBackgroundColor))
                if await shoot(notice, width: 380, height: nil, look: look,
                               to: out.appending(path: "notice-\(suffix).png")) { written += 1 }
                let sheet = CloneVoiceSheet().environmentObject(state).environmentObject(prefs)
                    .background(Color(nsColor: .windowBackgroundColor))
                if await shoot(sheet, width: 480, height: nil, look: look,
                               to: out.appending(path: "clone-sheet-\(suffix).png")) { written += 1 }
                // The Agents pane runs past the window; shoot all of it once.
                let agents = AgentsTab().environmentObject(state).environmentObject(prefs)
                    .frame(width: 640, height: 1180).background(Color(nsColor: .windowBackgroundColor))
                if await shoot(agents, width: 640, height: nil, look: look,
                               to: out.appending(path: "agents-full-\(suffix).png")) { written += 1 }
                for pane in SettingsTab.allCases {
                    UserDefaults.standard.set(pane.rawValue, forKey: "settingsPane")
                    // The Voices pane looks different per engine: shoot both.
                    for engine in pane == .voice ? ["kokoro", "pocket"] : [prefs.engine] {
                        let was = prefs.engine
                        prefs.engine = engine
                        let name = pane == .voice ? "\(pane.rawValue)-\(engine)" : pane.rawValue
                        let view = SettingsView().environmentObject(state).environmentObject(prefs)
                        if await shoot(view, width: 860, height: 620, look: look,
                                       to: out.appending(path: "settings-\(name)-\(suffix).png")) { written += 1 }
                        prefs.engine = was
                    }
                }
            }
            print("uishot: wrote \(written) images to \(out.path)")
            exit(written > 0 ? 0 : 1)
        }
        app.run()
        exit(1)
    }

    private static func sampleHistory() -> Data {
        let now = Date()
        func e(_ kind: HistoryEntry.Kind, _ mins: Double, _ text: String, _ detail: String) -> HistoryEntry {
            HistoryEntry(date: now.addingTimeInterval(-mins * 60), kind: kind, text: text, detail: detail)
        }
        struct Snap: Encodable { var spoken: [HistoryEntry]; var dictated: [HistoryEntry] }
        let snap = Snap(
            spoken: [
                e(.spoken, 3, "Speak to me. The login fix is merged and all forty tests pass. Next I'll clean up the old helper.", "Kokoro · Clipboard"),
                e(.spoken, 26, "Kokoro is an open-weight text to speech model with 82 million parameters.", "Kokoro · Accessibility"),
            ],
            dictated: [
                e(.dictated, 2, "Okay, let's ship the new onboarding flow, but keep the old one behind a flag for a week.", "Terminal"),
                e(.dictated, 9, "Can you write a test for the empty cart case before you change anything?", "Claude"),
                e(.dictated, 31, "Thanks so much, Thursday at two works great for me.", "Mail"),
                e(.dictated, 58, "Remind me to rerun the benchmark when the laptop is idle.", "Notes"),
            ])
        return (try? JSONEncoder().encode(snap)) ?? Data()
    }

    /// `--uihold <pane> <seconds>`: show the Settings window on one pane and
    /// idle, so its CPU can be measured from outside (`ps`, `sample`). An open
    /// Settings window must cost nothing while nothing changes.
    static func hold(pane: String, seconds: Double) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let sample = FileManager.default.temporaryDirectory.appending(path: "yap-uishot-history-\(getpid()).json")
        try? sampleHistory().write(to: sample)
        setenv("YAP_HISTORY_FILE", sample.path, 1)
        Task { @MainActor in
            UserDefaults.standard.set(pane, forKey: "settingsPane")
            let view = SettingsView().environmentObject(AppState.shared).environmentObject(Prefs.shared)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 860, height: 620),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            print("uihold: \(pane) for \(seconds)s pid \(getpid())")
            try? await Task.sleep(for: .seconds(seconds))
            var u = rusage(); getrusage(RUSAGE_SELF, &u)
            let cpu = Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
            print(String(format: "uihold: %.2fs CPU in %.0fs", cpu, seconds))
            exit(0)
        }
        app.run()
        exit(1)
    }

    /// Sample voices, set again just before each capture: a pane's onAppear asks
    /// the live backend for its voices, and the screenshots must show these
    /// sample names, never the user's own cloned voices.
    @MainActor private static func seed(_ state: AppState) {
        // A few voices of each kind so the Voices pane shows a real list.
        state.voices = [("af_heart", "female"), ("af_bella", "female"), ("am_puck", "male"),
                        ("am_michael", "male"), ("bf_emma", "female"), ("bm_george", "male")].map {
            VoiceInfo(id: $0.0, lang: $0.0.hasPrefix("b") ? "en-gb" : "en-us",
                      lang_label: $0.0.hasPrefix("b") ? "English (UK)" : "English (US)", gender: $0.1)
        }
        state.hdVoices = ["alba", "eve", "marius", "michael", "jean", "azelma"].map {
            VoiceInfo(id: $0, lang: "en", lang_label: "English", gender: "", section: "Pocket Voices")
        } + ["Sam", "Riley"].map {
            VoiceInfo(id: $0, lang: "en", lang_label: "English", gender: "", section: "✨ Cloned", needs_cloning: true)
        }
        state.hdInstalled = true
        state.cloningReady = true
        state.cloningInstalled = true
    }

    /// Host `view` in an off-screen window, let SwiftUI settle, and write a PNG.
    @MainActor
    private static func shoot<V: View>(_ view: V, width: CGFloat, height: CGFloat?,
                                       look: NSAppearance?, to url: URL) async -> Bool {
        let host = NSHostingView(rootView: view)
        let size = height.map { CGSize(width: width, height: $0) }
            ?? CGSize(width: width, height: host.fittingSize.height)
        // Titled windows go on screen (bottom-left of the main display, behind
        // nothing that matters for a second) so `screencapture` can see them.
        let origin = height == nil ? CGPoint(x: -4000, y: -4000)
            : CGPoint(x: (NSScreen.main?.visibleFrame.minX ?? 0) + 40, y: (NSScreen.main?.visibleFrame.minY ?? 0) + 40)
        let window = NSWindow(contentRect: NSRect(origin: origin, size: size),
                              styleMask: height == nil ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.appearance = look
        window.contentView = host
        window.orderFrontRegardless()
        if height != nil { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        // A few turns of the run loop: the sidebar, the async voice list and the
        // symbol effects all land after the first layout pass.
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(120))
            host.layoutSubtreeIfNeeded()
        }
        seed(AppState.shared)   // undo whatever the live backend returned meanwhile
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(120))
            host.layoutSubtreeIfNeeded()
        }
        if height == nil {   // the popover sizes to its content
            window.setContentSize(CGSize(width: width, height: host.fittingSize.height))
            host.layoutSubtreeIfNeeded()
        }
        // A titled window draws its toolbar and sidebar chrome only when it is
        // really on screen, so take that one with `screencapture` (needs the
        // Screen Recording grant for the terminal; falls back to cacheDisplay).
        if height != nil, onScreen(window) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l\(window.windowNumber)", url.path]
            try? p.run(); p.waitUntilExit()
            window.orderOut(nil)
            if p.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) { return true }
        }
        // Fallback for a titled window `screencapture` could not take: the
        // content only (cacheDisplay draws sidebar vibrancy wrong on the frame view).
        let target: NSView = host
        let bounds = target.bounds
        // Always 2x, whatever screen the off-screen window lands on: these images
        // go into the README and videos, where 1x looks soft.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2),
                                         pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        rep.size = bounds.size
        target.cacheDisplay(in: bounds, to: rep)
        window.orderOut(nil)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: url); return true } catch {
            print("uishot: \(url.lastPathComponent): \(error.localizedDescription)"); return false
        }
    }

    @MainActor private static func onScreen(_ w: NSWindow) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(w.frame) }
    }
}
