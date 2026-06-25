# Privacy & permissions

Yap is a local-first utility. This document says exactly what it does, what
it touches, and why — so you don't have to take "private" on faith.

## The short version

- Runs entirely on your Mac. Speech is synthesized locally by the bundled
  Kokoro engine.
- No account, no sign-in, no analytics, no telemetry, no crash reporting.
- No network connection after the one-time model download (~340 MB from a public
  GitHub release). You can verify with Little Snitch / `nettop` — idle Yap
  makes no outbound connections.
- Open source. Every capability described here is in this repo.

## Why Accessibility is the one permission asked for

Yap's whole job: take the text you select and read it aloud. macOS protects
two capabilities behind the Accessibility permission, and both are needed for
that job:

1. **Reading the selected text of another app.** macOS only lets a *trusted*
   process query another app's UI via the Accessibility API (`AXUIElement` →
   `kAXSelectedTextAttribute`). Without the grant, that call returns nothing.

2. **Simulating ⌘C for the clipboard fallback.** When an app doesn't expose its
   selection over the Accessibility API, Yap falls back to copying: it posts
   a synthetic ⌘C (`CGEvent`), reads the result, and **restores your previous
   clipboard**. Posting a synthetic keystroke also requires the same trust.

These are the *only* reasons. The grant is broad on paper ("control your
computer") because that's the single switch macOS offers — but what Yap
actually does with it is narrow and visible in
[`TextCapture.swift`](../app/Sources/Yap/TextCapture.swift).

## What Yap does NOT do

- No keylogging. It reads a selection only when you press the shortcut — it does
  not observe what you type.
- No screen reading or screenshots.
- No background scraping. Nothing is captured unless you trigger it.
- No clipboard hijacking. The fallback restores whatever was on your clipboard.
- No data leaves the machine. There is no server, no API key, no upload path in
  the code.

## The no-permission option

You can use Yap without granting anything: set **Read source → Clipboard**.
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
