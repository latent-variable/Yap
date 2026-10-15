import SwiftUI

/// Settings ▸ Voices: pick the engine, then one of its voices, then tune how it
/// plays. Cloning lives here too, behind one visible button, instead of at the
/// bottom of an engine page.
///
/// The engine cards choose which engine's voices you are LOOKING at. Picking an
/// installed engine also makes it the active one; picking Pocket before it is
/// installed only shows its setup card, so the app never sits on an engine that
/// cannot speak.
struct VoicesPane: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Prefs
    @State private var viewing: String?
    @State private var installing = false
    @State private var installLog = ""
    @State private var cloning = false
    @State private var pendingDelete: EngineVoice?

    private var shown: String { viewing ?? prefs.engine }

    // Not a Form: the voice list scrolls itself to the current voice, and inside
    // a Form that scroll moved the whole pane and hid the engine cards.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    EngineCard(title: "Kokoro", tagline: "Instant", detail: "54 voices · 8 languages",
                               icon: "bolt.fill", gradient: Brand.voiceGradient,
                               selected: shown == "kokoro", active: prefs.engine == "kokoro",
                               badge: nil) { pick("kokoro") }
                    EngineCard(title: "Pocket", tagline: "Natural", detail: "26 voices · cloning",
                               icon: "sparkles", gradient: Brand.gradient,
                               selected: shown == "pocket", active: prefs.engine == "pocket",
                               badge: state.hdInstalled ? nil : "Set up") { pick("pocket") }
                }
                Text("Both run on this Mac's CPU. Kokoro starts instantly; Pocket sounds more human and can clone a voice from a short clip.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if shown == "pocket" && !state.hdInstalled {
                pocketSetup.glassCard(padding: 14)
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(shown == "pocket" ? "Pocket voices" : "Kokoro voices").font(.headline)
                        Spacer()
                        Button { state.testVoice() } label: { Label("Preview voice", systemImage: "play.fill") }
                            .buttonStyle(.borderless)
                            .disabled(shown != prefs.engine)
                        if shown == "pocket" {
                            Button { cloning = true } label: { Label("Clone a voice", systemImage: "plus") }
                                .buttonStyle(CapsuleButtonStyle(gradient: Brand.gradient))
                        }
                    }
                    VoicePickerList(voices: state.combinedVoices, selectionId: state.currentVoiceId,
                                    engine: shown, pocketAvailable: false,
                                    onSelectEngine: { state.selectEngine($0) },
                                    onDelete: shown == "pocket" ? { pendingDelete = $0 } : nil,
                                    // Picks the voice and plays it: the sample is always
                                    // spoken in the selected voice.
                                    onPreview: { state.selectVoice($0); state.testVoice() }) {
                        state.selectVoice($0)
                    }
                    .padding(6)
                    .frame(minHeight: 180, maxHeight: .infinity)
                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Playback").font(.headline)
                VStack(spacing: 8) {
                    slider("Speed", $prefs.speed, 0.5...2.0, "%.2f×")
                    slider("Pitch", $prefs.pitch, -600...600, "%.0f¢")
                    slider("Volume", $prefs.volume, 0...1, "%.0f%%", scale: 100)
                    slider("Pause", $prefs.pauseScale, 0...2.5, "%.2f×")
                }
                .glassCard()
            }
        }
        .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 16)
        .onAppear { state.refreshHD() }
        // A cloned voice is the user's own recording and nothing can download it
        // again, so deleting one asks first.
        .confirmationDialog("Delete the voice “\(pendingDelete?.label ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { v in
            Button("Delete", role: .destructive) { state.deleteHDVoice(v.voiceId); pendingDelete = nil }
        } message: { _ in
            Text("Its reference recording moves to the Trash, so you can still restore it from there.")
        }
        .sheet(isPresented: $cloning) {
            CloneVoiceSheet().environmentObject(state).environmentObject(prefs)
        }
    }

    private func pick(_ engine: String) {
        withAnimation(.easeOut(duration: 0.15)) { viewing = engine }
        if engine == "kokoro" || state.hdInstalled { state.selectEngine(engine) }
    }

    private var pocketSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set up Pocket").font(.headline)
            Text("Pocket downloads its engine once (about 1 GB) into Application Support, so the app itself stays small. Its voices download the first time it loads, and voice cloning adds one 209 MB file. No account.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if installing {
                HStack { ProgressView().controlSize(.small); Text("Installing… keep this window open").font(.caption) }
                ScrollView { Text(installLog).font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 110).border(.quaternary)
            } else {
                Button {
                    installing = true; installLog = ""
                    Task {
                        await state.installHD { line in installLog += line + "\n" }
                        installing = false
                        if state.hdInstalled { state.selectEngine("pocket") }
                    }
                } label: { Label("Download & enable Pocket", systemImage: "arrow.down.circle.fill") }
                .buttonStyle(CapsuleButtonStyle(gradient: Brand.gradient))
            }
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        _ fmt: String, scale: Double = 1) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading)
            Slider(value: value, in: range).accessibilityLabel(label)
            Text(String(format: fmt, value.wrappedValue * scale))
                .font(.caption.monospacedDigit()).frame(width: 56, alignment: .trailing)
        }
    }
}

