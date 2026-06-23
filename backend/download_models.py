"""Download Kokoro ONNX model + voices into the Parley models dir.

Usage: python download_models.py [--models-dir DIR]
Prints one JSON line per progress tick so the app can parse it.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request
from pathlib import Path

BASE = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
FILES = {
    "kokoro-v1.0.onnx": f"{BASE}/kokoro-v1.0.onnx",
    "voices-v1.0.bin": f"{BASE}/voices-v1.0.bin",
}


def emit(**kw):
    print(json.dumps(kw), flush=True)


def download(url: str, dest: Path) -> None:
    tmp = dest.with_suffix(dest.suffix + ".part")
    with urllib.request.urlopen(url) as r:
        total = int(r.headers.get("Content-Length", 0))
        done = 0
        with open(tmp, "wb") as f:
            while True:
                buf = r.read(1 << 20)
                if not buf:
                    break
                f.write(buf)
                done += len(buf)
                emit(file=dest.name, done=done, total=total)
    tmp.rename(dest)


def main() -> int:
    p = argparse.ArgumentParser()
    default = os.environ.get("PARLEY_MODELS_DIR") or str(
        Path.home() / "Library/Application Support/Parley/models")
    p.add_argument("--models-dir", default=default)
    args = p.parse_args()
    mdir = Path(args.models_dir).expanduser()
    mdir.mkdir(parents=True, exist_ok=True)

    for name, url in FILES.items():
        dest = mdir / name
        if dest.exists() and dest.stat().st_size > 0:
            emit(file=name, skipped=True)
            continue
        emit(file=name, started=True, url=url)
        try:
            download(url, dest)
            emit(file=name, finished=True)
        except Exception as e:  # noqa: BLE001
            emit(file=name, error=str(e))
            return 1
    emit(done=True, models_dir=str(mdir))
    return 0


if __name__ == "__main__":
    sys.exit(main())
