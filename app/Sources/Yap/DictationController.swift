import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Orchestrates the "ears": the dictation hot key, the live HUD, and inserting
/// the final text into whatever app you were in. Push-to-talk toggle — press to
/// start, press again to stop + insert.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    let dictation = Dictation()
    @Published private(set) var targetName = ""
    @Published private(set) var targetIcon: NSImage?

    private let hotkey = HotKeyManager(slot: 2)
    private var panel: NSPanel?
    private var targetObserver: Any?

    func bootstrap() {
        dictation.engineChoice = Dictation.EngineChoice(rawValue: Prefs.shared.dictationEngine) ?? .english
        hotkey.onFire = { [weak self] in self?.toggle() }
        hotkey.register(Prefs.shared.dictationHotKey)
        // Warm the model at launch (cached → fast; first ever launch downloads in
        // the background) so the first dictation isn't a cold load.
        Task { await dictation.loadModelAwaiting(dictation.engineChoice) }
    }

    /// Re-register after the user changes the dictation shortcut in Settings.
    func reapplyHotKey() { hotkey.register(Prefs.shared.dictationHotKey) }

    /// Short start/stop cue so you know recording began/ended without watching
    /// the screen (FluidVoice does this). Uses built-in macOS sounds.
    private func playChime(start: Bool) {
        guard Prefs.shared.dictationChime else { return }
        // Start: a bright "Tink" to cue recording. Stop: a soft "Pop" on insert —
        // unobtrusive, distinct from the start cue ("Bottle" was too heavy).
        NSSound(named: start ? "Tink" : "Pop")?.play()
    }

    /// Push-to-talk toggle.
    func toggle() {
        switch dictation.state {
        case .idle:
            captureTarget()
            startTargetTracking()    // keep target live if you switch apps
            showHUD()
            playChime(start: true)   // immediate "now recording" feedback
            Task {
                if !dictation.modelReady { await dictation.loadModelAwaiting(dictation.engineChoice) }
                guard dictation.modelReady else { return }   // load failed; HUD shows error
                dictation.startListening()
            }
        case .listening:
            playChime(start: false)
            Task {
                let text = await dictation.stopAndTranscribe()
                hideHUD()
                guard let text else { return }
                // Pasting fires a synthetic ⌘V, which needs Accessibility. Without
                // it the keystroke is dropped. Don't run the normal paste path then:
                // it would set the clipboard, fail to paste, and 0.6s later RESTORE
                // the old clipboard — wiping the dictated text. Instead leave the
                // text on the clipboard (no restore) so the user can ⌘V it manually,
                // and open the Accessibility pane so the next dictation just works.
                guard Permissions.axTrusted else {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    Permissions.requestAX()
                    Permissions.openAXSettings()
                    return
                }
                TextInsert.insertAtCursor(text)
            }
        case .loadingModel, .transcribing:
            break   // mid-flight — ignore re-trigger
        case .error:
            // Pressing the shortcut again clears a stuck error + dismisses the
            // HUD, instead of locking the app in the error state.
            dictation.clearError()
            hideHUD()
        }
    }

    /// Track the frontmost app — where the text will land. Polled while listening
    /// so switching apps mid-dictation updates the HUD *and* the paste target
    /// (⌘V always goes to the current frontmost app, so they stay in sync).
    /// Ignores Yap itself so our own HUD/menu never becomes the "target".
    private func captureTarget() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        targetName = app.localizedName ?? ""
        targetIcon = app.icon
    }

    private func startTargetTracking() {
        stopTargetTracking()
        // Event-driven (no polling): update the target the instant the frontmost
        // app changes while listening.
        targetObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.captureTarget() } }
    }

    private func stopTargetTracking() {
        if let targetObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(targetObserver)
            self.targetObserver = nil
        }
    }

    // MARK: - HUD panel

    private func showHUD() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 84),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
            p.level = .floating
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: DictationHUD(controller: self))
            panel = p
        }
        positionHUD()
        // orderFront (not makeKey) so focus stays in the user's target app.
        panel?.orderFrontRegardless()
    }

    private func hideHUD() { stopTargetTracking(); panel?.orderOut(nil) }

    private func positionHUD() {
        guard let panel, let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let size = panel.frame.size
        // Bottom-center, a little above the dock.
        let x = v.midX - size.width / 2
        let y = v.minY + 120
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Resize the panel to fit the HUD's natural height — keeping the bottom edge
    /// fixed so the box grows *upward* as more lines appear.
    func resizeHUD(height: CGFloat) {
        guard let panel else { return }
        let h = max(72, min(height, 320)).rounded()
        let f = panel.frame
        guard abs(f.height - h) > 0.5 else { return }
        panel.setFrame(NSRect(x: f.minX, y: f.minY, width: f.width, height: h),
                       display: true, animate: false)
    }
}

