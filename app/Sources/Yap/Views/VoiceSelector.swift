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
    var id: String { "\(engine):\(voiceId)" }
}

/// Scrollable, searchable picker spanning both engines. Kokoro voices are
/// grouped by language; HD voices sit in their own section. Picking a voice
/// also switches the engine — one place to choose everything.
struct VoicePickerList: View {
    let voices: [EngineVoice]
    let selectionId: String
    var onPick: (EngineVoice) -> Void
    @State private var query = ""

    private var grouped: [(String, [EngineVoice])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? voices : voices.filter {
            $0.label.lowercased().contains(q) || $0.section.lowercased().contains(q)
        }
        // HD section first, then languages alphabetically.
        return Dictionary(grouping: filtered, by: \.section)
            .sorted { ($0.key.hasPrefix("✨") ? "0" : "1") + $0.key < ($1.key.hasPrefix("✨") ? "0" : "1") + $1.key }
            .map { ($0.key, $0.value.sorted { $0.label < $1.label }) }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Search \(voices.count) voices", text: $query).textFieldStyle(.plain)
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
        }
    }

    private func row(_ v: EngineVoice) -> some View {
        Button { onPick(v) } label: {
            HStack {
                Text(v.label)
                Spacer()
                if v.id == selectionId {
                    Image(systemName: "checkmark").foregroundStyle(.tint).font(.caption.bold())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(v.id)
        .listRowBackground(v.id == selectionId ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}

/// Compact control showing the current voice; opens the unified list in a popover.
struct VoiceMenuButton: View {
    let voices: [EngineVoice]
    let selectionId: String
    var onPick: (EngineVoice) -> Void
    @State private var open = false

    private var current: String {
        if let v = voices.first(where: { $0.id == selectionId }) {
            return v.engine == "chatterbox" ? "✨ \(v.label)" : v.label
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
            VoicePickerList(voices: voices, selectionId: selectionId) { v in onPick(v); open = false }
                .frame(width: 280, height: 360)
                .padding(8)
        }
    }
}
