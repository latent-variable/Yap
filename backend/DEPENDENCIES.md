# Python runtime dependencies

Yap ships two Python dependency environments:

- `requirements.txt` describes the default Kokoro sidecar.
- `requirements-pocket.txt` describes the optional Pocket environment. It also
  includes the Kokoro and ONNX packages needed when both engines share one
  process.

The corresponding `requirements.txt` and `requirements-pocket.txt` files
are generated lockfiles. **Do not edit them by hand.** They pin every resolved
package version and include SHA-256 hashes for the allowed distributions.

## Runtime installation policy

Both install paths must use:

- `--require-hashes`: reject any distribution whose bytes do not match the
  committed lockfile.
- `--only-binary=:all:`: do not execute unreviewed source-distribution build
  scripts on a user's Mac.
- an isolated pip configuration and no pip cache.

The default bundled environment is built from `requirements.txt`. Pocket is
installed on demand from `requirements-pocket.txt`; it is not resolved from
live version ranges at install time.

## Regenerating locks

Push changes to either `.in` input file on the
`security/pin-python-runtime` review branch. The
`Lock Python dependencies` workflow:

1. Runs on an isolated GitHub-hosted Apple Silicon macOS runner.
2. Downloads the exact CPython 3.12.16 build used by Yap and verifies its
   published SHA-256 before running the resolver.
3. Uses pinned pip-tools 7.6.2 and resolves wheels only from PyPI.
4. Installs the default lock and the optional Pocket lock in temporary runner
   directories to prove the locks are installable for this target.
5. Commits the generated lockfiles back to the review branch only after both
   environments pass.

Review every version change and run the repository's OSV security scan before
merging. A hash lock proves the downloaded artifact matches the reviewed
digest; it does **not** prove that the package itself is benign. Keep the
dependency list minimal and review new direct/transitive packages.
