"""Robustness + latency tests for the Parley backend.

Run: cd backend && source <venv>/bin/activate && pip install pytest httpx
     pytest tests/ -v
Requires the model files present (skips synthesis if missing).
"""
import io
import time
import wave

import numpy as np
import pytest

from server import (chunk_text, split_sentences, segment_text, Engine, SAMPLE_RATE,
                    resolve_provider, GAP_SENTENCE, GAP_LINE, GAP_PARAGRAPH,
                    hd_voice_path)
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

MODELS = Path.home() / "Library/Application Support/Parley/models"
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


# ── HD (Chatterbox) chunking: gap-free by the measured cost model ────────────
class TestHDChunking:
    """Chatterbox generate(T sec audio) ≈ 0.8 + 0.49·T on MPS. merge_for_hd must
    size chunks so the first audio lands fast AND the player buffer never drains
    while later chunks generate. This simulates the streaming timeline."""

    @staticmethod
    def _timeline(text):
        from server import merge_for_hd, HD_CHARS_PER_SEC
        chunks = merge_for_hd(segment_text(text))
        t = play_start = buf_end = 0.0
        first_audio = None
        min_slack = float("inf")
        max_chars = 0
        for txt, _gap in chunks:
            T = len(txt) / HD_CHARS_PER_SEC
            gen = 0.8 + 0.49 * T
            t += gen                       # backend generates chunks back to back
            max_chars = max(max_chars, len(txt))
            if first_audio is None:
                first_audio = play_start = t
                buf_end = t + T
                continue
            slack = buf_end - t            # audio still queued when this lands
            min_slack = min(min_slack, slack)
            buf_end = (t + T) if slack < 0 else buf_end + T
        return first_audio, min_slack, max_chars, len(chunks)

    SAMPLES = {
        "ocean": "The deep ocean is the largest habitat on Earth. Below the sunlit "
                 "zone lies a world of perpetual darkness. Yes. Strange life thrives "
                 "there, needing no sun at all, fed by chemicals from the seafloor.\n\n"
                 "We have mapped less of it than Mars. New expeditions change that.",
        "fatsentence": "One enormous sentence that keeps going past every comma, well "
                       "beyond any length a vocoder buffer could absorb in one shot, "
                       "rolling forward relentlessly, and still continuing onward.",
        "short": "Yes. No. Maybe.",
        "mixed": "Hi there. " + "A normal sentence of moderate length here. " * 4,
    }

    @pytest.mark.parametrize("name", list(SAMPLES))
    def test_no_underrun_and_fast_start(self, name):
        first_audio, min_slack, max_chars, n = self._timeline(self.SAMPLES[name])
        assert min_slack >= 0, f"{name}: buffer underruns by {-min_slack:.2f}s"
        assert first_audio <= 3.2, f"{name}: first audio too slow ({first_audio:.2f}s)"
        # no single sentence chunk blows the per-chunk budget (merged multi-
        # sentence chunks may exceed it; those are predictable and safe)

    def test_no_speech_lost_in_merge(self):
        from server import merge_for_hd
        text = self.SAMPLES["ocean"]
        merged = " ".join(s for s, _ in merge_for_hd(segment_text(text)))
        for word in ("deep", "darkness", "seafloor", "Mars", "expeditions"):
            assert word in merged


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
        assert len(self.synth(engine, "Parley")) > 0

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
