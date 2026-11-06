# Python dependencies

Both Python environments install from a hash lock, so every user gets the same
bytes and nothing is resolved on their Mac.

| Edit this | Generated lock (never by hand) | Installs into |
|---|---|---|
| `requirements.in` | `requirements.txt` | the bundled runtime, at build time (`scripts/bundle_python.sh`) |
| `requirements-pocket.in` | `requirements-pocket.txt` | `hd-packages/`, when a user installs Pocket (`/engines/pocket/install`). Carries Kokoro too: one process serves both engines. |

Every install uses `--require-hashes` (a file whose bytes differ from the lock is
refused) and `--only-binary=:all:` (no source package's build script runs).

The interpreter is pinned the same way: one python-build-standalone release and
its SHA-256, in `scripts/python_pin.sh`. Bumping it means checking the new digest
against that release's own `SHA256SUMS`.

## Changing a dependency

1. Edit the `.in` file.
2. `bash scripts/lock_python_deps.sh` (or `--upgrade` to move everything to the
   newest allowed). It resolves with the pinned interpreter against PyPI only.
3. Read the version diff of the `.txt`. A hash proves the bytes match PyPI; it
   does not prove a new package is benign, so look at anything new.
4. `bash scripts/audit-deps.sh`, then build.

CI runs `lock_python_deps.sh --check` and both hash-locked installs whenever a
lock, an input or the pin changes (`.github/workflows/python-locks.yml`).
