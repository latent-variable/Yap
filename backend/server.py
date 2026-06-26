"""Yap Kokoro TTS backend.

Local FastAPI sidecar. Loads Kokoro once, keeps it warm, streams raw PCM for
low-latency playback. No cloud, no telemetry.

All endpoints except /verify require a shared-secret Bearer token (see the auth
section near the FastAPI app) and reject browser-originated requests.

Endpoints:
  GET  /verify?nonce=         -> HMAC(token, nonce) — auth-exempt identity proof
  GET  /health                -> readiness + model status
  GET  /voices                -> available voices grouped by language
  GET  /models                -> model file status in models dir
  POST /synthesize            -> stream raw int16 PCM mono (X-Sample-Rate header)
  POST /synthesize?format=wav -> full WAV blob (for export)
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import io
import logging
import os
import re
import secrets
import stat
import sys
import wave
from pathlib import Path
from typing import Iterator, Optional

import numpy as np
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse
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
    d = Path(os.environ.get("YAP_HD_VOICES") or os.environ.get("PARLEY_HD_VOICES") or
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


# ---------------------------------------------------------------------------
# Loopback auth. The sidecar binds 127.0.0.1, which is reachable by every local
# process AND by `fetch()` from any website the user visits. Two holes that
# closes: (1) a website CSRFing a no-body POST (e.g. the multi-GB pip install),
# and (2) Yap reusing an impostor that squatted the port and then receiving
# captured selected text. Defense: a shared secret in a 0600 file both the app
# and this backend read-or-create. Every request must carry it as a Bearer
# token; cross-user processes can't read the file, so they can't forge it. The
# app proves a *reused* backend is genuine via /verify (HMAC challenge) before
# trusting it. Same-user attackers are out of scope — they already own the
# user's data and Accessibility grants.
def _load_or_create_token() -> Optional[str]:
    # Explicit path wins (the app passes it when spawning us); else the default
    # app-support location, which the app uses too. A hand-started dev backend
    # creates the file; a later app launch reads the same one.
    path = os.environ.get("YAP_AUTH_TOKEN_FILE")
    if not path:
        path = str(Path.home() / "Library/Application Support/Yap/auth-token")
    # An inline token override (env) is honored without touching disk.
    inline = os.environ.get("YAP_AUTH_TOKEN")
    if inline:
        return inline.strip() or None
    p = Path(path)
    try:
        if p.exists():
            tok = p.read_text().strip()
            if tok:
                return tok
        p.parent.mkdir(parents=True, exist_ok=True)
        tok = secrets.token_urlsafe(32)
        # Write 0600 atomically: create with restrictive mode, then write.
        fd = os.open(str(p), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, stat.S_IRUSR | stat.S_IWUSR)
        with os.fdopen(fd, "w") as f:
            f.write(tok)
        os.chmod(str(p), stat.S_IRUSR | stat.S_IWUSR)
        return tok
    except OSError as e:
        # Fail open on the Bearer check rather than bricking TTS, but the Origin
        # guard below still runs, so CSRF stays closed even here.
        log.warning("auth: could not load/create token (%s); Bearer auth disabled", e)
        return None


AUTH_TOKEN = _load_or_create_token()


def _is_browser_request(request: Request) -> bool:
    # The native Swift client never sets these; a browser always does on a
    # cross-origin fetch/form-POST. Reject them outright (belt-and-suspenders
    # for CSRF — the Bearer check already blocks browsers, which can't set an
    # Authorization header cross-origin without a preflight we don't satisfy).
    if request.headers.get("origin"):
        return True
    sfs = request.headers.get("sec-fetch-site")
    if sfs and sfs not in ("same-origin", "none"):
        return True
    return False


app = FastAPI(title="Yap TTS", docs_url=None, redoc_url=None)


@app.middleware("http")
async def auth_guard(request: Request, call_next):
    # /verify self-authenticates (it returns an HMAC over a caller nonce and
    # leaks nothing), so the app can probe an unknown listener without first
    # handing it the token.
    if request.url.path == "/verify":
        return await call_next(request)
    if _is_browser_request(request):
        return JSONResponse({"detail": "cross-origin requests are not allowed"}, status_code=403)
    if AUTH_TOKEN is not None:
        header = request.headers.get("authorization", "")
        prefix = "Bearer "
        presented = header[len(prefix):] if header.startswith(prefix) else ""
        if not presented or not hmac.compare_digest(presented, AUTH_TOKEN):
            return JSONResponse({"detail": "unauthorized"}, status_code=401)
    return await call_next(request)


@app.get("/verify")
def verify(nonce: str = Query("")):
    """Prove this is a genuine Yap backend without revealing the token: return
    HMAC-SHA256(token, nonce). A process that can't read the 0600 token file
    (i.e. a different user / an impostor) can't produce a matching proof."""
    if AUTH_TOKEN is None or not nonce:
        raise HTTPException(400, "verification unavailable")
    proof = hmac.new(AUTH_TOKEN.encode(), nonce.encode(), hashlib.sha256).hexdigest()
    return {"proof": proof}


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