/// Combine the accurate rolling preview (`refined`) with the live streaming
/// transcript (`partial`) for the dictation HUD.
///
/// Both are full running transcripts of the same audio: `refined` (batch model)
/// lags ~1s but is accurate; `partial` (streaming model) has the newest words
/// instantly but is lossy. We show `refined` for the settled head and append
/// only the streaming words PAST where refined has reached, so the latest words
/// stream live and get absorbed + corrected on the next refine pass.
///
/// Finding the seam by raw word count alone duplicates or drops words when the
/// two models tokenize the same audio differently (punctuation, casing). So
/// anchor on refined's last two words (normalized) and locate them in `partial`,
/// appending only what follows. Fall back to the count split when no anchor
/// matches. Pure + deterministic — unit-tested in `Selftest`.
enum TranscriptStitch {
    static func merge(refined: String, partial: String) -> String {
        if refined.isEmpty { return partial }
        if partial.isEmpty { return refined }
        // Keep these as Substrings (no per-word String allocation) — merge runs
        // several times a second on the HUD's main thread.
        let r = refined.split(whereSeparator: { $0.isWhitespace })
        let p = partial.split(whereSeparator: { $0.isWhitespace })
        // Anchor on refined's last two words to find the seam inside partial.
        // Both anchors must be non-empty: a punctuation-only token (e.g. a stray
        // "." split off) normalizes to "" and would match anything — skip to the
        // count fallback instead of mis-anchoring.
        if r.count >= 2, p.count >= 2 {
            let a1 = norm(r[r.count - 2]), a2 = norm(r[r.count - 1])
            if !a1.isEmpty, !a2.isEmpty {
                var i = p.count - 2
                while i >= 0 {
                    if norm(p[i]) == a1, norm(p[i + 1]) == a2 {
                        let tail = i + 2
                        guard tail < p.count else { return refined }  // nothing new past the anchor
                        return refined + " " + p[tail...].joined(separator: " ")
                    }
                    i -= 1
                }
            }
        }
        // No anchor: append partial's words beyond refined's length (or trust
        // refined when the lossy model has produced fewer words).
        guard p.count > r.count else { return refined }
        return refined + " " + p[r.count...].joined(separator: " ")
    }

    /// Lowercase + strip surrounding punctuation so "World." anchors to "world".
    private static func norm(_ w: Substring) -> String {
        w.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}

/// Natural height of the transcript text (drives the in-box grow-then-scroll).
private struct TextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Natural height of the whole HUD (drives the panel resize).
private struct HUDHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The live transcript box: recording state, the words as they're recognized,
/// and where they'll be inserted.
struct DictationHUD: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var dictation: Dictation

    init(controller: DictationController) {
        self.controller = controller
        self.dictation = controller.dictation
    }

    // Transcript area grows line-by-line, then scrolls. Smaller 13pt text fits
    // more context on screen, so the cap holds ~5 lines before scrolling.
    @State private var textHeight: CGFloat = 20
    private let oneLine: CGFloat = 20
    private let maxTextHeight: CGFloat = 100   // ~5 lines at 13pt, then it scrolls

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                statusDot
                Text(statusLabel)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if controller.targetIcon != nil || !controller.targetName.isEmpty {
                    Text("→").font(.caption2).foregroundStyle(.secondary)
                    if let icon = controller.targetIcon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    Text(controller.targetName)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            transcript
        }
        .padding(14)
        .frame(width: 460, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
        // Report the box's natural height so the panel can grow/shrink to fit.
        .background(GeometryReader { g in
            Color.clear.preference(key: HUDHeightKey.self, value: g.size.height)
        })
        .onPreferenceChange(HUDHeightKey.self) { controller.resizeHUD(height: $0) }
    }

    /// Bottom-pinned scroll of the FULL transcript: the whole text slides up so
    /// the last lines stay visible (not just the tail of one line). The frame
    /// hugs the text up to maxTextHeight, then scrolls.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Text(transcriptText)
                    .font(.system(size: 13))
                    .foregroundStyle(displayText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: TextHeightKey.self, value: g.size.height)
                    })
                Color.clear.frame(height: 1).id("bottom")
            }
            .frame(height: min(max(textHeight, oneLine), maxTextHeight))
            // Only once the transcript actually overflows the box do we bottom-pin
            // and fade the top edge (where text is genuinely cut). While it's still
            // growing it fits and stays top-aligned — so no line is chopped AND no
            // legible line gets dimmed by the gradient.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: overflowing ? 30 : 0)
                    Color.black
                }
            }
            .onPreferenceChange(TextHeightKey.self) { h in
                // Snap (don't animate) the height: animating drove a native NSPanel
                // resize every frame (heavy on the window server). The box grows a
                // discrete line at a time and stays top-aligned while it fits, so
                // there's no clip to smooth over anyway.
                textHeight = h
            }
            .onChange(of: displayText) {
                // Keep the latest words visible only when scrolling (overflow); while
                // it still fits, top-alignment already shows everything.
                guard overflowing else { return }
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// The transcript is taller than the box — it scrolls, so the cut top edge
    /// needs the softening fade. Below this it fits and is shown in full.
    private var overflowing: Bool { textHeight > maxTextHeight + 1 }

    @ViewBuilder private var statusDot: some View {
        switch dictation.state {
        case .listening:   Circle().fill(.red).frame(width: 9, height: 9)
        case .loadingModel, .transcribing:
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 9, height: 9)
        case .error:       Circle().fill(.orange).frame(width: 9, height: 9)
        case .idle:        Circle().fill(.secondary).frame(width: 9, height: 9)
        }
    }

    private var statusLabel: String {
        switch dictation.state {
        case .idle:         return "Ready"
        case .loadingModel: return "Loading \(dictation.engineChoice.label) model…"
        case .listening:    return "Listening"
        case .transcribing: return "Transcribing…"
        case .error(let m): return m
        }
    }

    /// What the box shows: accurate head + live tail — see `TranscriptStitch`.
    private var displayText: String {
        TranscriptStitch.merge(refined: dictation.refined, partial: dictation.partial)
    }

    private var transcriptText: String {
        if case .error(let m) = dictation.state { return m }
        if displayText.isEmpty {
            return dictation.state == .listening ? "Speak now…" : " "
        }
        return displayText
    }
}
