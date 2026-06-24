import SwiftUI
import Carbon.HIToolbox

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            VoiceTab().tabItem { Label("Voice & Audio", systemImage: "waveform") }
            EngineTab().tabItem { Label("Engine", systemImage: "cpu") }
            CaptureTab().tabItem { Label("Capture", systemImage: "text.viewfinder") }
            CleanupTab().tabItem { Label("Cleanup", systemImage: "wand.and.stars") }
            ShortcutTab().tabItem { Label("Shortcut", systemImage: "command") }
            ModelsTab().tabItem { Label("Models", systemImage: "cube.box") }
            DiagnosticsTab().tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .padding(16)
        // Parley runs as an accessory (menu-bar only) app, whose windows can't
        // take keyboard focus — text fields (e.g. the custom-voice name) silently
        // reject typing. Promote to a regular app while Settings is open so its
        // window becomes key and accepts input, then drop back to accessory.
        .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var state: AppState
    var body: some View {
        Form {
            Picker("Read source", selection: $prefs.readSource) {
                ForEach(ReadSource.allCases) { Text($0.label).tag($0) }
            }
            Picker("Cleanup profile", selection: $prefs.profile) {
                ForEach(Profile.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Stop current speech when shortcut pressed again", isOn: $prefs.stopOnNewTrigger)
            Toggle("Keep model warm", isOn: $prefs.keepWarm)
            Toggle("Show mini-player controls", isOn: $prefs.showMiniPlayer)
            Toggle("Launch at login", isOn: $prefs.launchAtLogin)
                .onChange(of: prefs.launchAtLogin) { _, on in LoginItem.set(on) }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Voice & Audio

private struct VoiceTab: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Voice").font(.headline)
                Spacer()
                Button { state.testVoice() } label: { Label("Test", systemImage: "speaker.wave.2.fill") }
                    .controlSize(.small)
            }
            VoicePickerList(voices: state.combinedVoices, selectionId: state.currentVoiceId) {
                state.selectVoice($0)
            }
                .frame(minHeight: 220)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))

            Form {
                Section("Playback") {
                    slider("Speed", $prefs.speed, 0.5...2.0, "%.2f×")
                    slider("Pitch", $prefs.pitch, -600...600, "%.0f¢")
                    slider("Volume", $prefs.volume, 0...1, "%.0f%%", scale: 100)
                    slider("Pause", $prefs.pauseScale, 0...2.5, "%.2f×")
                }
            }
            .formStyle(.grouped)
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        _ fmt: String, scale: Double = 1) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: fmt, value.wrappedValue * scale))
                .font(.caption.monospacedDigit()).frame(width: 56, alignment: .trailing)
        }
    }
}

// MARK: - Engine (Kokoro / Chatterbox HD)

