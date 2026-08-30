"""Pocket TTS engine — Kyutai Pocket TTS. Yap's second (HD) engine; replaces
Chatterbox.

One model family, two capabilities:

  - **Catalog voices** (built-in, no account): 26 predefined speakers. Served by
    the *ungated* `kyutai/pocket-tts-without-voice-cloning` weights, downloaded
    automatically on first load. This is what every user gets out of the box.
  - **Voice cloning** (opt-in): clone any reference clip in `hd-voices/`. Needs
    Kyutai's English cloning weights, which upstream gates behind a Hugging Face
    account. Yap fetches a byte-identical CC-BY-4.0 mirror instead (see
    CLONING_WEIGHTS_URL) — no account, no token, no Keychain. Until those weights
    are on disk, cloning is unavailable and the catalog still works.

CPU, ~10x realtime on Apple Silicon — fast enough that it uses the normal
per-segment pipeline (no buffer-aware HD chunking). Lazy: nothing here imports
torch / pocket_tts until the engine actually loads, so the default Kokoro path
stays light. Heavy deps install on demand into hd-packages (shared dir, already
on the backend's PYTHONPATH), same as the old HD engine.
"""
from __future__ import annotations

import gc
import hashlib
import logging
import os
import shutil
import sys
import threading
from pathlib import Path
from typing import Optional

import numpy as np

log = logging.getLogger("yap")

SAMPLE_RATE = 24000  # Pocket native; matches Kokoro / the int16 PCM contract

# Pocket wraps every utterance in its own silence, and it is per-utterance
# overhead rather than anything to do with the line: measured at 0.56-0.96s
# leading and 0.20-0.34s trailing on lines from three words to twenty. Kokoro,
# on the identical text, leaves 0.04-0.05s and 0.09-0.19s.
#
# Playing that verbatim put roughly a second of dead air in front of EVERY
# sentence, on top of the pause server.py already inserts between segments — so
# a Pocket read dragged, and GAP_SENTENCE meant one thing on Kokoro and another
# on Pocket. Trimming back to Kokoro's range is what makes the gap a caller asks
# for the gap a listener hears, on either engine.
LEAD_PAD = 0.05    # seconds of silence to keep before the first sound
TRAIL_PAD = 0.15   # ...and after the last, so a line doesn't end clipped


