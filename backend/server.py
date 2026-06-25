"""Yap Kokoro TTS backend.

Local FastAPI sidecar. Loads Kokoro once, keeps it warm, streams raw PCM for
low-latency playback. No cloud, no telemetry.

Endpoints:
  GET  /health                -> readiness + model status
  GET  /voices                -> available voices grouped by language
  GET  /models                -> model file status in models dir
  POST /synthesize            -> stream raw int16 PCM mono (X-Sample-Rate header)
  POST /synthesize?format=wav -> full WAV blob (for export)
"""
from __future__ import annotations

import argparse
import io
import logging
import os
import re
import sys
import wave
from pathlib import Path
from typing import Iterator, Optional

import numpy as np
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import Response, StreamingResponse
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO, format="%(asctime)s yap %(levelname)s %(message)s")
log = logging.getLogger("yap")

SAMPLE_RATE = 24000  # Kokoro native

# Language code per voice prefix (first two chars of voice name).
LANG_BY_PREFIX = {
    "af": "en-us", "am": "en-us",
    "bf": "en-gb", "bm": "en-gb",
    "ef": "es", "em": "es",
    "ff": "fr-fr",
    "hf": "hi", "hm": "hi",
    "if": "it", "im": "it",
    "jf": "ja", "jm": "ja",
    "pf": "pt-br", "pm": "pt-br",
    "zf": "cmn", "zm": "cmn",   # espeak uses "cmn" (Mandarin), not "zh"
}
LANG_LABEL = {
    "en-us": "English (US)", "en-gb": "English (UK)", "es": "Spanish",
    "fr-fr": "French", "hi": "Hindi", "it": "Italian", "ja": "Japanese",
    "pt-br": "Portuguese (BR)", "cmn": "Chinese (Mandarin)",
}


def lang_for_voice(voice: str) -> str:
    return LANG_BY_PREFIX.get(voice[:2], "en-us")


# --- sentence-ish chunking, abbreviation aware ----------------------------------
_ABBREV = {
    "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g", "i.e",
    "fig", "inc", "ltd", "co", "no", "vol", "approx", "dept", "univ", "min", "max",
}
_SENT_END = re.compile(r"([.!?]+[\"')\]]?)(\s+)")


def split_sentences(text: str) -> list[str]:
    text = text.strip()
    if not text:
        return []
    out: list[str] = []
    parts = _SENT_END.split(text)
    # parts: [chunk, punct, space, chunk, punct, space, ...]
    buf = ""
    i = 0
    while i < len(parts):
        buf += parts[i]
        if i + 1 < len(parts):
            punct = parts[i + 1]
            buf += punct
            last_word = re.split(r"\s+", buf.strip())[-1].rstrip(".!?\"')]").lower()
            if last_word in _ABBREV:
                buf += parts[i + 2] if i + 2 < len(parts) else ""
                i += 3
                continue
            out.append(buf.strip())
            buf = ""
            i += 3
        else:
            i += 1
    if buf.strip():
        out.append(buf.strip())
    return out


def chunk_text(text: str, max_chars: int = 320) -> list[str]:
    """Paragraphs -> sentences -> length-capped chunks (text only)."""
    return [seg for seg, _gap in segment_text(text, max_chars)]


# Silence (seconds) inserted AFTER a segment, by the boundary it ends on. These
# are what give speech its natural cadence instead of one run-on stream.
GAP_SENTENCE = 0.18   # between sentences in the same line/paragraph
GAP_LINE = 0.28       # at a single line break (lists, headings, wrapped lines)
GAP_PARAGRAPH = 0.5   # between paragraphs (blank line)


# Structural-line detection, so a sentence that's merely hard-wrapped across
# lines isn't read as two clipped fragments with a pause between them. Only a
# line break that ends a sentence, or starts/ends a list item or heading, is a
# real boundary; everything else is a soft wrap and gets rejoined.
_LIST_RE = re.compile(r"^\s*([-*+•]|\d+[.)]|[A-Za-z][.)])\s+")
_HEADING_RE = re.compile(r"^\s*#{1,6}\s+")
_ENDS_SENTENCE_RE = re.compile(r"[.!?…][\"')\]]*$")


