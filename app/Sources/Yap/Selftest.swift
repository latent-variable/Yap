import Foundation
import AVFoundation
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

        print("Settings tab bar fits")
        // Regression: the Settings scene sizes its window to CONTENT, so when the
        // bar needed more width than the widest tab body, macOS collapsed the tail
        // into a `>>` chevron whose items do not switch tabs. Diagnostics was
        // visible and unreachable, with no way to widen the window.
        let needed = SettingsView.requiredTabBarWidth(SettingsTab.allCases.map(\.title))
        let cap = SettingsView.minTabBarWidth
        if needed <= cap {
            print(String(format: "  ✓ %d tabs need %.0fpt, window floor is %.0fpt",
                         SettingsTab.allCases.count, needed, cap))
        } else {
            failures += 1
            print(String(format: "  ✗ tab bar needs %.0fpt but the window floor is only %.0fpt — raise SettingsView.minTabBarWidth or shorten a label",
                         needed, cap))
        }
        // Control: the guard must actually fire. A label long enough to overflow
        // has to be caught, or the check above passes for any input.
        let overflowing = SettingsTab.allCases.map(\.title) + [String(repeating: "X", count: 60)]
        if SettingsView.requiredTabBarWidth(overflowing) > cap {
            print("  ✓ control: an over-long label is detected")
        } else {
            failures += 1; print("  ✗ control: the width guard does not fire on overflow")
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
        // A separator-only line must vanish, NOT become a blank-line paragraph break
        // (server.py would pause on it). Header and Body end up adjacent.
        check("separator line leaves no blank paragraph", box, contains: ["Header\nBody"], absent: ["Header\n\n"])
        // But a genuinely blank line in the input is preserved as a paragraph break.
        check("keep intentional blank line", Preprocess.clean("Para one ✅\n\nPara two", options: Preprocess.options(for: .general), custom: []),
              contains: ["Para one\n\nPara two"])
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

        print("Dictation — a model load must not reset an active session")
        // An engine switch is one click away in the menu bar AND in Settings, and
        // nothing disables it mid-dictation. A load that commits `state = .idle`
        // over a live session made stopAndTranscribe's `guard state == .listening`
        // fail, and the speech was dropped with no error shown.
        checkBool("listening is protected",
                  Dictation.loadMayWriteState(starting: false, state: .listening), false)
        checkBool("transcribing is protected",
                  Dictation.loadMayWriteState(starting: false, state: .transcribing), false)
        // The mic-permission window: state is still .idle but a session is coming
        // up, so `starting` alone must protect it.
        checkBool("permission window is protected",
                  Dictation.loadMayWriteState(starting: true, state: .idle), false)
        checkBool("starting outranks any state",
                  Dictation.loadMayWriteState(starting: true, state: .loadingModel), false)
        // With no session in flight a load owns the state, or the picker would
        // never show "loading" and a failed load could never surface its error.
        checkBool("idle is writable",
                  Dictation.loadMayWriteState(starting: false, state: .idle), true)
        checkBool("loadingModel is writable",
                  Dictation.loadMayWriteState(starting: false, state: .loadingModel), true)
        checkBool("error is writable",
                  Dictation.loadMayWriteState(starting: false, state: .error("x")), true)

        // The batch model must belong to the session's engine, not the live picker
        // selection. Switching multilingual→English mid-utterance loaded the English
        // batch model and ran it over Spanish audio; the garbage overrode the correct
        // live transcript, because a non-empty accurate pass always wins.
        checkBool("batch model matching the session is used",
                  Dictation.batchModelUsable(loaded: .v3, session: .v3), true)
        checkBool("batch model from a later engine switch is refused",
                  Dictation.batchModelUsable(loaded: .v2, session: .v3), false)
        checkBool("no batch model loaded yet is refused",
                  Dictation.batchModelUsable(loaded: nil, session: .v3), false)
        checkBool("no session binding is refused",
                  Dictation.batchModelUsable(loaded: .v2, session: nil), false)

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

        print("AudioPlayer — queued-seconds accounting (drives stream backpressure)")
        do {
            let bp = AudioPlayer()
            try? bp.start(volume: 1, pitchCents: 0, rate: 1, cushionSeconds: 0.05)
            checkBool("fresh session starts empty", bp.queuedSeconds == 0, true)
            // 24000 frames = 1s of int16 mono @ 24 kHz = 48000 bytes.
            bp.feed(Data(count: 48000))
            // feed() is async on the player queue; queuedSeconds syncs on the same
            // queue, so the read is ordered after the append — no sleep needed.
            checkBool("1s of PCM reads as ~1s queued", abs(bp.queuedSeconds - 1.0) < 0.01, true)
            bp.feed(Data(count: 48000 * 3))
            checkBool("queue accumulates across chunks", abs(bp.queuedSeconds - 4.0) < 0.01, true)
            // The gate stalls the reader above this; a queue that couldn't exceed
            // the cap would mean the backpressure branch is dead code.
            checkBool("queue can exceed the cap (gate has something to clamp)",
                      4.0 < AudioPlayer.maxQueuedSeconds, true)
            // An odd trailing byte is carried, not counted as a whole frame.
            bp.feed(Data(count: 1))
            checkBool("odd trailing byte doesn't inflate the count",
                      abs(bp.queuedSeconds - 4.0) < 0.01, true)
            bp.stop()
            checkBool("stop() clears the queue (gate sees an empty player)",
                      bp.queuedSeconds == 0, true)
        }

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

        print("AudioImport — a failed import never destroys the existing voice")
        do {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appending(path: "yap-import-\(UUID().uuidString)")
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: root) }

            // A real 1s source clip (48 kHz stereo float, i.e. needs converting).
            let src = root.appending(path: "source.wav")
            let srcFmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            do {
                let f = try AVAudioFile(forWriting: src, settings: srcFmt.settings)
                let buf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: 48000)!
                buf.frameLength = 48000
                for ch in 0..<Int(srcFmt.channelCount) {
                    for i in 0..<48000 {
                        buf.floatChannelData![ch][i] = sinf(Float(i) * 0.05) * 0.5
                    }
                }
                try f.write(from: buf)
            } catch {
                failures += 1; print("  ✗ could not build the source clip: \(error)")
            }

            // The voice the user already has, standing in for a cloned reference.
            let dest = root.appending(path: "Lino.wav")
            let existing = Data("an existing cloned voice".utf8)
            fm.createFile(atPath: dest.path, contents: existing)

            // maxSeconds: 0 makes the conversion produce nothing and throw — the
            // exact shape of any mid-conversion failure. The original code had
            // already deleted `dest` and opened a new empty file there by this
            // point, so the user lost their voice and got a 0-frame stub.
            var threw = false
            do { try AudioImport.toReferenceWAV(src: src, dest: dest, maxSeconds: 0) }
            catch { threw = true }
            checkBool("failed conversion throws", threw, true)
            checkBool("existing voice survives a failed import",
                      fm.contents(atPath: dest.path) == existing, true)

            // Success must still land: same name, replaced in place, real audio.
            var ok = true
            do { try AudioImport.toReferenceWAV(src: src, dest: dest, maxSeconds: 20) }
            catch { ok = false }
            checkBool("successful import replaces the voice", ok, true)
            if let out = try? AVAudioFile(forReading: dest) {
                checkBool("replacement is mono 24 kHz with audio in it",
                          out.fileFormat.sampleRate == 24000 && out.fileFormat.channelCount == 1
                          && out.length > 0, true)
            } else {
                failures += 1; print("  ✗ replacement is not a readable audio file")
            }
            // The staging dir must not leave a stray *.wav next to the voices —
            // the backend globs that directory and would list it as a voice.
            let strays = (try? fm.contentsOfDirectory(atPath: root.path))?
                .filter { $0.hasSuffix(".wav") && $0 != "Lino.wav" && $0 != "source.wav" } ?? []
            checkBool("no temp file left beside the voice", strays.isEmpty, true)
        }

        print("VoiceID — a cloned voice's id must be one the backend resolves")
        // The claim under test is not "slug rewrites strings" — it is "every id
        // this app mints satisfies hd_voice_path's guard", which is what decides
        // whether an imported voice can ever speak.
        for raw in ["My Sam", "Dad's voice", "Ángel", "パパ", "Дом", "a/b\\c",
                    "  padded  ", "Sam!!!", "voice (2)", "MIXED_case-99",
                    String(repeating: "long name ", count: 20)] {
            guard let id = VoiceID.slug(raw) else {
                failures += 1; print("  ✗ slug dropped a usable name «\(raw)»"); continue
            }
            checkBool("«\(raw)» -> «\(id)» is backend-legal", VoiceID.isLegal(id), true)
        }
        // Control: without slugging, those same names are exactly what the backend
        // rejects. If slug ever degrades to identity, the loop above stops proving
        // anything — this is the assertion that notices.
        checkBool("control: raw «My Sam» is NOT legal", VoiceID.isLegal("My Sam"), false)
        checkBool("control: raw «Dad's voice» is NOT legal", VoiceID.isLegal("Dad's voice"), false)
        checkEq("spaces collapse to one dash", VoiceID.slug("My  Sam") ?? "<nil>", "My-Sam")
        checkEq("apostrophe drops, space joins", VoiceID.slug("Dad's voice") ?? "<nil>", "Dads-voice")
        checkEq("accents transliterate, not vanish", VoiceID.slug("Ángel") ?? "<nil>", "Angel")
        checkEq("legal name passes through untouched", VoiceID.slug("MIXED_case-99") ?? "<nil>", "MIXED_case-99")
        checkEq("no leading or trailing dash", VoiceID.slug("  !Sam!  ") ?? "<nil>", "Sam")
        checkEq("path separators can't escape the dir", VoiceID.slug("../../etc/x") ?? "<nil>", "etc-x")
        checkBool("emoji-only name yields no id", VoiceID.slug("🎤🎤") == nil, true)
        checkBool("separator-only name yields no id", VoiceID.slug("---") == nil, true)
        checkBool("empty name yields no id", VoiceID.slug("") == nil, true)
        checkBool("id is capped and still legal",
                  VoiceID.slug(String(repeating: "long name ", count: 20)).map {
                      $0.count <= 64 && VoiceID.isLegal($0) } ?? false, true)
        // The starter voices ship as ids already; slugging must not rename them
        // out from under a user's saved selection.
        for starter in ["Aria", "Clara", "Ben", "Cole", "Jake", "Angus", "Ravi"] {
            checkEq("starter «\(starter)» unchanged", VoiceID.slug(starter) ?? "<nil>", starter)
        }

        print("VoiceID — repairing clips a previous build already broke")
        do {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appending(path: "yap-repair-\(UUID().uuidString)")
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: root) }
            func put(_ stem: String, _ body: String) {
                fm.createFile(atPath: root.appending(path: "\(stem).wav").path,
                              contents: Data(body.utf8))
            }
            put("My Sam", "broken")            // renameable
            put("Ravi", "starter")             // already legal — must not move
            put("Clara", "legal-clara")        // the collision target below
            put("Clara!", "would-clobber")     // slugs onto Clara — must be left alone
            put("🎤", "nothing-sluggable")     // no id to rename it to
            fm.createFile(atPath: root.appending(path: "notes.txt").path, contents: Data())

            let renamed = AppState.repairVoiceIDs(in: root, fm: fm)
            let names = Set((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])

            checkBool("broken clip is renamed to a legal id", names.contains("My-Sam.wav"), true)
            checkBool("the illegal name is gone", names.contains("My Sam.wav"), false)
            checkEq("rename is reported so the selection can follow",
                    renamed.renamed.map { "\($0.0)->\($0.1)" }.joined(separator: ","), "My Sam->My-Sam")
            // The bytes must be the SAME file, not a fresh empty one.
            checkEq("the audio moved, not just the name",
                    (try? String(contentsOf: root.appending(path: "My-Sam.wav"), encoding: .utf8)) ?? "<gone>",
                    "broken")
            checkBool("an already-legal voice is untouched", names.contains("Ravi.wav"), true)
            // A collision must never overwrite the voice that already works.
            checkEq("a colliding rename does not clobber the working voice",
                    (try? String(contentsOf: root.appending(path: "Clara.wav"), encoding: .utf8)) ?? "<gone>",
                    "legal-clara")
            checkBool("the colliding clip is left in place", names.contains("Clara!.wav"), true)
            checkBool("an unsluggable stem is left alone", names.contains("🎤.wav"), true)
            checkBool("non-wav files are ignored", names.contains("notes.txt"), true)
            // Every clip left behind must be REPORTED, not silently abandoned —
            // it is still listed by the backend and still refuses to synthesize,
            // so the caller has to know not to leave it selected.
            checkEq("skipped clips are reported as unresolved",
                    renamed.unresolved.sorted().joined(separator: ","), "Clara!,🎤")
            // Re-running must be a no-op, not a second round of renames.
            let again = AppState.repairVoiceIDs(in: root, fm: fm)
            checkBool("repair is idempotent", again.renamed.isEmpty, true)
            checkEq("and still reports the same leftovers",
                    again.unresolved.sorted().joined(separator: ","), "Clara!,🎤")

            // Where the saved selection ends up. A selection left pointing at an
            // id the backend refuses can only 400 — that's the case the repair has
            // to catch, not just the one it can rename.
            func sel(_ current: String) -> String {
                AppState.selection(after: renamed, current: current)
            }
            checkEq("a renamed selection follows its voice", sel("My Sam"), "My-Sam")
            checkEq("a selection left unresolvable is dropped", sel("Clara!"), "")
            checkEq("an unsluggable selection is dropped too", sel("🎤"), "")
            checkEq("a working selection is left alone", sel("Ravi"), "Ravi")
            checkEq("a catalog voice is left alone", sel("eve"), "eve")
            checkEq("no selection stays no selection", sel(""), "")
        }

        print("Delete guard — only our own Application Support dirs")
        do {
            let support = URL(fileURLWithPath: NSHomeDirectory())
                .appending(path: "Library/Application Support/Yap")
            // Refuses anything outside, however it was computed.
            checkBool("home itself is refused",
                      AppState.isDeletableAppSupportDir(URL(fileURLWithPath: NSHomeDirectory())), false)
            checkBool("Application Support itself is refused",
                      AppState.isDeletableAppSupportDir(support.deletingLastPathComponent()), false)
            checkBool("a nested path is refused",
                      AppState.isDeletableAppSupportDir(support.appending(path: "a/b")), false)
            checkBool("someone else's app dir is refused",
                      AppState.isDeletableAppSupportDir(
                        support.deletingLastPathComponent().appending(path: "OtherApp")), false)
            // A real one of ours passes only when it actually exists as a directory.
            checkBool("a non-existent dir of ours is refused (nothing to delete)",
                      AppState.isDeletableAppSupportDir(support.appending(path: "no-such-dir-xyz")), false)
            let tmp = support.appending(path: "selftest-delete-guard")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            checkBool("a real dir of ours is allowed",
                      AppState.isDeletableAppSupportDir(tmp), true)
            try? FileManager.default.removeItem(at: tmp)
        }

        print("Voice picker — a cloned voice is locked while cloning is off")
        do {
            // Shape the backend actually returns: catalog voices plus cloned refs
            // flagged needs_cloning, listed even when cloning failed to load.
            let vs = [
                VoiceInfo(id: "eve", lang: "en", lang_label: "English", gender: "female",
                          section: "Pocket Voices", needs_cloning: nil),
                VoiceInfo(id: "Philip", lang: "en", lang_label: "English", gender: "male",
                          section: "✨ Cloned", needs_cloning: true),
            ]
            // Absent reads as unavailable here, so presence is asserted separately —
            // "locked" and "dropped from the list" are different bugs.
            func avail(_ list: [EngineVoice], _ id: String) -> Bool {
                list.first { $0.voiceId == id }?.available ?? false
            }
            let off = AppState.pocketVoices(vs, cloningReady: false)
            checkBool("catalog voice stays available with cloning off", avail(off, "eve"), true)
            checkBool("cloned voice is locked with cloning off", avail(off, "Philip"), false)
            checkBool("a locked cloned voice is still LISTED, not hidden",
                      off.contains { $0.voiceId == "Philip" }, true)

            let on = AppState.pocketVoices(vs, cloningReady: true)
            checkBool("cloned voice unlocks once cloning loads", avail(on, "Philip"), true)
            checkBool("catalog voice unaffected by cloning state", avail(on, "eve"), true)
        }

        print("UpdateChecker — semantic version compare")
        checkBool("newer patch is newer", UpdateChecker.isNewer("0.8.2", than: "0.8.1"), true)
        checkBool("older is not newer", UpdateChecker.isNewer("0.8.0", than: "0.8.1"), false)
        checkBool("equal is not newer", UpdateChecker.isNewer("0.8.1", than: "0.8.1"), false)
        checkBool("v-prefix tolerated", UpdateChecker.isNewer("v0.9.0", than: "0.8.9"), true)
        checkBool("1.2 equals 1.2.0 (not newer)", UpdateChecker.isNewer("1.2", than: "1.2.0"), false)
        checkBool("minor beats high patch", UpdateChecker.isNewer("0.9.0", than: "0.8.99"), true)
        checkBool("major beats all", UpdateChecker.isNewer("1.0.0", than: "0.99.99"), true)
        checkBool("prerelease is not newer than its stable", UpdateChecker.isNewer("0.8.1-beta", than: "0.8.1"), false)
        checkBool("stable IS newer than same-core prerelease", UpdateChecker.isNewer("0.8.1", than: "0.8.1-beta"), true)
        checkBool("higher release beats a prerelease", UpdateChecker.isNewer("0.9.0", than: "0.8.9-beta"), true)
        checkBool("normalized strips leading v", UpdateChecker.normalized("v1.2.3") == "1.2.3", true)

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
