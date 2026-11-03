import hashlib
import io
import sys
from pathlib import Path

import pytest

import download_models


class FakeResponse:
    def __init__(self, payload: bytes):
        self._stream = io.BytesIO(payload)
        self.headers = {"Content-Length": str(len(payload))}

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return None

    def read(self, size: int = -1) -> bytes:
        return self._stream.read(size)


def test_download_verifies_hash_before_publishing_file(monkeypatch, tmp_path):
    payload = b"verified model bytes"
    expected = hashlib.sha256(payload).hexdigest()
    dest = tmp_path / "model.bin"
    monkeypatch.setattr(
        download_models.urllib.request, "urlopen",
        lambda *_args, **_kwargs: FakeResponse(payload),
    )

    download_models.download("https://example.invalid/model", dest, expected)

    assert dest.read_bytes() == payload
    assert not dest.with_suffix(".bin.part").exists()


def test_hash_mismatch_never_publishes_partial_model(monkeypatch, tmp_path):
    payload = b"tampered model bytes"
    dest = tmp_path / "model.bin"
    monkeypatch.setattr(
        download_models.urllib.request, "urlopen",
        lambda *_args, **_kwargs: FakeResponse(payload),
    )

    with pytest.raises(ValueError, match="SHA-256 mismatch"):
        download_models.download("https://example.invalid/model", dest, "0" * 64)

    assert not dest.exists()
    assert not dest.with_suffix(".bin.part").exists()


def test_main_replaces_invalid_existing_model_and_verifies_download(monkeypatch, tmp_path):
    payload = b"correct model bytes"
    expected = hashlib.sha256(payload).hexdigest()
    dest = tmp_path / "model.bin"
    dest.write_bytes(b"old or modified model")
    monkeypatch.setattr(download_models, "FILES", {"model.bin": ("https://example.invalid/model", expected)})
    monkeypatch.setattr(sys, "argv", ["download_models.py", "--models-dir", str(tmp_path)])
    monkeypatch.setattr(
        download_models.urllib.request, "urlopen",
        lambda *_args, **_kwargs: FakeResponse(payload),
    )

    assert download_models.main() == 0
    assert dest.read_bytes() == payload


def test_main_skips_only_an_existing_model_with_the_expected_hash(monkeypatch, tmp_path):
    payload = b"already verified model"
    expected = hashlib.sha256(payload).hexdigest()
    dest = tmp_path / "model.bin"
    dest.write_bytes(payload)
    monkeypatch.setattr(download_models, "FILES", {"model.bin": ("https://example.invalid/model", expected)})
    monkeypatch.setattr(sys, "argv", ["download_models.py", "--models-dir", str(tmp_path)])

    def unexpected_download(*_args, **_kwargs):
        pytest.fail("verified existing model should not be downloaded again")

    monkeypatch.setattr(download_models.urllib.request, "urlopen", unexpected_download)
    assert download_models.main() == 0
