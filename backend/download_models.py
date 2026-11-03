"""Download the pinned Kokoro ONNX model + voices into Yap's models dir.

Usage: python download_models.py [--models-dir DIR]
Prints one JSON line per progress tick so the app can parse it.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
import tempfile
import urllib.request
from pathlib import Path

BASE = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
FILES = {
    "kokoro-v1.0.onnx": (
        f"{BASE}/kokoro-v1.0.onnx",
        "7d5df8ecf7d4b1878015a32686053fd0eebe2bc377234608764cc0ef3636a6c5",
    ),
    "voices-v1.0.bin": (
        f"{BASE}/voices-v1.0.bin",
        "bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d",
    ),
}


def emit(**kw):
    print(json.dumps(kw), flush=True)


def sha256_file(path: Path) -> str:
    # O_NOFOLLOW prevents an existing model symlink from redirecting the read.
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError(f"{path.name} is not a regular file")
        digest = hashlib.sha256()
        with os.fdopen(fd, "rb", closefd=False) as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                digest.update(chunk)
        return digest.hexdigest()
    finally:
        os.close(fd)


def download(url: str, dest: Path, expected_sha256: str) -> None:
    # mkstemp uses exclusive creation and a private mode; never open a
    # predictable .part path that another local process could pre-create as
    # a symlink to an unrelated file.
    fd, tmp_name = tempfile.mkstemp(prefix=f".{dest.name}.", suffix=".part", dir=dest.parent)
    tmp = Path(tmp_name)
    digest = hashlib.sha256()
    try:
        with os.fdopen(fd, "wb") as f:
            with urllib.request.urlopen(url, timeout=30) as response:
                total = int(response.headers.get("Content-Length", 0))
                done = 0
                while True:
                    buf = response.read(1 << 20)
                    if not buf:
                        break
                    f.write(buf)
                    digest.update(buf)
                    done += len(buf)
                    emit(file=dest.name, done=done, total=total)
        actual = digest.hexdigest()
        if actual != expected_sha256:
            raise ValueError(f"SHA-256 mismatch for {dest.name}: {actual}")
        # os.replace replaces a destination symlink itself; it never follows it.
        os.replace(tmp, dest)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def main() -> int:
    p = argparse.ArgumentParser()
    default = os.environ.get("YAP_MODELS_DIR") or os.environ.get("PARLEY_MODELS_DIR") or str(
        Path.home() / "Library/Application Support/Yap/models")
    p.add_argument("--models-dir", default=default)
    args = p.parse_args()
    mdir = Path(args.models_dir).expanduser()
    mdir.mkdir(parents=True, exist_ok=True)

    for name, (url, expected_sha256) in FILES.items():
        dest = mdir / name
        if dest.is_symlink():
            # Remove the link itself, never follow it into another location.
            dest.unlink()
            emit(file=name, discarded_invalid_existing=True)
        elif dest.exists():
            if not dest.is_file():
                emit(file=name, error="existing model path is not a regular file")
                return 1
            try:
                if sha256_file(dest) == expected_sha256:
                    emit(file=name, skipped=True, verified=True)
                    continue
            except OSError:
                # An unreadable or replaced file is not a verified model.
                pass
            # Never trust a partial, stale, or modified pre-existing model.
            dest.unlink()
            emit(file=name, discarded_invalid_existing=True)
        emit(file=name, started=True, url=url)
        try:
            download(url, dest, expected_sha256)
            emit(file=name, finished=True, verified=True)
        except Exception as e:  # noqa: BLE001
            emit(file=name, error=str(e))
            return 1
    emit(done=True, models_dir=str(mdir))
    return 0


if __name__ == "__main__":
    sys.exit(main())
