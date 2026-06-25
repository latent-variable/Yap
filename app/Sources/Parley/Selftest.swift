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
        let llm = "Answer [1] with detail [2].\n\n```\nrm -rf /\n```\n\nDone."
        let llmOut = Preprocess.clean(llm, options: Preprocess.options(for: .llm), custom: [])
        check("drop citations", llmOut, contains: ["Answer", "Done"], absent: ["[1]", "[2]"])
        check("skip code block", llmOut, contains: ["Answer"], absent: ["rm -rf"])

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

        print("Clipboard — capture never permanently overwrites it")
        let pb = NSPasteboard.general
        // Save the user's real clipboard so the test itself isn't destructive.
        let userClipboard = pb.string(forType: .string)
        let sentinel = "parley-sentinel-\(UUID().uuidString)"
        pb.clearContents(); pb.setString(sentinel, forType: .string)
        // viaClipboard sends Cmd+C (no selection here), must restore sentinel.
        _ = TextCapture.viaClipboard()
        let after = pb.string(forType: .string) ?? ""
        if after == sentinel { print("  ✓ clipboard restored") }
        else { failures += 1; print("  ✗ clipboard NOT restored: got «\(after)»") }
        // Restore the user's original clipboard contents.
        pb.clearContents()
        if let userClipboard { pb.setString(userClipboard, forType: .string) }

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
