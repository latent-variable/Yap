import SwiftUI

extension VoiceInfo {
    /// "Puck · English (US) ♂"
    var display: String {
        let base = id.split(separator: "_").last.map(String.init)?.capitalized ?? id
        return "\(base) · \(lang_label) \(gender == "female" ? "♀" : "♂")"
    }
    var shortName: String {
        let base = id.split(separator: "_").last.map(String.init)?.capitalized ?? id
        return "\(base) \(gender == "female" ? "♀" : "♂")"
    }
}

/// A voice from either engine, in one id space ("engine:voiceId").
struct EngineVoice: Identifiable, Hashable {
    let engine: String
    let voiceId: String
    let label: String
    let section: String
    /// False when the backend lists the voice but cannot actually speak it — a
    /// cloned Pocket voice while cloning is unavailable. Such a voice is shown
    /// LOCKED rather than hidden: the user's own recordings vanishing from the
    /// picker is its own confusion, and the lock names the reason. Offering it as
    /// selectable is what made a dead selection look like a crash — the pick
    /// 403s on the next read and refreshHD demotes it back to a catalog voice.
    var available: Bool = true
    var id: String { "\(engine):\(voiceId)" }
}

/// Scrollable, searchable picker. A segmented control at the top switches the
/// active engine (Kokoro ↔ Pocket); the list below shows ONLY that engine's
/// voices — Kokoro grouped by language, Pocket as built-in catalog + cloned. One
/// engine is active at a time, so its voices aren't buried among the other's.
struct VoicePickerList: View {
    let voices: [EngineVoice]
    let selectionId: String
    let engine: String                 // currently active engine
    let pocketAvailable: Bool          // show the Pocket segment?
    var onSelectEngine: (String) -> Void
    var onPick: (EngineVoice) -> Void
    @State private var query = ""

    // Only the active engine's voices.
    private var scoped: [EngineVoice] { voices.filter { $0.engine == engine } }

    private var grouped: [(String, [EngineVoice])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? scoped : scoped.filter {
            $0.label.lowercased().contains(q) || $0.section.lowercased().contains(q)
        }
        // ✨ Cloned first, then other sections (catalog / languages) alphabetically.
        return Dictionary(grouping: filtered, by: \.section)
            .sorted { ($0.key.hasPrefix("✨") ? "0" : "1") + $0.key < ($1.key.hasPrefix("✨") ? "0" : "1") + $1.key }
            .map { ($0.key, $0.value.sorted { $0.label < $1.label }) }
    }

    var body: some View {
        VStack(spacing: 6) {
            if pocketAvailable {
                Picker("", selection: Binding(get: { engine }, set: { onSelectEngine($0) })) {
                    Text("Kokoro").tag("kokoro")
                    Text("Pocket").tag("pocket")
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Search \(scoped.count) voices", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))

            ScrollViewReader { proxy in
                List {
                    ForEach(grouped, id: \.0) { section, list in
                        Section(section) { ForEach(list) { row($0) } }
                    }
                    if grouped.isEmpty { Text("No matches").foregroundStyle(.secondary).font(.caption) }
                }
                .listStyle(.inset)
                .onAppear { proxy.scrollTo(selectionId, anchor: .center) }
            }
            // Say why the locked rows are locked, once, instead of leaving a user
            // to guess at a voice that won't take. Only when something is locked.
            if scoped.contains(where: { !$0.available }) {
                Text("🔒 Cloned voices need the gated Pocket weights — Settings ▸ Voices ▸ Voice cloning.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ v: EngineVoice) -> some View {
        Button { onPick(v) } label: {
            HStack {
                Text(v.label).foregroundStyle(v.available ? AnyShapeStyle(.primary)
                                                          : AnyShapeStyle(.secondary))
                Spacer()
                if !v.available {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                } else if v.id == selectionId {
                    Image(systemName: "checkmark").foregroundStyle(.tint).font(.caption.bold())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!v.available)
        .help(v.available ? "" : Self.lockedHelp)
        .id(v.id)
        .listRowBackground(v.id == selectionId ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    static let lockedHelp =
        "Voice cloning is off, so this voice can't be spoken. Set it up in Settings ▸ Voices ▸ Voice cloning."
}

/// Compact control showing the current voice; opens the unified list in a popover.
struct VoiceMenuButton: View {
    let voices: [EngineVoice]
    let selectionId: String
    let engine: String
    let pocketAvailable: Bool
    var onSelectEngine: (String) -> Void
    var onPick: (EngineVoice) -> Void
    @State private var open = false

    private var current: String {
        if let v = voices.first(where: { $0.id == selectionId }) {
            // Mark cloned voices with the sparkle; catalog voices read plain.
            return v.section.contains("Cloned") ? "✨ \(v.label)" : v.label
        }
        return selectionId.split(separator: ":").last.map(String.init) ?? selectionId
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Text(current).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VoicePickerList(voices: voices, selectionId: selectionId, engine: engine,
                            pocketAvailable: pocketAvailable, onSelectEngine: onSelectEngine) { v in
                onPick(v); open = false
            }
            .frame(width: 280, height: pocketAvailable ? 392 : 360)
            .padding(8)
        }
    }
}