# SHA-256 of each CMU ARCTIC clip we fetch, keyed "<spk>_<n>". festvox.org
# serves no HTTPS (port 443 refused), so the clips come over plain HTTP — a MITM
# could otherwise swap the voice-conditioning reference and poison all HD synth
# for that persona. Pinning the digest makes the transport untrusted: a swapped
# file fails the check and is discarded. These are immutable canonical research
# files; bump only if the speaker set changes.
STARTER_SHA256 = {
    "slt_0001": "7862eb2cccb56875910f6bf46f9b8d26dac36e7672829aabe3956b0837ae122e",
    "slt_0002": "d09c9367d7e756cb5f6854d4e8a279e6e6e543fafeb4d04b32757c639f7f38d3",
    "slt_0003": "0b32e00846e132826f46d7e5cabb2d8b370a5dc654bac0447cb63285f81cc413",
    "slt_0004": "2a653cf74346ff24690f8a2abcff5091b81463f277b0062c851031a293f25167",
    "slt_0005": "f93c823f955875d2389ae0f731a95128afb1ee096df7614e063e8b4b5695801d",
    "clb_0001": "c8d628cd73028ebd30741da8d49bcc18a28c67bb9d0dca2c94b72a13e2ac1545",
    "clb_0002": "032ffd806fdae5b3173ee944479f064d5662ed042d6ffdb24c0091311d1c04be",
    "clb_0003": "224c1376c65a65720b75a51bb1df12ded17b306b828c3133fc01d0a8875e8507",
    "clb_0004": "61a48dcd39039227645b9d9eae7c2fd37a2ca54b4ab78c5dafb04a8eb026ee4c",
    "clb_0005": "9ee3ec38d5096b65ad4e90f9ac81f5ea7015a5e5cf46560c30de1940f42a1004",
    "bdl_0001": "2594562568c97203d6c3c2c2ff87b9a7c62389100a014934ab0ad39d15af0384",
    "bdl_0002": "88b2c3f29f696637ec34f8a031964920d7e187a903ba88fd720d3cb1b0d50c2a",
    "bdl_0003": "6bf2ec5e40a8a01a690d7aa5d1aa3a1489baae614850c7a716bf00092b005028",
    "bdl_0004": "9014c7af0c450ffab8a64f211559ed6eb61d1eb6c8a8288cca40325e64f702e7",
    "bdl_0005": "b654e28a68b0f49d40f715744f99f4bba338b1f66e61b58e428588e886d8fa1f",
    "rms_0001": "728ae021d1f21042abe3cde8c9c100fd2ade82a5a5db56ae412b9c7d99355aa9",
    "rms_0002": "a8067145cf402d06b0e97600a137aa3bb0079b857acd0962b2dccfb442dc6d5f",
    "rms_0003": "c99fc0cd44894394e3c5f206928e5271e02162f55eca89e913a3e8baf94f15f3",
    "rms_0004": "5b038c0b4acf5b5193e97274ac547f03ee399c2bd65cc08a29df80f263fedfa3",
    "rms_0005": "3b6d28a4eb6b0feb56fb0f4f6eaca1e714d69119a824918c716620912ce011ea",
    "jmk_0001": "71b1eceea11f82a9b1b0d1658753e572ec5f4dab524ff60ddfc25b6452131686",
    "jmk_0002": "0350a354c40ac035186d773f3e47ec23c3321b40c53848ee4b076f6dd28aa32d",
    "jmk_0003": "e59e893cbe96481cd645755512392447dc3f55d5e2afc052bf4a2a9884d6445d",
    "jmk_0004": "7f118f87a68d8e7592df7791cffa1e8e4a414c615a0ac557a7b5570eb0732f63",
    "jmk_0005": "a2b444edcf99bf19fde11306086bffb5c9e220b2a5d8e77c0615d09a7a7dbfdc",
    "awb_0001": "d1ebf15b59fb1887bb0282bbff508c1db28a706b98cfa8a683a85a98fe2b7567",
    "awb_0002": "26d811548f811128ebe3e969fe0fa74f91c5fad9097e2057f16ffbe4af0e0105",
    "awb_0003": "ad01ac37983ff61b251115e0461a36cd7af014f432084313a2c00205443c3d70",
    "awb_0004": "896c6fb751391a4e25117acb57f17436f44ec71932d2c9af69556c4adb1caa40",
    "awb_0005": "e525cf1c4e98b15b5e9aa191897534aed9e69163d67f6b14de86179db08b6b85",
    "ksp_0001": "1f7c300199340733daf09fb440c64517047124c2703048a3c6b965a39e17553a",
    "ksp_0002": "2ff5029c6f4ded953b9bb964935913f639e8d6b021fc7c7428d15e605dcab06d",
    "ksp_0003": "0af26fb7e5488ee9536b0e0ae0c56be9f8a598e190faf5c1088d3a6697719708",
    "ksp_0004": "64af85ce3acf67081178bf9c54bad4dd500743343b1cd7787369347d36c8676b",
    "ksp_0005": "dbaf077726b438247124a1da8a93159fb314f1980c14463307bf49297a380fea",
}

