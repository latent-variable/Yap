import SwiftUI
import AVFoundation
import Carbon.HIToolbox

/// One case per Settings pane. The sidebar, the pane header and `--selftest`
/// all read from here, so a new pane needs a case (and a group) to appear at
/// all, and the selftest catches a case left out of every group.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, shortcut, history, dictation, voice, cleanup, agents, capture, models, diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:     return "General"
        case .voice:       return "Voices"
        case .dictation:   return "Dictation"
        case .capture:     return "Permissions"
        case .cleanup:     return "Cleanup"
        case .shortcut:    return "Shortcuts"
        case .history:     return "History"
        case .agents:      return "Agents"
        case .models:      return "Models"
        case .diagnostics: return "Diagnostics"
        }
    }

    /// One line under the pane title: what this pane is for.
    var subtitle: String {
        switch self {
        case .general:     return "What's on, what it reads, how it sounds off."
        case .voice:       return "Pick an engine and a voice, clone your own, tune how it plays."
        case .dictation:   return "Language, sounds and filler words for push-to-talk."
        case .capture:     return "What Yap may read and hear, and how it grabs your selection."
        case .cleanup:     return "Strip Markdown, code and citations before they're spoken."
        case .shortcut:    return "Global keys for reading and dictating."
        case .history:     return "Everything you've read and dictated, kept on this Mac."
        case .agents:      return "Teach your AI agents to talk to you."
        case .models:      return "Download, check and delete each local model."
        case .diagnostics: return "Backend health, acceleration and capture checks."
        }
    }

    var icon: String {
        switch self {
        case .general:     return "gearshape.fill"
        case .voice:       return "waveform"
        case .dictation:   return "mic.fill"
        case .capture:     return "lock.shield.fill"
        case .cleanup:     return "wand.and.stars"
        case .shortcut:    return "command"
        case .history:     return "clock.arrow.circlepath"
        case .agents:      return "sparkles"
        case .models:      return "shippingbox.fill"
        case .diagnostics: return "stethoscope"
        }
    }

    /// The tile behind the icon, System Settings style.
    var tile: AnyShapeStyle {
        switch self {
        case .general:     return AnyShapeStyle(Color.gray.gradient)
        case .shortcut:    return AnyShapeStyle(Color.blue.gradient)
        case .history:     return AnyShapeStyle(Color.green.gradient)
        case .voice:       return AnyShapeStyle(Brand.voiceGradient)
        case .dictation:   return AnyShapeStyle(Brand.earsGradient)
        case .cleanup:     return AnyShapeStyle(Color.orange.gradient)
        case .capture:     return AnyShapeStyle(Color.teal.gradient)
        case .agents:      return AnyShapeStyle(Brand.gradient)
        case .models:      return AnyShapeStyle(Color.brown.gradient)
        case .diagnostics: return AnyShapeStyle(Color.red.gradient)
        }
    }

    /// Sidebar groups, in order. Every case belongs to exactly one.
    static let groups: [(title: String, tabs: [SettingsTab])] = [
        ("Yap", [.general, .shortcut, .history]),
        ("Ears", [.dictation]),
        ("Voice", [.voice, .cleanup]),
        ("Agents", [.agents]),
        ("System", [.capture, .models, .diagnostics]),
    ]
}

