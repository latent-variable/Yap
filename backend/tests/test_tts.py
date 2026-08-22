"""Robustness + latency tests for the Yap backend.

Run: cd backend && source <venv>/bin/activate && pip install pytest httpx
     pytest tests/ -v
Requires the model files present (skips synthesis if missing).
"""
import io
import time
import wave

import numpy as np
import pytest

from server import (chunk_text, split_sentences, segment_text, speakable, Engine, SAMPLE_RATE,
                    resolve_provider, GAP_SENTENCE, GAP_LINE, GAP_PARAGRAPH,
                    hd_voice_path)
from pocket_engine import PocketEngine
from pathlib import Path


@pytest.mark.parametrize("bad", [
    "../../../etc/passwd", "..%2f..", "a/b", "foo bar", "../secret",
    "x;y", "..", ".", "name.with.dots", "voice/../../x",
])
def test_hd_voice_path_rejects_traversal_and_unsafe_ids(bad):
    # voice_id flows in from the synth request; only bare [A-Za-z0-9_-] ids may
    # resolve, and only inside hd_voices_dir — never an arbitrary file.
    assert hd_voice_path(bad) is None


def test_hd_voice_path_accepts_safe_id_and_stays_in_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("PARLEY_HD_VOICES", str(tmp_path))
    (tmp_path / "Ben.wav").write_bytes(b"RIFF")
    p = hd_voice_path("Ben")
    assert p is not None and p.parent == tmp_path.resolve()
    assert hd_voice_path("Missing") is None  # safe id, but no such file


def _seg_texts(text):
    return [s for s, _g in segment_text(text)]


class TestSoftWrapReflow:
    """A hard-wrapped sentence must read as one unit, not get sliced (with a
    pause) at every newline."""

    def test_wrapped_sentence_joins(self):
        assert _seg_texts("I went to the store\nand bought some milk.") == \
            ["I went to the store and bought some milk."]

    def test_multiline_wrap_joins(self):
        assert _seg_texts("This is a long sentence that\nwraps across\nthree lines.") == \
            ["This is a long sentence that wraps across three lines."]

    def test_sentence_end_at_linebreak_keeps_pause(self):
        segs = segment_text("Buy milk.\nGo home.")
        assert [s for s, _ in segs] == ["Buy milk.", "Go home."]
        assert segs[0][1] == GAP_LINE   # real break, real pause

    def test_list_items_stay_separate(self):
        assert _seg_texts("- apples\n- oranges\n- pears") == \
            ["- apples", "- oranges", "- pears"]

    def test_wrapped_list_item_joins(self):
        assert _seg_texts("- a long bullet that\ncontinues on") == \
            ["- a long bullet that continues on"]

    def test_heading_stays_separate_from_wrapped_body(self):
        segs = segment_text("# Title\nbody text that\nwraps here.")
        assert [s for s, _ in segs] == ["# Title", "body text that wraps here."]
        assert segs[0][1] == GAP_LINE

    def test_colon_lead_in_keeps_break(self):
        assert _seg_texts("Here is the list:\nfirst thing") == \
            ["Here is the list:", "first thing"]

    def test_paragraph_gap_preserved(self):
        segs = segment_text("First para.\n\nSecond para.")
        assert [s for s, _ in segs] == ["First para.", "Second para."]
        assert segs[0][1] == GAP_PARAGRAPH

MODELS = Path.home() / "Library/Application Support/Yap/models"
HAVE_MODEL = (MODELS / "kokoro-v1.0.onnx").exists() and (MODELS / "voices-v1.0.bin").exists()
needs_model = pytest.mark.skipif(not HAVE_MODEL, reason="model files not installed")


@pytest.fixture(scope="session")
def engine():
    e = Engine(MODELS)
    e.load()
    assert e.kokoro is not None, e.error
    return e


