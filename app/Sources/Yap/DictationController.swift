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
    private var panel: HUDPanel?
    /// Where the HUD's bottom-left corner belongs: the remembered spot, or home.
    /// The panel sits here whenever it fits, so growing near a screen edge and
    /// shrinking again brings it back instead of drifting.
    private var hudAnchor: NSPoint?
    /// Where the remembered spot is kept. Injectable so `--hudtest` can drag the
    /// HUD around without moving the user's.
    var hudDefaults: UserDefaults = .standard
    static let hudOriginKey = "dictationHUDOrigin"
    private var targetObserver: Any?
    /// Which HUD session is current. A delayed dismissal remembers the one that
    /// scheduled it and does nothing if a newer session has started since: it would
    /// otherwise hide the HUD (and clear the error) of a session whose mic is open.
    private var hudSession = 0
    /// Probe-only: how many delayed dismissals actually acted.
    private(set) var delayedDismissals = 0

    func bootstrap() {
        dictation.engineChoice = Dictation.EngineChoice(rawValue: Prefs.shared.dictationEngine) ?? .english
        hotkey.onFire = { [weak self] in self?.toggle() }
        reapplyHotKey()   // honors dictationEnabled — won't bind the hot key when ears are off
        // Warm the model at launch (cached → fast; first ever launch downloads in
        // the background) so the first dictation isn't a cold load. Skip entirely
        // when dictation is disabled — no point downloading/loading a model the
        // user turned off.
        if Prefs.shared.dictationEnabled {
            Task { await dictation.loadModelAwaiting(dictation.engineChoice) }
        }
    }

    /// Bind the dictation hot key only when the ears feature is enabled; otherwise
    /// fully unbind it so it can't fire by accident. Also called after the user
    /// changes the dictation shortcut in Settings.
    func reapplyHotKey() {
        if Prefs.shared.dictationEnabled { hotkey.register(Prefs.shared.dictationHotKey) }
        else { hotkey.unregister() }
    }

    /// Short start/stop cue so you know recording began/ended without watching
    /// the screen (FluidVoice does this). Uses built-in macOS sounds.
    private func playChime(start: Bool) {
        guard !Prefs.shared.muteAllSounds, Prefs.shared.dictationChime else { return }
        // Start: "Tink" cues recording. Stop: "Pop" confirms the mic has closed,
        // before transcription finishes; it cannot enter the recorded tail.
        NSSound(named: start ? "Tink" : "Pop")?.play()
    }

    /// Push-to-talk toggle.
    func toggle() {
        // An agent's listen owns the session: the shortcut ends it (the agent gets
        // the words, nothing is pasted unless it asked for that) instead of racing
        // it with a second, human start/stop.
        if let session = agentSession {
            session.stopReason = session.stopReason ?? "stopped"
            return
        }
        switch dictation.state {
        case .idle:
            captureTarget()
            startTargetTracking()    // keep target live if you switch apps
            hudSession += 1
            showHUD()
            playChime(start: true)   // immediate "now recording" feedback
            Task {
                if !dictation.modelReady { await dictation.loadModelAwaiting(dictation.engineChoice) }
                guard dictation.modelReady else { return }   // load failed; HUD shows error
                dictation.startListening()
            }
        case .listening:
            Task {
                let text = await dictation.stopAndTranscribe {
                    self.playChime(start: false)
                }
                guard let text else { hideHUD(); return }
                insertDictated(text)
            }
        case .loadingModel, .finishing, .transcribing:
            break   // mid-flight — ignore re-trigger
        case .error:
            // Pressing the shortcut again clears a stuck error + dismisses the
            // HUD, instead of locking the app in the error state.
            dictation.clearError()
            hideHUD()
        }
    }

    /// Record a finished dictation and paste it at the cursor.
    /// Returns whether the text was actually pasted: false when Accessibility is
    /// missing and it was only copied, so callers (the agent API) do not claim more.
    @discardableResult
    private func insertDictated(_ text: String, agent: Bool = false) -> Bool {
        // Log before we try to paste — a dictation that fails to insert
        // (no Accessibility, dropped ⌘V) is exactly what History rescues.
        HistoryStore.shared.recordDictated(text, detail: Self.historyDetail(target: targetName, agent: agent))
        if let simulatedPaste { stopTargetTracking(); simulatedPaste(text); return true }
        // Pasting fires a synthetic ⌘V, which needs Accessibility. Without
        // it the keystroke is dropped. Don't run the normal paste path then:
        // it would set the clipboard, fail to paste, and 0.6s later RESTORE
        // the old clipboard — wiping the dictated text. Instead leave the
        // text on the clipboard (no restore), keep the HUD up with a clear
        // message, and open the Accessibility pane so the next dictation
        // just works.
        guard Permissions.axTrusted else {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            dictation.note("Copied. Enable Accessibility for Yap, then ⌘V to paste.")
            Permissions.requestAX()
            Permissions.openAXSettings()
            dismissHUDLater(after: 5)
            return false
        }
        hideHUD()
        TextInsert.insertAtCursor(text)
        return true
    }

    /// Clear a lingering message and hide the HUD after a pause, unless a newer
    /// dictation session has begun by then.
    func dismissHUDLater(after seconds: Double) {
        let scheduledBy = hudSession
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hudSession == scheduledBy else { return }
                self.delayedDismissals += 1
                self.dictation.clearError()
                self.hideHUD()
            }
        }
    }

    // MARK: - agent listen (docs/AGENT-API.md, POST /listen)

    /// One agent's open microphone. `stopReason` is how it ends early: the
    /// shortcut, or `POST /listen/stop`.
    final class AgentSession {
        let insert: Bool
        var stopReason: String?
        init(insert: Bool) { self.insert = insert }
    }

    struct AgentListenResult: Equatable {
        var text: String
        /// "silence", "max_seconds" or "stopped".
        var reason: String
        var seconds: Double
        var inserted: Bool
    }

    private(set) var agentSession: AgentSession?

    /// How long a listen waits for the microphone to come up (the first run shows
    /// macOS's Microphone prompt). A variable so the probe can shorten it.
    static var startTimeout: TimeInterval = 45

    /// Probe-only (`--apitest`): feed audio from a file instead of the mic, and
    /// keep the HUD and chimes off the owner's screen and speakers. The real path
    /// (nil / false) always shows the HUD: the user must be able to SEE the mic is
    /// open, and no API parameter can turn that off.
    var simulatedCapture: ((Dictation) async throws -> Void)?
    var headless = false
    /// Probe-only (`--apitest`): receives the text instead of a real ⌘V, so the
    /// pasted path runs without touching the user's frontmost app or clipboard.
    var simulatedPaste: ((String) -> Void)?

    /// What History shows as a dictation's context. An agent's words are marked
    /// whether or not they were pasted, so they never pass for the user's own.
    nonisolated static func historyDetail(target: String, agent: Bool) -> String {
        guard agent else { return target }
        return target.isEmpty ? "Agent API" : "Agent API → \(target)"
    }

    /// Ask the running agent listen (if any) to end. False when there is none.
    @discardableResult
    func stopAgentListen(reason: String = "stopped") -> Bool {
        guard let s = agentSession else { return false }
        s.stopReason = s.stopReason ?? reason
        return true
    }

    /// Open dictation for an agent: HUD up, mic on, end on trailing silence, the
    /// time limit, or a stop request; then the accurate final pass, exactly as a
    /// hotkey stop does (`stopAndTranscribe`). The text goes back to the caller,
    /// and is pasted at the cursor only if `insert` is set.
    ///
    /// Cancelling the calling task (the client hung up, the API was switched off,
    /// listening was revoked) ends the session and DISCARDS the words.
    func listenForAgent(maxSeconds: Double, silenceSeconds: Double, insert: Bool) async -> Result<AgentListenResult, APIError> {
        guard Prefs.shared.dictationEnabled else {
            return .failure(APIError(403, "dictation_disabled", "Dictation is turned off in Yap's settings."))
        }
        // Another listen, or the human's own dictation, owns the mic.
        if agentSession != nil || dictation.state == .listening || dictation.state == .finishing || dictation.state == .transcribing {
            return .failure(APIError(409, "already_listening", "Yap is already listening. Wait for it to finish, or POST /listen/stop."))
        }
        if dictation.state == .loadingModel {
            return .failure(APIError(503, "model_loading", "The dictation model is still loading. Try again in a moment."))
        }
        let session = AgentSession(insert: insert)
        agentSession = session
        defer { agentSession = nil }
        if case .error = dictation.state { dictation.clearError() }

        hudSession += 1
        if insert { captureTarget(); startTargetTracking() }
        else { targetName = "Agent (not pasted)"; targetIcon = nil }
        if !headless { showHUD() }
        if !headless { playChime(start: true) }

        func abandon() { if !headless { hideHUD() } else { stopTargetTracking() } }

        if !dictation.modelReady { await dictation.loadModelAwaiting(dictation.engineChoice) }
        guard dictation.modelReady else {
            let why: String
            if case .error(let m) = dictation.state { why = m } else { why = "The dictation model is not available." }
            dictation.clearError(); abandon()
            return .failure(APIError(503, "model_unavailable", why))
        }
        // Asked to stop (or hung up) while the model loaded: never open the mic.
        if Task.isCancelled || session.stopReason != nil {
            abandon()
            return .success(AgentListenResult(text: "", reason: "stopped", seconds: 0, inserted: false))
        }
        do {
            if let simulatedCapture { try await simulatedCapture(dictation) }
            else { dictation.startListening() }
        } catch {
            abandon()
            return .failure(APIError(500, "listen_failed", "Could not start the capture: \(error.localizedDescription)"))
        }
        // The first run asks for Microphone access, so this wait is the user's to
        // answer; give it room. A stop or hang-up ends it at once (below): the
        // start-up token is cancelled, so the capture can no longer come up.
        let startBy = Date().addingTimeInterval(Self.startTimeout)
        while dictation.state != .listening {
            // Stopped or hung up while the mic is still coming up (often: the prompt is
            // open). Spend the start-up token now, so an "Allow" clicked later opens nothing.
            if Task.isCancelled || session.stopReason != nil {
                dictation.cancelStart()
                if dictation.state != .listening {
                    abandon()
                    return .success(AgentListenResult(text: "", reason: "stopped", seconds: 0, inserted: false))
                }
                break
            }
            if case .error(let m) = dictation.state {
                dictation.clearError(); abandon()
                return .failure(APIError(500, "listen_failed", m))
            }
            if Date() > startBy {
                // Give the start-up up for good: a Microphone prompt answered later
                // finds its token spent and opens nothing. (If it finished in the
                // same instant, the session is stopped here rather than left open.)
                dictation.cancelStart()
                if dictation.state == .listening { _ = await dictation.stopAndTranscribe() }
                abandon()
                return .failure(APIError(500, "listen_failed", "Microphone did not start in time."))
            }
            // Not Task.sleep in THIS task: once the caller hangs up it is cancelled, and
            // a cancelled sleep returns at once, which would spin this loop on the main actor.
            await Task { try? await Task.sleep(nanoseconds: 50_000_000) }.value
        }

        let began = Date()
        var reason = "max_seconds"
        var discard = false
        while true {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled || !Prefs.shared.agentListenEnabled { discard = true; break }
            if let r = session.stopReason { reason = r; break }
            guard dictation.state == .listening else { reason = "stopped"; break }
            if Date().timeIntervalSince(began) >= maxSeconds || dictation.recorderFull { reason = "max_seconds"; break }
            if dictation.speakerFinished(silence: silenceSeconds) { reason = "silence"; break }
        }
        let elapsed = Date().timeIntervalSince(began)

        // Its own task, never this one: a caller that hung up has cancelled THIS task,
        // and the final pass run under a cancelled task throws, which would leave
        // the session in an error state instead of closed (found by --apitest).
        let text = await Task { @MainActor [weak self] () -> String? in
            guard let self else { return nil }
            return await self.dictation.stopAndTranscribe { [weak self] in
                guard let self, !self.headless else { return }
                self.playChime(start: false)
            }
        }.value
        var stopError: String?
        if case .error(let m) = dictation.state { stopError = m; dictation.clearError() }
        if discard {
            abandon()
            return .success(AgentListenResult(text: "", reason: "stopped", seconds: elapsed, inserted: false))
        }
        guard let text, !text.isEmpty else {
            abandon()
            if let stopError { return .failure(APIError(500, "listen_failed", stopError)) }
            return .success(AgentListenResult(text: "", reason: reason, seconds: elapsed, inserted: false))
        }
        var pasted = false
        if insert {
            pasted = insertDictated(text, agent: true)
        } else {
            HistoryStore.shared.recordDictated(text, detail: "Agent API")
            abandon()
        }
        return .success(AgentListenResult(text: text, reason: reason, seconds: elapsed, inserted: pasted))
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
            let p = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 84),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
            p.level = .floating
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let host = NSHostingView(rootView: DictationHUD(controller: self))
            // `resizeHUD` owns the panel's size and place. Left on, the hosting
            // view also resizes the window to its content, from the top edge,
            // which nudged the panel up 3pt behind our back every time.
            host.sizingOptions = []
            p.contentView = host
            p.onDragEnd = { [weak self] in self?.settleHUD() }
            panel = p
        }
        positionHUD()
        // orderFront (not makeKey) so focus stays in the user's target app.
        panel?.orderFrontRegardless()
    }

    private func hideHUD() {
        stopTargetTracking()
        // Covers a drag whose mouse-up never reached us.
        if panel?.dragOrigin == nil { settleHUD() }
        panel?.orderOut(nil)
    }

    /// Probe-only (`--hudtest`): the real show and hide, without a session.
    func showHUDForProbe() -> HUDPanel? { showHUD(); return panel }
    func hideHUDForProbe() { hideHUD() }

    private var screens: [NSRect] { NSScreen.screens.map(\.visibleFrame) }

    private var savedHUDOrigin: NSPoint? {
        get { hudDefaults.string(forKey: Self.hudOriginKey).map(NSPointFromString) }
        set { hudDefaults.set(newValue.map(NSStringFromPoint), forKey: Self.hudOriginKey) }
    }

    /// The remembered spot, or bottom-center of the focused screen the first time.
    private func positionHUD() {
        guard let panel else { return }
        let size = panel.frame.size
        if let saved = savedHUDOrigin {
            hudAnchor = saved
        } else if let screen = NSScreen.main {
            hudAnchor = HUDPlacement.home(size: size, in: screen.visibleFrame)
        }
        panel.setFrameOrigin(onScreenOrigin(for: size))
    }

    /// The anchor, moved only as far as it takes to keep a panel of `size`
    /// wholly on a screen.
    private func onScreenOrigin(for size: NSSize) -> NSPoint {
        guard let panel else { return .zero }
        return HUDPlacement.onScreen(NSRect(origin: hudAnchor ?? panel.frame.origin, size: size),
                                     screens: screens)
    }

    /// The user let go of the HUD: bring it wholly back on screen if it was
    /// dropped past an edge, then remember that spot. Only a drag that moved it
    /// counts, so a plain click remembers nothing.
    private func settleHUD() {
        guard let panel, let from = panel.dragStart else { return }
        panel.dragStart = nil
        guard panel.frame.origin != from else { return }
        let origin = HUDPlacement.onScreen(panel.frame, screens: screens)
        if origin != panel.frame.origin { panel.setFrameOrigin(origin) }
        hudAnchor = origin
        savedHUDOrigin = origin
    }

    /// Resize the panel to fit the HUD's natural height — keeping the bottom edge
    /// fixed so the box grows *upward* as more lines appear.
    func resizeHUD(height: CGFloat) {
        guard let panel else { return }
        // Round UP (never below content) and add a 2pt cushion: rounding to
        // nearest could set the panel a hair shorter than the SwiftUI content,
        // and the material/shadow inset then clipped the top of the first row.
        let h = max(74, min(height.rounded(.up) + 2, 322))
        let f = panel.frame
        guard abs(f.height - h) > 0.5 else { return }
        // Mid-drag the panel follows the pointer: `f.origin` is where it was a
        // moment ago, and resizing there pulls it back out from under the hand.
        // At rest it goes back to its anchor, kept on screen at the new height.
        let size = NSSize(width: f.width, height: h)
        let o = panel.dragOrigin ?? onScreenOrigin(for: size)
        panel.setFrame(NSRect(origin: o, size: size), display: true, animate: false)
    }
}

