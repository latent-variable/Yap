# Yap demo narration

Canonical voiceover script for the README/hero video. Written to be **heard**,
not read, in a **Pocket TTS** voice — the demo should show off the nicest voice
Yap ships, since the voice *is* the product. The take that ships is the cloned
**Philip** at **1.25x**, which is what a real Yap read sounds like.

## How to render the voiceover

```bash
scripts/make_voiceover.sh      # -> docs/demo-voiceover.wav (gitignored, regenerable)
scripts/make_hero_video.sh     # muxes it over docs/yap-hero.png -> docs/yap-readme.mp4
```

`Philip` is a cloned reference clip in `~/Library/Application Support/Yap/hd-voices`,
not in the repo, so anyone else renders with a catalog voice:
`YAP_VOICEOVER_VOICE=eve scripts/make_voiceover.sh`. `YAP_VOICEOVER_SPEED` and
`YAP_VOICEOVER_GAP` are there for auditioning other takes.

**Two things the renderer has to do, and the first take did neither.** Pocket
pads every utterance with its own silence — measured at 0.66–0.91s leading, up to
0.40s trailing — so the pauses this script asks for landed *on top* of it and the
first cut ran 61s at 57% silence. And Pocket ignores its `speed` argument
entirely; Yap applies speed at playback, so rendering raw gives a 1.0x take
nobody hears. `make_voiceover.py` trims each chunk before adding the pause and
finishes with a pitch-preserving `atempo` pass. Same script, 31s.

## Script (≈30s at 1.25x)

Meet Yap. Your Mac just grew ears and a voice.

Stop typing. Hold one key, start talking, and your words land right where your cursor is. Anywhere. Any app.

See something worth hearing? Highlight it, tap a shortcut, and Yap reads it back in a voice this natural. Wait. That's me. Hi.

Here's the real trick. Point Yap at your coding agent. Ramble your idea out loud, then kick back and let the agent brief you out loud while you stare out the window. No keyboard. No eye strain. Just two voices, going back and forth.

And all of it, every single word, stays on your Mac. No cloud. No account. Nobody listening but you.

This is Yap. Quit typing at your computer. Start yapping with it.