# ── chunking (pure, no model) ───────────────────────────────────────────────
class TestChunking:
    def test_empty(self):
        assert chunk_text("") == []
        assert chunk_text("   \n\n  ") == []

    def test_short(self):
        assert chunk_text("Hello world.") == ["Hello world."]

    def test_paragraph_split(self):
        c = chunk_text("First para.\n\nSecond para.")
        assert len(c) == 2

    def test_abbreviations_not_split(self):
        # "Dr. Smith" must not break after "Dr."
        s = split_sentences("Dr. Smith went to Washington. He left.")
        assert len(s) == 2
        assert s[0].startswith("Dr. Smith")

    def test_long_sentence_hard_wrapped(self):
        long = "word " * 400  # ~2000 chars, no punctuation
        chunks = chunk_text(long, max_chars=320)
        assert all(len(c) <= 320 for c in chunks)
        assert len(chunks) > 1

    def test_chunk_cap_respected(self):
        text = ". ".join([f"Sentence number {i} here" for i in range(200)])
        chunks = chunk_text(text, max_chars=320)
        assert all(len(c) <= 320 for c in chunks)

    def test_no_degenerate_chunks(self):
        text = "Title\n\n```\ncode\n```\n\n---\n\nReal content here."
        chunks = chunk_text(text)
        for c in chunks:
            assert c.strip(), "empty chunk leaked"


class TestSegmentation:
    def test_sentence_gaps(self):
        segs = segment_text("One. Two. Three.")
        assert [s for s, _ in segs] == ["One.", "Two.", "Three."]
        # last segment no trailing gap; earlier ones get the sentence gap
        assert segs[0][1] == GAP_SENTENCE and segs[-1][1] == 0.0

    def test_paragraph_gap_longer_than_sentence(self):
        segs = segment_text("First para.\n\nSecond para.")
        assert segs[0][1] == GAP_PARAGRAPH
        assert GAP_PARAGRAPH > GAP_LINE > GAP_SENTENCE

    def test_line_breaks_get_pauses(self):
        # a bulleted-style list on separate lines must not run together
        segs = segment_text("Apples\nOranges\nPears")
        assert [s for s, _ in segs] == ["Apples", "Oranges", "Pears"]
        assert segs[0][1] == GAP_LINE and segs[1][1] == GAP_LINE

    def test_no_speech_lost(self):
        text = "Intro line.\n\n- one\n- two\n\nOutro."
        joined = " ".join(s for s, _ in segment_text(text))
        for word in ("Intro", "one", "two", "Outro"):
            assert word in joined

    @pytest.mark.parametrize("mark", ["---", "***", "___", "```", "|---|---|", "..."])
    def test_unspeakable_lines_are_dropped(self, mark):
        """A rule/fence phonemizes to nothing; Kokoro then raises on it. Streaming
        swallowed that (an error log per rule), WAV export 500'd. Drop at source."""
        segs = segment_text(f"First para.\n\n{mark}\n\nSecond para.")
        assert [s for s, _ in segs] == ["First para.", "Second para."]
        assert all(speakable(s) for s, _ in segs)

    def test_dropped_line_keeps_its_pause(self):
        """Losing the segment must not silently lose the beat it stood for."""
        segs = segment_text("First para.\n\n---\n\nSecond para.")
        assert segs[0][1] == GAP_PARAGRAPH

    def test_speakable_keeps_non_latin_and_digits(self):
        # isalnum is Unicode-aware; `\w` would wrongly accept the `_` in `___`.
        assert speakable("你好") and speakable("Привет") and speakable("42")
        assert not speakable("---") and not speakable("___") and not speakable("!?")

    def test_readme_has_no_unspeakable_segments(self):
        """The repo's own README is what turned the long-document tests red."""
        text = (Path(__file__).parents[2] / "README.md").read_text()
        bad = [s for s, _ in segment_text(text) if not speakable(s)]
        assert bad == [], f"unspeakable segments would fail synthesis: {bad[:5]}"