/// The coloured rounded-square icon used in the sidebar and the pane header.
struct SettingsIcon: View {
    let tab: SettingsTab
    var size: CGFloat = 22
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tab.tile)
            .frame(width: size, height: size)
            .overlay(Image(systemName: tab.icon)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

struct SettingsView: View {
    /// Window floor applied by the `Settings` scene in YapApp. The sidebar
    /// replaced the old nine-item tab bar, whose overflow chevron made the last
    /// tabs visible-but-unreachable below 760pt; a list has no such cliff.
    static let minSize = CGSize(width: 780, height: 540)

    @AppStorage("settingsPane") private var pane = SettingsTab.general

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(SettingsTab.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.tabs) { tab in
                            Label { Text(tab.title) } icon: { SettingsIcon(tab: tab, size: 20) }
                                .tag(tab)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
            .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                paneHeader
                pane.content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .navigationTitle(pane.title)
        }
        .tint(Brand.violet)
        // Keep "on" toggles visibly accent-colored even when the window isn't key
        // (Yap is a menu-bar accessory, so Settings is often inactive — stock
        // switches would gray out and you couldn't tell what's on). See StableToggleStyle.
        .toggleStyle(StableToggleStyle())
        // Yap runs as an accessory (menu-bar only) app, whose windows can't
        // take keyboard focus — text fields (e.g. the custom-voice name) silently
        // reject typing. Promote to a regular app while Settings is open so its
        // window becomes key and accepts input, then drop back to accessory.
        .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    private var paneHeader: some View {
        HStack(spacing: 12) {
            SettingsIcon(tab: pane, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title).font(Brand.title(20, .bold))
                Text(pane.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 4)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            BrandMark(size: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text("Yap").font(Brand.title(13, .bold))
                Text("v\(UpdateChecker.currentVersion)").lineLimit(1)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }
}

private extension SettingsTab {
    /// The pane body. Form panes bring their own grouped insets; the free-form
    /// panes get matching padding so every pane lines up under the header.
    @ViewBuilder var content: some View {
        switch self {
        case .general:     GeneralTab()
        case .voice:       VoicesPane()
        case .dictation:   DictationTab()
        case .capture:     PermissionsTab()
        case .cleanup:     CleanupTab().padding(.horizontal, 20).padding(.vertical, 12)
        case .shortcut:    ShortcutTab()
        case .history:     HistoryTab().padding(.horizontal, 20).padding(.vertical, 12)
        case .agents:      AgentsTab()
        case .models:      ModelsTab()
        case .diagnostics: DiagnosticsTab()
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var state: AppState
    var body: some View {
        Form {
            Section("Features") {
                Toggle("Reading aloud (voice)", isOn: $prefs.voiceEnabled)
                    .onChange(of: prefs.voiceEnabled) { _, _ in state.reapplyHotKey() }
                Toggle("Dictation (ears)", isOn: $prefs.dictationEnabled)
                    .onChange(of: prefs.dictationEnabled) { _, _ in DictationController.shared.reapplyHotKey() }
                Text("Turn a feature off to disable its global shortcut. The other keeps working. With Dictation on, its models load at launch and download if missing. While it is off, the menu's Dictate button and Settings ▸ Models can still download them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Cleanup profile", selection: $prefs.profile) {
                ForEach(Profile.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Stop current speech when shortcut pressed again", isOn: $prefs.stopOnNewTrigger)
            Toggle("Mute all sounds", isOn: $prefs.muteAllSounds)
            Text("Silences every cue at once — read-fail, HD buffering, and dictation start/stop — without touching their individual settings.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Play an error sound when a read fails", isOn: $prefs.failChime)
                .disabled(prefs.muteAllSounds)
            Text("A short cue when nothing can be read — empty or stale selection, or a window you haven't clicked into yet. Without it a failed shortcut is just silence.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Launch at login", isOn: $prefs.launchAtLogin)
                .onChange(of: prefs.launchAtLogin) { _, on in LoginItem.set(on) }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $prefs.autoUpdateCheck)
                Text("Once a day, Yap asks GitHub for the latest release version. This check sends no personal data. Turning it off stops update checks only. Dictation and Pocket models can still download at launch.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(state.checkingForUpdate ? "Checking…" : "Check now") {
                        state.checkForUpdatesNow()
                    }
                    .disabled(state.checkingForUpdate)
                    Spacer()
                    if let u = state.availableUpdate {
                        Link("Update \(u.version) available", destination: u.url)
                    } else if state.checkFailed {
                        Text("Couldn't check — check your connection").foregroundStyle(.secondary)
                    } else if state.checkedForUpdate {
                        Text("Up to date (\(UpdateChecker.currentVersion))").foregroundStyle(.secondary)
                    } else {
                        Text("v\(UpdateChecker.currentVersion)").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Dictation

private struct DictationTab: View {
    @ObservedObject private var dictation = DictationController.shared.dictation
    @ObservedObject private var prefs = Prefs.shared
    var body: some View {
        Form {
            Section {
                Picker("Language", selection: Binding(
                    get: { dictation.engineChoice },
                    set: { c in dictation.requestLoad(c) }
                )) {
                    ForEach(Dictation.EngineChoice.allCases) { Text($0.label).tag($0) }
                }
                .disabled(dictation.state == .listening || dictation.state == .finishing || dictation.state == .loadingModel)
                Text("English is fastest and most accurate for English. Multilingual understands 25 languages. Switching downloads that model pair if it is missing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("While you talk") {
                Toggle("Play start/stop chime", isOn: $prefs.dictationChime)
                Toggle("Remove filler words (um, uh)", isOn: $prefs.removeFillers)
                Text("The chime cues recording on and off. Filler removal strips clear disfluencies from the inserted text, never meaningful words.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("A live preview floats while you talk; drag it anywhere and it opens there next time. The final, more accurate transcript is pasted at your cursor, and every dictation is kept in History.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Permissions (capture)

private struct PermissionsTab: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var state: AppState
    @State private var trusted = Permissions.axTrusted
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    var body: some View {
        Form {
            Section("Permissions") {
                permissionRow("Accessibility", granted: trusted,
                              detail: trusted ? "Yap can read your selected text and paste dictation."
                                              : "Needed to read your selection and paste dictation.") {
                    Button("Grant") { Permissions.requestAX(); Permissions.openAXSettings() }
                    Button("Recheck") { trusted = Permissions.axTrusted }
                }
                permissionRow("Microphone", granted: mic == .authorized,
                              detail: mic == .authorized ? "Dictation can hear you." : "Needed for dictation and recording a voice to clone.") {
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                    Button("Recheck") { mic = AVCaptureDevice.authorizationStatus(for: .audio) }
                }
            }
            Section {
                Picker("Read source", selection: $prefs.readSource) {
                    ForEach(ReadSource.allCases) { Text($0.label).tag($0) }
                }
                Picker("Capture method", selection: $prefs.captureMode) {
                    ForEach(CaptureMode.allCases) { Text($0.label).tag($0) }
                }
                Text("Read source decides WHAT is read: your selection, your clipboard, or Auto (selection, then clipboard for terminals that hide it). Capture method decides HOW a selection is grabbed. Clipboard needs no permission: copy first, then press the shortcut.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Reading your selection")
            }
            Section("Why Yap asks") {
                Label("No keylogging, no screen reading, nothing sent anywhere. Yap reads only the text you select and trigger, and hears only while you dictate. All local, all open source.",
                      systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Last capture") {
                LabeledContent("Method", value: state.lastMethod.rawValue)
                if !state.lastCaptured.isEmpty {
                    Text(state.lastCaptured).font(.caption).lineLimit(4)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: recheck)
        // Coming back from System Settings is when a grant changes, either way.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in recheck() }
    }

    private func recheck() {
        trusted = Permissions.axTrusted
        mic = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    private func permissionRow<B: View>(_ name: String, granted: Bool, detail: String,
                                        @ViewBuilder buttons: () -> B) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(granted ? .green : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { buttons() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name): \(granted ? "granted" : "not granted")")
    }
}

// MARK: - Cleanup

private struct CleanupTab: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var state: AppState
    @State private var sample = "## Heading\n\nWe show **the result** [1, 2] holds [here](https://x.com), see also [9, 10, 11].\n- bullet one\n- bullet two\n\n$ echo hi  [1]"
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview").font(.headline)
            HStack(spacing: 10) {
                VStack(alignment: .leading) {
                    Text("Original").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $sample).font(.caption.monospaced())
                        .frame(height: 110).border(.quaternary)
                }
                VStack(alignment: .leading) {
                    Text("Spoken").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        Text(cleaned).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 110).border(.quaternary)
                }
            }
            Picker("Profile", selection: $prefs.profile) {
                ForEach(Profile.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)

            HStack {
                Text("Custom regex rules").font(.headline)
                Spacer()
                Button {
                    prefs.customRules.append(CleanRule(name: "New rule", pattern: "", replacement: ""))
                } label: { Image(systemName: "plus") }
            }
            List {
                ForEach($prefs.customRules) { $rule in
                    HStack(spacing: 6) {
                        // Compact inline switch in a fixed-width row — keep the
                        // stock style so it doesn't claim the row's flexible width.
                        Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch)
                        TextField("name", text: $rule.name).frame(width: 90)
                        TextField("pattern", text: $rule.pattern).font(.caption.monospaced())
                        TextField("→ repl", text: $rule.replacement).font(.caption.monospaced()).frame(width: 90)
                        Button(role: .destructive) {
                            prefs.customRules.removeAll { $0.id == rule.id }
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 90)
        }
    }
    private var cleaned: String {
        Preprocess.clean(sample, options: Preprocess.options(for: prefs.profile), custom: prefs.customRules)
    }
}

// MARK: - Shortcut

private struct ShortcutTab: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var state: AppState
    var body: some View {
        Form {
            Section("Global read shortcut") {
                HStack {
                    Text("Read selection"); Spacer()
                    HotKeyRecorder(combo: $prefs.hotKey, conflictsWith: prefs.dictationHotKey) {
                        state.reapplyHotKey()
                    }
                }
                Text("Reads the selected text aloud (text → speech).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Global dictation shortcut") {
                HStack {
                    Text("Dictate"); Spacer()
                    HotKeyRecorder(combo: $prefs.dictationHotKey, conflictsWith: prefs.hotKey) {
                        DictationController.shared.reapplyHotKey()
                    }
                }
                Text("Press to start dictating, press again to insert (speech → text).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Click a field, then press a modifier + key (e.g. ⌘⇧R) — or hold two or more modifiers together and release for a modifier-only chord (e.g. ⌥⌘, the “Alt+Win” press).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

/// Records the next modifier+key chord into a HotKeyCombo.
private struct HotKeyRecorder: View {
    @Binding var combo: HotKeyCombo
    /// The OTHER action's chord — recording the same one is rejected (it would
    /// fail to register and silently disable this shortcut).
    var conflictsWith: HotKeyCombo? = nil
    var onChange: () -> Void
    @State private var recording = false
    @State private var conflicted = false
    @State private var monitor: Any?
    @State private var peakMods: UInt32 = 0   // largest modifier set held this recording

    var body: some View {
        Button {
            recording.toggle()
            recording ? startMonitor() : stopMonitor()
        } label: {
            Text(recording ? "Press keys…" : (conflicted ? "Already in use" : KeyName.describe(combo)))
                .font(.body.monospaced())
                .frame(minWidth: 110)
                .foregroundStyle(conflicted ? Color.orange : Color.primary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(recording ? Color.accentColor.opacity(0.2) : Color(.quaternaryLabelColor),
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onDisappear { stopMonitor() }
    }

    private func startMonitor() {
        conflicted = false
        peakMods = 0
        // Two recording paths share one monitor:
        //  • keyDown  → a normal modifier+key chord (e.g. ⌘⇧R).
        //  • flagsChanged → a modifier-only chord (e.g. ⌥⌘). We watch the
        //    modifiers build up, then commit when they're all released.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { ev in
            if ev.type == .flagsChanged {
                let mods = KeyName.carbonModifiers(ev.modifierFlags)
                if mods == 0 {
                    // All modifiers released — commit if a ≥2-modifier chord was held.
                    let chord = HotKeyCombo(keyCode: 0, modifiers: peakMods)
                    if chord.isModifierOnly { commit(chord) }
                    peakMods = 0
                } else if popcount(mods) >= popcount(peakMods) {
                    peakMods = mods   // track the richest set held so far
                }
                return ev
            }
            // keyDown path
            let mods = KeyName.carbonModifiers(ev.modifierFlags)
            guard mods != 0 else { return ev } // require a modifier
            commit(HotKeyCombo(keyCode: UInt32(ev.keyCode), modifiers: mods))
            return nil
        }
    }

    /// Apply a recorded combo, rejecting a duplicate of the other action's chord
    /// (Carbon would reject the dup and silently disable this shortcut).
    private func commit(_ new: HotKeyCombo) {
        if new == conflictsWith {
            conflicted = true
        } else {
            combo = new
            onChange()
        }
        recording = false
        stopMonitor()
    }

    private func popcount(_ m: UInt32) -> Int { m.nonzeroBitCount }

    private func stopMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        peakMods = 0
    }
}

// MARK: - History

private struct HistoryTab: View {
    @ObservedObject private var history = HistoryStore.shared
    // Dictation is the more-used half, so it leads and is the default view.
    @State private var kind: HistoryEntry.Kind = .dictated
    @State private var query = ""
    @State private var expanded: Set<UUID> = []
    @State private var confirmClear = false

    private var entries: [HistoryEntry] {
        let all = kind == .spoken ? history.spoken : history.dictated
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $kind) {
                Text("Dictated (\(history.dictated.count))").tag(HistoryEntry.Kind.dictated)
                Text("Spoken (\(history.spoken.count))").tag(HistoryEntry.Kind.spoken)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query).textFieldStyle(.plain)
                Spacer()
                Button(role: .destructive) { confirmClear = true } label: {
                    Label("Clear", systemImage: "trash")
                }
                .controlSize(.small)
                // Clear wipes the whole list (not the filtered view), so gate only
                // on the underlying list — a search query must not re-enable it.
                .disabled((kind == .spoken ? history.spoken : history.dictated).isEmpty)
            }

            if entries.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(entries) { entry in
                        HistoryRow(entry: entry,
                                   isExpanded: expanded.contains(entry.id),
                                   toggle: { toggleExpand(entry.id) },
                                   delete: { delete(entry) })
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 240)
            }

            Text(kind == .spoken
                 ? "Everything Yap has read aloud, newest first. Kept locally so a passage is never lost; copy any entry to re-read it."
                 : "Everything you've dictated, newest first. If a paste ever fails, recover the text here.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .confirmationDialog(
            kind == .spoken ? "Clear spoken history?" : "Clear dictated history?",
            isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                kind == .spoken ? history.clearSpoken() : history.clearDictated()
                expanded.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes all \(kind == .spoken ? "spoken" : "dictated") entries. This can't be undone.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: query.isEmpty ? "clock" : "magnifyingglass")
                .font(.largeTitle).foregroundStyle(.tertiary)
            Text(query.isEmpty
                 ? (kind == .spoken ? "Nothing read aloud yet." : "Nothing dictated yet.")
                 : "No matches.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private func toggleExpand(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func delete(_ entry: HistoryEntry) {
        expanded.remove(entry.id)
        history.delete(entry)
    }
}

/// One history entry: timestamp + context, the text (tap to expand), and
/// copy / delete actions.
private struct HistoryRow: View {
    let entry: HistoryEntry
    let isExpanded: Bool
    let toggle: () -> Void
    let delete: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Tap-to-expand lives only on the timestamp/chevron cluster — not the
            // whole header (which would swallow the Copy/Delete button taps) and
            // not the body text (which would fight `.textSelection`).
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    if !entry.detail.isEmpty {
                        Text("· \(entry.detail)").font(.caption).foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { toggle() }

                Spacer()
                Button { copy() } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless).help("Copy")
                Button(role: .destructive) { delete() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless).help("Delete")
            }

            Text(entry.text)
                .font(.callout)
                .lineLimit(isExpanded ? nil : 2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

// MARK: - Models

private struct ModelsTab: View {
    @EnvironmentObject var state: AppState
    // Owned by AppState so a download survives closing the Settings window.
    @ObservedObject private var dl = AppState.shared.downloader
    @State private var confirmDeleteKokoro = false
    @State private var confirmDeleteHD = false
    @State private var hdInstalling = false
    @State private var hdInstallLog = ""
    @State private var kokoroSize: String?
    @State private var hdSize: String?
    @State private var sizeTask: Task<Void, Never>?
    @ObservedObject private var dictation = DictationController.shared.dictation
    @ObservedObject private var prefs = Prefs.shared
    @State private var parakeetSize: String?
    @State private var parakeetPresent = false
    @State private var confirmDeleteParakeet = false

    private static let sizeFmt: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.allowedUnits = [.useMB, .useGB]; f.countStyle = .file
        return f
    }()

    /// Walk model dirs off the main actor (can be large) and cache the formatted
    /// sizes — never size a directory inside the SwiftUI body.
    private func refreshSizes() {
        let kdir = state.backend.modelsDir, hdir = state.hdPackagesDir
        // Deleting Pocket reclaims the cloning weights too, so the figure here has
        // to include them. Counting only hd-packages understated it by 209 MB and
        // made the delete look like it freed more than it claimed.
        let wdir = state.hdVoicesDir.deletingLastPathComponent().appending(path: "pocket-weights")
        let kPresent = state.modelsPresent, hdPresent = state.hdInstalled
        sizeTask?.cancel()   // supersede any in-flight walk; avoid redundant disk I/O
        let pdir = Dictation.modelsDirOnDisk
        let pPresent = Dictation.modelsPresentOnDisk
        sizeTask = Task {
            // static dirSizeBytes — no @MainActor state captured into this task.
            let kb = kPresent ? await Task.detached { AppState.dirSizeBytes(kdir) }.value : 0
            let hb = hdPresent ? await Task.detached {
                AppState.dirSizeBytes(hdir) + AppState.dirSizeBytes(wdir)
            }.value : 0
            let pb = pPresent ? await Task.detached { AppState.dirSizeBytes(pdir) }.value : 0
            if Task.isCancelled { return }
            kokoroSize = kb > 0 ? Self.sizeFmt.string(fromByteCount: kb) : nil
            hdSize = hb > 0 ? Self.sizeFmt.string(fromByteCount: hb) : nil
            parakeetPresent = pPresent
            parakeetSize = pb > 0 ? Self.sizeFmt.string(fromByteCount: pb) : nil
        }
    }

    var body: some View {
        Form {
            Section("Kokoro model") {
                LabeledContent("Status",
                    value: state.modelsPresent ? "Installed" : "Not installed")
                if state.modelsPresent, let s = kokoroSize {
                    LabeledContent("Size on disk", value: s)
                }
                LabeledContent("Location", value: state.backend.modelsDir.path)
                    .font(.caption)
                if state.deletingKokoro {
                    HStack { ProgressView().controlSize(.small); Text("Deleting model…").font(.caption) }
                } else if dl.downloading {
                    ProgressView(value: dl.progress) { Text(dl.statusText).font(.caption) }
                } else if !state.modelsPresent {
                    Button("Download model (~340 MB)") { dl.start() }
                } else if state.backend.ownsProcess {
                    Button("Delete model", role: .destructive) { confirmDeleteKokoro = true }
                } else {
                    Text("Connected to a backend Yap didn't start — restart Yap to manage models.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let e = dl.error { Text(e).font(.caption).foregroundStyle(.red) }
                if dl.done { Text("Downloaded. Restart playback to load.").font(.caption).foregroundStyle(.green) }
            }
            Section {
                Text("Voices included: 54 across English, Spanish, French, Italian, Hindi, Japanese, Portuguese, and Chinese.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Pocket model") {
                LabeledContent("Status",
                    value: state.hdInstalled ? "Installed" : "Not installed")
                if state.hdInstalled, let s = hdSize {
                    LabeledContent("Size on disk", value: s)
                }
                LabeledContent("Location", value: state.hdPackagesDir.path)
                    .font(.caption)
                if state.deletingHD {
                    HStack { ProgressView().controlSize(.small); Text("Deleting model…").font(.caption) }
                } else if hdInstalling {
                    HStack { ProgressView().controlSize(.small); Text("Installing… keep this open").font(.caption) }
                    ScrollView { Text(hdInstallLog).font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 90).border(.quaternary)
                } else if !state.hdInstalled {
                    Text("Optional ~1 GB engine for natural built-in voices and cloning. Its model files download when Pocket first loads.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Download & install Pocket") {
                        hdInstalling = true; hdInstallLog = ""
                        Task {
                            await state.installHD { line in hdInstallLog += line + "\n" }
                            hdInstalling = false
                        }
                    }.buttonStyle(.borderedProminent)
                } else if state.backend.ownsProcess {
                    Button("Delete model", role: .destructive) { confirmDeleteHD = true }
                } else {
                    Text("Connected to a backend Yap didn't start — restart Yap to manage models.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if state.hdInstalled {
                Section {
                    Toggle("Pre-load Pocket at launch", isOn: $prefs.autoLoadHD)
                    Text("Loads Pocket in the background at launch, so the first read plays right away. It always loads at launch when Pocket is the active engine. Missing model files download when it loads.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Dictation models") {
                Picker("Engine", selection: Binding(
                    get: { dictation.engineChoice },
                    set: { c in dictation.requestLoad(c) }
                )) {
                    ForEach(Dictation.EngineChoice.allCases) { Text($0.label).tag($0) }
                }
                .disabled(dictation.state == .listening || dictation.state == .finishing || dictation.state == .loadingModel)

                LabeledContent("Status", value: parakeetStatus)
                if let s = parakeetSize { LabeledContent("Size on disk", value: s) }
                LabeledContent("Location", value: Dictation.modelsDirOnDisk.path).font(.caption)

                switch dictation.state {
                case .loadingModel:
                    HStack { ProgressView().controlSize(.small)
                        Text("Downloading / loading…").font(.caption) }
                case .error(let m):
                    Text(m).font(.caption).foregroundStyle(.red)
                    Button("Retry") { dictation.requestLoad(dictation.engineChoice) }
                default:
                    if parakeetPresent {
                        Button("Delete models", role: .destructive) { confirmDeleteParakeet = true }
                            // Tearing out the model mid-session would orphan the
                            // mic engine + pump; only allow it when idle.
                            .disabled(dictation.isListening || dictation.state == .finishing || dictation.state == .transcribing)
                    } else {
                        Button("Download model") {
                            dictation.requestLoad(dictation.engineChoice)
                        }.buttonStyle(.borderedProminent)
                    }
                }
                Text("English uses Parakeet Flash (streaming) and Parakeet TDT v2 (final); Multilingual uses Nemotron (streaming) and Parakeet TDT v3 (final). The selected pair downloads at launch when Dictation is on, or when you request it here.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            }
        .formStyle(.grouped)
        .onAppear { state.refreshHD(); refreshSizes() }
        .onChange(of: state.modelsPresent) { _, _ in refreshSizes() }
        .onChange(of: state.hdInstalled) { _, _ in refreshSizes() }
        .onChange(of: hdInstalling) { _, _ in refreshSizes() }
        .onChange(of: dl.done) { _, done in
            if done { state.reloadAfterKokoroDownload(); refreshSizes() }
        }
        .confirmationDialog("Delete the Kokoro model?", isPresented: $confirmDeleteKokoro, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { kokoroSize = nil; state.deleteKokoroModel() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees ~340 MB. Yap can't speak with Kokoro until you download it again.")
        }
        .confirmationDialog("Delete the Pocket model?", isPresented: $confirmDeleteHD, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { hdSize = nil; state.deleteHDModel() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees ~1 GB. Your cloned voices are kept; you can reinstall Pocket any time.")
        }
        .onChange(of: dictation.state) { _, _ in refreshSizes() }
        .confirmationDialog("Delete the dictation models?", isPresented: $confirmDeleteParakeet, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                parakeetSize = nil; parakeetPresent = false; dictation.deleteModelsFromDisk()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the downloaded dictation models. They download again at launch when Dictation is on, or the next time you dictate or pick a model.")
        }
    }

    private var parakeetStatus: String {
        if dictation.modelReady { return "Loaded (\(dictation.engineChoice.label))" }
        return parakeetPresent ? "Downloaded" : "Not downloaded"
    }
}

// MARK: - Diagnostics

private struct DiagnosticsTab: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Prefs
    @State private var health = "checking…"
    @State private var activeProvider = "—"
    @State private var availableProviders = "—"
    var body: some View {
        Form {
            Section("Backend") {
                LabeledContent("Ready", value: state.backend.ready ? "yes" : "no")
                LabeledContent("Health", value: health)
                if let e = state.backend.lastError { Text(e).font(.caption).foregroundStyle(.red) }
                Button("Recheck") { Task { await refresh() } }
                Button("Open backend log") {
                    NSWorkspace.shared.open(FileManager.default.temporaryDirectory
                        .appending(path: "yap_backend.log"))
                }
            }
            Section("Acceleration") {
                Picker("Compute", selection: $prefs.providerMode) {
                    Text("Auto (CPU — fastest for Kokoro)").tag("auto")
                    Text("CPU").tag("cpu")
                    Text("CoreML (GPU / Neural Engine)").tag("coreml")
                }
                LabeledContent("Active", value: activeProvider)
                LabeledContent("Available", value: availableProviders)
                Text("Kokoro is small (82M); the vectorized CPU path benchmarks as fast as or faster than CoreML. Changing this restarts the engine.")
                    .font(.caption).foregroundStyle(.secondary)
                // restart() (not stop() + start()): stop() only sends SIGTERM, so the
                // old backend is still answering /health when start() runs, gets
                // reused as-is — the new provider never applied — and then exits,
                // leaving port 8766 dead. restart() awaits stopAndWait() first.
                Button("Apply & restart engine") {
                    Task { await state.backend.restart(); await refresh() }
                }
            }
            Section("Capture") {
                LabeledContent("Accessibility trusted", value: Permissions.axTrusted ? "yes" : "no")
                LabeledContent("Last method", value: state.lastMethod.rawValue)
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
    }
    private func refresh() async {
        if let h = await state.backend.client.health() {
            health = "\(h.status) · model \(h.model_loaded ? "loaded" : "off") · \(h.sample_rate) Hz"
            activeProvider = (h.active_providers?.first ?? "unknown")
                .replacingOccurrences(of: "ExecutionProvider", with: "")
            availableProviders = (h.available_providers ?? [])
                .map { $0.replacingOccurrences(of: "ExecutionProvider", with: "") }
                .joined(separator: ", ")
        } else { health = "unreachable" }
    }
}