/// The HUD's window. A press anywhere on it drags it: the HUD has no controls,
/// so a mouse-down can only mean "move this out of my way".
///
/// It used to rely on `isMovableByWindowBackground`. On macOS 27 that no longer
/// moves this window: the press goes to the SwiftUI content and the panel stays
/// where it is (`--hudtest --legacy` measures it). Starting the drag here does
/// not depend on how the content hit-tests.
final class HUDPanel: NSPanel {
    /// Probe-only (`--hudtest --legacy`): off restores the pre-fix behaviour.
    var dragsOnPress = true

    /// Runs once the user lets go, a turn later so `frame` has caught up.
    var onDragEnd: (() -> Void)?

    /// Where the panel was when the user pressed on it, until that drag is
    /// settled.
    var dragStart: NSPoint?

    /// Pointer minus frame origin, set for the length of a drag.
    private var grabOffset: CGSize?

    override func sendEvent(_ event: NSEvent) {
        if dragsOnPress, event.type == .leftMouseDown {
            let m = NSEvent.mouseLocation
            grabOffset = CGSize(width: m.x - frame.minX, height: m.y - frame.minY)
            if dragStart == nil { dragStart = frame.origin }
            performDrag(with: event)
            return
        }
        if event.type == .leftMouseUp, grabOffset != nil {
            grabOffset = nil
            DispatchQueue.main.async { [weak self] in self?.onDragEnd?() }
        }
        super.sendEvent(event)
    }

