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

    func bootstrap() {
        dictation.engineChoice = Dictation.EngineChoice(rawValue: Prefs.shared.dictationEngine) ?? .english
        hotkey.onFire = { [weak self] in self?.toggle() }
        hotkey.register(Prefs.shared.dictationHotKey)
        // Warm the model at launch (cached → fast; first ever launch downloads in
        // the background) so the first dictation isn't a cold load.
        Task { await dictation.loadModel(dictation.engineChoice) }
    }

    /// Re-register after the user changes the dictation shortcut in Settings.
    func reapplyHotKey() { hotkey.register(Prefs.shared.dictationHotKey) }

    /// Push-to-talk toggle.
    func toggle() {
        switch dictation.state {
        case .idle:
            captureTarget()
            showHUD()
            Task {
                if !dictation.modelReady { await dictation.loadModel(dictation.engineChoice) }
                guard dictation.modelReady else { return }   // load failed; HUD shows error
                dictation.startListening()
            }
        case .listening:
            Task {
                let text = await dictation.stopAndTranscribe()
                hideHUD()
                if let text { TextInsert.insertAtCursor(text) }
            }
        case .loadingModel, .transcribing, .error:
            break   // mid-flight — ignore re-trigger
        }
    }

    /// Remember the frontmost app *before* we show the (non-activating) HUD, so
    /// the HUD can show where the text will land.
    private func captureTarget() {
        if let app = NSWorkspace.shared.frontmostApplication {
            targetName = app.localizedName ?? ""
            targetIcon = app.icon
        } else {
            targetName = ""; targetIcon = nil
        }
    }

    // MARK: - HUD panel

    private func showHUD() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 120),
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

    private func hideHUD() { panel?.orderOut(nil) }

    private func positionHUD() {
        guard let panel, let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let size = panel.frame.size
        // Bottom-center, a little above the dock.
        let x = v.midX - size.width / 2
        let y = v.minY + 120
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
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
            Text(transcriptText)
                .font(.system(size: 15))
                .foregroundStyle(dictation.partial.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
                .animation(.easeOut(duration: 0.12), value: dictation.partial)
        }
        .padding(14)
        .frame(width: 460, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
    }

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

    private var transcriptText: String {
        if case .error(let m) = dictation.state { return m }
        if dictation.partial.isEmpty {
            return dictation.state == .listening ? "Speak now…" : " "
        }
        return dictation.partial
    }
}
