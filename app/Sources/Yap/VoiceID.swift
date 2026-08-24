import Foundation

/// The id grammar for a cloned Pocket voice.
///
/// A clone's id is one string doing three jobs: the WAV's filename stem under
/// `hd-voices`, the `id` that `/voices` lists, and the `voice` field of a synth
/// request. Only the last one is guarded — `hd_voice_path` in `server.py` rejects
/// anything outside `^[A-Za-z0-9_-]+$` — so an id minted outside that grammar is
/// still written to disk, listed in the picker and selectable, and then 400s on
/// every read, preview and export. Mint every id through `slug`, never from the
/// user's raw text.
enum VoiceID {
    /// Exactly the backend's guard, spelled out rather than written as a regex so
    /// the two can be diffed by eye against `hd_voice_path`.
    private static let legal = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")

    /// Straight, curly and modifier apostrophes — dropped, never separated on.
    private static let apostrophes = CharacterSet(charactersIn: "'\u{2019}\u{02BC}\u{0060}")

    /// Longest id we mint. Guards the 255-byte filename limit with room to spare;
    /// nothing about the backend needs it.
    private static let maxLength = 64

    /// True when `id` is already something the backend will resolve.
    static func isLegal(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { legal.contains($0) }
    }

    /// A backend-legal id for a free-form name, or nil when nothing usable
    /// survives (an emoji-only name).
    ///
    /// Transliterates *before* filtering, so a non-Latin or accented name keeps
    /// its sound instead of collapsing to a row of dashes: "Ángel" → "Angel",
    /// "パパ" → "papa", "Дом" → "Dom". Each run of anything else becomes a single
    /// "-", never a leading or trailing one: "Dad's voice" → "Dads-voice".
    static func slug(_ name: String) -> String? {
        let latin = name.applyingTransform(.toLatin, reverse: false)
            .flatMap { $0.applyingTransform(.stripDiacritics, reverse: false) } ?? name
        // An apostrophe sits *inside* a word, so it drops rather than separating:
        // "Dad's voice" is "Dads-voice", not "Dad-s-voice".
        let deapostrophed = latin.unicodeScalars.filter { !apostrophes.contains($0) }
        var out = ""
        var gap = false   // saw illegal scalars; emit one "-" iff something follows
        for u in deapostrophed {
            guard legal.contains(u) else { gap = true; continue }
            if gap && !out.isEmpty { out.append("-") }
            gap = false
            out.unicodeScalars.append(u)
        }
        // A name made only of "-"/"_" passes the backend's charset but is a
        // useless id — it trims away to nothing here, same as an emoji-only name.
        let trim = CharacterSet(charactersIn: "-_")
        let id = String(out.trimmingCharacters(in: trim).prefix(maxLength))
            .trimmingCharacters(in: trim)   // the cap may have landed mid-separator
        return id.isEmpty ? nil : id
    }
}
