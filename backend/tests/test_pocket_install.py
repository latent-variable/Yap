"""The Pocket installer installs the committed hash lock and nothing else."""
from pathlib import Path

import server


def test_pocket_install_uses_only_the_hash_lock(tmp_path):
    cmd = server.pocket_install_command(tmp_path)
    lock = Path(server.__file__).parent / "requirements-pocket.txt"

    assert cmd[cmd.index("-r") + 1] == str(lock)
    assert lock.is_file(), "the lock the installer names must ship in backend/"
    assert {"--require-hashes", "--only-binary=:all:", "--isolated"} <= set(cmd)
    assert cmd[cmd.index("--target") + 1] == str(tmp_path)
    # No package named on the command line: that would resolve outside the lock.
    assert not [a for a in cmd if a.startswith(("pocket", "kokoro", "onnx", "torch"))]


def test_pocket_lock_carries_kokoro_and_every_entry_is_hashed():
    lock = (Path(server.__file__).parent / "requirements-pocket.txt").read_text()
    entries = [l for l in lock.replace("\\\n", " ").splitlines()
               if l.strip() and not l.lstrip().startswith(("#", "-"))]
    names = {e.split("==")[0].strip() for e in entries}
    assert {"pocket-tts", "kokoro-onnx", "onnxruntime", "torch"} <= names
    unpinned = [e for e in entries if "==" not in e or "--hash=sha256:" not in e]
    assert not unpinned, unpinned
