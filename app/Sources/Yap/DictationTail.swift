import Foundation
import FluidAudio

/// Decode the tail even when its loudness looks like noise. Token times locate
/// six seconds of overlap; a unique three-word seam protects the join.
enum DictationTail {
    struct Plan {
        let start: Double
        let prefix: String
        let anchor: [String]

        func finish(_ tail: String) -> String? {
            let words = tail.split(whereSeparator: { $0.isWhitespace })
            guard words.count >= anchor.count else { return nil }
            let keys = words.map { DictationTail.key(String($0)) }
            let matches = (0...(words.count - anchor.count)).filter {
                Array(keys[$0..<($0 + anchor.count)]) == anchor
            }
            // Repeated phrases are ambiguous: use a full pass instead of guessing.
            guard matches.count == 1, let at = matches.first, at <= 10 else { return nil }
            let ending = words[at...].joined(separator: " ")
            return prefix.isEmpty ? ending : prefix + " " + ending
        }
    }

    static func key(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
    }

    static func plan(text: String, timings: [TokenTiming], covered: Double) -> Plan? {
        guard covered.isFinite, covered > 6, !timings.isEmpty,
              timings.map(\.token).joined().trimmingCharacters(in: .whitespacesAndNewlines) == text
        else { return nil }
        var words: [(text: String, start: Double)] = []
        var previous = 0.0
        for t in timings {
            guard t.startTime.isFinite, t.endTime.isFinite,
                  t.startTime >= previous, t.endTime >= t.startTime,
                  t.startTime <= covered else { return nil }
            previous = t.startTime
            if t.token.first?.isWhitespace == true || words.isEmpty {
                words.append((t.token.trimmingCharacters(in: .whitespacesAndNewlines), t.startTime))
            } else {
                words[words.count - 1].text += t.token
            }
        }
        guard let cut = words.lastIndex(where: { $0.start <= covered - 6 }), cut >= 4 else { return nil }
        let anchorStart = cut - 3
        let anchor = words[anchorStart..<cut].map { key($0.text) }
        guard anchor.allSatisfy({ !$0.isEmpty }) else { return nil }
        let remaining = words[anchorStart...].map { key($0.text) }
        let occurrences = (0...(remaining.count - anchor.count)).filter {
            Array(remaining[$0..<($0 + anchor.count)]) == anchor
        }
        guard occurrences.count == 1 else { return nil }
        let start = max(0, words[anchorStart].start - 0.4)
        guard start >= 1 else { return nil }
        return Plan(start: start,
                    prefix: words[..<anchorStart].map(\.text).joined(separator: " "),
                    anchor: anchor)
    }
}
