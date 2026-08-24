# Privacy & permissions

Yap is a local-first utility. This document says exactly what it does, what
it touches, and why — so you don't have to take "private" on faith.

## The short version

- Runs entirely on your Mac. Speech is synthesized locally (Kokoro, or Pocket
  TTS if you enable it); dictation is transcribed locally on the Apple Neural
  Engine (Parakeet).
- No account, no sign-in, no analytics, no telemetry, no crash reporting.
- No telemetry, no account, nothing about you is ever sent. Yap's only network
  activity is fetching assets you opt into, plus an optional update check: the
  one-time Kokoro model download (~340 MB); the Pocket engine's packages and
  voices if you set that up; the gated weights if you clone a voice; and a
  once-a-day check for a newer release (default on, toggle off in Settings ▸
  General). With the update check off and nothing downloading, idle Yap makes no
  outbound connections — verify with Little Snitch / `nettop`.
- Open source. Every capability described here is in this repo.
- Don't trust the prose? It's 2026. Point your coding agent (Claude Code or
  similar) at this repo and let it confirm these claims, or read the source
  yourself. Start with [`TextCapture.swift`](../app/Sources/Yap/TextCapture.swift)
  (capture) and [`server.py`](../backend/server.py) (the only thing that touches
  the TTS model). Or build your own and use these binaries as a reference.

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

Dictation is a toggle: the mic opens when you press ⌘⇧D and closes when you
press it again. The audio goes straight to a local Parakeet model on the Apple
Neural Engine; it is
**never written to disk and never leaves the machine**. There is no sidecar and
no network call anywhere in the dictation path
([`Dictation.swift`](../app/Sources/Yap/Dictation.swift)). Don't dictate? Don't
grant it. The read-aloud half works without it.

## What Yap does NOT do

- No keylogging. It reads a selection only when you press the shortcut — it does
  not observe what you type.
- No always-on listening. The mic opens when you press the dictation shortcut and
  closes when you press it again. Nothing is recorded between those two presses.
- No screen reading or screenshots.
- No background scraping. Nothing is captured unless you trigger it.
- No clipboard hijacking. The fallback restores whatever was on your clipboard.
- No data leaves the machine. There is no server, no API key, no upload path in
  the code.

## The update check (the one optional network call)

So you know when a new version ships, Yap checks GitHub once a day for the latest
release. It's a single unauthenticated GET to the public releases API
(`api.github.com/repos/latent-variable/Yap/releases/latest`) — no account, no
identifier, no usage data sent. Yap just receives the latest version number,
compares it to the running build, and shows a banner if a newer one exists. It
never downloads or installs anything on its own: the banner links to the release
page, and you update via Homebrew or the DMG yourself.

On by default, throttled to once per day. Turn it off in **Settings ▸ General ▸
Updates**; with it off, Yap makes no *automatic* network calls — every other
download (the model, optional Pocket packages, cloned-voice weights) is one-time
and something you initiate. The whole thing is one file:
[`UpdateChecker.swift`](../app/Sources/Yap/UpdateChecker.swift).

## The Auto read source and your clipboard

The default **Auto** read source grabs your selection directly where it can.
Some apps (iTerm and other terminals) don't expose their selection to the
Accessibility API and also block the synthetic ⌘C, so in those apps Yap reads
your clipboard instead. Two things worth knowing:

- **Yap never overwrites your clipboard doing this.** The synthetic-⌘C path
  saves and restores it; the plain clipboard read only reads.
- **The one clipboard change you'll see in a terminal is its own doing.** iTerm's
  copy-on-select feature replaces your clipboard the moment you highlight text.
  That's the terminal, not Yap. So after reading in iTerm, your previous
  clipboard contents are gone, replaced by what you selected.

It's a small quirk you get used to. For strict selection-only behavior with no
clipboard involvement, set **Read source → Selected text**.

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
