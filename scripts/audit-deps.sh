#!/usr/bin/env bash
# The dependency gate, run before every merge: every committed lockfile checked
# against the OSV vulnerability database (npm, Python, Rust, Go), plus the OpenSSF
# malicious-package list. Under a second.
# Exit 0 clean, non-zero on a known vulnerability or on a scan that could not run.
# A finding is fixed first; one that cannot reach us goes in osv-scanner.toml with
# its reason and an expiry. A repo with no lockfile at all fails too: commit one
# (npm install writes it; uv lock for Python), because an unlocked project is
# invisible to the scan. A repo whose lockfile lists zero packages is clean:
# osv-scanner exits 128 "No package sources found" there, so that one outcome is
# accepted, but only when the scanner reported reading a lockfile ("Scanned <file>
# and found 0 packages"). No lockfile prints no such line, so it still fails.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v osv-scanner >/dev/null || { echo "osv-scanner not installed: brew install osv-scanner" >&2; exit 1; }
rc=0
out="$(osv-scanner scan source -r --config osv-scanner.toml . 2>&1)" || rc=$?
printf '%s\n' "$out"
if [ "$rc" -eq 128 ] && grep -q 'No package sources found' <<<"$out" \
  && grep -qE '^Scanned .* and found 0 packages' <<<"$out"; then
  echo "audit-deps: lockfile present with 0 packages, nothing to scan: clean"
  exit 0
fi
exit "$rc"
