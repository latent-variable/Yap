# Python runtime dependencies

Yap ships two Python dependency environments. Each has a human-maintained input
and a generated, fully pinned lock:

| Input (edit this) | Generated lock (never edit by hand) | Purpose |
|---|---|---|
| `requirements.in` | `requirements.txt` | Default Kokoro sidecar |
| `requirements-pocket.in` | `requirements-pocket.txt` | Optional Pocket engine, plus Kokoro and ONNX for the shared process |

The generated `.txt` files pin every resolved package version and include
SHA-256 hashes for the allowed distributions. Their conventional
`requirements*.txt` names also make them visible to the repository's OSV
dependency scanner.

## Runtime installation policy

Both install paths must use:

- `--require-hashes`: reject any distribution whose bytes do not match the
  committed lockfile.
- `--only-binary=:all:`: do not execute unreviewed source-distribution build
  scripts on a user's Mac.
- isolated pip configuration and no pip cache.

The default bundled environment is built from `requirements.txt`. Pocket is
installed on demand from `requirements-pocket.txt`; neither resolves live
version ranges on a user's Mac.

## Regenerating locks

Use the exact CPython 3.12.16 Apple Silicon runtime pinned in
`scripts/bundle_python.sh`, with pip-tools 7.6.2. Set
`PIP_CONFIG_FILE=/dev/null` and `PIP_INDEX_URL=https://pypi.org/simple`, then
run:

```bash
pip-compile --upgrade --generate-hashes --allow-unsafe \
  --resolver=backtracking --strip-extras --no-emit-index-url \
  --pip-args="--only-binary=:all:" \
  --output-file=backend/requirements.txt backend/requirements.in

pip-compile --upgrade --generate-hashes --allow-unsafe \
  --resolver=backtracking --strip-extras --no-emit-index-url \
  --pip-args="--only-binary=:all:" \
  --output-file=backend/requirements-pocket.txt backend/requirements-pocket.in
```

Review the entire version diff, then install both environments with
`--require-hashes --only-binary=:all:` before committing. The
`Python dependency lock validation` GitHub Actions workflow repeats this
validation on an isolated Apple Silicon runner and checks that the committed
locks still match their inputs. It has read-only repository permissions; it
does not modify branches or commit generated files.

Review every version change and run the repository's OSV security scan before
merging. A hash lock proves the downloaded artifact matches the committed
digest; it does **not** prove that the package itself is benign. Keep the
dependency list minimal and review new direct/transitive packages.