/// One selectable engine: a tile with its icon, name, one-word character and
/// what it offers. The ring marks the engine you are looking at; the "In use"
/// tag marks the one Yap speaks with.
private struct EngineCard: View {
    let title: String, tagline: String, detail: String, icon: String
    let gradient: LinearGradient
    let selected: Bool, active: Bool
    let badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(gradient)
                    .frame(width: 36, height: 36)
                    .overlay(Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(Brand.title(15, .bold))
                        Text(tagline).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let badge {
                    Text(badge).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.18), in: Capsule())
                } else if active {
                    Text("In use").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(gradient))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(.primary.opacity(selected ? 0.07 : 0.03),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(gradient) : AnyShapeStyle(.primary.opacity(0.1)),
                              lineWidth: selected ? 2 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) engine, \(tagline). \(detail)\(active ? ". In use" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The whole cloning flow in one sheet: enable cloning if it isn't, then name
/// the voice and record or import 10–20 seconds of it.
struct CloneVoiceSheet: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Prefs
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = VoiceRecorder()
    @State private var newName = ""
    @State private var showImporter = false
    @State private var fetching = false
    @State private var cloningLog = ""
    @State private var saving = false
    @State private var saved: String?

    // A name that slugs to nothing (emoji only) can never become a voice id, so
    // it must not unlock recording — the failure would otherwise land after a
    // 20s take.
    private var newID: String? { VoiceID.slug(newName) }
    private var nameReady: Bool { newID != nil }

    /// The id this name will be saved under, when it isn't the name itself.
    /// Slugging means what the user typed and what the voice is called can differ
    /// ("Dad's voice" → "Dads-voice"), so say so rather than surprise them later.
    private var idNote: String? {
        guard let id = newID, id != newName else { return nil }
        return id
    }

    /// The existing cloned voice this import would overwrite. The write is a
    /// `rename(2)` onto `<id>.wav`, which replaces — deliberate when you re-record
    /// a voice, but slugging means two names you typed differently can land on one
    /// id. Name the casualty before the user commits a 20s take to it.
    private var replacesExisting: String? {
        guard let id = newID,
              state.hdVoices.contains(where: { $0.id == id && $0.needs_cloning == true })
        else { return nil }
        return id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.gradient)
                    .frame(width: 40, height: 40)
                    .overlay(Image(systemName: "person.wave.2.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clone a voice").font(Brand.title(20, .bold))
                    Text("10–20 seconds of one clear voice is enough.").font(.callout).foregroundStyle(.secondary)
                }
            }

            if state.cloningReady || state.cloningInstalled {
                if !state.cloningReady {
                    Label("Cloning is installed. It loads with Pocket on your next read.", systemImage: "clock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
                steps
            } else {
                enableCloning
            }

            Label("Only clone voices you have permission to use: your own, or someone who agreed to it.",
                  systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button {
                    fetching = true
                    state.fetchStarterVoices { l in if l.contains("[refreshed]") { fetching = false } }
                } label: { Label("Get free starter voices", systemImage: "person.3") }
                    .disabled(fetching || !state.cloningInstalled)
                    .help("Six CMU ARCTIC speakers, free to use")
                if fetching { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result {
                // addHDVoice owns the security-scoped access lifecycle (it reads
                // the file on a detached task). Starting/stopping it here would
                // revoke the sandbox extension before that task runs.
                save(url)
            }
        }
    }

    /// Save a take as the new voice; it comes back selected, ready to preview.
    private func save(_ url: URL) {
        saving = true; saved = nil
        state.addHDVoice(from: url, name: newName) { id in
            saving = false
            saved = id   // the name stays: another take under it replaces this one
        }
    }

    /// Shown once a take is saved: hear it before closing the sheet.
    @ViewBuilder private var result: some View {
        if saving {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Saving your voice…").font(.callout) }
        } else if let saved {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("“\(saved)” is ready").font(.callout.weight(.semibold))
                    Text("It's now your selected voice. Not quite right? Record another take under the same name.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Button { state.testVoice("Hi, this is my new voice in Yap. How do I sound?") } label: {
                    Label("Preview", systemImage: "play.fill")
                }
                .buttonStyle(CapsuleButtonStyle(gradient: Brand.voiceGradient))
            }
            .glassCard()
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            result
            VStack(alignment: .leading, spacing: 6) {
                Text("1  Name it").font(.callout.weight(.semibold))
                TextField("e.g. Sam", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(recorder.recording)   // don't let the name change mid-record
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("2  Record or import 10–20 seconds")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(nameReady ? .primary : .tertiary)
                HStack {
                    Button {
                        recorder.toggle { url in
                            if let url { save(url) }
                        }
                    } label: {
                        Label(recorder.recording ? String(format: "Stop  %.0fs", recorder.elapsed) : "Record from mic",
                              systemImage: recorder.recording ? "stop.circle.fill" : "mic.circle.fill")
                    }
                    .buttonStyle(CapsuleButtonStyle(gradient: recorder.recording ? Brand.earsGradient : Brand.gradient))
                    .disabled((!nameReady && !recorder.recording) || saving)
                    Button { showImporter = true } label: { Label("Import a file…", systemImage: "square.and.arrow.down") }
                        .disabled(!nameReady || recorder.recording || saving)
                }
                if !nameReady {
                    Text("Name the voice to turn on recording and import.").font(.caption).foregroundStyle(.secondary)
                } else if let id = replacesExisting {
                    Label("Replaces your existing “\(id)” voice.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else if let id = idNote {
                    Text("Saved as “\(id)”.").font(.caption).foregroundStyle(.secondary)
                }
                if recorder.recording {
                    ProgressView(value: recorder.elapsed, total: recorder.maxSeconds)
                    Text("Speak naturally. It stops on its own at \(Int(recorder.maxSeconds))s.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if recorder.denied {
                    Text("Microphone access denied. Enable it in System Settings ▸ Privacy ▸ Microphone.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            Text("Best results: a quiet room, no music, one speaker. The new voice appears in the Pocket list.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var enableCloning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cloning needs one extra model file (209 MB, downloaded once). No account, and nothing leaves your Mac.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if state.installingCloning {
                HStack { ProgressView().controlSize(.small)
                    Text(cloningLog.isEmpty ? "Downloading…" : cloningLog).font(.caption).lineLimit(1) }
            } else {
                Button { Task { await state.installCloningWeights { cloningLog = $0 } } } label: {
                    Label("Download & enable cloning", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(CapsuleButtonStyle(gradient: Brand.gradient))
            }
            Text("Model by Kyutai Labs, CC-BY-4.0. Yap downloads it from its own mirror and checks the checksum before use.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