def _is_soft_wrap(cur: str, nxt: str) -> bool:
    """True if the break between `cur` and `nxt` is a mid-sentence wrap (join
    them), not a structural boundary (keep the pause)."""
    cur = cur.rstrip()
    if not cur or not nxt.strip():
        return False
    # cur completes a sentence, or is a deliberate lead-in (colon) → real break.
    if _ENDS_SENTENCE_RE.search(cur) or cur.endswith(":"):
        return False
    # cur is a heading, or nxt starts a new block (list item / heading) → real
    # break. (A wrapped list item — cur is a bullet, nxt is plain text — still
    # joins, so a long bullet reads as one line.)
    if _HEADING_RE.match(cur):
        return False
    if _LIST_RE.match(nxt) or _HEADING_RE.match(nxt):
        return False
    # A wrapped sentence flows into a lowercase continuation. A line that starts
    # with a capital (or digit/symbol) is its own unit — e.g. a bare list of
    # capitalized items — so don't swallow it into the previous line.
    if not nxt.strip()[0].islower():
        return False
    return True


def _reflow_lines(raw_lines: list[str]) -> list[str]:
    """Merge soft-wrapped continuation lines into logical lines (stripped,
    non-empty), so each logical line is a real structural unit."""
    out: list[str] = []
    buf = ""
    for ln in raw_lines:
        if not ln.strip():
            continue
        if buf and _is_soft_wrap(buf, ln):
            buf = buf.rstrip() + " " + ln.strip()
        else:
            if buf:
                out.append(buf)
            buf = ln.strip()
    if buf:
        out.append(buf)
    return out


def _hardwrap(sentence: str, max_chars: int) -> list[str]:
    if len(sentence) <= max_chars:
        return [sentence]
    out, line = [], ""
    for w in sentence.split(" "):
        if len(line) + len(w) + 1 > max_chars:
            out.append(line.strip()); line = w
        else:
            line = f"{line} {w}".strip()
    if line:
        out.append(line.strip())
    return out


def segment_text(text: str, max_chars: int = 320) -> list[tuple[str, float]]:
    """Split into speakable segments, each tagged with the silence to play
    after it. Respects paragraphs (blank lines), single line breaks, and
    sentences so the audio gets real pauses where the writing has structure.
    """
    segs: list[tuple[str, float]] = []
    paragraphs = [p for p in re.split(r"\n\s*\n", text)]
    for pi, para in enumerate(paragraphs):
        if not para.strip():
            continue
        last_para = pi == len(paragraphs) - 1
        # Rejoin soft-wrapped lines first so a wrapped sentence stays one unit
        # (no spurious GAP_LINE mid-sentence); real boundaries survive.
        lines = _reflow_lines(para.split("\n"))
        for li, line in enumerate(lines):
            last_line = li == len(lines) - 1
            sentences = split_sentences(line) or [line]
            for si, sent in enumerate(sentences):
                last_sent = si == len(sentences) - 1
                pieces = _hardwrap(sent.strip(), max_chars)
                for k, piece in enumerate(pieces):
                    if not piece:
                        continue
                    last_piece = k == len(pieces) - 1
                    if last_piece and last_sent and last_line and last_para:
                        gap = 0.0
                    elif last_piece and last_sent and last_line:
                        gap = GAP_PARAGRAPH
                    elif last_piece and last_sent:
                        gap = GAP_LINE
                    elif last_piece:
                        gap = GAP_SENTENCE
                    else:
                        gap = GAP_SENTENCE * 0.5  # mid-sentence hard wrap
                    segs.append((piece, gap))
    return segs


# Chatterbox Turbo cost model, measured on Apple-Silicon MPS (2nd-run, synced):
#   generate(T seconds of audio) ≈ HD_GEN_FIXED  (s3gen vocoder floor, per call)
#                                 + HD_GEN_PER_SEC * T   (AR decode + vocode)
# so a chunk's generate stays FASTER than its playback once it holds more than
# ~1.6s of audio. Speech runs ~HD_CHARS_PER_SEC chars/sec.
HD_CHARS_PER_SEC = 17.0
HD_GEN_FIXED = 0.8         # vocoder floor per generate() call
HD_GEN_PER_SEC = 0.49     # marginal generate cost per second of audio
HD_FIRST_SECONDS = 2.8    # first chunk floor: sets the buffer floor T₀ and very
                          # nearly covers any later chunk's generate. First audio
                          # lands ~2.2s.
