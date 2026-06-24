import SwiftUI

struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Prefs
    @Environment(\.openSettings) private var openSettings

    /// Open Settings and force it to the front, even when the app is an
    /// accessory (no dock icon) and the window is already buried behind others.
    private func showSettings() {
        // Promote to a regular app so the Settings window can become key and
        // accept keyboard input (accessory windows can't). SettingsView drops
        // back to .accessory on close.
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

            Divider()

            sectionLabel("Voice", "speaker.wave.2.fill")

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

            Divider()

            HStack {
                Text("Read shortcut")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(KeyName.describe(prefs.hotKey))
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }

            if !state.lastCleaned.isEmpty {
                preview
            }

            Divider()

            sectionLabel("Ears", "waveform.badge.mic")
            DictationRow()

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

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: state.status.symbol)
                .font(.title3)
                .foregroundStyle(statusColor)
                .symbolEffect(.pulse, isActive: state.status == .reading)
            VStack(alignment: .leading, spacing: 1) {
                Text("Parley").font(.headline)
                Text(state.preparing ? state.preparingDetail : state.status.label)
                    .font(.caption).foregroundStyle(.secondary)
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

    private var preview: some View {
        DisclosureGroup("Last read") {
            ScrollView {
                Text(state.lastCleaned)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 80)
            HStack {
                Text(state.lastMethod == .none ? "" : "via \(state.lastMethod.rawValue)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.lastCleaned, forType: .string)
                }.controlSize(.mini)
                Button("Export WAV") { state.exportWAV() }.controlSize(.mini)
            }
        }
        .font(.caption)
    }

    private var statusColor: Color {
        switch state.status {
        case .reading: return .accentColor
        case .paused: return .orange
        case .error: return .red
        case .loadingModel: return .blue
        default: return .secondary
        }
    }

    /// Small header that separates the Voice (TTS) and Ears (dictation) halves.
    private func sectionLabel(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2)
            Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(0.5)
            Spacer()
        }
        .foregroundStyle(.secondary)
    }

}

/// Dictation ("ears") controls in the menu: toggle, live state, engine picker.
struct DictationRow: View {
    @ObservedObject private var controller = DictationController.shared
    @ObservedObject private var dictation = DictationController.shared.dictation
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button { controller.toggle() } label: {
                    Label(buttonLabel, systemImage: buttonIcon)
                }
                .buttonStyle(.borderless)
                .help("Dictate — press, speak, press again to insert")
                Spacer()
                Text(KeyName.describe(prefs.dictationHotKey))
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
            HStack {
                Text("Dictation engine").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { dictation.engineChoice },
                    set: { choice in Task { await dictation.loadModel(choice) } }
                )) {
                    ForEach(Dictation.EngineChoice.allCases) { c in
                        Text(c.label).tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .disabled(dictation.state == .listening)
            }

            if !dictation.lastFinal.isEmpty {
                lastDictation
            }
        }
    }

    /// Quick retrieval of the most recent dictation — for when a paste landed in
    /// the wrong place (or didn't). Copy it, or re-insert at the current cursor.
    private var lastDictation: some View {
        DisclosureGroup("Last dictation") {
            ScrollView {
                Text(dictation.lastFinal)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 70)
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(dictation.lastFinal, forType: .string)
                }.controlSize(.mini)
                Button("Insert") { TextInsert.insertAtCursor(dictation.lastFinal) }
                    .controlSize(.mini)
            }
        }
        .font(.caption)
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