# (voice id, cmu speaker, description) and the five clips concatenated per voice.
# Module-level so the integrity check and the fetch loop share one source of
# truth — and so the guard below can prove every requested clip has a pin.
STARTER_VOICES = [
    ("Aria", "slt", "US female"), ("Clara", "clb", "US female"),
    ("Ben", "bdl", "US male"), ("Cole", "rms", "US male"),
    ("Jake", "jmk", "Canadian male"), ("Angus", "awb", "Scottish male"),
    ("Ravi", "ksp", "Indian male"),
]
STARTER_CLIP_IDS = ("0001", "0002", "0003", "0004", "0005")  # zero-padded, matches key format
# Reachability guard: every clip the fetch loop will request must have a pinned
# digest, else `.get()` returns None and a genuine clip is silently rejected.
assert all(
    f"{spk}_{n}" in STARTER_SHA256
    for _, spk, _ in STARTER_VOICES
    for n in STARTER_CLIP_IDS
), "STARTER_SHA256 is missing a pin for a clip the fetch loop requests"


@app.post("/voices/hd/starters")
def fetch_starter_voices():
    """Download a few clean, openly-licensed reference voices (CMU ARCTIC,
    free to use) into hd-voices. Streams progress. Uses stdlib only."""
    import hashlib
    import urllib.request
    base = "http://festvox.org/cmu_arctic/cmu_arctic"
    voices = STARTER_VOICES
    voices_dir = hd_voices_dir()   # the directory; per-voice files are voices_dir/<id>.wav

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
            out = voices_dir / f"{vid}.wav"
            if out.exists():
                yield f"skip {vid} (exists)\n".encode(); continue
            yield f"fetching {vid} ({desc})...\n".encode()
            tmp = None
            clips = []
            try:
                # Temp dir on the SAME filesystem as the destination (inside
                # voices_dir, a real directory) so the final shutil.move is an
                # atomic rename, not a cross-device copy+delete. Inside the try so
                # an mkdtemp failure yields a clean "failed" line, not a 500.
                tmp = Path(tempfile.mkdtemp(dir=voices_dir))
                for n in STARTER_CLIP_IDS:
                    url = f"{base}/cmu_us_{spk}_arctic/wav/arctic_a{n}.wav"
                    cp = tmp / f"{n}.wav"
                    # urlopen(timeout=) — urlretrieve has no timeout, so a stalled
                    # connection would hang the worker thread indefinitely.
                    # Bounded read: over plain HTTP a MITM could stream unbounded
                    # bytes and exhaust the disk. Clips are <200 KB; cap well above.
                    with urllib.request.urlopen(url, timeout=30) as r, open(cp, "wb") as f:
                        cap, got = 8 * 1024 * 1024, 0
                        while chunk := r.read(64 * 1024):
                            got += len(chunk)
                            if got > cap:
                                raise ValueError(f"clip exceeds {cap} byte cap (truncated/hostile?)")
                            f.write(chunk)
                    # Integrity gate over untrusted HTTP: reject a swapped clip
                    # before it becomes a voice reference.
                    digest = hashlib.sha256(cp.read_bytes()).hexdigest()
                    expected = STARTER_SHA256.get(f"{spk}_{n}")
                    if digest != expected:
                        raise ValueError(
                            f"checksum mismatch for {spk} a{n} "
                            f"(got {digest[:12]}…, expected {str(expected)[:12]}…)"
                        )
                    clips.append(cp)
                # Concat into tmp, then atomically move into place. A failure in
                # concat_wavs or a client disconnect (GeneratorExit) mid-write
                # must not leave a partial file at `out` — the exists() check
                # above would otherwise treat it as a finished install forever.
                tmp_out = tmp / "concat.wav"
                concat_wavs(clips, tmp_out)
                shutil.move(str(tmp_out), str(out))
                yield f"  installed {vid}\n".encode()
            except Exception as e:  # noqa: BLE001
                yield f"  failed {vid}: {e}\n".encode()
            finally:
                if tmp is not None:
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
    default_models = os.environ.get("YAP_MODELS_DIR") or os.environ.get("PARLEY_MODELS_DIR") or str(
        Path.home() / "Library/Application Support/Yap/models")
    p.add_argument("--models-dir", default=default_models)
    p.add_argument("--provider", default=os.environ.get("YAP_PROVIDER") or os.environ.get("PARLEY_PROVIDER", "auto"),
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