HD_MIN_SECONDS = 1.8      # drain-free floor for later chunks: above the RTF=1
                          # breakeven (~1.6s), so each still banks slack
HD_MAX_SECONDS = 6.0      # target ceiling (keeps long runs responsive)
HD_MAX_CHARS = 68         # cap ONE sentence (comma-preferring) so gen(sentence)
                          # ≤ gen at the first-chunk floor T₀ — no single sentence
                          # can outrun the initial banked buffer
HD_SAFETY_SECONDS = 0.3   # size chunks to finish generating this far AHEAD of
                          # the buffer draining, so MPS/CPU jitter can't underrun


def _hd_gen_seconds(audio_seconds: float) -> float:
    return HD_GEN_FIXED + HD_GEN_PER_SEC * audio_seconds


def _split_long_for_hd(text: str, gap: float) -> list[tuple[str, float]]:
    """Break a single over-long sentence into <=HD_MAX_CHARS pieces, preferring
    comma boundaries then spaces, so no one chunk's generate can outrun the
    playback buffer. Inner pieces get gap 0 (no pause — still one sentence); the
    last piece keeps the sentence's real trailing gap."""
    if len(text) <= HD_MAX_CHARS:
        return [(text, gap)]
    words = text.split()
    pieces: list[str] = []
    line = ""
    for w in words:
        cand = f"{line} {w}".strip()
        if len(cand) > HD_MAX_CHARS and line:
            pieces.append(line)
            line = w
        else:
            line = cand
        if line.endswith((",", ";", ":")) and len(line) >= HD_MAX_CHARS * 0.6:
            pieces.append(line)   # clean break at a clause boundary
            line = ""
    if line:
        pieces.append(line)
    return [(p, gap if i == len(pieces) - 1 else 0.0) for i, p in enumerate(pieces)]


def merge_for_hd(segs: list[tuple[str, float]]) -> list[tuple[str, float]]:
    """Merge sentence-level segments into HD chunks, sized so the player buffer
    never drains while the next chunk generates.

    Budget-aware greedy scheduler: it tracks `banked` — the seconds of audio
    queued when the NEXT chunk starts generating — and caps each chunk so its
    generate time can't exceed what's banked. The first chunk is small (fast
    first audio); chunks grow as the buffer banks, then settle. Provably no
    underrun (each chunk's gen ≤ banked buffer). Whole sentences stay together;
    paragraph gaps force a break and keep their silence between chunks."""
    segs = [p for text, gap in segs for p in _split_long_for_hd(text, gap)]
    out: list[tuple[str, float]] = []
    buf: list[tuple[str, float]] = []
    length = 0
    banked = 0.0
    target_s = HD_FIRST_SECONDS
    first = True

    def flush() -> None:
        nonlocal buf, length, banked, target_s, first
        if not buf:
            return
        text = " ".join(t for t, _ in buf)
        # Trailing gap = the LARGEST gap among the merged segments, not just the
        # last. When a short paragraph/line is absorbed into a chunk, its longer
        # pause is preserved at the chunk boundary instead of being dropped.
        # (Extra silence only deepens the buffer — it can't cause an underrun.)
        out.append((text, max(g for _, g in buf)))
        audio_s = len(text) / HD_CHARS_PER_SEC
        if first:
            banked = audio_s                # playback starts as this chunk lands
            first = False
        else:
            banked = max(0.0, banked - _hd_gen_seconds(audio_s)) + audio_s
        # largest next chunk whose generate fits inside the banked buffer, with a
        # jitter margin so it lands ahead of the buffer draining (not at the wire)
        safe = (banked - HD_GEN_FIXED - HD_SAFETY_SECONDS) / HD_GEN_PER_SEC
        target_s = min(HD_MAX_SECONDS, max(HD_MIN_SECONDS, safe))
        buf, length = [], 0

    # Gap-free invariant: the player buffer only grows once playback starts
    # (every chunk ≥ ~1.6s audio nets positive), so its floor is banked₀ = T₀,
    # the FIRST chunk's duration. Two rules make it hold for any input:
    #   1. never flush the first chunk below the minimum — it sets that floor;
    #   2. size every later chunk to target_s = gen⁻¹(banked), so its generate
    #      time can't exceed the buffer already queued.
    first_min = HD_FIRST_SECONDS * HD_CHARS_PER_SEC   # floor for chunk 0 (T₀)
    drain_min = HD_MIN_SECONDS * HD_CHARS_PER_SEC     # drain-free floor after
    ceil_chars = HD_MAX_SECONDS * HD_CHARS_PER_SEC
    for text, gap in segs:
        seglen = len(text) + 1
        # A chunk may flush only past its floor: the first chunk past first_min
        # (so T₀ covers any later chunk's generate), later chunks past the small
        # drain-free floor (so they never drain the buffer). Below the floor,
        # short adjacent sentences / paragraphs merge instead of shipping tiny.
        floor = drain_min if out else first_min
        if buf and length >= floor and (
                length + seglen > target_s * HD_CHARS_PER_SEC or length + seglen > ceil_chars):
            flush()
        buf.append((text, gap))
        length += seglen
        if gap >= GAP_PARAGRAPH and length >= floor:
            flush()
    flush()
    return out


