import Foundation

/// One recorded passage — text Yap spoke (TTS) or text you dictated (STT).
/// The full text is kept so a whole read can be recovered later; only the
/// number of entries is bounded (see `HistoryStore.cap`).
struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case spoken, dictated }
    let id: UUID
    let date: Date
    let kind: Kind
    let text: String
    /// Context for the row: the voice for a spoken entry, the target app for a
    /// dictated one. Optional, purely informational.
    let detail: String

    init(id: UUID = UUID(), date: Date = Date(), kind: Kind, text: String, detail: String = "") {
        self.id = id
        self.date = date
        self.kind = kind
        self.text = text
        self.detail = detail
    }
}

/// Durable log of everything Yap has said and everything you've dictated, so a
/// passage is never lost to a crash or a missed paste. Two rolling lists
/// (newest first), JSON-backed in Application Support, capped by count.
///
/// The store is the single source of truth; the History tab reads it and can
/// clear or delete entries. Recording is fire-and-forget from the read pipeline
/// (`AppState.stream`) and the dictation controller.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    /// Max entries per list. Full text is preserved; only the count is bounded so
    /// the on-disk file can't grow without limit. `nonisolated` so the pure
    /// `capped(_:)` helper can read it off the main actor.
    nonisolated static let cap = 500

    @Published private(set) var spoken: [HistoryEntry] = []
    @Published private(set) var dictated: [HistoryEntry] = []

    private let fileURL: URL
    // Writes hop off the main thread; encoding stays on main (cheap for ≤1000
    // short entries) so only the Sendable `Data` crosses the boundary.
    private let io = DispatchQueue(label: "com.yap.history.io", qos: .utility)

    private struct Snapshot: Codable { var spoken: [HistoryEntry]; var dictated: [HistoryEntry] }

    /// `fileURL` is injectable so `--selftest` can exercise a temp file.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL
        load()
    }

    private static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Yap").appending(path: "history.json")
    }

    // MARK: - Record

    func recordSpoken(_ text: String, detail: String = "") { add(kind: .spoken, text: text, detail: detail) }
    func recordDictated(_ text: String, detail: String = "") { add(kind: .dictated, text: text, detail: detail) }

    private func add(kind: HistoryEntry.Kind, text: String, detail: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let entry = HistoryEntry(kind: kind, text: t, detail: detail)
        switch kind {
        case .spoken:   spoken = Self.capped([entry] + spoken)
        case .dictated: dictated = Self.capped([entry] + dictated)
        }
        save()
    }

    // MARK: - Mutate

    func delete(_ entry: HistoryEntry) {
        spoken.removeAll { $0.id == entry.id }
        dictated.removeAll { $0.id == entry.id }
        save()
    }

    func clearSpoken()   { spoken = [];   save() }
    func clearDictated() { dictated = []; save() }

    // MARK: - Persistence

    /// Newest-first, bounded to `cap`. Pure so `--selftest` can verify it.
    nonisolated static func capped(_ entries: [HistoryEntry], cap: Int = HistoryStore.cap) -> [HistoryEntry] {
        entries.count > cap ? Array(entries.prefix(cap)) : entries
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        spoken = Self.capped(snap.spoken)
        dictated = Self.capped(snap.dictated)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Snapshot(spoken: spoken, dictated: dictated)) else { return }
        let url = fileURL
        io.async {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
