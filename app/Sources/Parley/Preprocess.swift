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
            r += [
                (#"\[\d+\]"#, "", false),                        // [1]
                (#"\[\^?\w+\]"#, "", false),                     // [^1] footnotes
            ]
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

    /// Profile -> default option set.
    static func options(for profile: Profile) -> CleanOptions {
        var o = CleanOptions()
        switch profile {
        case .general:
            break
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