# ── synthesis robustness ────────────────────────────────────────────────────
@needs_model
class TestSynth:
    def synth(self, engine, text, voice="af_heart", speed=1.0):
        return engine.synth(text, voice, speed, None)

    def test_short(self, engine):
        a = self.synth(engine, "Hello.")
        assert len(a) > 0

    def test_unicode_and_emoji(self, engine):
        a = self.synth(engine, "Café résumé naïve — 100% done 🎉 ✓")
        assert len(a) > 0

    def test_numbers_and_symbols(self, engine):
        a = self.synth(engine, "Order #42 cost $19.99 at 3:30pm (50% off).")
        assert len(a) > 0

    def test_urls_and_code(self, engine):
        a = self.synth(engine, "See https://github.com/x/y and run snake_case_func().")
        assert len(a) > 0

    def test_punctuation_only_does_not_crash(self, engine):
        # may be near-silent, must not raise
        a = self.synth(engine, "... --- *** ###")
        assert isinstance(a, np.ndarray)

    def test_single_word(self, engine):
        assert len(self.synth(engine, "Yap")) > 0

    def test_dense_max_chunk(self, engine):
        # a full 320-char chunk of real words (chunk-size boundary stress)
        text = ("the quick brown fox jumps over the lazy dog " * 8)[:319] + "."
        assert len(self.synth(engine, text)) > 0

    @pytest.mark.parametrize("voice", ["af_heart", "am_michael", "bf_emma", "ef_dora"])
    def test_multiple_voices(self, engine, voice):
        assert len(self.synth(engine, "Testing this voice.", voice=voice)) > 0

    # Each non-English voice family must phonemize its own language. Regression
    # guard for the zh->cmn espeak code fix.
    @pytest.mark.parametrize("voice,text", [
        ("ef_dora", "Hola, esto es una prueba."),
        ("ff_siwis", "Bonjour, ceci est un test."),
        ("hf_alpha", "नमस्ते, यह एक परीक्षण है।"),
        ("if_sara", "Ciao, questo è un test."),
        ("jf_alpha", "こんにちは、テストです。"),
        ("pf_dora", "Olá, isto é um teste."),
        ("zf_xiaobei", "你好，这是测试。"),
        ("zm_yunjian", "你好，世界。"),
    ])
    def test_all_languages(self, engine, voice, text):
        assert len(self.synth(engine, text, voice=voice)) > 0, f"{voice} produced no audio"


# ── long-document streaming + latency (uses the chunk loop) ─────────────────
@needs_model
class TestLongDocument:
    def stream(self, engine, text):
        """Mimic /synthesize streaming: chunk, synth each, time first chunk."""
        chunks = chunk_text(text)
        t0 = time.time()
        first = None
        total = 0
        failed = 0
        for c in chunks:
            try:
                s = engine.synth(c, "af_heart", 1.0, None)
            except Exception:
                failed += 1
                continue
            if first is None:
                first = time.time() - t0
            total += len(s)
        return {"chunks": len(chunks), "first": first, "failed": failed,
                "audio_s": total / SAMPLE_RATE, "wall": time.time() - t0}

    def test_readme_sized(self, engine):
        text = (Path(__file__).parents[2] / "README.md").read_text()
        r = self.stream(engine, text)
        assert r["failed"] == 0, f"{r['failed']} chunks failed"
        assert r["first"] < 1.5, f"first chunk too slow: {r['first']:.2f}s"
        assert r["audio_s"] > 10

    def test_very_long_10x(self, engine):
        text = (Path(__file__).parents[2] / "README.md").read_text() * 10  # ~44k chars
        r = self.stream(engine, text)
        assert r["failed"] == 0, f"{r['failed']} chunks failed out of {r['chunks']}"
        assert r["first"] < 1.5, f"first chunk latency {r['first']:.2f}s"

    def test_huge_single_paragraph(self, engine):
        # 5000 chars, no paragraph breaks -> exercises sentence+hardwrap path
        text = "This is a sentence. " * 250
        r = self.stream(engine, text)
        assert r["failed"] == 0


# ── execution provider / acceleration ───────────────────────────────────────
class TestProvider:
    def test_resolve(self):
        assert resolve_provider("auto") == "CPUExecutionProvider"
        assert resolve_provider("cpu") == "CPUExecutionProvider"
        assert resolve_provider("coreml") == "CoreMLExecutionProvider"

    @needs_model
    def test_auto_loads_and_reports(self):
        e = Engine(MODELS, provider_mode="auto")
        e.load()
        assert e.kokoro is not None
        # CPU EP is always present as the implicit fallback
        assert "CPUExecutionProvider" in e.active_providers

    @needs_model
    def test_coreml_available_and_loads(self):
        # Apple Silicon should expose CoreML; loading it must not crash and must
        # keep CPU as fallback.
        e = Engine(MODELS, provider_mode="coreml")
        e.load()
        assert e.kokoro is not None, e.error
        assert "CPUExecutionProvider" in e.active_providers


