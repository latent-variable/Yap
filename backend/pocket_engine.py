"""Pocket TTS engine — Kyutai Pocket TTS. Yap's second (HD) engine; replaces
Chatterbox.

One model family, two capabilities:

  - **Catalog voices** (built-in, no account): 26 predefined speakers. Served by
    the *ungated* `kyutai/pocket-tts-without-voice-cloning` weights, downloaded
    automatically on first load. This is what every user gets out of the box.
  - **Voice cloning** (opt-in): clone any reference clip in `hd-voices/`. Needs
    the *gated* `kyutai/pocket-tts` weights — the user supplies their OWN Hugging
    Face token (read scope) AND accepts the repo terms once at
    https://huggingface.co/kyutai/pocket-tts . Token is read from the HF_TOKEN
    env var (the app sets it from the user's Keychain). Without it, cloning is
    unavailable but the catalog still works.

CPU, ~10x realtime on Apple Silicon — fast enough that it uses the normal
per-segment pipeline (no buffer-aware HD chunking). Lazy: nothing here imports
torch / pocket_tts until the engine actually loads, so the default Kokoro path
stays light. Heavy deps install on demand into hd-packages (shared dir, already
on the backend's PYTHONPATH), same as the old HD engine.
"""
from __future__ import annotations

import gc
import logging
import os
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


def _hf_token() -> str:
    return (os.environ.get("HF_TOKEN")
            or os.environ.get("HUGGING_FACE_HUB_TOKEN")
            or os.environ.get("HUGGINGFACE_HUB_TOKEN")
            or "").strip()


def _hf_hub_cache() -> str:
    """Where huggingface_hub keeps downloaded repos, honoring its env overrides."""
    try:
        from huggingface_hub.constants import HF_HUB_CACHE
        return HF_HUB_CACHE
    except Exception:
        if os.environ.get("HF_HUB_CACHE"):
            return os.environ["HF_HUB_CACHE"]
        if os.environ.get("HF_HOME"):
            return os.path.join(os.environ["HF_HOME"], "hub")
        return os.path.join(os.path.expanduser("~"), ".cache", "huggingface", "hub")


# A real weights file (kyutai/pocket-tts ships a ~219 MB model.safetensors) dwarfs
# the repo's config/tokenizer JSON, so its presence means the download COMPLETED.
_MIN_WEIGHT_BYTES = 10 * 1024 * 1024


def gated_weights_cached() -> bool:
    """True once the gated cloning weights (kyutai/pocket-tts) are FULLY in the HF
    cache.

    Requires an actual weights-sized file (>_MIN_WEIGHT_BYTES) somewhere under a
    snapshot — a non-empty dir is NOT enough. An interrupted download can leave a
    snapshot with only small files (config.json, a partial/lock file, or the repo's
    subdir tree with the big model.safetensors still missing), and treating that as
    "cached" would force an offline load that fails AND blocks the re-download,
    bricking cloning. The weights live in a subdir (languages/<lang>/model.safetensors),
    so walk the whole tree. os.path.getsize follows the snapshot's symlink into blobs.

    When genuinely cached, the weights load straight from disk with no network and
    no token — the token is ONLY ever needed to DOWNLOAD them the first time. Loading
    online without a token 403s on the gated repo and silently drops to catalog-only,
    so offline-when-cached is what keeps cloning working token-free after setup."""
    snaps = os.path.join(_hf_hub_cache(), "models--kyutai--pocket-tts", "snapshots")
    try:
        snap_dirs = os.listdir(snaps)
    except OSError:
        return False
    for s in snap_dirs:
        for root, _dirs, files in os.walk(os.path.join(snaps, s)):
            for f in files:
                try:
                    if os.path.getsize(os.path.join(root, f)) > _MIN_WEIGHT_BYTES:
                        return True
                except OSError:
                    pass
    return False


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

    def has_token(self) -> bool:
        return bool(_hf_token())

    def load(self) -> bool:
        with self._lock:
            if self.model is not None:
                return True
            if not self.available():
                self.error = "Pocket engine not installed"
                return False
            try:
                _ensure_path()
                tok = _hf_token()
                cached = gated_weights_cached()
                offline_prev = os.environ.get("HF_HUB_OFFLINE")
                # The offline env mutation and BOTH the import and the load must sit
                # inside one try/finally: `from pocket_tts import …` can itself fail on
                # a broken Pocket install, and if it does with HF_HUB_OFFLINE already
                # set, an un-restored value would wedge later hub calls (e.g. a
                # first-time download after a delete) offline. Restore on every path.
                try:
                    if cached:
                        # Weights already downloaded: load them straight from disk with
                        # no network and no token. The token is only needed to DOWNLOAD
                        # the gated weights once; after that this keeps cloning working
                        # token-free (and stops the app from ever reading the Keychain).
                        os.environ["HF_HUB_OFFLINE"] = "1"
                    elif tok:
                        # First-time download path. Direct assignment, not setdefault:
                        # an inherited but EMPTY HF_TOKEN ("") would otherwise survive
                        # and block auth even though we resolved a real token elsewhere.
                        os.environ["HF_TOKEN"] = tok
                    from pocket_tts import TTSModel
                    log.info("loading Pocket TTS (token=%s, cached=%s)", bool(tok), cached)
                    # Cached -> offline load (cloning works with no token). Otherwise a
                    # valid token + accepted terms pulls the gated cloning weights; with
                    # neither, pocket_tts drops to the ungated catalog-only weights
                    # (has_voice_cloning=False).
                    m = TTSModel.load_model()
                finally:
                    if cached:
                        if offline_prev is None:
                            os.environ.pop("HF_HUB_OFFLINE", None)
                        else:
                            os.environ["HF_HUB_OFFLINE"] = offline_prev
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
            "has_token": self.has_token(),
            "error": self.error,
        }