def trim_padding(a: np.ndarray, sr: int = SAMPLE_RATE,
                 lead: float = LEAD_PAD, trail: float = TRAIL_PAD) -> np.ndarray:
    """Cut a Pocket utterance's leading/trailing silence back to `lead`/`trail`.

    Only ever REMOVES: a clip already tighter than the targets is returned
    untouched, and one with no detectable speech at all is returned whole rather
    than emptied — dropping audio would be a far worse failure than leaving a
    little silence on it.
    """
    if a.size == 0:
        return a
    fl = max(1, int(0.01 * sr))                       # 10 ms frames
    frames = a[: a.size // fl * fl].reshape(-1, fl)
    if frames.size == 0:
        return a
    rms = np.sqrt((frames ** 2).mean(axis=1))
    peak = float(np.abs(a).max())

    # TWO thresholds, because one cannot do this job. A single "is this speech"
    # level set high enough to ignore the model's noise floor also sits above a
    # quiet onset — an /s/ or /f/ before the vowel — and trimming to it lops the
    # front off the word. So: `speech` finds a frame that is confidently speech,
    # then we walk outward while frames stay above `floor`, which is barely off
    # true silence. The word's quiet edges are inside that walk.
    speech = max(0.005, peak * 0.02)
    floor = max(0.0015, peak * 0.004)
    loud = np.flatnonzero(rms >= speech)
    if loud.size == 0:
        return a
    first, last = int(loud[0]), int(loud[-1])
    while first > 0 and rms[first - 1] >= floor:
        first -= 1
    while last < rms.size - 1 and rms[last + 1] >= floor:
        last += 1

    start = max(0, first * fl - int(lead * sr))
    end = min(a.size, (last + 1) * fl + int(trail * sr))
    return a[start:end]


# Predefined catalog voices (the without-cloning model). Hardcoded so we can list
# them before the model loads; mirrors pocket_tts _ORIGINS_OF_PREDEFINED_VOICES.
# (lang lets the UI group non-English voices.)
CATALOG_VOICES: list[tuple[str, str]] = [
    ("alba", "en"), ("anna", "en"), ("azelma", "en"), ("bill_boerst", "en"),
    ("caro_davy", "en"), ("charles", "en"), ("cosette", "en"), ("eponine", "en"),
    ("eve", "en"), ("fantine", "en"), ("george", "en"), ("jane", "en"),
    ("javert", "en"), ("jean", "en"), ("marius", "en"), ("mary", "en"),
    ("michael", "en"), ("paul", "en"), ("peter_yearsley", "en"),
    ("stuart_bell", "en"), ("vera", "en"),
    ("giovanni", "it"), ("lola", "es"), ("juergen", "de"),
    ("rafael", "pt"), ("estelle", "fr"),
]
CATALOG_NAMES = frozenset(name for name, _ in CATALOG_VOICES)


# Heavy deps live here (shared with the rest of the app's on-demand install dir,
# already added to the backend PYTHONPATH by BackendManager).
def hd_packages_dir() -> Path:
    return Path(os.environ.get("YAP_HD_DIR") or os.environ.get("PARLEY_HD_DIR") or
                (Path.home() / "Library/Application Support/Yap/hd-packages"))


def _ensure_path() -> None:
    p = str(hd_packages_dir())
    if p not in sys.path and Path(p).exists():
        sys.path.insert(0, p)


# ── cloning weights: self-hosted, no account ────────────────────────────────
#
# Cloning needs Kyutai's English cloning weights. Upstream ships them in a GATED
# HF repo, so every user needed a Hugging Face account, a terms click and a token
# in their Keychain — the one part of Yap that required an account, in an app
# whose whole promise is that it requires none.
#
# The weights are CC-BY-4.0, which permits redistribution with attribution, so we
# serve a byte-identical mirror instead and fetch it like any other model file.
# Verified identical to the gated original: same 219,029,196 bytes, same SHA256
# (HF's own dedup collapsed the upload to zero new bytes). Kyutai's acceptable-use
# terms travel with the file, and are carried in the mirror's model card and in
# Yap's own cloning UI.
CLONING_WEIGHTS_URL = (
    "https://huggingface.co/latent-variable/pocket-tts-cloning-en/"
    "resolve/main/languages/english/model.safetensors"
)
# Pinned and CHECKED before the file is handed to the loader. Same discipline as
# STARTER_SHA256 in server.py: a mirror we control is still a network fetch, and a
# swapped weights file would silently poison every cloned voice rather than fail.
CLONING_WEIGHTS_SHA256 = "473f47d99560bd50eb8b4509d3cacfe7f316ab20bdca86505403a2e6a936a6e9"
CLONING_WEIGHTS_BYTES = 219029196


def weights_dir() -> Path:
    return Path(os.environ.get("YAP_POCKET_WEIGHTS_DIR") or
                (Path.home() / "Library/Application Support/Yap/pocket-weights"))


def cloning_weights_path() -> Path:
    return weights_dir() / "english-cloning.safetensors"


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def cloning_weights_ready() -> bool:
    """Is a usable copy of the cloning weights on disk?

    Size only, deliberately. This is called on every /health and /engines, and
    hashing 209 MB each time would cost ~0.5s per status poll. The full digest is
    checked where it actually matters — once, after the download, before the file
    is ever used (see ensure_cloning_weights). A file of exactly the right size but
    wrong content cannot arrive from a completed verified download; it could only
    be put there by hand.
    """
    try:
        return cloning_weights_path().stat().st_size == CLONING_WEIGHTS_BYTES
    except OSError:
        return False


def _legacy_hf_copy() -> Optional[Path]:
    """A copy already in the HF cache, from the old token-based setup.

    Anyone who set cloning up before this change has the identical file sitting in
    ~/.cache/huggingface. Reusing it saves them a second 209 MB download; the hash
    check in ensure_cloning_weights still gates it, so a truncated or unrelated
    cache entry is rejected exactly like a bad download.
    """
    try:
        from huggingface_hub.constants import HF_HUB_CACHE
        hub = HF_HUB_CACHE
    except Exception:  # noqa: BLE001
        hub = (os.environ.get("HF_HUB_CACHE")
               or (os.path.join(os.environ["HF_HOME"], "hub") if os.environ.get("HF_HOME") else None)
               or os.path.join(os.path.expanduser("~"), ".cache", "huggingface", "hub"))
    snaps = Path(hub) / "models--kyutai--pocket-tts" / "snapshots"
    try:
        for snap in snaps.iterdir():
            for f in snap.rglob("*.safetensors"):
                try:
                    if f.stat().st_size == CLONING_WEIGHTS_BYTES:
                        return f
                except OSError:
                    continue
    except OSError:
        pass
    return None


def ensure_cloning_weights(log_line=None) -> bool:
    """Put a VERIFIED copy of the cloning weights on disk. Returns success.

    Never leaves a partial file where a later run would trust it: the download goes
    to a temp path, is hashed, and is only renamed into place once it matches. A
    mismatch deletes the temp file and fails loudly rather than half-enabling
    cloning.
    """
    say = log_line or (lambda _m: None)
    dest = cloning_weights_path()
    if cloning_weights_ready():
        return True
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(".part")
    # A .part left by a crashed or killed run is NOT a download to finish: urllib
    # gives us no resume, and the code below only downloads when tmp is absent. A
    # leftover would therefore be hashed, rejected, and reported as a failed fetch
    # while nothing was ever retried. Clear it and start clean.
    tmp.unlink(missing_ok=True)

    legacy = _legacy_hf_copy()
    if legacy is not None:
        say(f"reusing the cloning weights already in your Hugging Face cache ({legacy})")
        try:
            shutil.copyfile(legacy, tmp)
        except OSError as e:
            say(f"could not reuse the cached copy ({e}); downloading instead")
            tmp.unlink(missing_ok=True)
    if not tmp.exists():
        say(f"downloading Pocket cloning weights ({CLONING_WEIGHTS_BYTES // (1 << 20)} MB, one time)")
        try:
            import urllib.request
            with urllib.request.urlopen(CLONING_WEIGHTS_URL, timeout=60) as r, open(tmp, "wb") as f:
                shutil.copyfileobj(r, f, length=1 << 20)
        except Exception as e:  # noqa: BLE001
            say(f"download failed: {e}")
            tmp.unlink(missing_ok=True)
            return False

    got = _sha256(tmp)
    if got != CLONING_WEIGHTS_SHA256:
        say(f"checksum mismatch (got {got[:16]}…, want {CLONING_WEIGHTS_SHA256[:16]}…) — discarding")
        tmp.unlink(missing_ok=True)
        return False
    tmp.replace(dest)
    say("cloning weights verified and installed")
    return True


def _cloning_config() -> Optional[Path]:
    """pocket_tts's own english.yaml with `weights_path` pointed at our local file.

    Derived from the INSTALLED package rather than vendored: that YAML carries the
    model architecture and the tokenizer revision, so pinning a copy here would
    silently freeze us at today's architecture and break on the next pocket_tts
    upgrade. Only the one line changes; `download_if_necessary` treats a value that
    is neither http(s):// nor hf:// as a plain local path.
    """
    try:
        from pocket_tts.models.tts_model import CONFIGS_DIR
        src = Path(CONFIGS_DIR) / "english.yaml"
        out = weights_dir() / "english-local.yaml"
        weights = str(cloning_weights_path())
        lines = []
        replaced = False
        for line in src.read_text().splitlines(keepends=True):
            if line.startswith("weights_path:"):
                lines.append(f"weights_path: {weights}\n")
                replaced = True
            else:
                lines.append(line)
        if not replaced:          # upstream renamed the key — don't guess
            return None
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text("".join(lines))
        return out
    except Exception:  # noqa: BLE001
        log.exception("could not build a local Pocket config")
        return None


def _restore_language_origin(model) -> None:
    """Point a config-loaded model back at the canonical english.yaml.

    pocket_tts resolves a CATALOG voice by taking the language from the stem of the
    config the model was loaded from, and refuses outright unless that config sits
    inside its own CONFIGS_DIR (see get_state_for_audio_prompt). Loading through our
    copy therefore keeps cloning working but breaks all 26 catalog voices with
    "Cannot use predefined voices ...". Caught end-to-end, not in review.

    Our config IS that english.yaml with a single line changed, so restoring the
    origin states which language config this is rather than defeating a check. Best
    effort: if upstream drops the attribute, catalog voices fail loudly the same way
    they would have anyway, and cloning is unaffected.
    """
    try:
        from pocket_tts.models.tts_model import CONFIGS_DIR
        model.origin = Path(CONFIGS_DIR) / "english.yaml"
    except Exception:  # noqa: BLE001
        log.warning("could not restore the model's language origin; "
                    "catalog voices may be unavailable this session", exc_info=True)


class PocketEngine:
    name = "pocket"
    label = "Pocket TTS"

    def __init__(self):
        self.model = None
        self.error: Optional[str] = None
        self.has_cloning = False          # set True only if the gated model loaded
        # voice key -> cached conditioning. Catalog voices key by name (str);
        # cloned refs key by (path, mtime) so re-recording a voice under the same
        # name busts the stale conditioning instead of reusing the old clip's.
        self._states: dict[object, object] = {}
        # Serializes model access: pocket_tts/torch inference is not guaranteed
        # thread-safe and FastAPI sync endpoints run in a threadpool, so a warm
        # (voice switch) and a synth (read) can land concurrently. load() is only
        # ever called OUTSIDE a held lock, so no locked section re-enters it.
        self._lock = threading.Lock()

    def available(self) -> bool:
        """Is pocket_tts importable (without loading the model)?"""
        _ensure_path()
        import importlib.util
        return importlib.util.find_spec("pocket_tts") is not None

    def load(self) -> bool:
        with self._lock:
            if self.model is not None:
                return True
            if not self.available():
                self.error = "Pocket engine not installed"
                return False
            try:
                _ensure_path()
                from pocket_tts import TTSModel
                # Cloning weights present -> load through a config pointing at our
                # own verified copy. Absent -> the plain load, which pulls the
                # UNGATED catalog weights. Neither path needs a token or an
                # account, and neither touches the Keychain.
                cfg = _cloning_config() if cloning_weights_ready() else None
                log.info("loading Pocket TTS (cloning weights=%s)", cfg is not None)
                if cfg is not None:
                    m = TTSModel.load_model(config=str(cfg))
                    _restore_language_origin(m)
                else:
                    m = TTSModel.load_model()
                self.model = m
                self.has_cloning = bool(getattr(m, "has_voice_cloning", False))
                self.error = None
                self._warmup()
                log.info("Pocket TTS ready (cloning=%s, sr=%d)", self.has_cloning,
                         getattr(m, "sample_rate", SAMPLE_RATE))
                return True
            except Exception as e:  # noqa: BLE001
                self.error = str(e)
                log.exception("failed to load Pocket TTS")
                return False

    def _warmup(self) -> None:
        """First generate builds graphs; warm with a catalog voice so the user's
        first real read is fast. (Holds the load lock — no re-entry.)"""
        try:
            st = self._state_for("alba")
            self.model.generate_audio(st, "Ready.")
        except Exception:  # noqa: BLE001
            pass

    def _state_for(self, voice: str):
        """Resolve + cache the conditioning state for a voice. `voice` is either a
        catalog name (e.g. 'michael') or an absolute .wav path (cloning). Caller
        must hold the lock. Cloned refs are keyed by (path, mtime) so replacing a
        clip under the same name busts the cache."""
        key: object = voice
        if voice not in CATALOG_NAMES:
            try:
                key = (voice, os.path.getmtime(voice))
            except OSError:
                pass
        st = self._states.get(key)
        if st is None:
            st = self.model.get_state_for_audio_prompt(voice)
            self._states[key] = st
        return st

    def warm(self, voice: str) -> bool:
        """Load the model and prepare a voice so the first real read is fast."""
        if self.model is None and not self.load():
            return False
        try:
            with self._lock:
                if self.model is None:      # unloaded between load() and here
                    return False
                if voice:
                    # A cloned ref needs the gated model; if cloning isn't loaded,
                    # warm a catalog voice instead so the engine is still primed
                    # (and we don't log a spurious failure).
                    if voice not in CATALOG_NAMES and not self.has_cloning:
                        log.warning("Pocket cloning unavailable; warming catalog voice 'alba'")
                        voice = "alba"
                    st = self._state_for(voice)
                    self.model.generate_audio(st, "Ready.")
            return True
        except Exception as e:  # noqa: BLE001
            log.warning("Pocket warm failed: %s", e)
            return False

    def unload(self) -> bool:
        """Drop the loaded model + cached conditioning to free memory (torch is the
        heavy resident). Idempotent; a later synth/warm lazily reloads. Resets
        has_cloning so status reflects "not loaded", not a stale cloning verdict."""
        with self._lock:
            if self.model is None:
                return False
            self.model = None
            self._states.clear()
            self.has_cloning = False
        gc.collect()
        log.info("Pocket TTS unloaded")
        return True

    def voices(self) -> list[tuple[str, str]]:
        """Catalog voices (name, lang). Cloned reference clips are listed by the
        server from hd-voices/, gated on has_cloning."""
        return list(CATALOG_VOICES)

    def synth(self, text: str, voice: str, speed: float = 1.0) -> np.ndarray:
        """Speak `text` in `voice` (catalog name or reference-clip path). Returns
        float32 @ 24kHz. Speed is applied at playback, not here (parity with the
        other engines)."""
        if self.model is None and not self.load():
            raise RuntimeError(self.error or "Pocket engine not loaded")
        with self._lock:
            # Re-check inside the lock: a concurrent unload() could have nulled the
            # model between load() above and here (same guard as Engine.synth).
            if self.model is None:
                raise RuntimeError(self.error or "Pocket engine not loaded")
            st = self._state_for(voice)
            audio = self.model.generate_audio(st, text)
        if hasattr(audio, "detach"):
            out = audio.detach().cpu().numpy().astype(np.float32)
        else:
            out = np.asarray(audio, dtype=np.float32)
        # Strip the model's per-utterance padding before it reaches the caller,
        # so the segment gaps server.py inserts are the only silence between
        # sentences. See trim_padding().
        return trim_padding(out)

    def status(self) -> dict:
        return {
            "name": self.name,
            "label": self.label,
            "installed": self.available(),
            "loaded": self.model is not None,
            "cloning": self.has_cloning,
            # Whether the weights are ON DISK, which is a different question from
            # whether they are LOADED: the engine is lazy, so `cloning` reads false
            # until something warms it. The app needs the disk answer to decide
            # between offering cloning and offering to install it.
            "cloning_installed": cloning_weights_ready(),
            "error": self.error,
        }
