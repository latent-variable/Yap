import Foundation

/// One editable regex cleanup rule.
struct CleanRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var pattern: String
    var replacement: String
    var enabled: Bool = true
    var caseInsensitive: Bool = false
}

/// Toggleable preprocessing options layered on top of regex rules.
struct CleanOptions: Equatable {
    var collapseWhitespace = true
    var normalizeQuotes = true
    var stripSymbols = true            // emoji + decorative box-drawing/symbol glyphs
    var stripMarkdown = true
    var bulletsToPauses = true
    var skipCodeBlocks = false
    var skipURLs = false
    var spaceOutIdentifiers = false   // snake_case / camelCase
    var stripPrompts = false          // $ % > PS> C:>
    var dropCitations = false         // [1] [2]
    var symbolsToWords = false
}

/// The cleanup engine. Pure functions so the UI can preview instantly.
enum Preprocess {

    /// Built-in rules applied (when enabled) for a given profile.
    static func builtinRules(_ opt: CleanOptions) -> [(String, String, Bool)] {
        // (pattern, replacement, caseInsensitive)
        var r: [(String, String, Bool)] = []
        if opt.stripMarkdown {
            r += [
                (#"!\[[^\]]*\]\([^)]*\)"#, "", false),          // images
                (#"\[([^\]]+)\]\([^)]*\)"#, "$1", false),       // links -> text
                (#"^#{1,6}\s*"#, "", false),                     // headings
                (#"(\*\*|__)(.*?)\1"#, "$2", false),            // bold
                (#"(\*|_)(.*?)\1"#, "$2", false),               // italic
                (#"`{1,3}"#, "", false),                         // backticks
                (#"^\s*\|.*\|\s*$"#, "", false),                // table rows
                (#"^\s*[-:|]{3,}\s*$"#, "", false),             // table sep / hr
                (#"~~(.*?)~~"#, "$1", false),                   // strikethrough
            ]
        }
        if opt.bulletsToPauses {
            r.append((#"^\s*([-*+•]|\d+[.)])\s+"#, "", false))
        }
        if opt.stripPrompts {
            r.append((#"^\s*(PS [A-Z]:\\[^>]*>|[A-Z]:\\>|[\$%>])\s+"#, "", false))
        }
        if opt.dropCitations {
            // Bracketed numeric citations — the noise academic papers are full of:
            // [1] [^1] [1, 2] [9, 10, 11] [1-3] [5; 6]. Handles comma / semicolon
            // lists and ranges, and ^-footnote refs.
            //
            //  - Requires start-of-line or whitespace before "[", so identifier
            //    subscripts (array[1], x[0]) are left untouched — this rule runs
            //    in the default profile now, and mangling code prose would be bad.
            //  - Consumes a whole *run* of adjacent citations ("[1], [2], [3]") in
            //    one match, so removal never strands stacked commas ("See,, and").
            //  - Eats the *entire* leading whitespace run (\s+), so even a
            //    double-space from PDF-to-text extraction ("works  [14].") reads
            //    "works." with no gap before the period.
            //  - Non-numeric brackets ([Note], [TODO]) are left intact.
            let atom = #"\[\^?\s*\d+(?:\s*[-,;]\s*\d+)*\s*\]"#
            r.append((#"(?:^|\s+)"# + atom + #"(?:\s*,?\s*"# + atom + #")*"#, "", false))
        }
        return r
    }

    static func clean(_ input: String, options: CleanOptions, custom: [CleanRule]) -> String {
        var text = input

        if options.skipCodeBlocks {
            text = regexReplace(text, #"```[\s\S]*?```"#, "", false)
            text = regexReplace(text, #"(?m)^( {4,}|\t).*$"#, "", false)
        }
        if options.skipURLs {
            text = regexReplace(text, #"https?://\S+"#, "", true)
        }
        if options.stripSymbols {
            text = stripSymbols(text)
        }

        // line-anchored rules need multiline mode -> prepend (?m)
        for (pat, rep, ci) in builtinRules(options) {
            text = regexReplace(text, "(?m)" + pat, rep, ci)
        }

        for rule in custom where rule.enabled {
            text = regexReplace(text, rule.pattern, rule.replacement, rule.caseInsensitive)
        }

        if options.spaceOutIdentifiers {
            text = regexReplace(text, #"([a-z0-9])([A-Z])"#, "$1 $2", false)   // camelCase
            text = regexReplace(text, #"_+"#, " ", false)                       // snake_case
        }
        if options.symbolsToWords {
            let map = ["&": " and ", "@": " at ", "%": " percent ", "#": " number ",
                       "+": " plus ", "=": " equals ", "/": " slash "]
            for (k, v) in map { text = text.replacingOccurrences(of: k, with: v) }
        }
        if options.normalizeQuotes {
            let map = ["“": "\"", "”": "\"", "‘": "'", "’": "'", "—": ", ", "–": "-", "…": "..."]
            for (k, v) in map { text = text.replacingOccurrences(of: k, with: v) }
        }
        if options.collapseWhitespace {
            text = regexReplace(text, #"[ \t]+"#, " ", false)
            text = regexReplace(text, #"\n{3,}"#, "\n\n", false)
            text = regexReplace(text, #"(?m)^[ \t]+|[ \t]+$"#, "", false)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip emoji and decorative symbol glyphs that a TTS engine would either
    /// vocalize by name ("speaker with three sound waves") or turn into noise.
    /// Targets what leaks in from copied terminal / chat / Markdown output:
    /// emoji (🔊 ✅ ⚠️), box-drawing separators (────), block + geometric shapes
    /// (█ ▶ ●), and the invisible glue that binds emoji sequences (ZWJ, variation
    /// selectors, skin-tone modifiers, keycap combiners).
    ///
    /// Deliberately conservative about text: letters, digits, punctuation, currency,
    /// math operators and delimiters (⌈ ⌉ ⌊ ⌋ at U+2308–230B, ⟂ …), and the *prose*
    /// arrow block (← → ↑ ↓, U+2190–21FF) are kept — copied output writes directions
    /// as "A → B" and formulas with ASCII/math glyphs, never the emoji form. The
    /// heavy emoji-style lookalikes (⬅ ➡ in U+2B00–2BFF; ➕ ✖ in the dingbats) travel
    /// with decoration (⭐ ⬛ ✅) and ARE stripped. In the mixed Misc-Technical block
    /// only the clock/media emoji are stripped, never the neighbouring math delimiters.
    ///
    /// Each removed glyph becomes a **space**, not nothing, so adjacent words can't
    /// fuse ("word🔊word" → "word word"); collapseWhitespace (which runs afterward)
    /// tidies the resulting gaps and drops now-empty decorator lines. Multi-scalar
    /// sequences (ZWJ families, skin-tone modifiers, subdivision-flag tags) collapse
    /// to a single space the same way.
    static func stripSymbols(_ text: String) -> String {
        func isStrippable(_ s: Unicode.Scalar) -> Bool {
            switch s.value {
            case 0x200D,                       // zero-width joiner (emoji sequences)
                 0xFE00...0xFE0F,              // variation selectors (e.g. VS16 emoji style)
                 0x20E3,                       // combining enclosing keycap
                 0x2318,                       // ⌘ command-key symbol (TTS says "place of interest sign")
                 0x231A...0x231B,              // ⌚ ⌛ emoji (NOT the 2308–230B ⌈⌉⌊⌋ math delimiters)
                 0x23E9...0x23FA,              // media-control / clock / timer emoji (⏩ ⏰ ⏳ ⏸ …)
                 0x2500...0x25FF,              // box drawing, block elements, geometric shapes
                 0x2600...0x27BF,              // misc symbols + dingbats (☀ ★ ✅ ✂ ❌ …)
                 0x2B00...0x2BFF,              // misc symbols & arrows (⭐ ⬛ ⬅ ➡ …)
                 0x1F000...0x1FFFF,            // all of Plane 1's symbol/emoji blocks (no prose letters live above 1F000)
                 0xE0000...0xE007F,            // tags (subdivision-flag glue: 🏴 Scotland/England)
                 0xE0100...0xE01EF:            // variation selectors supplement
                return true
            default:
                return false
            }
        }
        // Fast path: plain prose (the common case) has nothing to strip, so skip
        // the allocation + copy entirely and hand back the original untouched.
        guard text.unicodeScalars.contains(where: isStrippable) else { return text }
        // Build a scalar array (contiguous 32-bit ints, one UTF-8 pass at the end)
        // rather than growing a String's UTF-8 storage per scalar.
        //
        // Keycap emoji (1️⃣ #️⃣ *️⃣ = ASCII base + optional VS16 + U+20E3) are handled
        // right here by design: the combining marks strip to spaces while the base
        // (1 # *) is KEPT, so "press 1️⃣ or 2️⃣" reads "press 1 or 2". Numbered lists and
        // choices carry their meaning in that digit — an earlier version dropped the
        // whole sequence and silenced it ("press or"), which made the audio unusable.
        // Preserving the base is the deliberate call; do not re-add a drop-the-base pass.
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(text.unicodeScalars.count)
        for s in text.unicodeScalars { out.append(isStrippable(s) ? " " : s) }
        return String(String.UnicodeScalarView(out))
    }

    /// Profile -> default option set.
    static func options(for profile: Profile) -> CleanOptions {
        var o = CleanOptions()
        switch profile {
        case .general:
            // Drop bracketed numeric citations even in the default profile —
            // "[1, 2]" mid-sentence is pure noise read aloud (papers, wikis),
            // and stripping it can't hurt ordinary prose (plain [numbers] carry
            // no spoken meaning). Non-numeric brackets are left intact.
            o.dropCitations = true
        case .markdown:
            o.stripMarkdown = true; o.bulletsToPauses = true
        case .code:
            o.skipCodeBlocks = false; o.stripPrompts = true
            o.spaceOutIdentifiers = true; o.symbolsToWords = false
        case .blog:
            o.stripMarkdown = true; o.dropCitations = true; o.skipURLs = true
        case .llm:
            o.stripMarkdown = true; o.bulletsToPauses = true
            o.dropCitations = true; o.skipCodeBlocks = true
        }
        return o
    }

    // Compiling NSRegularExpression is expensive; cache by pattern (+ case flag)
    // so repeated cleans of the same rules don't recompile every call.
    private static let regexCacheLock = NSLock()
    private static var regexCache: [String: NSRegularExpression] = [:]

    private static func compiledRegex(_ pattern: String, _ ci: Bool) -> NSRegularExpression? {
        let key = (ci ? "i\u{0}" : "s\u{0}") + pattern
        regexCacheLock.lock(); defer { regexCacheLock.unlock() }
        if let cached = regexCache[key] { return cached }
        var opts: NSRegularExpression.Options = []
        if ci { opts.insert(.caseInsensitive) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return nil }
        regexCache[key] = re
        return re
    }

    private static func regexReplace(_ s: String, _ pattern: String, _ repl: String, _ ci: Bool) -> String {
        guard let re = compiledRegex(pattern, ci) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: repl)
    }
}
