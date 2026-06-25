"""Chatterbox Turbo engine — optional "HD" voice cloning.

Heavy (PyTorch). Lazy: nothing here imports torch until the engine actually
loads, so the default Kokoro path stays light. Deps live in a separate
app-support directory (installed on demand), not the signed app bundle.

Chatterbox Turbo is cloning-only: it needs a ~10s reference clip per voice.
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

SAMPLE_RATE = 24000  # matches Kokoro / the PCM contract

# Where on-demand HD deps (torch, chatterbox-tts, ...) get installed.
def hd_packages_dir() -> Path:
    d = Path(os.environ.get("YAP_HD_DIR") or os.environ.get("PARLEY_HD_DIR") or
             (Path.home() / "Library/Application Support/Yap/hd-packages"))
    return d


def _ensure_path() -> None:
    p = str(hd_packages_dir())
    if p not in sys.path and Path(p).exists():
        sys.path.insert(0, p)


_mps_patched = False


def _patch_mps_float64(torch) -> None:
    """Apple's Metal backend has no float64. Chatterbox's reference-audio
    preprocessing moves float64 tensors to the GPU and crashes. Globally
    downcast float64 -> float32 on any move to mps. (Bounded to this HD process.)"""
    global _mps_patched
    if _mps_patched:
        return
    _orig_to = torch.Tensor.to

    def _safe_to(self, *a, **k):
        dev = k.get("device")
        if dev is None:
            for x in a:
                if isinstance(x, (str, torch.device)) and "mps" in str(x):
                    dev = x
                    break
        if dev is not None and "mps" in str(dev) and self.dtype == torch.float64:
            self = _orig_to(self, torch.float32)
        return _orig_to(self, *a, **k)

    torch.Tensor.to = _safe_to
    _mps_patched = True


class ChatterboxTurboEngine:
    name = "chatterbox"
    label = "Chatterbox Turbo (HD)"

    def __init__(self):
        self.model = None
        self.device = "cpu"
        self.error: Optional[str] = None
        self._cached_ref: Optional[str] = None  # voice whose conditioning is loaded
        # Serializes all model/GPU access. PyTorch/MPS is not thread-safe, and the
        # FastAPI sync endpoints run in a threadpool — so a warm (voice switch)
        # and a synth (read) can land concurrently. Without this they corrupt
        # each other on the GPU and the read's segments silently fail. A plain
        # lock suffices: load() is only ever called OUTSIDE a held lock, so no
        # locked section re-enters it.
        self._lock = threading.Lock()

    def available(self) -> bool:
        """Are the heavy deps importable (without loading the model)?"""
        _ensure_path()
        import importlib.util
        return all(importlib.util.find_spec(m) is not None
                   for m in ("torch", "chatterbox"))

    def _install_watermarker(self):
        """Chatterbox requires a perth watermarker instance. Use the real one
        when present; otherwise a pass-through so HD mode still runs (logged)."""
        try:
            import perth
            if getattr(perth, "PerthImplicitWatermarker", None) is not None:
                return  # real watermarker available
        except Exception:  # noqa: BLE001
            import types
            perth = types.ModuleType("perth")
            sys.modules["perth"] = perth
        log.warning("perth watermarker unavailable — HD audio will NOT be watermarked")

        class _PassThrough:
            def apply_watermark(self, wav, sample_rate=None, **k):
                return wav

            def get_watermark(self, *a, **k):
                return None

        perth.PerthImplicitWatermarker = _PassThrough  # type: ignore[attr-defined]

    def load(self) -> bool:
        with self._lock:
            if self.model is not None:
                return True
            if not self.available():
                self.error = "HD engine not installed"
                return False
            try:
                _ensure_path()
                import torch
                self._install_watermarker()
                self.device = "mps" if torch.backends.mps.is_available() else "cpu"
                if self.device == "mps":
                    _patch_mps_float64(torch)  # Metal has no float64; downcast on ->mps
                from chatterbox.tts_turbo import ChatterboxTurboTTS
                log.info("loading Chatterbox Turbo on %s", self.device)
                self.model = ChatterboxTurboTTS.from_pretrained(device=self.device)
                self.error = None
                self._warmup()
                log.info("Chatterbox Turbo ready (%s)", self.device)
                return True
            except Exception as e:  # noqa: BLE001
                self.error = str(e)
                log.exception("failed to load Chatterbox Turbo")
                return False

    def _warmup(self) -> None:
        """First generate compiles the graph (~8s). Warm it with any reference
        clip so the user's first real request is fast (~RTF 0.7)."""
        try:
            hd_voices = os.environ.get("YAP_HD_VOICES") or os.environ.get("PARLEY_HD_VOICES") or (
                Path.home() / "Library/Application Support/Yap/hd-voices")
            refs = sorted(Path(hd_voices).glob("*.wav"))
            if not refs or self.model is None:
                return
            self.model.generate("Ready.", audio_prompt_path=str(refs[0]))
        except Exception:  # noqa: BLE001
            pass

    def _prepare(self, ref_path: str) -> None:
        """Compute the voice conditioning once and cache it. generate() then
        reuses it instead of re-encoding the reference on every call."""
        if self._cached_ref != ref_path:
            self.model.prepare_conditionals(ref_path)
            self._cached_ref = ref_path

    def warm(self, ref_path: str) -> bool:
        """Load the model and prepare a voice so the first real read is fast."""
        if self.model is None and not self.load():
            return False
        try:
            with self._lock:   # never run concurrently with a synth on the GPU
                if ref_path and Path(ref_path).exists():
                    self._prepare(ref_path)
                    self.model.generate("Ready.")  # compile the graph for this voice
            return True
        except Exception as e:  # noqa: BLE001
            log.warning("HD warm failed: %s", e)
            return False

    def synth(self, text: str, ref_path: str, speed: float = 1.0) -> np.ndarray:
        """Clone the voice in ref_path and speak `text`. Returns float32 @ 24kHz.
        (Chatterbox has no speed knob; speed is honored by the Kokoro engine.)"""
        if self.model is None and not self.load():
            raise RuntimeError(self.error or "HD engine not loaded")
        if not ref_path or not Path(ref_path).exists():
            raise RuntimeError("reference voice clip missing")
        with self._lock:   # serialize GPU access — warm/synth must not overlap
            self._prepare(ref_path)             # cached; cheap after first call
            wav = self.model.generate(text)     # reuse cached conditioning
            # MPS ops are async; keep the GPU->CPU transfer inside the lock so it
            # can't read the tensor while another thread runs generate().
            arr = wav.squeeze(0).detach().cpu().numpy().astype(np.float32)
        return arr

    def status(self) -> dict:
        return {
            "name": self.name,
            "label": self.label,
            "installed": self.available(),
            "loaded": self.model is not None,
            "device": self.device,
            "error": self.error,
        }