# --- engine ---------------------------------------------------------------------
# onnxruntime execution-provider selection. CoreML routes to Apple GPU/ANE,
# but for an 82M model like Kokoro it benchmarks ~even-to-slower than the
# vectorized CPU EP (most ops fall back to CPU). So "auto" picks CPU; users can
# force CoreML. CPU is always appended as the implicit fallback either way.
PROVIDER_ALIASES = {
    "cpu": "CPUExecutionProvider",
    "coreml": "CoreMLExecutionProvider",
}


def resolve_provider(mode: str) -> str:
    mode = (mode or "auto").lower()
    if mode == "auto":
        return "CPUExecutionProvider"
    return PROVIDER_ALIASES.get(mode, mode)


class Engine:
    def __init__(self, models_dir: Path, provider_mode: str = "auto"):
        self.models_dir = models_dir
        self.kokoro = None
        self.model_path = models_dir / "kokoro-v1.0.onnx"
        self.voices_path = models_dir / "voices-v1.0.bin"
        self.error: Optional[str] = None
        self.provider_mode = provider_mode
        self.active_providers: list[str] = []

    def files_present(self) -> bool:
        return self.model_path.exists() and self.voices_path.exists()

    def load(self) -> None:
        if self.kokoro is not None:
            return
        if not self.files_present():
            self.error = "model files missing"
            return
        chosen = resolve_provider(self.provider_mode)
        if self._try_load(chosen):
            return
        # fall back to CPU if the requested provider failed to build a session
        if chosen != "CPUExecutionProvider":
            log.warning("provider %s failed, falling back to CPU", chosen)
            self._try_load("CPUExecutionProvider")

    def _try_load(self, provider: str) -> bool:
        try:
            from kokoro_onnx import Kokoro
            os.environ["ONNX_PROVIDER"] = provider  # kokoro-onnx reads this
            log.info("loading Kokoro from %s (provider=%s)", self.models_dir, provider)
            kokoro = Kokoro(str(self.model_path), str(self.voices_path))
            kokoro.create("Ready.", voice="af_heart", speed=1.0, lang="en-us")  # warm
            self.kokoro = kokoro
            self.active_providers = list(kokoro.sess.get_providers())
            self.error = None
            log.info("Kokoro warm on %s, %d voices", self.active_providers, len(kokoro.get_voices()))
            return True
        except Exception as e:  # noqa: BLE001
            self.error = str(e)
            log.exception("failed to load Kokoro on %s", provider)
            return False

    def available_providers(self) -> list[str]:
        try:
            import onnxruntime as ort
            return list(ort.get_available_providers())
        except Exception:  # noqa: BLE001
            return []

    def voices(self) -> list[str]:
        if self.kokoro is None:
            return []
        return sorted(self.kokoro.get_voices())

    def synth(self, text: str, voice: str, speed: float, lang: Optional[str]) -> np.ndarray:
        if self.kokoro is None:
            self.load()
        if self.kokoro is None:
            raise RuntimeError(self.error or "engine not loaded")
        lang = lang or lang_for_voice(voice)
        samples, _sr = self.kokoro.create(text, voice=voice, speed=speed, lang=lang)
        return np.asarray(samples, dtype=np.float32)


