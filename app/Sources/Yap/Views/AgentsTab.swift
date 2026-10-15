import SwiftUI

/// Settings ▸ Agents: the instructions that make a coding agent end its replies
/// with a short spoken briefing, ready to copy into AGENTS.md / CLAUDE.md, and
/// how to listen to it with Yap. Plain text in, plain text out: nothing here
/// talks to an agent or the network.
struct AgentsTab: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Prefs
    @State private var variant = AgentPrompt.Variant.decisions

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Agent replies are full of code, tables and links that sound awful read aloud. Paste this into your agent's instructions and every reply ends with a few plain sentences written to be heard, so you can listen to your agent instead of reading it.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("Style", selection: $variant) {
                        ForEach(AgentPrompt.Variant.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(variant.blurb).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                PromptBlock(text: AgentPrompt.text(variant))

                HStack {
                    Button {
                        state.readAloud(AgentPrompt.sample(variant))
                    } label: {
                        Label("Hear an example", systemImage: "play.fill")
                    }
                    .buttonStyle(CapsuleButtonStyle(gradient: Brand.voiceGradient))
                    Spacer()
                    Text("Works in Claude Code, Codex, Cursor, or any agent that reads an instructions file.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Make your agent talk back")
            }

            Section("Then, every reply") {
                step(1, "Copy the block above into AGENTS.md, CLAUDE.md, or your agent's system prompt.")
                step(2, "When the agent answers, select its Speak to me section and press", combo: prefs.hotKey)
                step(3, "Answer out loud: press, talk, press again. Your words land in the agent's prompt.",
                     combo: prefs.dictationHotKey)
            }
        }
        .formStyle(.grouped)
    }

    private func step(_ n: Int, _ text: String, combo: HotKeyCombo? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(Brand.title(12, .bold)).foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Brand.gradient))
            Text(text).fixedSize(horizontal: false, vertical: true)
            if let combo { ShortcutChip(combo: combo) }
            Spacer(minLength: 0)
        }
    }
}

/// A read-only, monospaced block with a Copy button: the thing you paste.
struct PromptBlock: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("AGENTS.md", systemImage: "doc.text")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: text)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.primary.opacity(0.05))
            Divider()
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
        }
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
    }
}

/// The instruction text itself, kept out of the view so `--selftest` can check
/// it stays speakable advice (and the README can quote the same words).
enum AgentPrompt {
    enum Variant: String, CaseIterable, Identifiable {
        case simple, decisions
        var id: String { rawValue }
        var label: String { self == .simple ? "Simple" : "With decisions" }
        var blurb: String {
            self == .simple
                ? "One spoken summary at the end of each reply."
                : "The header tells you, before you listen, whether the agent needs something from you."
        }
    }

    static func text(_ v: Variant) -> String {
        switch v {
        case .simple:
            return """
            ## 🔊 Speak to me
            End every reply longer than a line with a section headed `## 🔊 Speak to me`: a few plain, conversational sentences saying what you did, what it means, and what happens next, written to be heard, not skimmed.

            Inside it: no markdown, code, tables, links or symbols, because a voice reads them out literally. Spell out numbers and flags in words. Skip it when the task asks for an exact machine format, like JSON, a diff or a commit message.
            """
        case .decisions:
            return """
            ## 🔊 Speak to me
            End every reply longer than a line with a spoken block I will listen to through text-to-speech. Its header says whether I have to act:

            - `## 🔊 Speak to me · no input needed`: where the work stands and when it will be done.
            - `## 🔊 Speak to me · decision needed`: what you need from me, what I need to understand to decide, the options counted out in words with what each costs, and which you would pick. One ask per reply.

            Inside the block: plain spoken sentences only. No markdown, code, tables, links or symbols, because a voice reads them out literally. Spell out numbers and flags in words. Skip the block when the task asks for an exact machine format, like JSON, a diff or a commit message.
            """
        }
    }

    /// What an agent's block sounds like, for "Hear an example".
    static func sample(_ v: Variant) -> String {
        switch v {
        case .simple:
            return "Speak to me. I fixed the login bug. The session token was expiring a minute early because of a time zone mix up. All forty tests pass, and next I'll clean up the old helper."
        case .decisions:
            return "Speak to me, decision needed. The new search is ready, but it's slower on very large folders. You have two options. First, ship it now and speed it up next week. Second, wait two days and ship it fast. I'd ship it now, since most folders are small."
        }
    }
}
