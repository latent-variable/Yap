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
TAP_DIR="${PARLEY_TAP_DIR:-$ROOT/../homebrew-tap}"
CASK="$TAP_DIR/Casks/parley.rb"
TAG="v$VERSION"
DMG="$ROOT/dist/Parley-$VERSION.dmg"
say() { printf '\n\033[1m[release] %s\033[0m\n' "$1"; }

# ---- preflight ----
command -v gh >/dev/null || { echo "gh CLI required"; exit 1; }
[ -f "$CASK" ] || { echo "cask not found at $CASK (set PARLEY_TAP_DIR)"; exit 1; }
[ -d "$TAP_DIR/.git" ] || { echo "tap repo has no git at $TAP_DIR"; exit 1; }
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "release $TAG already exists — bump the version"; exit 1
fi
if [ -n "$NOTES_FILE" ] && [ ! -f "$NOTES_FILE" ]; then echo "no notes file: $NOTES_FILE"; exit 1; fi

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
  git -C "$ROOT" checkout -- "$PLIST"
  git -C "$TAP_DIR" checkout -- "$CASK"
  echo "would publish $TAG with $DMG and bump the cask. Looks good? re-run without --dry-run."
  exit 0
fi

# ---- publish ----
say "committing version bump"
git -C "$ROOT" add "$PLIST"
git -C "$ROOT" commit -qm "Release $TAG"
git -C "$ROOT" push -q origin HEAD

say "creating GitHub release $TAG"
gh release create "$TAG" "$DMG" --title "Parley $VERSION" "${NOTES_ARGS[@]}"

say "bumping Homebrew cask"
git -C "$TAP_DIR" commit -aqm "Parley $VERSION"
git -C "$TAP_DIR" push -q origin HEAD

say "done — $TAG published, cask points at it."
gh release view "$TAG" --json url -q .url