def pcm16(samples: np.ndarray) -> bytes:
    clipped = np.clip(samples, -1.0, 1.0)
    return (clipped * 32767.0).astype("<i2").tobytes()


def wav_bytes(samples: np.ndarray) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm16(samples))
    return buf.getvalue()


# --- app ------------------------------------------------------------------------
from chatterbox_engine import ChatterboxTurboEngine

engine: Engine  # set in main
cb_engine = ChatterboxTurboEngine()  # optional HD engine; lazy, no torch import yet


class SynthReq(BaseModel):
    text: str
    voice: str = "am_puck"      # kokoro voice id, OR chatterbox reference-clip id
    speed: float = Field(1.0, ge=0.25, le=4.0)
    lang: Optional[str] = None
    pause_scale: float = Field(1.0, ge=0.0, le=10.0)    # multiplies the gaps between sentences/lines/paragraphs
    engine: str = "kokoro"      # "kokoro" | "chatterbox"


# Reference voice clips for the Chatterbox (cloning) engine live here.
def hd_voices_dir() -> Path:
    d = Path(os.environ.get("PARLEY_HD_VOICES") or
             (Path.home() / "Library/Application Support/Yap/hd-voices"))
    d.mkdir(parents=True, exist_ok=True)
    return d


def hd_voice_path(voice_id: str) -> Optional[Path]:
    # voice_id comes straight from the synth request — reject anything but a
    # bare safe id and confirm the resolved path stays inside hd_voices_dir, so
    # a crafted "../" can't read arbitrary .wav files off disk.
    if not re.match(r"^[A-Za-z0-9_-]+$", voice_id):
        return None
    base = hd_voices_dir().resolve()
    p = (base / f"{voice_id}.wav").resolve()
    if p.parent != base:
        return None
    return p if p.exists() else None


app = FastAPI(title="Yap TTS", docs_url=None, redoc_url=None)


@app.get("/health")
def health():
    return {
        "status": "ok",
        "model_loaded": engine.kokoro is not None,
        "files_present": engine.files_present(),
        "models_dir": str(engine.models_dir),
        "error": engine.error,
        "sample_rate": SAMPLE_RATE,
        "provider_mode": engine.provider_mode,
        "active_providers": engine.active_providers,
        "available_providers": engine.available_providers(),
        "engines": engines_status(),
    }


def engines_status() -> dict:
    return {
        "kokoro": {"name": "kokoro", "label": "Kokoro", "installed": engine.files_present(),
                   "loaded": engine.kokoro is not None},
        "chatterbox": cb_engine.status(),
    }


@app.get("/engines")
def engines():
    return engines_status()


@app.post("/engines/chatterbox/install")
def install_chatterbox():
    """Install the heavy HD deps into app-support hd-packages (not the bundle).
    Streams pip output so the app can show progress. ~2-3 GB, one time."""
    import subprocess
    from chatterbox_engine import hd_packages_dir
    target = hd_packages_dir()
    target.mkdir(parents=True, exist_ok=True)
    req_file = Path(__file__).parent / "requirements-chatterbox.txt"
    pip = [sys.executable, "-m", "pip", "install", "--target", str(target)]
    # 1) HD deps (numpy<2). 2) kokoro into the SAME env without disturbing numpy,
    # so one process can serve both engines.
    steps = [
        pip + ["--upgrade", "-r", str(req_file)],
        pip + ["--no-deps", "--upgrade", "kokoro-onnx", "onnxruntime"],
    ]

    def gen() -> Iterator[bytes]:
        yield f"installing HD engine into {target}\n".encode()
        try:
            import importlib.util
            if importlib.util.find_spec("pip") is None:
                subprocess.run([sys.executable, "-m", "ensurepip", "--upgrade"],
                               capture_output=True)
        except Exception:  # noqa: BLE001
            pass
        rc = 0
        for cmd in steps:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True, bufsize=1)
            try:
                assert proc.stdout is not None
                for line in proc.stdout:
                    yield line.encode()
                proc.wait()
                rc = proc.returncode
            finally:
                # If the client disconnects, GeneratorExit fires at the yield;
                # don't leave an orphaned pip running in the background.
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=5)
                    except Exception:  # noqa: BLE001
                        proc.kill()
            if rc != 0:
                break
        ok = rc == 0 and cb_engine.available()
        yield f"\n[{'done' if ok else 'failed'}] exit={rc} installed={cb_engine.available()}\n".encode()
        yield b"\n[note] restart the engine to activate HD (the app does this for you).\n"

    return StreamingResponse(gen(), media_type="text/plain")


