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


def test_voices_lists_only_clips_synthesis_can_resolve(tmp_path, monkeypatch):
    # The picker and the synth guard must agree on the id grammar. They didn't:
    # /voices globbed every *.wav while hd_voice_path refused anything outside
    # [A-Za-z0-9_-], so a clip named "My Sam.wav" was offered and then 400'd for
    # a voice the user could see. Old builds still leave such files on disk.
    import server
    monkeypatch.setenv("PARLEY_HD_VOICES", str(tmp_path))
    for stem in ["My Sam", "My-Sam", "Ravi", "Dad's voice", "🎤"]:
        (tmp_path / f"{stem}.wav").write_bytes(b"RIFF")
    monkeypatch.setattr(server.pk_engine, "voices", lambda: [], raising=False)

    listed = {v["id"] for v in server.voices(engine_name="pocket")["voices"]
              if v.get("needs_cloning")}

    assert listed == {"My-Sam", "Ravi"}
    # The claim is not "some were filtered" but "everything listed resolves" —
    # assert it against the guard itself, so the two can't drift apart again.
    assert all(hd_voice_path(v) is not None for v in listed)
    # Control: the names dropped are exactly the ones the guard refuses, and the
    # files are still on disk (an unusable clip is hidden, never deleted).
    assert all(hd_voice_path(bad) is None for bad in ["My Sam", "Dad's voice", "🎤"])
    assert len(list(tmp_path.glob("*.wav"))) == 5


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

    def test_us_abbreviation_not_split(self):
        assert split_sentences("The U.S. is big.") == ["The U.S. is big."]

    def test_bracketed_abbreviation_not_split(self):
        assert split_sentences("(e.g. foo)") == ["(e.g. foo)"]

    def test_numbered_list_item_not_split(self):
        assert split_sentences("10. End of line.") == ["10. End of line."]

    def test_real_sentence_boundary_after_abbreviation(self):
        assert split_sentences("The U.S. is big. He lives there.") == [
            "The U.S. is big.",
            "He lives there.",
        ]

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

    @pytest.mark.slow
    @pytest.mark.parametrize("voice", ["af_heart", "am_michael", "bf_emma", "ef_dora"])
    def test_multiple_voices(self, engine, voice):
        assert len(self.synth(engine, "Testing this voice.", voice=voice)) > 0

    # Each non-English voice family must phonemize its own language. Regression
    # guard for the zh->cmn espeak code fix.
    @pytest.mark.slow
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
# Slow by SCALE, not by kind: test_very_long_10x alone streams ~45 minutes of
# audio. The three full-document cases are marked individually rather than on the
# class, because the default run must keep one real multi-chunk stream — chunking
# and synthesis are each covered alone (TestChunking, TestSynth), but only this
# loop covers them TOGETHER, and a chunk that silently fails to synthesize is
# exactly the kind of break that finishes green everywhere else.
@needs_model
class TestLongDocument:
    def stream(self, engine, text):
        """Mimic /synthesize streaming: chunk, synth each, time first chunk."""
        chunks = chunk_text(text)
        t0 = time.time()
        first = None
        total = 0
        failed = 0
        # Smallest per-chunk output. A chunk that returns an EMPTY array never
        # raises, so it is not "failed" and the total still looks healthy off the
        # other chunks — a silent hole in the middle of a read. Only a per-chunk
        # floor catches that, so track it here rather than inferring from audio_s.
        min_samples = None
        for c in chunks:
            try:
                s = engine.synth(c, "af_heart", 1.0, None)
            except Exception:
                failed += 1
                continue
            if first is None:
                first = time.time() - t0
            total += len(s)
            min_samples = len(s) if min_samples is None else min(min_samples, len(s))
        return {"chunks": len(chunks), "first": first, "failed": failed,
                "audio_s": total / SAMPLE_RATE, "wall": time.time() - t0,
                "min_samples": min_samples}

    def test_multi_chunk_stream_survives_every_chunk(self, engine):
        """The default set's multi-chunk guard: several chunks, all synthesized.

        Deliberately small — ~800 chars is a few chunks past the 320-char cap,
        enough to cross chunk boundaries without streaming minutes of audio. The
        scale cases below are the same loop with volume; this one is the loop.
        """
        text = ("Yap reads the text you select. " * 26)  # ~800 chars -> several chunks
        r = self.stream(engine, text)   # session fixture — no second model load
        assert r["chunks"] > 1, f"needs multiple chunks to be a multi-chunk test, got {r['chunks']}"
        assert r["failed"] == 0, f"{r['failed']} of {r['chunks']} chunks failed to synthesize"
        # Per-chunk, not just the total: an empty chunk raises nothing and hides
        # behind its neighbours' audio, which is the silent hole this test exists
        # to catch.
        assert r["min_samples"], "a chunk produced no audio at all"
        assert r["audio_s"] > 0

    @pytest.mark.slow
    def test_readme_sized(self, engine):
        text = (Path(__file__).parents[2] / "README.md").read_text()
        r = self.stream(engine, text)
        assert r["failed"] == 0, f"{r['failed']} chunks failed"
        assert r["first"] < 1.5, f"first chunk too slow: {r['first']:.2f}s"
        assert r["audio_s"] > 10

    @pytest.mark.slow
    def test_very_long_10x(self, engine):
        text = (Path(__file__).parents[2] / "README.md").read_text() * 10  # ~44k chars
        r = self.stream(engine, text)
        assert r["failed"] == 0, f"{r['failed']} chunks failed out of {r['chunks']}"
        assert r["first"] < 1.5, f"first chunk latency {r['first']:.2f}s"

    @pytest.mark.slow
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

    @pytest.mark.slow
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

    def test_cloning_weights_ready_is_size_exact(self, tmp_path, monkeypatch):
        # ready() gates whether the app offers cloning at all, and it is called on
        # every status poll, so it checks SIZE not hash. Exact size, not a floor: a
        # truncated download is the failure it exists to catch. No torch needed.
        import pocket_engine
        monkeypatch.setattr(pocket_engine, "weights_dir", lambda: tmp_path)
        monkeypatch.setattr(pocket_engine, "CLONING_WEIGHTS_BYTES", 64)
        assert pocket_engine.cloning_weights_ready() is False        # nothing there

        w = pocket_engine.cloning_weights_path()
        w.write_bytes(b"\0" * 32)
        assert pocket_engine.cloning_weights_ready() is False        # truncated
        w.write_bytes(b"\0" * 128)
        assert pocket_engine.cloning_weights_ready() is False        # too big
        w.write_bytes(b"\0" * 64)
        assert pocket_engine.cloning_weights_ready() is True

    def test_bad_checksum_is_discarded_not_installed(self, tmp_path, monkeypatch):
        # The whole point of pinning: a mirror we control is still a network fetch.
        # A file that downloads fine but hashes wrong must leave NOTHING behind —
        # a half-installed weights file would be trusted forever after by the
        # size-only ready() check. No torch, no network.
        import pocket_engine
        monkeypatch.setattr(pocket_engine, "weights_dir", lambda: tmp_path)
        monkeypatch.setattr(pocket_engine, "CLONING_WEIGHTS_BYTES", 4)
        monkeypatch.setattr(pocket_engine, "_legacy_hf_copy", lambda: None)

        payload = b"junk"
        def fake_urlopen(url, timeout=0):
            import io, contextlib
            return contextlib.closing(io.BytesIO(payload))
        import urllib.request
        monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)

        # Wrong hash -> refused, and no file (nor .part) survives.
        monkeypatch.setattr(pocket_engine, "CLONING_WEIGHTS_SHA256", "00" * 32)
        assert pocket_engine.ensure_cloning_weights() is False
        assert not pocket_engine.cloning_weights_path().exists()
        assert not list(tmp_path.glob("*.part"))
        assert pocket_engine.cloning_weights_ready() is False

        # Right hash -> installed.
        import hashlib
        monkeypatch.setattr(pocket_engine, "CLONING_WEIGHTS_SHA256",
                            hashlib.sha256(payload).hexdigest())
        assert pocket_engine.ensure_cloning_weights() is True
        assert pocket_engine.cloning_weights_path().read_bytes() == payload

    def test_oversized_response_is_refused_not_streamed_to_disk(self, tmp_path, monkeypatch):
        # We know the exact byte count, so a longer response is junk by definition
        # (an error page, a redirect loop, a swapped file). Writing it anyway turns
        # a bad download into a full disk. It must stop and leave nothing behind.
        import pocket_engine
        monkeypatch.setattr(pocket_engine, "weights_dir", lambda: tmp_path)
        monkeypatch.setattr(pocket_engine, "_legacy_hf_copy", lambda: None)
        monkeypatch.setattr(pocket_engine, "CLONING_WEIGHTS_BYTES", 8)

        # Far past the cap (size + 1 MB slack), delivered in chunks like a stream.
        flood = b"x" * (8 + (1 << 20) + 4096)
        def fake_urlopen(url, timeout=0):
            import io, contextlib
            return contextlib.closing(io.BytesIO(flood))
        import urllib.request
        monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)

        assert pocket_engine.ensure_cloning_weights() is False
        assert not pocket_engine.cloning_weights_path().exists()
        assert not list(tmp_path.glob("*.part")), "an oversized body was left on disk"

    def test_progress_arrives_during_the_download_not_after(self, tmp_path, monkeypatch):
        # The install dialog sat silent for the whole 209 MB because a callback's
        # lines could only be flushed once the work finished. The generator must
        # emit WHILE bytes are still arriving, so the test reads one line and then
        # asserts the stream has not finished reading the body yet.
        import pocket_engine, hashlib
        monkeypatch.setattr(pocket_engine, "weights_dir", lambda: tmp_path)
        monkeypatch.setattr(pocket_engine, "_legacy_hf_copy", lambda: None)
        payload = b"z" * (6 << 20)                      # 6 blocks of 1 MB
        monkeypatch.setattr(pocket_engine, "CLONING_WEIGHTS_BYTES", len(payload))
        monkeypatch.setattr(pocket_engine, "CLONING_WEIGHTS_SHA256",
                            hashlib.sha256(payload).hexdigest())

        reads = {"n": 0}
        class CountingBody:
            def __init__(self): self.buf = __import__("io").BytesIO(payload)
            def read(self, n): reads["n"] += 1; return self.buf.read(n)
            def __enter__(self): return self
            def __exit__(self, *a): return False
        monkeypatch.setattr(__import__("urllib.request", fromlist=["x"]),
                            "urlopen", lambda url, timeout=0: CountingBody())

        gen = pocket_engine.ensure_cloning_weights_stream()
        first = next(gen)                               # "downloading ... one time"
        assert "download" in first.lower(), first
        assert reads["n"] == 0, "the body was consumed before the first line was emitted"

        seen = [first]
        while True:
            try:
                seen.append(next(gen))
            except StopIteration as done:
                assert done.value is True
                break
        pct = [l for l in seen if "%" in l]
        assert len(pct) >= 2, f"expected byte progress while downloading, got {seen}"
        assert any("100%" in l for l in pct), f"never reported completion: {pct}"
        assert pocket_engine.cloning_weights_ready() is True

    def test_stale_part_file_does_not_block_a_retry(self, tmp_path, monkeypatch):
        # A .part left by a killed run must not be mistaken for the download we are
        # about to verify. urllib cannot resume, and the fetch only runs when tmp is
        # absent, so a leftover would be hashed, rejected and reported as a failed
        # fetch having retried nothing. The retry must actually re-download.
        import hashlib, pocket_engine
        monkeypatch.setattr(pocket_engine, "weights_dir", lambda: tmp_path)
        monkeypatch.setattr(pocket_engine, "_legacy_hf_copy", lambda: None)
        payload = b"the real weights"
        monkeypatch.setattr(pocket_engine, "CLONING_WEIGHTS_BYTES", len(payload))
        monkeypatch.setattr(pocket_engine, "CLONING_WEIGHTS_SHA256",
                            hashlib.sha256(payload).hexdigest())

        calls = []
        def fake_urlopen(url, timeout=0):
            import io, contextlib
            calls.append(url)
            return contextlib.closing(io.BytesIO(payload))
        import urllib.request
        monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)

        # Truncated leftover from a previous crash.
        stale = pocket_engine.cloning_weights_path().with_suffix(".part")
        stale.parent.mkdir(parents=True, exist_ok=True)
        stale.write_bytes(b"half")

        assert pocket_engine.ensure_cloning_weights() is True
        assert calls, "a stale .part suppressed the retry entirely"
        assert pocket_engine.cloning_weights_path().read_bytes() == payload
        assert not stale.exists()

    def test_upgrade_adopts_the_old_install_without_network(self, tmp_path, monkeypatch):
        # The regression this PR exists to prevent, reintroduced by the PR itself:
        # an existing token-era user has the weights only in the HF cache, so on the
        # first launch after upgrading load() would go catalog-only and refreshHD
        # would demote their cloned voice. Adoption must therefore happen on LOAD,
        # locally, and must never reach for the network to do it.
        import hashlib, pocket_engine
        payload = b"existing users weights"
        cache = tmp_path / "hf" / "models--kyutai--pocket-tts" / "snapshots" / "r" / "languages" / "english"
        cache.mkdir(parents=True)
        (cache / "model.safetensors").write_bytes(payload)
        monkeypatch.setenv("HF_HUB_CACHE", str(tmp_path / "hf"))
        monkeypatch.setattr(pocket_engine, "weights_dir", lambda: tmp_path / "dest")
        monkeypatch.setattr(pocket_engine, "CLONING_WEIGHTS_BYTES", len(payload))
        monkeypatch.setattr(pocket_engine, "CLONING_WEIGHTS_SHA256",
                            hashlib.sha256(payload).hexdigest())
        import urllib.request
        def boom(*a, **k):
            raise AssertionError("adoption must be local; it downloaded instead")
        monkeypatch.setattr(urllib.request, "urlopen", boom)

        assert pocket_engine.cloning_weights_ready() is False     # pre-upgrade state
        assert pocket_engine.adopt_legacy_copy() is True
        assert pocket_engine.cloning_weights_ready() is True      # cloning survives

    def test_adoption_never_downloads_when_there_is_nothing_local(self, tmp_path, monkeypatch):
        # allow_download=False is the whole safety of calling adoption on every
        # load: a fresh user with no local copy must get a cheap False, not 209 MB
        # pulled behind their back.
        import pocket_engine
        monkeypatch.setattr(pocket_engine, "weights_dir", lambda: tmp_path / "dest")
        monkeypatch.setattr(pocket_engine, "_legacy_hf_copy", lambda: None)
        import urllib.request
        def boom(*a, **k):
            raise AssertionError("adoption downloaded without being asked")
        monkeypatch.setattr(urllib.request, "urlopen", boom)

        assert pocket_engine.adopt_legacy_copy() is False
        assert not pocket_engine.cloning_weights_path().exists()

    def test_legacy_hf_cache_copy_is_reused_not_redownloaded(self, tmp_path, monkeypatch):
        # Anyone who set cloning up under the old token flow already has the exact
        # file. Reusing it saves a second 209 MB download, and it must still pass
        # the same hash gate rather than being trusted for being local.
        import hashlib, pocket_engine
        payload = b"weights!"
        cache = tmp_path / "hf" / "models--kyutai--pocket-tts" / "snapshots" / "r1" / "languages" / "english"
        cache.mkdir(parents=True)
        (cache / "model.safetensors").write_bytes(payload)

        monkeypatch.setenv("HF_HUB_CACHE", str(tmp_path / "hf"))
        monkeypatch.setattr(pocket_engine, "weights_dir", lambda: tmp_path / "dest")
        monkeypatch.setattr(pocket_engine, "CLONING_WEIGHTS_BYTES", len(payload))
        monkeypatch.setattr(pocket_engine, "CLONING_WEIGHTS_SHA256",
                            hashlib.sha256(payload).hexdigest())
        # Any network attempt is a failure of the test's premise.
        import urllib.request
        def boom(*a, **k):
            raise AssertionError("downloaded despite a usable local copy")
        monkeypatch.setattr(urllib.request, "urlopen", boom)

        assert pocket_engine.ensure_cloning_weights() is True
        assert pocket_engine.cloning_weights_path().read_bytes() == payload

    def test_catalog_voices_survive_a_custom_config(self, tmp_path, monkeypatch):
        # Loading through our own config file broke ALL 26 catalog voices while
        # cloning kept working: pocket_tts derives the language from the config's
        # stem and refuses any config outside its own CONFIGS_DIR. Found end-to-end,
        # not in review, so it gets a test. No torch needed.
        import sys, types, pocket_engine
        from pathlib import Path
        cfgdir = tmp_path / "pkgconfigs"; cfgdir.mkdir()
        mod = types.ModuleType("pocket_tts.models.tts_model")
        mod.CONFIGS_DIR = cfgdir
        monkeypatch.setitem(sys.modules, "pocket_tts", types.ModuleType("pocket_tts"))
        monkeypatch.setitem(sys.modules, "pocket_tts.models", types.ModuleType("pocket_tts.models"))
        monkeypatch.setitem(sys.modules, "pocket_tts.models.tts_model", mod)

        class FakeModel:
            origin = Path("/somewhere/else/english-local.yaml")
        m = FakeModel()
        pocket_engine._restore_language_origin(m)
        # Both halves of pocket_tts's check: inside CONFIGS_DIR, and stem == language.
        assert m.origin.is_relative_to(cfgdir), "config must look package-local"
        assert m.origin.stem == "english", "stem is what selects the voice language"

    def test_local_config_swaps_only_the_weights_path(self, tmp_path, monkeypatch):
        # The config carries the model architecture, so we copy pocket_tts's own
        # YAML and change ONE line. If upstream renames the key we must return None
        # (fall back to catalog) rather than emit a config that silently drops
        # cloning or loads the wrong weights.
        import sys, types, pocket_engine
        cfgdir = tmp_path / "cfg"; cfgdir.mkdir()
        (cfgdir / "english.yaml").write_text(
            "weights_path: hf://kyutai/pocket-tts/x.safetensors@abc\n"
            "weights_path_without_voice_cloning: hf://kyutai/other/y.safetensors\n"
            "flow_lm:\n  dtype: float32\n")
        mod = types.ModuleType("pocket_tts.models.tts_model")
        mod.CONFIGS_DIR = cfgdir
        monkeypatch.setitem(sys.modules, "pocket_tts", types.ModuleType("pocket_tts"))
        monkeypatch.setitem(sys.modules, "pocket_tts.models", types.ModuleType("pocket_tts.models"))
        monkeypatch.setitem(sys.modules, "pocket_tts.models.tts_model", mod)
        monkeypatch.setattr(pocket_engine, "weights_dir", lambda: tmp_path / "out")

        out = pocket_engine._cloning_config()
        text = out.read_text()
        assert text.startswith(f"weights_path: {pocket_engine.cloning_weights_path()}\n")
        # Untouched: the catalog path, and the architecture below it.
        assert "weights_path_without_voice_cloning: hf://kyutai/other/y.safetensors" in text
        assert "flow_lm:\n  dtype: float32" in text
        assert "hf://kyutai/pocket-tts/x.safetensors" not in text

        # Upstream renamed the key -> refuse rather than guess.
        (cfgdir / "english.yaml").write_text("model_weights: hf://x/y.safetensors\n")
        assert pocket_engine._cloning_config() is None

    @pytest.mark.slow
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

    @pytest.mark.slow
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
