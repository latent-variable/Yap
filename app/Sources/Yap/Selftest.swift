import Foundation
import AppKit
import Carbon.HIToolbox

/// Headless validation of the pure logic (preprocessing). Run with `--selftest`.
enum Selftest {
    static func run() -> Never {
        var failures = 0
        func check(_ name: String, _ got: String, contains needles: [String], absent: [String] = []) {
            var ok = true
            for n in needles where !got.contains(n) { ok = false; print("  ✗ \(name): missing «\(n)»") }
            for a in absent where got.contains(a) { ok = false; print("  ✗ \(name): should not contain «\(a)»") }
            if ok { print("  ✓ \(name)") } else { failures += 1; print("    got: \(got.replacingOccurrences(of: "\n", with: "⏎"))") }
        }

        print("Preprocess — Markdown profile")
        let md = "## Title\n\nSee **bold** and [link](https://x.com) plus `code`.\n- one\n- two"
        let mdOut = Preprocess.clean(md, options: Preprocess.options(for: .markdown), custom: [])
        check("strip heading", mdOut, contains: ["Title"], absent: ["##"])
        check("strip bold", mdOut, contains: ["bold"], absent: ["**"])
        check("link to text", mdOut, contains: ["link"], absent: ["https://x.com", "]("])
        check("strip backticks", mdOut, contains: ["code"], absent: ["`"])
        check("bullets removed", mdOut, contains: ["one", "two"], absent: ["- one"])

        print("Preprocess — LLM profile (citations + code)")
        let llm = "Answer [1] with detail [2, 3] and more [9, 10, 11].\n\n```\nrm -rf /\n```\n\nDone."
        let llmOut = Preprocess.clean(llm, options: Preprocess.options(for: .llm), custom: [])
        check("drop list citations", llmOut, contains: ["Answer", "Done"],
              absent: ["[1]", "[2, 3]", "[9, 10, 11]", "[", "]"])
        check("skip code block", llmOut, contains: ["Answer"], absent: ["rm -rf"])

        print("Preprocess — citations dropped in general profile too")
        let paper = "We show [1, 2] that the method [9, 10, 11] works [14]. Range [1-3] holds; see [5; 6]."
        let paperOut = Preprocess.clean(paper, options: Preprocess.options(for: .general), custom: [])
        // Also asserts no stranded gap before punctuation (leading space eaten).
        check("general drops numeric citations", paperOut,
              contains: ["We show that the method works.", "Range holds; see."],
              absent: ["[1, 2]", "[9, 10, 11]", "[14]", "[1-3]", "[5; 6]", "works .", "see ."])
        check("general keeps non-numeric brackets",
              Preprocess.clean("Add a [TODO] note here.", options: Preprocess.options(for: .general), custom: []),
              contains: ["[TODO]"])
        // Identifier subscripts must survive — the rule only fires after whitespace
        // or line start, never glued to a word like array[1].
        check("general keeps identifier subscripts",
              Preprocess.clean("total = array[1] + x[0] here", options: Preprocess.options(for: .general), custom: []),
              contains: ["array[1]", "x[0]"])
        // A run of separate citations collapses without stranding stacked commas.
        check("general collapses consecutive citations cleanly",
              Preprocess.clean("See [1], [2], and [3]. Also [4], [5] here.", options: Preprocess.options(for: .general), custom: []),
              contains: ["See, and.", "Also here."], absent: [",,", ", ,", "[1]", "[5]"])
        // Double space before a citation (a PDF-to-text artifact) must not leave a
        // stranded gap before the period — the anchor eats the whole space run.
        check("general handles double-space before citation",
              Preprocess.clean("works  [14]. next  [1, 2]!", options: Preprocess.options(for: .general), custom: []),
              contains: ["works. next!"], absent: ["works .", "works  ", "next !"])

        print("Preprocess — Code profile (prompts + identifiers)")
        let code = "$ runTask\nthe user_name field"
        let codeOut = Preprocess.clean(code, options: Preprocess.options(for: .code), custom: [])
        check("strip prompt", codeOut, contains: ["run"], absent: ["$ "])
        check("space identifiers", codeOut, contains: ["run Task", "user name"])

        print("Preprocess — custom rule")
        let rule = CleanRule(name: "t", pattern: "foo", replacement: "bar", enabled: true)
        let custom = Preprocess.clean("a foo b", options: Preprocess.options(for: .general), custom: [rule])
        check("custom regex", custom, contains: ["a bar b"], absent: ["foo"])

        print("Preprocess — general normalizes quotes/whitespace")
        let gen = Preprocess.clean("“hi”   there\n\n\n\nbye", options: Preprocess.options(for: .general), custom: [])
        check("normalize quotes", gen, contains: ["\"hi\""], absent: ["“"])
        check("collapse spaces", gen, contains: ["hi\" there"])

        print("Preprocess — strip emoji + decorative symbols (all profiles)")
        let sym = Preprocess.clean("Speak to me 🔊 now ✅", options: Preprocess.options(for: .general), custom: [])
        check("drop emoji", sym, contains: ["Speak to me", "now"], absent: ["🔊", "✅"])
        let box = Preprocess.clean("Header\n────────────────\nBody █ ▶ ⭐ ⌘ item", options: Preprocess.options(for: .general), custom: [])
        check("drop box-drawing + shapes", box, contains: ["Header", "Body", "item"],
              absent: ["─", "█", "▶", "⭐", "⌘"])
        // ZWJ/skin-tone compound emoji removed whole, no orphaned glue left behind.
        check("drop compound emoji", Preprocess.clean("team 👨‍👩‍👧 done", options: Preprocess.options(for: .general), custom: []),
              contains: ["team", "done"], absent: ["👨", "👧", "\u{200D}"])
        // Subdivision flags carry trailing Unicode tag scalars — the whole run must go.
        check("drop subdivision flag", Preprocess.clean("flag 🏴󠁧󠁢󠁳󠁣󠁴󠁿 done", options: Preprocess.options(for: .general), custom: []),
              contains: ["flag", "done"], absent: ["🏴", "\u{E0067}", "\u{E007F}"])
        // Each stripped glyph becomes a space, so words on either side never fuse.
        check("no word-gluing", Preprocess.clean("word🔊word", options: Preprocess.options(for: .general), custom: []),
              contains: ["word word"], absent: ["wordword"])
        // Keycap emoji: the ASCII base (1 # *) is PRESERVED so numbered lists/choices are
        // still spoken; only the emoji combining marks (VS16, U+20E3) are stripped.
        check("keep keycap base, drop combiners", Preprocess.clean("press 1️⃣ or #️⃣ now", options: Preprocess.options(for: .general), custom: []),
              contains: ["press 1 or # now"], absent: ["1️⃣", "#️⃣"])
        // Prose arrows (U+2190–21FF) and ordinary punctuation survive — they carry meaning.
        check("keep prose arrows + text", Preprocess.clean("A → B, 50% off", options: Preprocess.options(for: .general), custom: []),
              contains: ["A → B", "50% off"])
        // Math delimiters in the Misc-Technical block stay; only its clock/media emoji go.
        check("keep math delimiters, drop clock emoji",
              Preprocess.clean("f(x) = ⌈x⌉ ⌊y⌋ ⟂ done ⏳", options: Preprocess.options(for: .general), custom: []),
              contains: ["⌈x⌉", "⌊y⌋", "⟂", "done"], absent: ["⏳"])

        print("Fillers — strip disfluencies, keep meaningful words")
        check("remove um/uh", Fillers.clean("so um I uh think"), contains: ["so I think"], absent: ["um", "uh"])
        check("runs + caps", Fillers.clean("Well Ummm yeah UH okay"), contains: ["Well yeah okay"], absent: ["Ummm", "UH"])
        check("keep 'like'/'well'", Fillers.clean("I like it well enough"), contains: ["I like it well enough"])
        check("tidy punctuation", Fillers.clean("wait , um, now"), contains: ["wait, now"], absent: ["um"])
        check("recapitalize after leading filler", Fillers.clean("Um, we should go"),
              contains: ["We should go"], absent: ["we should go"])
        check("recapitalize past leading space", Fillers.clean(" Um, we should go"),
              contains: ["We should go"])

        print("HotKeyCombo — modifier-only chord classification")
        func checkBool(_ name: String, _ got: Bool, _ want: Bool) {
            if got == want { print("  ✓ \(name)") }
            else { failures += 1; print("  ✗ \(name): got \(got) want \(want)") }
        }
        // ⌥⌘ (two modifiers, no key) is a valid modifier-only chord.
        checkBool("two-mod chord valid",
                  HotKeyCombo(keyCode: 0, modifiers: UInt32(optionKey | cmdKey)).isModifierOnly, true)
        // A single modifier alone must NOT qualify (would fire on every ⌘ press).
        checkBool("single mod rejected",
                  HotKeyCombo(keyCode: 0, modifiers: UInt32(cmdKey)).isModifierOnly, false)
        // A normal key chord (⌘⇧R) is not modifier-only.
        checkBool("key chord not modifier-only",
                  HotKeyCombo.defaultCombo.isModifierOnly, false)
        // Three modifiers also valid.
        checkBool("three-mod chord valid",
                  HotKeyCombo(keyCode: 0, modifiers: UInt32(controlKey | optionKey | cmdKey)).isModifierOnly, true)
        check("describe modifier-only", KeyName.describe(HotKeyCombo(keyCode: 0, modifiers: UInt32(optionKey | cmdKey))),
              contains: ["⌥", "⌘"])
        check("describe unset", KeyName.describe(HotKeyCombo(keyCode: 0, modifiers: 0)), contains: ["Unset"])

        print("TranscriptStitch — live tail onto accurate head")
        func checkEq(_ name: String, _ got: String, _ want: String) {
            if got == want { print("  ✓ \(name)") }
            else { failures += 1; print("  ✗ \(name): got «\(got)» want «\(want)»") }
        }
        checkEq("empty refined -> partial",
                TranscriptStitch.merge(refined: "", partial: "hello there"), "hello there")
        checkEq("empty partial -> refined",
                TranscriptStitch.merge(refined: "Hello there.", partial: ""), "Hello there.")
        // Refined's tail anchors in partial; only the words past it are appended.
        checkEq("anchor appends live tail",
                TranscriptStitch.merge(refined: "The quick brown", partial: "the quick brown fox jumps"),
                "The quick brown fox jumps")
        // Anchor matches across casing + punctuation differences between models.
        checkEq("anchor ignores case/punctuation",
                TranscriptStitch.merge(refined: "Hello, world.", partial: "hello world today"),
                "Hello, world. today")
        // Partial caught up to refined — nothing new to append.
        checkEq("no new words keeps refined",
                TranscriptStitch.merge(refined: "all done here", partial: "all done here"),
                "all done here")
        // No anchor match (disjoint) — fall back to word-count stitch.
        checkEq("count fallback when no anchor",
                TranscriptStitch.merge(refined: "alpha", partial: "alpha beta gamma"),
                "alpha beta gamma")
        // Trailing punctuation-only token (empty anchor) must not mis-anchor —
        // falls back to count and still appends the new tail word.
        checkEq("punctuation-only anchor falls back to count",
                TranscriptStitch.merge(refined: "one two .", partial: "one two . three"),
                "one two . three")

        print("AppMigration — recursive merge never strands files")
        do {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appending(path: "yap-migtest-\(UUID().uuidString)")
            let src = root.appending(path: "Parley")
            let dst = root.appending(path: "Yap")
            // src has a cloned voice; dst/hd-voices ALREADY exists but empty — the
            // exact trap a shallow per-child move would skip (silent data loss).
            try? fm.createDirectory(at: src.appending(path: "hd-voices"), withIntermediateDirectories: true)
            fm.createFile(atPath: src.appending(path: "hd-voices/Lino.wav").path, contents: Data("voice".utf8))
            fm.createFile(atPath: src.appending(path: "yap.log").path, contents: Data("log".utf8))
            try? fm.createDirectory(at: dst.appending(path: "hd-voices"), withIntermediateDirectories: true)
            AppMigration.merge(src, into: dst, fm: fm)
            if fm.fileExists(atPath: dst.appending(path: "hd-voices/Lino.wav").path) { print("  ✓ file merged into pre-existing dst subdir") }
            else { failures += 1; print("  ✗ file STRANDED — data loss") }
            if fm.fileExists(atPath: dst.appending(path: "yap.log").path) { print("  ✓ top-level file moved") }
            else { failures += 1; print("  ✗ top-level file not moved") }
            if !fm.fileExists(atPath: src.path) { print("  ✓ emptied source removed") }
            else { failures += 1; print("  ✗ source dir left behind") }
            try? fm.removeItem(at: root)
        }

        print("Clipboard — capture never permanently overwrites it")
        let pb = NSPasteboard.general
        // Save the user's real clipboard so the test itself isn't destructive.
        let userClipboard = pb.string(forType: .string)
        let sentinel = "yap-sentinel-\(UUID().uuidString)"
        pb.clearContents(); pb.setString(sentinel, forType: .string)
        // viaClipboard sends Cmd+C (no selection here), must restore sentinel.
        _ = TextCapture.viaClipboard()
        let after = pb.string(forType: .string) ?? ""
        if after == sentinel { print("  ✓ clipboard restored") }
        else { failures += 1; print("  ✗ clipboard NOT restored: got «\(after)»") }
        // Restore the user's original clipboard contents.
        pb.clearContents()
        if let userClipboard { pb.setString(userClipboard, forType: .string) }

        print("AudioPlayer — engine parks when idle (energy)")
        let ap = AudioPlayer()
        if ap.isEngineRunning { failures += 1; print("  ✗ engine running before any playback") }
        else { print("  ✓ engine idle before first playback") }
        try? ap.start(volume: 1, pitchCents: 0, rate: 1, cushionSeconds: 0.05)
        // With an output device the engine runs now; headless (no device) it may
        // not start — the park invariant below holds either way.
        print(ap.isEngineRunning ? "  ✓ engine runs during a playback session"
                                 : "  · engine didn't start (no output device) — park check still valid")
        ap.stop()
        if ap.isEngineRunning { failures += 1; print("  ✗ engine STILL running after stop — idle CPU drain") }
        else { print("  ✓ engine parked after stop") }

        print("History — cap keeps newest, drops overflow; entries round-trip")
        do {
            // capped() takes the first N (newest, since we prepend) and drops the rest.
            let many = (0..<10).map { HistoryEntry(kind: .spoken, text: "e\($0)") }
            let kept = HistoryStore.capped(many, cap: 3)
            checkBool("cap bounds count", kept.count == 3, true)
            checkBool("cap keeps newest (head)", kept.first?.text == "e0" && kept.last?.text == "e2", true)
            let under = HistoryStore.capped(many, cap: 50)
            checkBool("under cap is untouched", under.count == 10, true)
            // Codable round-trip preserves every field (persistence format).
            let e = HistoryEntry(kind: .dictated, text: "hello world", detail: "Notes")
            if let data = try? JSONEncoder().encode(e),
               let back = try? JSONDecoder().decode(HistoryEntry.self, from: data) {
                checkBool("entry round-trips", back == e, true)
            } else {
                failures += 1; print("  ✗ entry failed to encode/decode")
            }
            // Load-window merge: window entries lead; a cleared list drops restored;
            // a deleted id isn't resurrected by the restore.
            let id0 = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            let win = [HistoryEntry(kind: .spoken, text: "new")]
            let old = [HistoryEntry(id: id0, kind: .spoken, text: "old1"),
                       HistoryEntry(id: id1, kind: .spoken, text: "old2")]
            let plain = HistoryStore.merged(window: win, restored: old, cleared: false, deleted: [])
            checkBool("merge keeps window ahead of restored",
                      plain.map(\.text) == ["new", "old1", "old2"], true)
            let cleared = HistoryStore.merged(window: win, restored: old, cleared: true, deleted: [])
            checkBool("merge honors a cleared list", cleared.map(\.text) == ["new"], true)
            let deleted = HistoryStore.merged(window: win, restored: old, cleared: false, deleted: [id0])
            checkBool("merge doesn't resurrect a deleted entry",
                      deleted.map(\.text) == ["new", "old2"], true)
        }

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
