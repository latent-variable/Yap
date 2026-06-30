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

import logging
import os
import sys
import threading
from pathlib import Path
from typing import Optional

import numpy as np

log = logging.getLogger("yap")

SAMPLE_RATE = 24000  # Pocket native; matches Kokoro / the int16 PCM contract

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
                # huggingface_hub reads HF_TOKEN from the env; mirror our accepted
                # aliases into it so a token set as HUGGINGFACE_HUB_TOKEN still
                # unlocks the gated cloning weights.
                tok = _hf_token()
                if tok:
                    os.environ.setdefault("HF_TOKEN", tok)
                from pocket_tts import TTSModel
                log.info("loading Pocket TTS (token=%s)", bool(tok))
                # With a valid token AND accepted terms this pulls the cloning
                # weights; otherwise pocket_tts silently falls back to the ungated
                # catalog-only weights (has_voice_cloning=False).
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
                if voice:
                    st = self._state_for(voice)
                    self.model.generate_audio(st, "Ready.")
            return True
        except Exception as e:  # noqa: BLE001
            log.warning("Pocket warm failed: %s", e)
            return False

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
            st = self._state_for(voice)
            audio = self.model.generate_audio(st, text)
        if hasattr(audio, "detach"):
            return audio.detach().cpu().numpy().astype(np.float32)
        return np.asarray(audio, dtype=np.float32)

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