@app.get("/voices")
def voices(engine_name: str = Query("kokoro", alias="engine")):
    if engine_name == "chatterbox":
        items = []
        for p in sorted(hd_voices_dir().glob("*.wav")):
            items.append({"id": p.stem, "lang": "any", "lang_label": "Cloned", "gender": "ref"})
        return {"voices": items, "count": len(items)}
    items = []
    for v in engine.voices():
        lang = lang_for_voice(v)
        gender = "female" if v[1] == "f" else "male"
        items.append({
            "id": v,
            "lang": lang,
            "lang_label": LANG_LABEL.get(lang, lang),
            "gender": gender,
        })
    return {"voices": items, "count": len(items)}


@app.get("/models")
def models():
    return {
        "models_dir": str(engine.models_dir),
        "model_file": {"name": engine.model_path.name, "present": engine.model_path.exists(),
                       "bytes": engine.model_path.stat().st_size if engine.model_path.exists() else 0},
        "voices_file": {"name": engine.voices_path.name, "present": engine.voices_path.exists(),
                        "bytes": engine.voices_path.stat().st_size if engine.voices_path.exists() else 0},
    }


def _segment_synth(req: SynthReq):
    """Return a `synth(text) -> ndarray` bound to the requested engine."""
    if req.engine == "chatterbox":
        ref = hd_voice_path(req.voice)
        if ref is None:
            raise HTTPException(400, f"reference voice '{req.voice}' not found")
        if not cb_engine.load():
            raise HTTPException(503, cb_engine.error or "HD engine not available")
        ref_str = str(ref)
        return lambda text: cb_engine.synth(text, ref_str, req.speed)
    # default: Kokoro
    if engine.kokoro is None:
        engine.load()
    if engine.kokoro is None:
        raise HTTPException(503, engine.error or "engine not loaded")
    return lambda text: engine.synth(text, req.voice, req.speed, req.lang)


@app.post("/engines/chatterbox/warm")
def warm_chatterbox(voice: str = Query("")):
    """Pre-load the HD model + a voice so the first read is fast. Called when
    the user switches to the HD engine. Blocks until warm (~8s cold)."""
    if not cb_engine.available():
        raise HTTPException(503, "HD engine not installed")
    ref = hd_voice_path(voice) if voice else None
    ok = cb_engine.warm(str(ref) if ref else "")
    return {"warm": ok, "loaded": cb_engine.model is not None, "voice": voice}


