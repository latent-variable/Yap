import SwiftUI

/// The two halves of Yap: ears (dictation) first — used most often — then
/// voice (text-to-speech). Persisted so the popover reopens where you left it.
enum MenuTab: String { case ears, voice }

/// The menu-bar popover. Every block here has a size that does not depend on
/// timing or on a scroll position: `.menuBarExtraStyle(.window)` sizes the
/// popover to this content, and a size that never settles turns into a
/// self-sustaining layout loop (AGENTS.md, "Menu-bar UI"). No ScrollView, no
/// text selection, no timers.
@MainActor
struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Prefs
    @ObservedObject private var dictation = DictationController.shared.dictation
    @Environment(\.openSettings) private var openSettings
    // @AppStorage binds directly to the RawRepresentable enum — no separate raw
    // string + computed property needed.
    @AppStorage("menuTab") private var tab = MenuTab.ears

    static let width: CGFloat = 320

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

            if let update = state.availableUpdate {
                updateBanner(update)
            }

            if !state.axTrusted && prefs.readSource == .selection {
                permissionBanner
            }

            PillSwitch(selection: $tab, options: [
                (MenuTab.ears, "Ears", "mic.fill", Brand.earsGradient),
                (MenuTab.voice, "Voice", "speaker.wave.2.fill", Brand.voiceGradient),
            ])

            Group {
                if tab == .ears { EarsSection() } else { voiceSection }
            }

            footer
        }
        .padding(14)
        .frame(width: Self.width)
        // A faint wash of the brand colour behind the header. Fixed height and
        // pinned to the top, so it can never feed back into the popover's size.
        .background(alignment: .top) {
            LinearGradient(colors: [(tab == .ears ? Brand.magenta : Brand.violet).opacity(0.16), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
                .allowsHitTesting(false)
        }
        .tint(tab == .ears ? Brand.magenta : Brand.violet)
        .onAppear { state.refreshHD() }   // pick up newly added HD voices
    }

    // MARK: Header + footer

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(size: 36, active: busy)
            VStack(alignment: .leading, spacing: 0) {
                Text("Yap").font(Brand.title(17, .bold))
                Text("Voice & ears, all local")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
            }
            Spacer(minLength: 6)
            if !state.modelsPresent && !state.preparing {
                Button {
                    // Land on the pane with the Download button, not the last one used.
                    UserDefaults.standard.set(SettingsTab.models.rawValue, forKey: "settingsPane")
                    showSettings()
                } label: {
                    StatusPill(text: state.kokoroDownloading ? "Getting voice" : "Set up",
                               color: .orange, busy: state.kokoroDownloading)
                }
                .buttonStyle(.plain)
                .help(state.kokoroDownloading
                      ? "Downloading the Kokoro voice. Progress is in Settings ▸ Models"
                      : "Models not installed. Open Settings ▸ Models")
            } else {
                StatusPill(text: statusText, color: statusColor, busy: busy)
                    .frame(maxWidth: 140, alignment: .trailing)
            }
        }
    }

    /// One status for the whole app: dictation outranks reading, because a
    /// live mic is the thing you most need to see.
    private var statusText: String {
        switch dictation.state {
        case .listening:    return "Listening"
        case .finishing:    return "Finishing"
        case .transcribing: return "Transcribing"
        case .loadingModel: return "Loading ears"
        case .error:        return "Dictation error"
        case .idle:         break
        }
        if state.preparing { return state.preparingDetail }
        switch state.status {
        case .idle:         return "Ready"
        case .loadingModel: return "Loading voice"
        case .capturing:    return "Capturing"
        case .reading:      return "Reading"
        case .paused:       return "Paused"
        case .error:        return "Error"
        }
    }

    private var statusColor: Color {
        switch dictation.state {
        case .listening, .finishing, .transcribing: return Brand.magenta
        case .loadingModel: return .orange
        case .error:        return .red
        case .idle:         break
        }
        if state.preparing { return Brand.violet }
        switch state.status {
        case .idle:                  return .green
        case .reading, .capturing:   return Brand.violet
        case .paused, .loadingModel: return .orange
        case .error:                 return .red
        }
    }

    private var busy: Bool {
        dictation.state == .listening || dictation.state == .transcribing
            || dictation.state == .finishing || state.status == .reading || state.preparing
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { showSettings() } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Spacer()
            Text("v\(UpdateChecker.currentVersion)")
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(GhostIconButtonStyle(size: 24))
            .help("Quit Yap")
            .accessibilityLabel("Quit Yap")
        }
        .font(.callout)
        .padding(.top, 2)
    }

    // MARK: Voice (text-to-speech)

    private var reading: Bool { state.status == .reading || state.status == .paused }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Who is speaking, and the big button.
            HStack(spacing: 12) {
                Button {
                    if reading { state.togglePlayPause() } else { state.triggerRead() }
                } label: {
                    Image(systemName: state.status == .reading ? "pause.fill" : "play.fill")
                        .offset(x: state.status == .reading ? 0 : 2)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(OrbButtonStyle(gradient: Brand.voiceGradient, glow: Brand.violet))
                .accessibilityLabel(state.status == .reading ? "Pause"
                                    : state.status == .paused ? "Resume" : "Read selection")
                .help(reading ? "Pause or resume" : "Read the selected text aloud")

                VStack(alignment: .leading, spacing: 5) {
                    Text(voiceHeadline).font(Brand.title(15)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text("Select text, press").font(.caption).foregroundStyle(.secondary)
                        ShortcutChip(combo: prefs.hotKey)
                    }
                }
                Spacer(minLength: 0)
                if reading {
                    Button { state.stop() } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(GhostIconButtonStyle())
                        .help("Stop reading")
                        .accessibilityLabel("Stop reading")
                }
            }
            .glassCard(radius: 14, padding: 12)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    VoiceMenuButton(voices: state.combinedVoices, selectionId: state.currentVoiceId,
                                    engine: prefs.engine, pocketAvailable: state.hdInstalled,
                                    onSelectEngine: { state.selectEngine($0) }) {
                        state.selectVoice($0)
                    }
                    Button { state.testVoice() } label: {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                    .buttonStyle(GhostIconButtonStyle())
                    .help("Test voice")
                    .accessibilityLabel("Test voice")
                }

                HStack(spacing: 8) {
                    Image(systemName: "hare.fill").font(.caption).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Slider(value: $prefs.speed, in: 0.5...2.0, step: 0.05)
                        .controlSize(.small)
                        .accessibilityLabel("Speed")
                    Text(String(format: "%.2f×", prefs.speed))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .frame(width: 40, alignment: .trailing)
                }
            }
            .glassCard()

            if !state.lastCleaned.isEmpty {
                LastResultCard(title: "Last read", icon: "text.quote", text: state.lastCleaned) {
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

    private var voiceHeadline: String {
        switch state.status {
        case .reading:   return "Reading aloud"
        case .paused:    return "Paused"
        case .capturing: return "Grabbing text…"
        default:         return state.preparing ? "Warming up…" : "Read anything"
        }
    }

    // MARK: Banners

    /// Shown when a newer release exists. Yap installs via Homebrew or a DMG, so
    /// there's no in-app installer — the button opens the release page (notes +
    /// download); brew users just `brew upgrade`.
    private func updateBanner(_ update: UpdateChecker.Release) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Update available — \(update.version)", systemImage: "arrow.down.circle.fill")
                .font(.caption.bold()).foregroundStyle(Brand.violet)
            Text("You're on \(UpdateChecker.currentVersion). Update with “brew upgrade yap”, or download the new release.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Release notes & download") { NSWorkspace.shared.open(update.url) }
                .buttonStyle(CapsuleButtonStyle(gradient: Brand.voiceGradient))
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Brand.violet.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Accessibility needed to read selected text", systemImage: "lock.shield")
                .font(.caption.bold()).foregroundStyle(.orange)
            Text("Grant access, or switch Read source to Clipboard (copy first, then press the shortcut — no permission needed).")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Grant Access") { Permissions.requestAX(); Permissions.openAXSettings() }
                    .controlSize(.small).buttonStyle(.borderedProminent).tint(.orange)
                Button("Use Clipboard") { prefs.readSource = .clipboard }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Shared pieces

/// Key-combo keycaps used wherever a shortcut is shown in the menu.
struct ShortcutChip: View {
    let combo: HotKeyCombo
    var body: some View {
        Text(KeyName.describe(combo))
            .font(.caption.monospaced().weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
            .accessibilityLabel("Shortcut \(KeyName.describe(combo))")
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
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help("Copy to clipboard")
    }
}

/// Compact card showing the most recent result with inline actions — replaces
/// the old disclosure dropdown so copying is a single click.
struct LastResultCard<Actions: View>: View {
    let title: String
    var icon = "text.quote"
    let text: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title.uppercased(), systemImage: icon)
                .font(.caption2.weight(.semibold)).tracking(0.4)
                .foregroundStyle(.secondary)
            // Fixed-height, line-limited, truncated — NOT a ScrollView. A
            // ScrollView here (plus .textSelection) made the MenuBarExtra(.window)
            // content renegotiate its size on every display cycle, so CoreAnimation
            // relaid the whole menu back-to-back forever: a self-sustaining
            // MenuBarExtraLayout loop that pinned the main thread (~continuous CPU)
            // and made every menu-bar click lag. A deterministic size lets layout
            // converge. The full text is one click away via the Copy button in
            // `actions`, so losing in-card scroll/selection costs little.
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(height: 54, alignment: .top)
                .clipped()
            HStack(spacing: 10) {
                actions()
            }
        }
        .glassCard()
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

    private var listening: Bool { dictation.state == .listening }
    private var working: Bool {
        dictation.state == .loadingModel || dictation.state == .finishing || dictation.state == .transcribing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { controller.toggle() } label: {
                    Image(systemName: listening ? "stop.fill" : "mic.fill")
                        .symbolEffect(.pulse, isActive: listening)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(OrbButtonStyle(gradient: Brand.earsGradient, glow: Brand.magenta))
                .accessibilityLabel(listening ? "Stop and insert" : "Dictate")
                .help("Dictate — press, speak, press again to insert")

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(headline).font(Brand.title(15)).lineLimit(1)
                        if listening {
                            Image(systemName: "waveform")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Brand.earsGradient)
                                .symbolEffect(.variableColor.iterative.reversing, isActive: true)
                                .accessibilityHidden(true)
                        } else if working {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    if case .error(let message) = dictation.state {
                        // The reason, not just "it failed": one line, full text on hover.
                        Text(message)
                            .font(.caption).foregroundStyle(.red)
                            .lineLimit(1).truncationMode(.tail)
                            .help(message)
                    } else {
                        HStack(spacing: 6) {
                            Text(listening ? "Press again to insert" : "Press, talk, press again")
                                .font(.caption).foregroundStyle(.secondary)
                            ShortcutChip(combo: prefs.dictationHotKey)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .glassCard(radius: 14, padding: 12)

            HStack {
                Label("Language", systemImage: "globe")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Picker("Language", selection: Binding(
                    get: { dictation.engineChoice },
                    set: { choice in dictation.requestLoad(choice) }
                )) {
                    ForEach(Dictation.EngineChoice.allCases) { c in
                        Text(c.label).tag(c)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(listening || working)
            }
            .glassCard(padding: 8)

            if !dictation.lastFinal.isEmpty {
                LastResultCard(title: "Last dictation", icon: "text.bubble", text: dictation.lastFinal) {
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

    private var headline: String {
        switch dictation.state {
        case .listening:    return "Listening…"
        case .loadingModel: return "Loading model…"
        case .finishing:    return "Finishing…"
        case .transcribing: return "Transcribing…"
        case .error:        return "Try again"
        case .idle:         return "Dictate anywhere"
        }
    }
}