# ── engine offload (memory reclaim) ─────────────────────────────────────────
class TestUnload:
    @needs_model
    def test_kokoro_unload_is_idempotent_and_lazily_reloads(self):
        # Fresh engine so we don't strand the shared session fixture unloaded.
        e = Engine(MODELS)
        e.load()
        assert e.kokoro is not None, e.error
        assert e.unload() is True          # frees the resident session
        assert e.kokoro is None
        assert e.active_providers == []
        assert e.unload() is False         # already unloaded -> no-op
        # A read must transparently reload — offload safety hinges on this.
        out = e.synth("Reload.", "am_puck", 1.0, None)
        assert e.kokoro is not None and out.size > 0

    def test_pocket_unload_noop_when_not_loaded(self):
        # Must not import torch or load anything when the model was never resident.
        pk = PocketEngine()
        assert pk.model is None
        assert pk.unload() is False
        assert pk.has_cloning is False

    def test_gated_weights_cached_detection(self, tmp_path, monkeypatch):
        # gated_weights_cached() drives the token-free offline load + the app
        # skipping the Keychain read. It must be true ONLY when the COMPLETED
        # weights (a weights-sized file, in a subdir) sit in the HF cache — an
        # incomplete download (only small files) must read False so the backend
        # stays online and can finish it. No torch needed.
        import pocket_engine
        monkeypatch.setattr(pocket_engine, "_hf_hub_cache", lambda: str(tmp_path))
        # Shrink the weights threshold so the test writes bytes, not 10 MB.
        monkeypatch.setattr(pocket_engine, "_MIN_WEIGHT_BYTES", 100)

        assert pocket_engine.gated_weights_cached() is False   # empty cache

        snaps = tmp_path / "models--kyutai--pocket-tts" / "snapshots"
        (snaps / "abc123").mkdir(parents=True)
        assert pocket_engine.gated_weights_cached() is False   # snapshot dir empty

        # Interrupted download: only small files present -> NOT cached.
        (snaps / "abc123" / "config.json").write_text("{}")
        assert pocket_engine.gated_weights_cached() is False

        # Completed: a weights-sized file in a subdir (mirrors languages/<lang>/…).
        weights = snaps / "abc123" / "languages" / "english" / "model.safetensors"
        weights.parent.mkdir(parents=True)
        weights.write_bytes(b"\0" * 200)                       # > threshold (100)
        assert pocket_engine.gated_weights_cached() is True

        # The ungated catalog repo must NOT count as cloning weights.
        import shutil
        shutil.rmtree(tmp_path / "models--kyutai--pocket-tts")
        catalog = tmp_path / "models--kyutai--pocket-tts-without-voice-cloning" / "snapshots" / "z"
        catalog.mkdir(parents=True)
        (catalog / "big.safetensors").write_bytes(b"\0" * 200)
        assert pocket_engine.gated_weights_cached() is False

    def test_hf_hub_offline_restored_when_load_fails(self, monkeypatch):
        # If load() sets HF_HUB_OFFLINE=1 (cached weights) but the pocket_tts import
        # or model load then fails, the env MUST be restored — a leaked offline flag
        # would wedge a later first-time download offline. No torch needed.
        import os, sys, types, pocket_engine
        monkeypatch.setattr(pocket_engine, "gated_weights_cached", lambda: True)
        eng = pocket_engine.PocketEngine()
        monkeypatch.setattr(eng, "available", lambda: True)
        # A stand-in pocket_tts module with no TTSModel -> the from-import raises,
        # simulating a broken/half-installed Pocket environment.
        monkeypatch.setitem(sys.modules, "pocket_tts", types.ModuleType("pocket_tts"))
        monkeypatch.delenv("HF_HUB_OFFLINE", raising=False)

        assert eng.load() is False                          # import failed
        assert "HF_HUB_OFFLINE" not in os.environ           # restored (was unset)

        # And when a prior value existed, it's put back verbatim (not clobbered).
        monkeypatch.setenv("HF_HUB_OFFLINE", "0")
        assert eng.load() is False
        assert os.environ.get("HF_HUB_OFFLINE") == "0"

    @pytest.mark.skipif(not PocketEngine().available(),
                        reason="Pocket deps (torch) not installed")
    def test_pocket_unload_then_lazy_reload(self):
        # The offload safety claim: unloading a loaded Pocket model, then reading,
        # transparently reloads it (catalog voice — no HF token/cloning needed).
        pk = PocketEngine()
        assert pk.load(), pk.error
        assert pk.model is not None
        assert pk.unload() is True
        assert pk.model is None and pk.has_cloning is False
        out = pk.synth("Reload.", "alba", 1.0)
        assert pk.model is not None and out.size > 0