@app.post("/voices/hd/starters")
def fetch_starter_voices():
    """Download a few clean, openly-licensed reference voices (CMU ARCTIC,
    free to use) into hd-voices. Streams progress. Uses stdlib only."""
    import urllib.request
    base = "http://festvox.org/cmu_arctic/cmu_arctic"
    # (voice id, cmu speaker, description)
    voices = [
        ("Aria", "slt", "US female"), ("Clara", "clb", "US female"),
        ("Ben", "bdl", "US male"), ("Cole", "rms", "US male"),
        ("Jake", "jmk", "Canadian male"), ("Angus", "awb", "Scottish male"),
        ("Ravi", "ksp", "Indian male"),
    ]
    dest = hd_voices_dir()

    def concat_wavs(paths: list[Path], out: Path) -> None:
        frames = b""
        params = None
        for p in paths:
            with wave.open(str(p), "rb") as w:
                params = params or w.getparams()
                frames += w.readframes(w.getnframes())
        with wave.open(str(out), "wb") as w:
            w.setnchannels(params.nchannels); w.setsampwidth(params.sampwidth)
            w.setframerate(params.framerate); w.writeframes(frames)

    def gen() -> Iterator[bytes]:
        import shutil
        import tempfile
        for vid, spk, desc in voices:
            out = dest / f"{vid}.wav"
            if out.exists():
                yield f"skip {vid} (exists)\n".encode(); continue
            yield f"fetching {vid} ({desc})...\n".encode()
            tmp = Path(tempfile.mkdtemp())
            clips = []
            try:
                for n in ("0001", "0002", "0003", "0004", "0005"):
                    url = f"{base}/cmu_us_{spk}_arctic/wav/arctic_a{n}.wav"
                    cp = tmp / f"{n}.wav"
                    # urlopen(timeout=) — urlretrieve has no timeout, so a stalled
                    # connection would hang the worker thread indefinitely.
                    with urllib.request.urlopen(url, timeout=30) as r, open(cp, "wb") as f:
                        shutil.copyfileobj(r, f)
                    clips.append(cp)
                concat_wavs(clips, out)
                yield f"  installed {vid}\n".encode()
            except Exception as e:  # noqa: BLE001
                yield f"  failed {vid}: {e}\n".encode()
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
        yield b"[done]\n"

    return StreamingResponse(gen(), media_type="text/plain")


@app.post("/synthesize")
def synthesize(req: SynthReq, format: str = Query("pcm")):
    if not req.text.strip():
        raise HTTPException(400, "empty text")

    segments = segment_text(req.text)
    if req.engine == "chatterbox":
        segments = merge_for_hd(segments)   # fewer, larger calls = smoother HD
    if not segments:
        raise HTTPException(400, "no speakable text")
    do_synth = _segment_synth(req)

    # Couple pauses to speed: faster speech -> proportionally shorter gaps, so
    # cadence stays natural at any speed. pause_scale is the user's multiplier.
    scale = max(0.0, req.pause_scale) / max(0.25, req.speed)

    def silence(seconds: float) -> np.ndarray:
        n = int(SAMPLE_RATE * seconds * scale)
        return np.zeros(n, dtype=np.float32) if n > 0 else np.zeros(0, dtype=np.float32)

    if format == "wav":
        parts: list[np.ndarray] = []
        for text, gap in segments:
            parts.append(do_synth(text))
            if gap > 0:
                parts.append(silence(gap))
        joined = np.concatenate(parts) if parts else np.zeros(0, np.float32)
        data = wav_bytes(joined)
        return Response(content=data, media_type="audio/wav",
                        headers={"Content-Disposition": "attachment; filename=yap.wav"})

    def gen() -> Iterator[bytes]:
        for i, (text, gap) in enumerate(segments):
            try:
                samples = do_synth(text)
            except Exception as e:  # noqa: BLE001
                log.error("synth segment %d failed: %s", i, e)
                continue
            yield pcm16(samples)
            if gap > 0:
                yield pcm16(silence(gap))

    return StreamingResponse(gen(), media_type="application/octet-stream",
                             headers={"X-Sample-Rate": str(SAMPLE_RATE),
                                      "X-Chunks": str(len(segments)),
                                      "X-Engine": req.engine})


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8766)
    default_models = os.environ.get("PARLEY_MODELS_DIR") or str(
        Path.home() / "Library/Application Support/Yap/models")
    p.add_argument("--models-dir", default=default_models)
    p.add_argument("--provider", default=os.environ.get("PARLEY_PROVIDER", "auto"),
                   help="auto | cpu | coreml")
    p.add_argument("--no-preload", action="store_true")
    args = p.parse_args()

    global engine
    mdir = Path(args.models_dir).expanduser()
    mdir.mkdir(parents=True, exist_ok=True)
    engine = Engine(mdir, provider_mode=args.provider)
    if not args.no_preload:
        engine.load()

    import uvicorn
    log.info("serving on http://%s:%d (models: %s)", args.host, args.port, mdir)
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    sys.exit(main())
