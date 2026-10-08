<div align="center">



https://github.com/user-attachments/assets/fee265a8-1ade-4293-bab5-8d3938d08598



# Yap

**Talk to your Mac. It talks back. You both yap.**

Your keyboard is slow and your eyes are slower. Give your Mac ears and a voice instead: hold a key and talk, your words type themselves; highlight anything and hear it out loud in a shockingly human voice. Fully local. No cloud, no account, nobody listening but you.

[Install](#install) · [The loop](#the-loop) · [What it does](#what-it-does)

</div>

---

You think faster than you type, and way faster than you read. So stop doing both. **Yap** gives your Mac two things it was missing: **ears** (hold a key, talk, and local [Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) drops your words right where the cursor is) and a **voice** (highlight anything, tap a shortcut, hear it read back in a real [Kokoro](https://github.com/hexgrad/kokoro) or Pocket voice). Until Neuralink wires you straight into your coding agent, this is the shortcut: quit typing *at* your computer, start yapping *with* it.

## Install

The app bundles its own Python — nothing else to install.

**① Homebrew** — easiest, no Gatekeeper prompt.

```bash
brew install --cask latent-variable/tap/yap
```

**② DMG** — grab `Yap-*.dmg` from [Releases](https://github.com/latent-variable/Yap/releases), drag to Applications, then clear the one-time quarantine (it's open-source, not notarized): `xattr -cr /Applications/Yap.app`.

**③ Build from source** — needs Xcode command-line tools.

```bash
git clone https://github.com/latent-variable/Yap.git
cd Yap && bash scripts/build_app.sh && open dist/Yap.app
```

On first launch, open **Settings ▸ Models** and download the Kokoro model (~340 MB) — the menu bar flags it until you do. Grant Accessibility + Microphone when asked (Clipboard mode skips Accessibility; dictation always needs the mic). Then: **⌘⇧D** to dictate, **⌘⇧R** to read the selection aloud.

## The loop

The real unlock is closing the loop with an **AI coding agent**. You stop touching the two slowest parts of the workflow:

1. **You → agent (ears).** ⌘⇧D, ramble your prompt, press again. No keyboard.
2. **Agent → you (voice).** Highlight its answer, ⌘⇧R, it reads back. No eyes.

Talk, listen, repeat — pair-program with something that briefs you out loud while you stare out the window.

### Make your agent talk back

Agent output is full of code and tables that sound awful aloud. One instruction fixes it — drop this into your agent's `AGENTS.md` / `CLAUDE.md` / system prompt:

```md
## 🔊 Speak to me
End substantive replies with a `## 🔊 Speak to me` section: a few plain,
conversational sentences narrating what you did, what it means, and what's next —
written to be *heard*, not skimmed. No markdown, code, tables, or symbols inside
it (a TTS tool reads "asterisk" and "backtick" out loud). Spell numbers and flags
out in words. Skip it for trivial one-liners.
```

Now highlight that section, hit ⌘⇧R, and your agent literally briefs you:

![A "Speak to me" section an agent wrote, ready to read aloud](docs/speak-to-me.png)

## What it does

![Yap's Settings window and menu-bar dropdown — pick a voice, speed, and read the selection](docs/settings.png)

- **Ears:** dictate into apps that accept a paste. Press the shortcut to start, speak, then press again to insert. A live preview updates in the floating HUD; the final, more accurate transcript is pasted at your cursor. English mode or the 25-language multilingual mode. Optional chime and cleanup for filler sounds such as "um" and "uh".
- **Free alternative to the dictation features of [Wispr Flow Pro](https://wisprflow.ai/pricing), [Superwhisper Pro](https://ai.superwhisper.com/), and [MacWhisper Pro](https://goodsnooze.gumroad.com/l/macwhisper).** Yap covers the core shortcut-to-cursor workflow with on-device Parakeet transcription.
- **Voice — read from anywhere.** Chrome, PDFs, Terminal, VS Code, Slack, Gmail. Reads the text you have selected (Accessibility), or right-click → **Services ▸ Read with Yap**. Opt into **Auto** and it falls back to your clipboard for apps that don't expose their selection (iTerm, other terminals).
- **Two engines, one dropdown.** **Kokoro** — 54 voices, 8 languages, instant, CPU. **Pocket TTS** (opt-in) — 26 markedly more natural built-in voices, ~10x realtime on CPU, plus **voice cloning** from a ~20s clip (one extra 209 MB download, no account).
- **Streaming playback** — audio starts while the rest synthesizes; live speed/pitch/volume, natural pauses. **Smart cleanup** strips Markdown/code/citations (General/Markdown/Code/Blog/LLM profiles + custom regex).
- **Flexible shortcuts** — a normal chord (⌘⇧R) or a **modifier-only chord** like ⌥⌘ (the "Alt+Win" press), held and released — handy for push-to-dictate.
- **Menu-bar only, fully local.** Manage/delete each model from Settings ▸ Models. Clone only voices you have rights to.

> **A clipboard quirk worth knowing.** In apps that don't expose their selection (iTerm, other terminals), Auto mode reads your clipboard. Two harmless side effects follow: highlighting in iTerm (copy-on-select) replaces whatever you had copied, and pressing Read with nothing selected speaks whatever is currently on your clipboard. You stop noticing it fast. Want strict selection-only? Settings ▸ Read source → **Selected text**.

## Permissions & privacy

100% on your Mac. No account, no telemetry, nothing about you ever sent. Missing dictation models download automatically at launch when Dictation is enabled (on by default): Parakeet Flash and Parakeet TDT v2 for English, or Nemotron and Parakeet TDT v3 for multilingual.

Turn off **Dictation (ears)** in Settings ▸ General to prevent automatic Dictation model downloads at launch. Missing models can still be requested from the menu's **Dictate** button or in Settings ▸ Models with the engine picker, **Download model**, or **Retry**, even when Dictation is off. Delete downloaded models from Settings ▸ Models; with Dictation on, missing files download again at the next launch.

Other downloads (the Kokoro model, Pocket packages, starter voices and cloning weights) are user-initiated. Pocket's catalog model weights download when Pocket first loads; this can happen at launch if Pre-load Pocket model at launch is enabled (on by default). The once-a-day update check is optional (toggle off in Settings ▸ General). **Accessibility** lets Yap read your selection and paste; **Microphone** feeds dictation. Audio never leaves the machine. Don't want to grant Accessibility? Switch **Read source → Clipboard** and copy text yourself first. Details: [docs/PRIVACY.md](docs/PRIVACY.md).

**Don't take my word for it.** It's 2026. Point your coding agent (Claude Code or similar) at this repo and have it read the source and confirm nothing about you ever leaves the machine. The source shows automatic and user-requested dictation model downloads, Pocket catalog weights that can download at launch, other Settings-initiated downloads, and the optional update check. Or build your own from source and use these binaries as a reference. If it holds up, a ⭐ is appreciated.

> Ad-hoc signed, so each reinstall is a new identity to macOS and the Accessibility grant can go stale — remove Yap from the list and re-add, or run `scripts/setup_signing.sh` once for a stable identity.

## Architecture

Native SwiftUI menu-bar app. **Voice** (TTS) talks to a local Python sidecar over `127.0.0.1`; **ears** (STT) run fully in-app on the ANE with local transcription. Missing dictation models download at launch when Dictation is enabled or when you request them.

```
SwiftUI app ──HTTP──> FastAPI sidecar ──┬─ kokoro-onnx (ONNX, CPU)      ← voice: default, instant
  hotkey · capture · cleanup            └─ Pocket TTS (PyTorch, CPU)   ← voice: opt-in, natural + cloning
  AVAudioEngine player                     streaming int16 PCM @ 24 kHz
  AVAudioEngine mic ──► FluidAudio / Parakeet + Nemotron (CoreML, ANE) ← ears: streaming dictation, in-app
```

~100 MB to download, ~270 MB installed (mostly the self-contained Python runtime). Download the Kokoro model (~340 MB) from Settings ▸ Models; the Pocket engine (torch, ~1 GB) is installed only if you enable it. Module map: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Develop

```bash
bash scripts/run_backend.sh                       # backend only (auto-creates venv)
bash scripts/build_app.sh && open dist/Yap.app    # build + run
cd app && swift build && "$(swift build --show-bin-path)/Yap" --selftest   # Swift tests
cd backend && python -m pytest tests/ -v          # backend suite
```

State lives in `~/Library/Application Support/Yap` (Kokoro models, venv, cloned voices) and `~/Library/Application Support/FluidAudio/Models` (dictation models). Both are gitignored and machine-local.

## License

MIT. Kokoro weights Apache-2.0 (hexgrad/Kokoro-82M); Pocket TTS by [Kyutai](https://github.com/kyutai-labs/pocket-tts), CC-BY-4.0 (Yap serves a byte-identical mirror of the cloning weights so no account is needed); starter reference voices from CMU ARCTIC. Dictation uses [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0) running NVIDIA Parakeet. Clone only voices you have rights to.