# ── WAV export ──────────────────────────────────────────────────────────────
@needs_model
class TestExport:
    def test_wav_valid(self, engine):
        from server import wav_bytes
        a = engine.synth("Export check.", "af_heart", 1.0, None)
        data = wav_bytes(a)
        with wave.open(io.BytesIO(data), "rb") as w:
            assert w.getframerate() == SAMPLE_RATE
            assert w.getnchannels() == 1
            assert w.getnframes() > 0


# ── connection lifetime ─────────────────────────────────────────────────────
class TestKeepAlive:
    """The app reads /synthesize at PLAYBACK rate, so a response the server has
    finished writing keeps draining out of the socket for as long as it takes to
    hear it. uvicorn's 5s default closes the connection during that drain and the
    client loses every byte still in flight — a read that stops a few sentences
    early with no error the listener sees. End-to-end probe: `Yap --tailtest`."""

    def test_keep_alive_outlasts_a_draining_read(self):
        import server
        # Only has to outlast a socket buffer draining at 48000 B/s. A minute is
        # already far past any real buffer; the floor is what matters, not 900.
        assert server.KEEP_ALIVE >= 60

    def test_main_actually_passes_it_to_uvicorn(self, monkeypatch, tmp_path):
        # The constant is worthless if main() stops handing it over.
        import sys, types, server
        seen = {}
        fake = types.ModuleType("uvicorn")
        fake.run = lambda app, **kw: seen.update(kw)
        monkeypatch.setitem(sys.modules, "uvicorn", fake)
        monkeypatch.setattr(sys, "argv",
                            ["server.py", "--no-preload", "--models-dir", str(tmp_path)])
        server.main()
        assert seen.get("timeout_keep_alive") == server.KEEP_ALIVE


