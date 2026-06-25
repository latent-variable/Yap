import SwiftUI

/// The two halves of Yap: ears (dictation) first — used most often — then
/// voice (text-to-speech). Persisted so the popover reopens where you left it.
enum MenuTab: String { case ears, voice }

struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Prefs
    @Environment(\.openSettings) private var openSettings
    // @AppStorage binds directly to the RawRepresentable enum — no separate raw
    // string + computed property needed.
    @AppStorage("menuTab") private var tab = MenuTab.ears

    /// Open Settings and force it to the front, even when the app is an
    /// accessory (no dock icon) and the window is already buried behind others.
    private func showSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            for window in NSApp.windows where window.styleMask.contains(.titled) {
                window.collectionBehavior.insert(.moveToActiveSpace)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !state.axTrusted && prefs.readSource == .selection {
                permissionBanner
            }

            Picker("", selection: $tab) {
                Label("Ears", systemImage: "waveform.badge.mic").tag(MenuTab.ears)
                Label("Voice", systemImage: "speaker.wave.2.fill").tag(MenuTab.voice)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                if tab == .ears { EarsSection() } else { voiceSection }
            }

            Divider()

            HStack {
                Button { showSettings() } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { state.refreshHD() }   // pick up newly added HD voices
    }

    // MARK: Voice (text-to-speech)

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VoiceMenuButton(voices: state.combinedVoices, selectionId: state.currentVoiceId) {
                    state.selectVoice($0)
                }
                Button { state.testVoice() } label: {
                    Image(systemName: "speaker.wave.2.fill")
                }
                .buttonStyle(.borderless)
                .help("Test voice")
            }

            VStack(spacing: 4) {
                HStack {
                    Text("Speed").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.2f×", prefs.speed)).font(.caption.monospacedDigit())
                }
                Slider(value: $prefs.speed, in: 0.5...2.0, step: 0.05)
            }

            transport

            HStack {
                Text("Read shortcut").font(.caption).foregroundStyle(.secondary)
                Spacer()
                ShortcutChip(combo: prefs.hotKey)
            }

            if !state.lastCleaned.isEmpty {
                LastResultCard(title: "Last read", text: state.lastCleaned) {
                    if state.lastMethod != .none {
                        Text("via \(state.lastMethod.rawValue)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    CopyButton(text: state.lastCleaned)
                    Button { state.exportWAV() } label: {
                        Label("WAV", systemImage: "square.and.arrow.down").font(.caption2)
                    }.buttonStyle(.borderless).help("Export spoken audio")
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            brandMark
            VStack(alignment: .leading, spacing: 1) {
                Text("Yap").font(.headline)
                Text(state.preparing ? state.preparingDetail : state.status.label)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if state.preparing {
                ProgressView().controlSize(.small)
            } else if !state.modelsPresent {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    .help("Models not installed — open Settings ▸ Models")
            }
        }
    }

    /// App glyph in a tinted rounded badge — echoes the indigo gradient of the
    /// app/menu-bar icon so the popover reads as the same product.
    private var brandMark: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(red: 0.44, green: 0.49, blue: 1.0),
                         Color(red: 0.29, green: 0.24, blue: 0.84)],
                startPoint: .top, endPoint: .bottom))
            .frame(width: 34, height: 34)
            .overlay(
                Image(systemName: state.status.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: state.status == .reading)
            )
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Accessibility needed to read selected text", systemImage: "lock.shield")
                .font(.caption.bold()).foregroundStyle(.orange)
            Text("Grant access, or switch Read source to Clipboard (copy first, then press the shortcut — no permission needed).")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Grant Access") { Permissions.requestAX(); Permissions.openAXSettings() }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                Button("Use Clipboard") { prefs.readSource = .clipboard }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var transport: some View {
        HStack(spacing: 16) {
            Button { state.togglePlayPause() } label: {
                Image(systemName: state.status == .paused ? "play.fill" : "pause.fill")
                    .font(.title2)
            }
            .disabled(state.status != .reading && state.status != .paused)

            Button { state.stop() } label: {
                Image(systemName: "stop.fill").font(.title2)
            }
            .disabled(state.status != .reading && state.status != .paused)

            Spacer()

            Button { state.triggerRead() } label: {
                Label("Read selection", systemImage: "text.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }
}

// MARK: - Shared pieces

/// Monospaced key-combo pill used wherever a shortcut is shown in the menu.
struct ShortcutChip: View {
    let combo: HotKeyCombo
    var body: some View {
        Text(KeyName.describe(combo))
            .font(.caption.monospaced())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
    }
}

/// One-click copy with a brief "Copied" checkmark — no menu, no expand.
struct CopyButton: View {
    let text: String
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
        }
        .buttonStyle(.borderless)
        .help("Copy to clipboard")
    }
}

/// Compact card showing the most recent result with inline actions — replaces
/// the old disclosure dropdown so copying is a single click.
struct LastResultCard<Actions: View>: View {
    let title: String
    let text: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Bounded scroll, not lineLimit: with .textSelection enabled, selecting
            // the text makes SwiftUI ignore lineLimit and expand to full height,
            // which would cover the Settings/Quit buttons. A fixed max height clips
            // it for good — long results scroll inside the card instead.
            ScrollView {
                Text(text)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 56)
            HStack(spacing: 10) {
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                actions()
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Section header (kept for any future use / accessibility labelling).
func menuSectionLabel(_ title: String, _ icon: String) -> some View {
    HStack(spacing: 5) {
        Image(systemName: icon).font(.caption2)
        Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(0.5)
        Spacer()
    }
    .foregroundStyle(.secondary)
}

// MARK: - Ears (dictation)

/// Dictation controls: toggle, live state, engine picker, one-click last result.
/// @MainActor so its @ObservedObject main-actor singletons initialize cleanly
/// under strict concurrency.
@MainActor
struct EarsSection: View {
    @ObservedObject private var controller = DictationController.shared
    @ObservedObject private var dictation = DictationController.shared.dictation
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { controller.toggle() } label: {
                    Label(buttonLabel, systemImage: buttonIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Dictate — press, speak, press again to insert")
                Spacer()
                ShortcutChip(combo: prefs.dictationHotKey)
            }

            HStack {
                Text("Engine").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { dictation.engineChoice },
                    set: { choice in dictation.requestLoad(choice) }
                )) {
                    ForEach(Dictation.EngineChoice.allCases) { c in
                        Text(c.label).tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .disabled(dictation.state == .listening || dictation.state == .loadingModel)
            }

            if !dictation.lastFinal.isEmpty {
                LastResultCard(title: "Last dictation", text: dictation.lastFinal) {
                    Spacer()
                    CopyButton(text: dictation.lastFinal)
                    Button { TextInsert.insertAtCursor(dictation.lastFinal) } label: {
                        Label("Insert", systemImage: "text.cursor").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("Paste at the current cursor")
                }
            }
        }
    }

    private var buttonLabel: String {
        switch dictation.state {
        case .listening:    return "Stop & Insert"
        case .loadingModel: return "Loading model…"
        case .transcribing: return "Transcribing…"
        default:            return "Dictate"
        }
    }

    private var buttonIcon: String {
        switch dictation.state {
        case .listening: return "stop.circle.fill"
        default:         return "mic.fill"
        }
    }
}
