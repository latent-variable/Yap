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

Edit either `.in` input file and push it to the
`security/pin-python-runtime` review branch. The
`Lock Python dependencies` workflow:

1. Runs on an isolated GitHub-hosted Apple Silicon macOS runner.
2. Downloads the exact CPython 3.12.16 build used by Yap and verifies its
   published SHA-256 before running the resolver.
3. Uses pinned pip-tools 7.6.2 and resolves binary wheels only from PyPI.
4. Installs the default lock and the optional Pocket lock in temporary runner
   directories to prove both environments are installable for this target.
5. Commits the generated lockfiles back to the review branch only after both
   environments pass.

Review every version change and run the repository's OSV security scan before
merging. A hash lock proves the downloaded artifact matches the committed
digest; it does **not** prove that the package itself is benign. Keep the
dependency list minimal and review new direct/transitive packages.
