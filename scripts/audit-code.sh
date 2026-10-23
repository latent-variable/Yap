#!/usr/bin/env bash
# The code gate, run before every merge. Two checks, seconds each:
#   1. Semgrep: known-dangerous code patterns (injection, eval, open redirects,
#      unsafe JWT, XSS sinks) in the files this branch changes: committed, staged,
#      unstaged and untracked, against the merge base with the default branch.
#   2. gitleaks: secrets in the commits this branch adds over the default branch,
#      printed REDACTED. Secrets are gitleaks' job alone: Semgrep's secret rules
#      print the matching line, key and all, into the log.
# Exit 0 clean, non-zero on a finding or on a scan that could not run: a check we
# could not take is never a pass.
#
#   audit-code.sh            the gate: changed files only
#   audit-code.sh --full     Semgrep over every tracked file (the weekly sweep,
#                            ~/.agents/bin/security-sweep, runs this on main)
#   audit-code.sh --targets  print the files the gate would scan, scan nothing
#
# Only changed files, because a whole-tree scan took 90 s in our two largest repos
# and a slow gate is a skipped gate; what nobody touched is covered weekly. Semgrep's
# own --baseline-commit is not used: it ignores untracked files, so a new file
# passed the gate until it was committed. Files named on the command line bypass
# .semgrepignore, so the list is filtered through it here.
#
# A finding is fixed first. One that cannot reach us is suppressed AT THE LINE with
# its reason: `// nosemgrep: <rule-id> -- <why>` or `// gitleaks:allow -- <why>`.
# Paths that are not our code (vendored, captured third-party pages, fixtures)
# go in .semgrepignore. Deeper scans (full git history, more rulesets) are run on
# purpose, not here: the security-audit skill.
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-gate}"
case "$mode" in gate|--full|--targets) ;; *) echo "usage: $0 [--full|--targets]" >&2; exit 2 ;; esac

# symbolic-ref, not `rev-parse --abbrev-ref origin/HEAD`: without origin/HEAD (every
# Actions checkout) rev-parse still prints "origin/HEAD" before failing, so the
# fallback added a second line and no merge base was found (findbusiness-mcp#57).
base_ref="$(git symbolic-ref -q --short refs/remotes/origin/HEAD || echo origin/main)"
base="$(git merge-base HEAD "$base_ref" 2>/dev/null || true)"
if [[ -z "$base" ]]; then
  echo "no merge base with $base_ref (shallow clone?): fetch it, e.g. fetch-depth: 0" >&2
  exit 1
fi

targets=()
if [[ "$mode" != "--full" ]]; then
  # Changed against the merge base (committed, staged, unstaged; deletions dropped),
  # plus untracked files git does not ignore, minus what .semgrepignore names.
  # Every step is checked: a selector that fails quietly hands Semgrep an empty
  # list, and an empty list passes. So any doubt about the list fails the gate.
  fail() { echo "code gate: $1; a check we could not take is never a pass" >&2; exit 1; }
  q=(-c core.quotePath=false)
  changed="$(git "${q[@]}" diff --name-only --diff-filter=d "$base" --)" || fail "could not list changed files"
  untracked="$(git "${q[@]}" ls-files --others --exclude-standard)" || fail "could not list untracked files"
  candidates="$(printf '%s\n%s\n' "$changed" "$untracked" | sed '/^$/d' | LC_ALL=C sort -u)" || fail "could not merge the file lists"
  # A branch that edits or deletes .semgrepignore may bring files nobody changed
  # into scope. (candidates drops deletions, so ask git about the file itself.)
  ignore_changed="$(git diff --name-only "$base" -- .semgrepignore)" || fail "could not diff .semgrepignore"
  if [[ -n "$ignore_changed" && "$mode" == gate ]]; then
    echo "▶ .semgrepignore changed on this branch: scanning every tracked file"
    mode=--full
  fi
  if [[ "$mode" == gate || "$mode" == --targets ]] && [[ -n "$candidates" ]]; then
    [[ "$candidates" == *'"'* ]] && fail "a changed path has characters git quotes; run with --full"
    # check-ignore -v -n prints every path, prefixed by the ignore file whose pattern
    # matched it (nothing when none did). Exit 1 means none matched, which is fine.
    semgrepignore="$PWD/.semgrepignore"
    verdicts="$(git "${q[@]}" -c core.excludesFile="$semgrepignore" check-ignore --no-index -v -n --stdin <<<"$candidates")" \
      || [[ $? -eq 1 ]] || fail "could not apply .semgrepignore"
    [[ "$(wc -l <<<"$verdicts")" -eq "$(wc -l <<<"$candidates")" ]] || fail "the ignore filter lost paths"
    while IFS= read -r line; do
      [[ "$line" == "$semgrepignore:"* ]] && continue
      f="${line#*$'\t'}"
      # ./ so a file named like an option (-x.js) is read as a path.
      # A symlink is skipped: semgrep rejects one as a target and exits non-zero
      # with no output, and the file it points at is scanned on its own.
      [[ -f "$f" && ! -L "$f" ]] && targets+=("./$f")
    done <<<"$verdicts"
  fi
fi

if [[ "$mode" == "--targets" ]]; then
  for f in ${targets[@]+"${targets[@]}"}; do printf '%s\n' "$f"; done
  exit 0
fi

for t in semgrep gitleaks; do
  command -v "$t" >/dev/null || { echo "$t not installed: brew install $t" >&2; exit 1; }
done

status=0
rules=(--config p/javascript --config p/typescript --config p/nodejs --config p/react
       --config p/expressjs --config p/jwt --config p/python)
if [[ "$mode" == "--full" ]]; then
  echo "▶ semgrep (every tracked file)"
  semgrep scan --metrics=off --error --quiet "${rules[@]}" . || status=1
elif (( ${#targets[@]} )); then
  echo "▶ semgrep (${#targets[@]} changed files)"
  semgrep scan --metrics=off --error --quiet "${rules[@]}" "${targets[@]}" || status=1
else
  echo "▶ semgrep: no changed files against $base_ref"
fi

echo "▶ gitleaks (commits on this branch)"
gitleaks git . --no-banner --redact --verbose --log-level warn --log-opts="$base..HEAD" || status=1
exit $status
