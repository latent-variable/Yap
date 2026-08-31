#!/usr/bin/env bash
# One-shot release: bump version, build the self-contained app + DMG, publish a
# GitHub release, and bump the Homebrew cask — so brew users never lag and the
# cask sha can't drift.
#
#   scripts/release.sh 0.2.1                      # auto-generated notes
#   scripts/release.sh 0.2.1 --notes-file NOTES.md
#   scripts/release.sh 0.2.1 --notes "Short text"
#   scripts/release.sh 0.2.1 --dry-run           # do everything except publish
#
# The tap repo is expected at ../homebrew-tap (override with PARLEY_TAP_DIR).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?usage: release.sh <version> [--notes-file FILE | --notes TEXT] [--dry-run]}"
shift
NOTES_FILE=""; NOTES=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --notes-file) NOTES_FILE="${2:?}"; shift 2;;
    --notes)      NOTES="${2:?}"; shift 2;;
    --dry-run)    DRY=1; shift;;
    *) echo "unknown arg: $1"; exit 1;;
  esac
done

PLIST="$ROOT/app/Resources/Info.plist"
TAP_DIR="${YAP_TAP_DIR:-${PARLEY_TAP_DIR:-$ROOT/../homebrew-tap}}"
CASK="$TAP_DIR/Casks/yap.rb"
TAG="v$VERSION"
DMG="$ROOT/dist/Yap-$VERSION.dmg"
say() { printf '\n\033[1m[release] %s\033[0m\n' "$1"; }

# ---- preflight ----
command -v gh >/dev/null || { echo "gh CLI required"; exit 1; }
[ -f "$CASK" ] || { echo "cask not found at $CASK (set PARLEY_TAP_DIR)"; exit 1; }
[ -d "$TAP_DIR/.git" ] || { echo "tap repo has no git at $TAP_DIR"; exit 1; }
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "release $TAG already exists — bump the version"; exit 1
fi
if [ -n "$NOTES_FILE" ] && [ ! -f "$NOTES_FILE" ]; then echo "no notes file: $NOTES_FILE"; exit 1; fi

# A real run commits both targets, so any edit already sitting in them would ride
# into a tagged, published release commit (and the cask push). Refuse instead.
# --dry-run is exempt: it restores the exact bytes it found (see the trap below).
# diff-index against HEAD, not `git diff`: `git diff` compares the worktree with
# the INDEX, so an edit that is already staged reads clean and then rides into the
# release commit anyway. Refresh first, or stale stat info reports a false dirty.
if [ "$DRY" = 0 ]; then
  git -C "$ROOT" update-index -q --refresh || true
  git -C "$TAP_DIR" update-index -q --refresh || true
  if ! git -C "$ROOT" diff-index --quiet HEAD -- "$PLIST"; then
    echo "uncommitted or staged changes in $PLIST — commit or stash them first"; exit 1
  fi
  if ! git -C "$TAP_DIR" diff-index --quiet HEAD -- "$CASK"; then
    echo "uncommitted or staged changes in $CASK — commit or stash them first"; exit 1
  fi
fi

# Snapshot both targets before editing them. --dry-run used to undo itself with
# `git checkout -- <file>`, which restores HEAD rather than what was there, so it
# silently destroyed any uncommitted edit the operator already had. Restore the
# bytes instead, from a trap so a mid-run failure or a Ctrl-C can't leave the
# files bumped either.
#
# Held base64-encoded in variables, not in temp files: command substitution eats
# trailing newlines (so a plain "$(cat …)" is not byte-exact), and a temp file is
# a thing that has to be cleaned up on every exit path, including the ones that
# skip the trap. Both files are a few KB.
PLIST_ORIG="$(base64 < "$PLIST")"
CASK_ORIG="$(base64 < "$CASK")"
# Restore anything this run edited but did not manage to COMMIT — on a dry run
# that is both files by definition, and on a real run it is whatever the failure
# got to before it died. Committed work is left alone: git owns it from then on.
PLIST_COMMITTED=0; CASK_COMMITTED=0
# Write beside the target, then rename over it. `> "$target"` truncates FIRST, so
# a signal landing between the truncate and the write leaves an empty file — this
# restore ran during a SIGPIPE and zeroed Info.plist, which is the very data loss
# the script is here to stop. rename(2) is atomic: either the old file is intact
# or the new one is complete, never a half of either. A kill inside that window
# leaves a <target>.release-restore holding the original bytes; that is left
# visible on purpose, since an untracked file next to a crashed release is a
# useful signal and a recovery copy, not litter to hide in .gitignore.
restore_one() {
  local encoded="$1" target="$2" tmp="$2.release-restore"
  printf '%s' "$encoded" | base64 -d > "$tmp" && mv -f "$tmp" "$target"
}
restore_targets() {
  if [ "$DRY" = 1 ] || [ "$PLIST_COMMITTED" = 0 ]; then restore_one "$PLIST_ORIG" "$PLIST"; fi
  if [ "$DRY" = 1 ] || [ "$CASK_COMMITTED" = 0 ]; then restore_one "$CASK_ORIG" "$CASK"; fi
}
trap restore_targets EXIT INT TERM

# ---- bump version ----
say "bumping version -> $VERSION"
BUILDNO="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $((BUILDNO + 1))" "$PLIST"

# ---- build DMG (builds app + embeds Python) ----
say "building DMG"
bash "$ROOT/scripts/make_dmg.sh" "$VERSION" >/dev/null
[ -f "$DMG" ] || { echo "DMG not produced: $DMG"; exit 1; }
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
say "DMG $(du -h "$DMG" | cut -f1)  sha256=$SHA"

# ---- notes args ----
if [ -n "$NOTES_FILE" ]; then NOTES_ARGS=(--notes-file "$NOTES_FILE")
elif [ -n "$NOTES" ]; then NOTES_ARGS=(--notes "$NOTES")
else NOTES_ARGS=(--generate-notes); fi

# ---- stage cask bump (don't push yet) ----
/usr/bin/sed -i '' -E "s/version \"[^\"]*\"/version \"$VERSION\"/" "$CASK"
/usr/bin/sed -i '' -E "s/sha256 \"[^\"]*\"/sha256 \"$SHA\"/" "$CASK"
say "cask updated: $(grep -E 'version|sha256' "$CASK" | tr -s ' ' | tr '\n' ' ')"

if [ "$DRY" = 1 ]; then
  say "DRY RUN — not committing or publishing. Reverting version bump + cask."
  echo "would publish $TAG with $DMG and bump the cask. Looks good? re-run without --dry-run."
  exit 0   # restore_targets runs on EXIT
fi

# ---- publish ----
say "committing version bump"
git -C "$ROOT" commit --only "$PLIST" -qm "Release $TAG"
PLIST_COMMITTED=1
git -C "$ROOT" push -q origin HEAD

say "creating GitHub release $TAG"
gh release create "$TAG" "$DMG" --title "Yap $VERSION" "${NOTES_ARGS[@]}"

say "bumping Homebrew cask"
git -C "$TAP_DIR" commit --only "$CASK" -qm "Yap $VERSION"
CASK_COMMITTED=1
git -C "$TAP_DIR" push -q origin HEAD

say "done — $TAG published, cask points at it."
gh release view "$TAG" --json url -q .url