# ── stream integrity ────────────────────────────────────────────────────────
class TestStreamIntegrity:
    """A read that dies partway must reach the app as a FAILURE.

    Segment failures used to be logged and skipped, so a document read aloud with
    holes in it — or with no audio at all — still finished as a clean HTTP 200 and
    the app announced a successful read. Two mechanisms close that, and the second
    exists because the first cannot cover mid-stream: once the body has started,
    the 200 is unretractable AND uvicorn still terminates the chunked response
    cleanly when the generator stops early (asserted below), so truncation is
    invisible on the wire without an in-band marker.
    """

    @staticmethod
    def _serve(monkeypatch, fail_at):
        """Run the real app under a real uvicorn, with synthesis failing at
        segment index `fail_at` (None = never). Returns (port, stop)."""
        import socket as _socket
        import threading
        import uvicorn
        import server

        monkeypatch.setattr(server, "AUTH_TOKEN", "stream-test-token")
        calls = {"n": -1}

        def fake_segment_synth(_req):
            def synth(_text):
                calls["n"] += 1
                if fail_at is not None and calls["n"] >= fail_at:
                    raise RuntimeError("synth exploded")
                return np.zeros(2400, dtype=np.float32)   # 0.1s
            return synth

        monkeypatch.setattr(server, "_segment_synth", fake_segment_synth)

        s = _socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        srv = uvicorn.Server(uvicorn.Config(server.app, host="127.0.0.1", port=port,
                                            log_level="critical"))
        threading.Thread(target=srv.run, daemon=True).start()
        for _ in range(200):
            if srv.started:
                break
            time.sleep(0.05)
        assert srv.started, "test server never came up"

        def stop():
            srv.should_exit = True
        return port, stop

    @staticmethod
    def _read(port):
        """Raw HTTP so the assertion is about the actual bytes on the wire, the
        way URLSession sees them — not what an HTTP client chooses to tolerate."""
        import http.client
        import json as _json
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        body = _json.dumps({"text": "One. Two. Three. Four.", "voice": "af_heart",
                            "speed": 1.0, "pause_scale": 1.0, "engine": "kokoro"})
        conn.request("POST", "/synthesize", body=body,
                     headers={"Content-Type": "application/json",
                              "Authorization": "Bearer stream-test-token"})
        r = conn.getresponse()
        return r.status, dict(r.getheaders()), r.read()

    def test_complete_stream_is_marked_complete(self, monkeypatch):
        import server
        port, stop = self._serve(monkeypatch, fail_at=None)
        try:
            status, headers, body = self._read(port)
        finally:
            stop()
        assert status == 200
        # Advertised, so an older sidecar without it just isn't checked.
        assert headers.get("x-stream-footer") == server.STREAM_FOOTER.decode()
        assert body.endswith(server.STREAM_FOOTER)
        assert len(body) > len(server.STREAM_FOOTER)

    def test_first_segment_failure_is_an_error_status(self, monkeypatch):
        # Nothing has been sent yet, so this one can still be a real 500 — and it
        # is the systemic case (model unloaded, unknown voice, cloning off) that
        # otherwise produced a 200 carrying no audio.
        port, stop = self._serve(monkeypatch, fail_at=0)
        try:
            status, _headers, body = self._read(port)
        finally:
            stop()
        assert status == 500
        assert b"synthesis failed" in body

    def test_mid_stream_failure_leaves_the_stream_unmarked(self, monkeypatch):
        import server
        port, stop = self._serve(monkeypatch, fail_at=2)
        try:
            status, _headers, body = self._read(port)
        finally:
            stop()
        # The status is still 200 and the body still ends cleanly — that is the
        # whole problem, and why the footer has to carry the verdict instead.
        assert status == 200
        assert len(body) > 0, "audio before the failure is still delivered"
        assert not body.endswith(server.STREAM_FOOTER), \
            "a truncated read must not be marked complete"


# ── Pocket utterance padding ────────────────────────────────────────────────
LEAD_PAD_SLACK = 0.03   # the trim quantizes to 10 ms frames