    /// Where the panel is while it is being dragged, nil when it is not. The
    /// window server moves a dragged window and AppKit hears about it late, so
    /// `frame` trails the pointer mid-drag (30pt in `--hudtest`); the pointer
    /// does not. The button check covers a mouse-up that never reached us.
    var dragOrigin: NSPoint? {
        guard let grabOffset, NSEvent.pressedMouseButtons & 1 != 0 else {
            self.grabOffset = nil
            return nil
        }
        let m = NSEvent.mouseLocation
        return NSPoint(x: m.x - grabOffset.width, y: m.y - grabOffset.height)
    }
}

/// Where the HUD may sit. Pure, so `--selftest` covers it.
enum HUDPlacement {
    /// Bottom-center of `visible`, a little above the dock.
    static func home(size: CGSize, in visible: CGRect) -> CGPoint {
        CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 120)
    }

    /// The origin nearest `frame`'s that puts all of it on one screen: the
    /// screen it overlaps most, or the closest one when it overlaps none (a
    /// remembered spot on a display that is gone). A remembered spot is the
    /// user's only way to lose the HUD, so it is never trusted as it stands.
    static func onScreen(_ frame: CGRect, screens: [CGRect]) -> CGPoint {
        func overlap(_ s: CGRect) -> CGFloat {
            let i = s.intersection(frame)
            return i.isNull ? 0 : i.width * i.height
        }
        func distance(_ s: CGRect) -> CGFloat {
            let dx = max(s.minX - frame.midX, 0, frame.midX - s.maxX)
            let dy = max(s.minY - frame.midY, 0, frame.midY - s.maxY)
            return dx * dx + dy * dy
        }
        guard let best = screens.max(by: { overlap($0) < overlap($1) }) else { return frame.origin }
        let s = overlap(best) > 0 ? best : screens.min(by: { distance($0) < distance($1) }) ?? best
        // max() last: a panel wider or taller than the screen keeps its origin
        // corner on it.
        return CGPoint(x: max(s.minX, min(frame.minX, s.maxX - frame.width)),
                       y: max(s.minY, min(frame.minY, s.maxY - frame.height)))
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
        // A live mic gets the ears gradient on the rim: you can tell from the
        // corner of your eye that Yap is listening.
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Brand.earsGradient, lineWidth: 1.5)
            .opacity(dictation.state == .listening ? 0.85 : 0))
        .animation(.easeOut(duration: 0.2), value: dictation.state == .listening)
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
        case .listening:
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Brand.earsGradient)
                .symbolEffect(.variableColor.iterative.reversing, isActive: true)
                .frame(width: 16, height: 12)
        case .finishing:   Circle().fill(Brand.magenta).frame(width: 9, height: 9)
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
        case .finishing:    return "Finishing…"
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
