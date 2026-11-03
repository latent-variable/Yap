from pathlib import Path
import sys

import server


def test_pocket_installer_uses_only_the_committed_hash_lock():
    target = Path("/tmp/yap-test-hd")
    command = server._pocket_install_command(target)

    assert command[:4] == [sys.executable, "-I", "-m", "pip"]
    assert "--isolated" in command
    assert "--require-hashes" in command
    assert "--only-binary=:all:" in command
    assert "--no-cache-dir" in command
    assert "--target" in command
    assert str(target) in command

    requirements_index = command.index("-r")
    lock_path = Path(command[requirements_index + 1])
    assert lock_path == Path(server.__file__).parent / "requirements-pocket.txt"
    assert lock_path.name == "requirements-pocket.txt"

    # No package names or live version ranges are passed on the command line.
    assert "kokoro-onnx" not in command
    assert "onnxruntime" not in command
    assert "pocket-tts" not in command
