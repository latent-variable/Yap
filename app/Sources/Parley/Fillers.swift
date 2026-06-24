import Foundation

/// Strips speech disfluencies ("um", "uh", …) from a dictated transcript.
/// Conservative on purpose: only clear filler sounds, never meaningful words
/// like "like" or "well" that change the sentence. Toggleable in Settings.
enum Fillers {
    // Standalone disfluencies, any run length: um/umm, uh/uhh, er/erm, ah, hmm,
    // mm/mhm. Word-bounded and case-insensitive.
    private static let pattern = try! NSRegularExpression(
        pattern: #"\b(?:u+m+|u+h+|e+r+|erm|a+h+|h+m+|m+h+m+|mm+)\b"#,
        options: [.caseInsensitive]
    )

    static func clean(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let wasCapitalized = text.first?.isUppercase ?? false
        var out = pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        // Tidy up the gaps the removals leave behind.
        out = out.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        // A filler removed from between commas leaves ", ," — collapse to one.
        out = out.replacingOccurrences(of: #"([,;:])(\s*[,;:])+"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"^[\s,]+"#, with: "", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // Re-capitalize if removing a leading filler exposed a lowercase start.
        if wasCapitalized, let first = out.first, first.isLowercase {
            out = first.uppercased() + out.dropFirst()
        }
        return out
    }
}