class TestPocketPadding:
    """Pocket wraps every utterance in its own silence — 0.56-0.96s leading,
    0.20-0.34s trailing, near-constant regardless of line length, against
    0.04-0.05s / 0.09-0.19s from Kokoro on the same text. Played verbatim that
    is a second of dead air in front of every sentence, stacked on top of the
    gap server.py already inserts, and it made GAP_SENTENCE mean different
    things on the two engines. trim_padding() cuts it back to Kokoro's range.

    The pure cases run anywhere; the synthesis case needs Pocket installed.
    """

    @staticmethod
    def _tone(seconds, sr=SAMPLE_RATE, amp=0.5):
        t = np.arange(int(seconds * sr)) / sr
        return (amp * np.sin(2 * np.pi * 220 * t)).astype(np.float32)

    @staticmethod
    def _edges(a, sr=SAMPLE_RATE, thr=0.01):
        fl = int(0.01 * sr)
        f = a[: a.size // fl * fl].reshape(-1, fl)
        rms = np.sqrt((f ** 2).mean(axis=1))
        loud = np.flatnonzero(rms >= thr)
        if loud.size == 0:
            return a.size / sr, 0.0
        return loud[0] * fl / sr, (len(f) - 1 - loud[-1]) * fl / sr

    def test_padding_is_cut_back_to_target(self):
        from pocket_engine import trim_padding, LEAD_PAD, TRAIL_PAD
        padded = np.concatenate([np.zeros(int(0.9 * SAMPLE_RATE), np.float32),
                                 self._tone(1.0),
                                 np.zeros(int(0.35 * SAMPLE_RATE), np.float32)])
        out = trim_padding(padded)
        lead, trail = self._edges(out)
        # A frame of slack either side: the trim quantizes to 10 ms frames.
        assert lead <= LEAD_PAD + 0.01, f"lead {lead:.3f}s"
        assert trail <= TRAIL_PAD + 0.02, f"trail {trail:.3f}s"

    def test_the_speech_itself_survives(self):
        from pocket_engine import trim_padding
        speech = self._tone(1.0)
        padded = np.concatenate([np.zeros(int(0.9 * SAMPLE_RATE), np.float32), speech,
                                 np.zeros(int(0.35 * SAMPLE_RATE), np.float32)])
        out = trim_padding(padded)
        # Cutting into the words is the failure that matters far more than
        # leaving silence, so assert the energy is all still there.
        assert out.size >= speech.size
        assert float(np.sum(out ** 2)) == pytest.approx(float(np.sum(speech ** 2)), rel=1e-3)

    def test_a_quiet_onset_is_not_clipped_off_the_word(self):
        from pocket_engine import trim_padding
        # A fricative — /s/, /f/ — carries a fraction of the energy of the vowel
        # after it. A single threshold set high enough to ignore the model's noise
        # floor sits above this, and the trim then starts at the vowel and eats the
        # consonant. This is the failure that matters: leaving silence is free,
        # cutting the front off a word is audible damage.
        rng = np.random.default_rng(7)
        fricative = (rng.standard_normal(int(0.14 * SAMPLE_RATE)) * 0.006).astype(np.float32)
        vowel = self._tone(0.5, amp=0.5)
        padded = np.concatenate([np.zeros(int(0.9 * SAMPLE_RATE), np.float32),
                                 fricative, vowel,
                                 np.zeros(int(0.35 * SAMPLE_RATE), np.float32)])
        out = trim_padding(padded)

        # Assert the CONTENT, not the length: a trim that cut the consonant still
        # returns a long clip, because the trailing pad makes up the difference.
        # So find where the vowel starts inside the result and weigh what is in
        # front of it — that is the consonant, or it is nothing.
        fl = int(0.01 * SAMPLE_RATE)
        f = out[: out.size // fl * fl].reshape(-1, fl)
        vowel_frame = int(np.flatnonzero(np.sqrt((f ** 2).mean(axis=1)) >= 0.05)[0])
        before = out[: vowel_frame * fl]
        kept = float(np.sum(before ** 2))
        want = float(np.sum(fricative ** 2))
        assert kept >= want * 0.9, (
            f"the /s/ was clipped: {kept:.4f} of {want:.4f} energy survives in "
            f"front of the vowel")
        # ...and it must still have done its job on the silence in front of that.
        from pocket_engine import LEAD_PAD
        assert vowel_frame * fl / SAMPLE_RATE <= 0.14 + LEAD_PAD + LEAD_PAD_SLACK, \
            f"lead to vowel {vowel_frame * fl / SAMPLE_RATE:.3f}s"

    def test_an_already_tight_clip_is_untouched(self):
        from pocket_engine import trim_padding
        tight = self._tone(0.5)
        out = trim_padding(tight)
        assert out.size == tight.size and np.array_equal(out, tight)

    def test_silence_only_is_returned_whole_not_emptied(self):
        from pocket_engine import trim_padding
        quiet = np.zeros(int(0.5 * SAMPLE_RATE), np.float32)
        # Nothing detectable means we cannot tell padding from content, so the
        # safe answer is to keep it. Emptying would drop audio outright.
        assert trim_padding(quiet).size == quiet.size
        assert trim_padding(np.zeros(0, np.float32)).size == 0

    def test_synthesized_pocket_lines_are_not_front_loaded_with_silence(self):
        from pocket_engine import PocketEngine, LEAD_PAD, TRAIL_PAD
        eng = PocketEngine()
        if not eng.available() or not eng.load():
            pytest.skip("Pocket engine not installed")
        # Bounds sit well under the 0.56-0.96s / 0.20-0.34s the model actually
        # emits, so they still fail outright if trimming stops working — but not
        # at LEAD_PAD exactly: a line like "See ..." opens on a quiet /s/ that the
        # detector deliberately keeps, and a test that punished that would be
        # asking the trim to cut speech.
        for line in ["Meet Yap.", "Stop typing.", "See something worth hearing?"]:
            lead, trail = self._edges(eng.synth(line, "eve", 1.0))
            assert lead <= 0.25, f"{line!r} still leads with {lead:.2f}s"
            assert trail <= 0.30, f"{line!r} still trails {trail:.2f}s"
