# Privacy & permissions

Yap is a local-first utility. This document says exactly what it does, what
it touches, and why — so you don't have to take "private" on faith.

## The short version

- Runs entirely on your Mac. Speech is synthesized locally (Kokoro, or Pocket
  TTS if you enable it); dictation is transcribed locally on the Apple Neural
  Engine using Parakeet and Nemotron models.
- No account, no sign-in, no analytics, no telemetry, no crash reporting. That
  now covers voice cloning too: it used to need your own Hugging Face token, and
  it no longer needs one, so Yap stores no credential of yours anywhere and reads
  nothing from your Keychain.
- Nothing about you is ever sent. Yap goes online only to download models and
  to check for updates. The full list is in
  [What goes over the network](#what-goes-over-the-network).
- Open source. Every capability described here is in this repo.
- Don't trust the prose? It's 2026. Point your coding agent (Claude Code or
  similar) at this repo and let it confirm these claims, or read the source
  yourself. Start with [`TextCapture.swift`](../app/Sources/Yap/TextCapture.swift)
  (capture) and [`server.py`](../backend/server.py) (the only thing that touches
  the TTS model). Or build your own and use these binaries as a reference.

## What goes over the network

Every network call Yap makes is a download or the update check. None of them
sends your audio, your text, or anything that identifies you.

**At launch, without a click:**

- **The Kokoro voice** (~340 MB), only when no voice is installed: no Kokoro
  files and no Pocket engine. Both files are checked against pinned SHA-256
  hashes before use. If the download fails, pressing the read shortcut tries
  again. If you delete Kokoro in Settings ▸ Models with Pocket not installed,
  it downloads again at the next launch. Turn off **Reading aloud (voice)** in
  Settings ▸ General to stop this.
- **Dictation models.** With Dictation on (the default), Yap loads the selected
  model pair at launch and downloads any missing files. English uses Parakeet
  Flash for streaming and Parakeet TDT v2 for the final pass; multilingual uses
  Nemotron and Parakeet TDT v3. They are cached in
  `~/Library/Application Support/FluidAudio/Models`. If you delete them in
  Settings ▸ Models, they download again at the next launch. Turn off
  **Dictation (ears)** in Settings ▸ General to stop this.
- **Pocket model files.** Once the Pocket engine is installed, its model files
  (weights, tokenizer and built-in voices) download from Hugging Face the first
  time Pocket loads. Pocket loads at launch when it is the selected engine, or
  when **Pre-load Pocket at launch** is on (the default, in Settings ▸
  Models). Turning pre-load off does not stop this while Pocket is selected.
- **The update check**, once a day. See [below](#the-update-check-optional).

**When you ask for it:**

- The Kokoro model (~340 MB), from **Download model** in Settings ▸ Models.
- The Pocket engine's packages, from Settings ▸ Voices or Settings ▸ Models.
  Setup also fetches the 209 MB voice-cloning weights if no usable local copy
  exists, even if you only use catalog voices. **Download & enable cloning** in
  Settings ▸ Voices ▸ Clone a voice fetches them on their own.
- The free CMU ARCTIC starter voices, from **Get free starter voices** in
  Settings ▸ Voices ▸ Clone a voice.
- Dictation models while Dictation is off, from the menu's **Dictate** button or
  engine picker, or from Settings ▸ Models.

Once those downloads finish, and with the update check off, idle Yap makes no
outbound connections. Check with Little Snitch or `nettop`.

## The two permissions Yap asks for

Yap has two jobs: read the text you select aloud, and type back what you say.
Each needs exactly one grant, and you can use either half without the other.

### Accessibility (reading a selection, and typing a transcript back)

macOS protects three capabilities behind it:

1. **Reading the selected text of another app.** macOS only lets a *trusted*
   process query another app's UI via the Accessibility API (`AXUIElement` →
   `kAXSelectedTextAttribute`). Without the grant, that call returns nothing.

2. **Simulating ⌘C for the clipboard fallback.** When an app doesn't expose its
   selection over the Accessibility API, Yap falls back to copying: it posts
   a synthetic ⌘C (`CGEvent`), reads the result, and **restores your previous
   clipboard**. Posting a synthetic keystroke also requires the same trust.

3. **Simulating ⌘V to paste a transcript at your cursor.** Dictation puts the
   finished text on the pasteboard, posts a synthetic ⌘V, then **restores your
   previous clipboard**: the same mechanism and the same restore as the copy
   path ([`TextInsert.swift`](../app/Sources/Yap/TextInsert.swift)).

These are the *only* reasons. The grant is broad on paper ("control your
computer") because that's the single switch macOS offers — but what Yap
actually does with it is narrow and visible in
[`TextCapture.swift`](../app/Sources/Yap/TextCapture.swift).

### Microphone (dictation)

Press ⌘⇧D to start dictation. Capture begins once the model is ready and
microphone permission is granted. Press again to stop; Yap allows a 0.6-second
finishing window to catch the last word and mic buffers.
The HUD stays red and says “Finishing…” during that window. The mic then closes
before the final transcript is inserted. Audio is processed by a local Parakeet
or Nemotron model on the Apple Neural Engine; it is
**never written to disk and never leaves the machine**. There is no sidecar,
and the only network use is downloading its models
([`Dictation.swift`](../app/Sources/Yap/Dictation.swift)). Don't dictate? Don't
grant it. The read-aloud half works without it.

## The agent API (a local socket)

Other programs on your Mac can ask Yap to speak, or to listen, through a Unix
socket at `~/Library/Application Support/Yap/yap.sock`
([details](AGENT-API.md)). It is a file, not a network port: no connection leaves
your Mac, web pages cannot reach it, and other macOS users cannot open it (it is
mode `0600`). The API adds no outbound network call.

It cannot stop a program running as *you* from using it. Speaking is harmless.
Listening is not, because those programs would borrow Yap's Microphone grant
without macOS asking them. So listening through the API is **off by default**, the
dictation HUD shows whenever the mic is open, and the words go to the program
that asked, not to your cursor, unless it asks for that. The whole API can be
switched off, which removes the socket.

## What Yap does NOT do

- No keylogging. It reads a selection only when you press the shortcut — it does
  not observe what you type.
- No always-on listening. The mic records only during a dictation session,
  including the 0.6-second finishing window after you press stop. A program using
  the [agent API](AGENT-API.md) starts the same session, with the same HUD, and
  only once you have turned that on.
- No screen reading or screenshots.
- No background scraping. Nothing is captured unless you trigger it.
- No clipboard hijacking. The fallback restores whatever was on your clipboard.
- Nothing about you leaves the machine. There is no remote server, no API key, no
  upload path in the code (the agent API is a local socket, not a network service). Outbound requests are the downloads and the update check
  listed in [What goes over the network](#what-goes-over-the-network).

## The update check (optional)

So you know when a new version ships, Yap checks GitHub once a day for the latest
release. It's a single unauthenticated GET to the public releases API
(`api.github.com/repos/latent-variable/Yap/releases/latest`) — no account, no
identifier, no usage data sent. Yap just receives the latest version number,
compares it to the running build, and shows a banner if a newer one exists. It
never downloads or installs anything on its own: the banner links to the release
page, and you update via Homebrew or the DMG yourself.

On by default, throttled to once per day. Turn it off in **Settings ▸ General ▸
Updates**. That stops update checks only; the launch downloads above are
separate. The whole thing is one file:
[`UpdateChecker.swift`](../app/Sources/Yap/UpdateChecker.swift).

## Read source modes and your clipboard

Yap ships with **Read source → Selected text** and **Capture method → Clipboard**.
For a selected-text read, Yap saves the pasteboard, posts a synthetic ⌘C to read
the selection, then restores the saved contents. This needs Accessibility
permission to post the key event. Set **Capture method → Accessibility** to read
a live selection through the Accessibility API without using the clipboard.

**Auto** is opt-in (Settings ▸ Permissions ▸ Read source). It tries to read the live
selection using the selected Capture method, then falls back to the clipboard
when no text is returned. Some apps (iTerm and other terminals) don't expose
their selection to the Accessibility API and block synthetic ⌘C, so Yap reads
the clipboard instead. If you turn Auto on, two things are worth knowing:

- **Yap restores the pasteboard after synthetic ⌘C.** The Auto fallback only
  reads the clipboard.
- **The one clipboard change you'll see in a terminal is its own doing.** iTerm's
  copy-on-select feature replaces your clipboard the moment you highlight text.
  That's the terminal, not Yap. So after reading in iTerm, your previous
  clipboard contents are gone, replaced by what you selected.

It's a small quirk you get used to.

## The no-permission option

You can read aloud without granting anything: set **Read source → Clipboard**.
Then you copy text yourself (⌘C) and press the shortcut; Yap reads the
clipboard. Reading your own clipboard is unrestricted, so no permission is
involved.

## The stale-grant gotcha (and the fix)

The app is ad-hoc signed for now. macOS ties an Accessibility grant to a code
identity, and an ad-hoc identity changes on every rebuild. So after you install
an update, the old "on" toggle can be orphaned — present and enabled, but not
matching the new binary. Symptom: the toggle is on yet Yap still asks.

Fix it cleanly:

1. System Settings ▸ Privacy & Security ▸ Accessibility.
2. Select **Yap**, click **−** to remove it.
3. Relaunch Yap and grant again (fresh entry, bound to the current binary).

Permanent fix — run once:

```bash
bash scripts/setup_signing.sh      # creates a stable self-signed identity
bash scripts/build_app.sh          # now signs with it
```

After that the code identity is stable across rebuilds, so a single grant
persists through every future update.

## Verify it yourself

```bash
# what the app sees for capture, including trust state:
/Applications/Yap.app/Contents/MacOS/Yap --diag

# runtime log of every capture attempt:
cat ~/Library/Application\ Support/Yap/yap.log
```

The log stays on this Mac. Per capture it records which app was in front (its
bundle id, e.g. `com.googlecode.iterm2`), whether the clipboard changed since the
last press, how long the capture took and how many characters it got. Never the
text itself.