private struct EngineTab: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Prefs
    @StateObject private var recorder = VoiceRecorder()
    @State private var installing = false
    @State private var installLog = ""
    @State private var showImporter = false
    @State private var newName = ""
    @State private var fetching = false
    @State private var fetchLog = ""

    private var nameReady: Bool { !newName.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Form {
            Section("Voice engine") {
                Picker("Engine", selection: $prefs.engine) {
                    Text("Kokoro — instant, 54 voices").tag("kokoro")
                    Text("Chatterbox HD — natural, cloned voices").tag("chatterbox")
                }
                .pickerStyle(.radioGroup)
                Text("Kokoro runs on CPU and starts instantly. Chatterbox HD uses the GPU for noticeably more natural speech (a few seconds of startup), and lets you add your own voices by cloning a short clip. Switch any time — or just pick a voice from the dropdown.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if state.hdInstalled {
                Section {
                    Toggle("Pre-load HD model at launch", isOn: $prefs.autoLoadHD)
                    Text("Loads the HD voice in the background when the app starts, so your first HD read plays right away instead of a ~10-second cold start.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if prefs.engine == "chatterbox" {
                if !state.hdInstalled { enableSection } else { voicesSection; addSection; ethicsSection }
            } else {
                Section {
                    Label("Custom voice cloning lives in the Chatterbox HD engine. Select it above to add your own voices.",
                          systemImage: "wand.and.stars").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { state.refreshHD() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result {
                // addHDVoice owns the security-scoped access lifecycle (it reads
                // the file on a detached task). Starting/stopping it here would
                // revoke the sandbox extension before that task runs.
                state.addHDVoice(from: url, name: newName)
                newName = ""
            }
        }
    }

    // MARK: enable / download
    private var enableSection: some View {
        Section("Enable HD") {
            Text("HD mode downloads its engine once (~1.3 GB) into Application Support. It is not bundled, so the app stays small.")
                .font(.caption).foregroundStyle(.secondary)
            if installing {
                HStack { ProgressView().controlSize(.small); Text("Installing… keep this open").font(.caption) }
                ScrollView { Text(installLog).font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 110).border(.quaternary)
            } else {
                Button("Download & enable HD") {
                    installing = true; installLog = ""
                    Task {
                        await state.installHD { line in installLog += line + "\n" }
                        installing = false
                    }
                }.buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: voice list
    private var voicesSection: some View {
        Section("Your HD voices") {
            if state.hdVoices.isEmpty {
                Text("No voices yet. Add one below, or get the free starter pack.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(state.hdVoices) { v in
                HStack(spacing: 8) {
                    Image(systemName: prefs.hdVoice == v.id ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(prefs.hdVoice == v.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Text(v.id)
                    Spacer()
                    Button { prefs.engine = "chatterbox"; prefs.hdVoice = v.id; state.testVoice() } label: {
                        Image(systemName: "play.circle")
                    }.buttonStyle(.borderless).help("Test")
                    Button(role: .destructive) { state.deleteHDVoice(v.id) } label: {
                        Image(systemName: "trash")
                    }.buttonStyle(.borderless).help("Delete")
                }
                .contentShape(Rectangle())
                .onTapGesture { prefs.engine = "chatterbox"; prefs.hdVoice = v.id }
            }
        }
    }

    // MARK: add a voice
    private var addSection: some View {
        Section("Add a custom voice") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Step 1 — name this voice").font(.caption).bold().foregroundStyle(.secondary)
                TextField("Type a name, e.g. Sam", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(recorder.recording)   // don't let the name change mid-record
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Step 2 — add 10–20s of audio")
                    .font(.caption).bold()
                    .foregroundStyle(nameReady ? .secondary : .tertiary)
                HStack {
                    Button { showImporter = true } label: { Label("Import audio file…", systemImage: "square.and.arrow.down") }
                        .disabled(!nameReady || recorder.recording)
                    Button {
                        recorder.toggle { url in
                            if let url { state.addHDVoice(from: url, name: newName); newName = "" }
                        }
                    } label: {
                        Label(recorder.recording ? String(format: "Stop  %.0fs", recorder.elapsed) : "Record from mic",
                              systemImage: recorder.recording ? "stop.circle.fill" : "mic.circle")
                    }
                    .disabled(!nameReady && !recorder.recording)
                    .tint(recorder.recording ? .red : nil)
                }
                if !nameReady {
                    Text("Enter a name above to enable recording and importing.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if recorder.recording {
                ProgressView(value: recorder.elapsed, total: recorder.maxSeconds)
                Text("Speak naturally — it auto-stops at \(Int(recorder.maxSeconds))s.").font(.caption2).foregroundStyle(.secondary)
            }
            if recorder.denied {
                Text("Microphone access denied. Enable it in System Settings ▸ Privacy ▸ Microphone.")
                    .font(.caption).foregroundStyle(.red)
            }
            Text("Tip: 10–20 seconds of one clear voice, no music or background noise, gives the best clone.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                fetching = true; fetchLog = "fetching…\n"
                state.fetchStarterVoices { l in fetchLog += l + "\n"; if l.contains("[refreshed]") { fetching = false } }
            } label: { Label("Get free starter voices (CMU ARCTIC)", systemImage: "person.3") }
                .controlSize(.small).disabled(fetching)
            if fetching { ProgressView().controlSize(.small) }
        }
    }

    private var ethicsSection: some View {
        Section {
            Label("HD audio is watermarked (Resemble Perth) to mark it AI-generated. Only clone voices you have permission to use.",
                  systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Capture

private struct CaptureTab: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var state: AppState
    @State private var trusted = Permissions.axTrusted
    var body: some View {
        Form {
            Picker("Capture method", selection: $prefs.captureMode) {
                ForEach(CaptureMode.allCases) { Text($0.label).tag($0) }
            }
            Section("Accessibility permission") {
                HStack {
                    Image(systemName: trusted ? "checkmark.seal.fill" : "xmark.seal")
                        .foregroundStyle(trusted ? .green : .orange)
                    Text(trusted ? "Granted — Parley can read your selected text"
                                 : "Not granted")
                    Spacer()
                }
                HStack {
                    Button("Request access") { Permissions.requestAX() }
                    Button("Open Settings") { Permissions.openAXSettings() }
                    Button("Recheck") { trusted = Permissions.axTrusted }
                }
            }
            Section("Why this is needed") {
                Text("macOS only lets a trusted app read another app's selected text, and only a trusted app can simulate ⌘C for the clipboard fallback. That's the sole reason Parley asks.")
                    .font(.caption).foregroundStyle(.secondary)
                Label("No keylogging, no screen reading, nothing sent anywhere — it reads only the text you select and trigger. All local, all open source.",
                      systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Prefer no permission? Set Capture method or Read source to Clipboard, then copy text yourself before pressing the shortcut.")
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
        .onAppear { trusted = Permissions.axTrusted }
    }
}

// MARK: - Cleanup

private struct CleanupTab: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var state: AppState
    @State private var sample = "## Heading\n\nSee **the docs** [here](https://x.com) for `code`.\n- bullet one\n- bullet two\n\n$ echo hi  [1]"
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
                        Toggle("", isOn: $rule.enabled).labelsHidden()
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
            Text("Click a field, then press a modifier + key combination (e.g. ⌘⇧R).")
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            let mods = KeyName.carbonModifiers(ev.modifierFlags)
            guard mods != 0 else { return ev } // require a modifier
            let new = HotKeyCombo(keyCode: UInt32(ev.keyCode), modifiers: mods)
            // Reject a chord already bound to the other action — Carbon would
            // reject the duplicate registration and leave this shortcut dead.
            if new == conflictsWith {
                conflicted = true
                recording = false
                stopMonitor()
                return nil
            }
            combo = new
            onChange()
            recording = false
            stopMonitor()
            return nil
        }
    }
    private func stopMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
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
        let kPresent = state.modelsPresent, hdPresent = state.hdInstalled
        sizeTask?.cancel()   // supersede any in-flight walk; avoid redundant disk I/O
        let pdir = Dictation.modelsDirOnDisk
        let pPresent = Dictation.modelsPresentOnDisk
        sizeTask = Task {
            // static dirSizeBytes — no @MainActor state captured into this task.
            let kb = kPresent ? await Task.detached { AppState.dirSizeBytes(kdir) }.value : 0
            let hb = hdPresent ? await Task.detached { AppState.dirSizeBytes(hdir) }.value : 0
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
                    Text("Connected to a backend Parley didn't start — restart Parley to manage models.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let e = dl.error { Text(e).font(.caption).foregroundStyle(.red) }
                if dl.done { Text("Downloaded. Restart playback to load.").font(.caption).foregroundStyle(.green) }
            }
            Section {
                Text("Voices included: 54 across English, Spanish, French, Italian, Hindi, Japanese, Portuguese, and Chinese.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("HD model (Chatterbox)") {
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
                    Text("Optional ~1.3 GB engine for natural, cloned voices.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Download & install HD") {
                        hdInstalling = true; hdInstallLog = ""
                        Task {
                            await state.installHD { line in hdInstallLog += line + "\n" }
                            hdInstalling = false
                        }
                    }.buttonStyle(.borderedProminent)
                } else if state.backend.ownsProcess {
                    Button("Delete model", role: .destructive) { confirmDeleteHD = true }
                } else {
                    Text("Connected to a backend Parley didn't start — restart Parley to manage models.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Dictation model (Parakeet)") {
                Picker("Engine", selection: Binding(
                    get: { dictation.engineChoice },
                    set: { c in Task { await dictation.loadModel(c) } }
                )) {
                    ForEach(Dictation.EngineChoice.allCases) { Text($0.label).tag($0) }
                }
                .disabled(dictation.state == .listening || dictation.state == .loadingModel)

                LabeledContent("Status", value: parakeetStatus)
                if let s = parakeetSize { LabeledContent("Size on disk", value: s) }
                LabeledContent("Location", value: Dictation.modelsDirOnDisk.path).font(.caption)

                switch dictation.state {
                case .loadingModel:
                    HStack { ProgressView().controlSize(.small)
                        Text("Downloading / loading…").font(.caption) }
                case .error(let m):
                    Text(m).font(.caption).foregroundStyle(.red)
                    Button("Retry") { Task { await dictation.loadModel(dictation.engineChoice) } }
                default:
                    if parakeetPresent {
                        Button("Delete models", role: .destructive) { confirmDeleteParakeet = true }
                            // Tearing out the model mid-session would orphan the
                            // mic engine + pump; only allow it when idle.
                            .disabled(dictation.isListening || dictation.state == .transcribing)
                    } else {
                        Button("Download model") {
                            Task { await dictation.loadModel(dictation.engineChoice) }
                        }.buttonStyle(.borderedProminent)
                    }
                }
                Text("English uses Parakeet Flash (real-time streaming); Multilingual uses Nemotron streaming (25 languages). Downloaded on first use.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Dictation behavior") {
                Toggle("Play start/stop chime", isOn: $prefs.dictationChime)
                Toggle("Remove filler words (um, uh)", isOn: $prefs.removeFillers)
                Text("The chime cues recording on/off. Filler removal strips clear disfluencies from the inserted text (never meaningful words).")
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
            Text("Frees ~340 MB. Parley can't speak with Kokoro until you download it again.")
        }
        .confirmationDialog("Delete the HD model?", isPresented: $confirmDeleteHD, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { hdSize = nil; state.deleteHDModel() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees ~1.3 GB. Your cloned voices are kept; you can reinstall HD any time.")
        }
        .onChange(of: dictation.state) { _, _ in refreshSizes() }
        .confirmationDialog("Delete the dictation models?", isPresented: $confirmDeleteParakeet, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                parakeetSize = nil; parakeetPresent = false; dictation.deleteModelsFromDisk()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the downloaded Parakeet models. Dictation re-downloads them on next use.")
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
                        .appending(path: "parley_backend.log"))
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
                Button("Apply & restart engine") {
                    Task { state.backend.stop(); state.backend.ready = false
                           await state.backend.start(); await refresh() }
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
