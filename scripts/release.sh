#!/usr/bin/env bash
# Two-step release that never writes to `main` of either repo.
#
#   scripts/release.sh prepare 0.9.5 [--dry-run]
#       Branch `release/v0.9.5` in Yap AND in the Homebrew tap (both created with
#       ~/.agents/bin/worktree.sh), bump the version, build the DMG from the
#       committed tree, bump the cask (version + sha256), push both branches and
#       open one reviewable PR in each. Publishes nothing. Review and merge both
#       PRs through the normal review cycle.
#
#   scripts/release.sh publish 0.9.5 [--notes-file F | --notes TEXT] [--yes] [--dry-run]
#       The explicit, separate step. Runs only after the Yap version PR is merged.
#       Refuses unless main's head carries the version AND has the exact tree the
#       DMG was built from, and the tap PR's cask carries the DMG's checksum. Then
#       tags that verified main commit, uploads the DMG, and merges the tap PR.
#       Without --yes it prints the plan and stops.
#
# --dry-run on either subcommand validates and prints the plan, touching nothing.
# Both repos may be plain clones or managed worktrees (a worktree's .git is a FILE).
# The tap is expected at ../homebrew-tap (override with YAP_TAP_DIR).
# This script deletes nothing (no rm, no trash), so there is no path to validate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAP_DIR="${YAP_TAP_DIR:-$ROOT/../homebrew-tap}"
WORKTREE_SH="${WORKTREE_SH:-$HOME/.agents/bin/worktree.sh}"
PLIST_REL="app/Resources/Info.plist"
CASK_REL="Casks/yap.rb"

say() { printf '\n\033[1m[release] %s\033[0m\n' "$1"; }
die() { echo "release: $*" >&2; exit 1; }
usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1; }

[ $# -ge 2 ] || usage
CMD="$1"; VERSION="$2"; shift 2
case "$CMD" in prepare|publish) ;; *) usage;; esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid version: $VERSION"

NOTES_FILE=""; NOTES=""; DRY=0; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --notes-file) NOTES_FILE="${2:?}"; shift 2;;
    --notes)      NOTES="${2:?}"; shift 2;;
    --dry-run)    DRY=1; shift;;
    --yes)        YES=1; shift;;
    *) die "unknown arg: $1";;
  esac
done
if [ "$CMD" = prepare ] && { [ -n "$NOTES_FILE" ] || [ -n "$NOTES" ] || [ "$YES" = 1 ]; }; then
  die "--notes/--notes-file/--yes belong to 'publish'"
fi
if [ -n "$NOTES_FILE" ] && [ ! -f "$NOTES_FILE" ]; then die "no notes file: $NOTES_FILE"; fi

TAG="v$VERSION"
BRANCH="release/$TAG"

# ---- helpers ----
# A worktree's .git is a file, so ask git rather than testing for a directory.
require_worktree() {
  local dir="$1" label="$2"
  [ -d "$dir" ] || die "$label not found at $dir"
  [ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] \
    || die "$label at $dir is not a git work tree"
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || die "$label at $dir has no git dir"
}
slug() { (cd "$1" && gh repo view --json nameWithOwner -q .nameWithOwner); }
# Path of the worktree that has $BRANCH checked out in repo $1 (empty if none).
worktree_for_branch() {
  git -C "$1" worktree list --porcelain | awk -v ref="refs/heads/$BRANCH" '
    $1=="worktree" {p=substr($0,10)} $1=="branch" && $2==ref {print p; exit}'
}
# Create (or reuse) the release worktree via the managed script; echo its path.
ensure_worktree() {
  local repo="$1" path
  path="$(worktree_for_branch "$repo")"
  if [ -z "$path" ]; then
    (cd "$repo" && "$WORKTREE_SH" "$BRANCH") >&2 || die "worktree.sh failed in $repo"
    path="$(worktree_for_branch "$repo")"
  fi
  [ -n "$path" ] && [ -d "$path" ] || die "no worktree for $BRANCH in $repo"
  echo "$path"
}
plist_version_of() { # reads a plist on stdin, prints CFBundleShortVersionString
  awk '/<key>CFBundleShortVersionString<\/key>/ {f=1; next} f && /<string>/ {gsub(/.*<string>|<\/string>.*/,""); print; exit}'
}
stamp_get() { grep -E "^$2=" "$1" | head -1 | cut -d= -f2-; }

# ---- shared preflight ----
command -v gh >/dev/null || die "gh CLI required"
[ -x "$WORKTREE_SH" ] || die "worktree.sh not found at $WORKTREE_SH"
require_worktree "$ROOT" "Yap repo"
require_worktree "$TAP_DIR" "tap repo (set YAP_TAP_DIR)"
git -C "$TAP_DIR" ls-files --error-unmatch "$CASK_REL" >/dev/null 2>&1 || die "$CASK_REL not tracked in $TAP_DIR"
YAP_SLUG="$(slug "$ROOT")"; TAP_SLUG="$(slug "$TAP_DIR")"

# =====================================================================
if [ "$CMD" = prepare ]; then
  git -C "$ROOT" fetch -q origin; git -C "$TAP_DIR" fetch -q origin
  CUR="$(git -C "$ROOT" show "origin/HEAD:$PLIST_REL" | plist_version_of)"
  [ "$CUR" != "$VERSION" ] || die "origin/HEAD is already at $VERSION"
  if gh release view "$TAG" -R "$YAP_SLUG" >/dev/null 2>&1; then die "release $TAG already exists"; fi
  # A half-finished earlier prepare would be bumped and PR'd twice. Refuse; recover by hand.
  for r in "$ROOT" "$TAP_DIR"; do
    if git -C "$r" show-ref --verify --quiet "refs/heads/$BRANCH" \
       || git -C "$r" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
      die "branch $BRANCH already exists in $r: finish or remove the earlier prepare (worktree.sh --remove $BRANCH, delete the branch and any open PR) before rerunning"
    fi
  done
  say "plan: $YAP_SLUG $CUR -> $VERSION"
  echo "  Yap : branch $BRANCH (worktree.sh in $ROOT): bump Info.plist, build dist/Yap-$VERSION.dmg, open PR"
  echo "  tap : branch $BRANCH (worktree.sh in $TAP_DIR): cask version $VERSION + DMG sha256, open PR"
  echo "  nothing is tagged, released or merged by 'prepare'"
  if [ "$DRY" = 1 ]; then say "DRY RUN: nothing created."; exit 0; fi

  YAP_WT="$(ensure_worktree "$ROOT")"
  TAP_WT="$(ensure_worktree "$TAP_DIR")"
  PLIST="$YAP_WT/$PLIST_REL"; CASK="$TAP_WT/$CASK_REL"
  [ -f "$PLIST" ] && [ -f "$CASK" ] || die "plist or cask missing in the release worktrees"
  [ -z "$(git -C "$YAP_WT" status --porcelain)" ] || die "$YAP_WT is not clean"
  [ -z "$(git -C "$TAP_WT" status --porcelain)" ] || die "$TAP_WT is not clean"

  say "bumping version -> $VERSION"
  BUILDNO="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
  /usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set CFBundleVersion $((BUILDNO + 1))" "$PLIST"
  git -C "$YAP_WT" commit -qm "chore: prepare Yap $VERSION" -- "$PLIST_REL"
  COMMIT="$(git -C "$YAP_WT" rev-parse HEAD)"; TREE="$(git -C "$YAP_WT" rev-parse 'HEAD^{tree}')"

  say "building DMG from $COMMIT"
  bash "$YAP_WT/scripts/make_dmg.sh" "$VERSION" >/dev/null
  DMG="$YAP_WT/dist/Yap-$VERSION.dmg"
  [ -f "$DMG" ] || die "DMG not produced: $DMG"
  [ "$(git -C "$YAP_WT" rev-parse HEAD)" = "$COMMIT" ] || die "HEAD moved during the build"
  [ -z "$(git -C "$YAP_WT" status --porcelain)" ] || die "build dirtied the tracked tree"
  SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  say "DMG $(du -h "$DMG" | cut -f1)  sha256=$SHA"

  /usr/bin/sed -i '' -E "s/version \"[^\"]*\"/version \"$VERSION\"/" "$CASK"
  /usr/bin/sed -i '' -E "s/sha256 \"[^\"]*\"/sha256 \"$SHA\"/" "$CASK"
  grep -q "version \"$VERSION\"" "$CASK" && grep -q "sha256 \"$SHA\"" "$CASK" || die "cask edit did not apply"
  git -C "$TAP_WT" commit -qm "chore: Yap $VERSION" -- "$CASK_REL"

  git -C "$YAP_WT" push -q -u origin "$BRANCH"
  YAP_PR="$(cd "$YAP_WT" && gh pr create --base main --head "$BRANCH" --title "chore: prepare Yap $VERSION" \
    --body "## Summary
Version bump to $VERSION (CFBundleShortVersionString, CFBundleVersion).

DMG built from this commit's tree: \`$TREE\`, sha256 \`$SHA\`. Publish (tag, release, cask merge) is a separate step, \`scripts/release.sh publish $VERSION\`, run only after this merges.

## Test plan
- [ ] Info.plist diff is only the two version keys
- [ ] \`release.sh publish $VERSION --dry-run\` passes after merge")"
  git -C "$TAP_WT" push -q -u origin "$BRANCH"
  TAP_PR="$(cd "$TAP_WT" && gh pr create --base main --head "$BRANCH" --title "chore: Yap $VERSION" \
    --body "## Summary
Cask \`yap\` to $VERSION, sha256 \`$SHA\` (DMG from $YAP_SLUG $BRANCH, tree \`$TREE\`). Merge only after the Yap release $TAG is published, or brew installs 404.

## Test plan
- [ ] sha256 matches the DMG attached to the $TAG release")"

  STAMP="$YAP_WT/dist/release-$VERSION.stamp"
  { echo "version=$VERSION"; echo "commit=$COMMIT"; echo "tree=$TREE"; echo "dmg=$DMG"; echo "sha256=$SHA"
    echo "yap_slug=$YAP_SLUG"; echo "yap_pr=$YAP_PR"; echo "tap_slug=$TAP_SLUG"; echo "tap_pr=$TAP_PR"
    echo "tap_wt=$TAP_WT"; } > "$STAMP"
  say "prepared. Yap PR: $YAP_PR   tap PR: $TAP_PR"
  echo "stamp: $STAMP"
  echo "next: review-cycle both PRs, merge the Yap one, then: scripts/release.sh publish $VERSION"
  exit 0
fi

# =====================================================================
# publish
YAP_WT="$(worktree_for_branch "$ROOT")"
[ -n "$YAP_WT" ] || die "no worktree for $BRANCH: run 'prepare $VERSION' first (and keep its worktree)"
STAMP="$YAP_WT/dist/release-$VERSION.stamp"
[ -f "$STAMP" ] || die "no stamp at $STAMP: run 'prepare $VERSION' first"
DMG="$(stamp_get "$STAMP" dmg)"; SHA="$(stamp_get "$STAMP" sha256)"; TREE="$(stamp_get "$STAMP" tree)"
YAP_PR="$(stamp_get "$STAMP" yap_pr)"; TAP_PR="$(stamp_get "$STAMP" tap_pr)"
[ "$(stamp_get "$STAMP" version)" = "$VERSION" ] || die "stamp is for another version"
[ -f "$DMG" ] || die "DMG missing: $DMG"
[ "$(shasum -a 256 "$DMG" | awk '{print $1}')" = "$SHA" ] || die "DMG no longer matches its recorded sha256; rebuild with prepare"

git -C "$ROOT" fetch -q origin; git -C "$TAP_DIR" fetch -q origin
MAIN_SHA="$(git -C "$ROOT" rev-parse origin/main)"
MAIN_VER="$(git -C "$ROOT" show "origin/main:$PLIST_REL" | plist_version_of)"
[ "$MAIN_VER" = "$VERSION" ] || die "origin/main is at $MAIN_VER, not $VERSION: merge the reviewed version PR first"
MAIN_TREE="$(git -C "$ROOT" rev-parse 'origin/main^{tree}')"
[ "$MAIN_TREE" = "$TREE" ] || die "origin/main ($MAIN_SHA) is not the tree the DMG was built from (main moved since prepare, or the PR was altered); rerun prepare"
[ "$(gh pr view "$YAP_PR" -R "$(stamp_get "$STAMP" yap_slug)" --json state -q .state)" = MERGED ] || die "Yap PR $YAP_PR is not merged"
if gh release view "$TAG" -R "$(stamp_get "$STAMP" yap_slug)" >/dev/null 2>&1; then die "release $TAG already exists"; fi
TAP_SLUG="$(stamp_get "$STAMP" tap_slug)"
[ "$(gh pr view "$TAP_PR" -R "$TAP_SLUG" --json state -q .state)" = OPEN ] || die "tap PR $TAP_PR is not open"
TAP_HEAD="$(gh pr view "$TAP_PR" -R "$TAP_SLUG" --json headRefOid -q .headRefOid)"
CASK_TEXT="$(git -C "$TAP_DIR" show "$TAP_HEAD:$CASK_REL")" || die "cannot read cask at tap PR head $TAP_HEAD"
grep -q "version \"$VERSION\"" <<<"$CASK_TEXT" && grep -q "sha256 \"$SHA\"" <<<"$CASK_TEXT" \
  || die "tap PR $TAP_PR cask does not carry $VERSION / the DMG sha256"

if [ -n "$NOTES_FILE" ]; then NOTES_ARGS=(--notes-file "$NOTES_FILE")
elif [ -n "$NOTES" ]; then NOTES_ARGS=(--notes "$NOTES")
else NOTES_ARGS=(--generate-notes); fi

# gh pr create printed URLs; the pr tool takes a number.
TAP_PR_NUM="${TAP_PR##*/}"
[[ "$TAP_PR_NUM" =~ ^[0-9]+$ ]] || die "cannot read a PR number from $TAP_PR"
PR_TOOL="${PR_TOOL:-$HOME/.agents/bin/pr}"
[ -x "$PR_TOOL" ] || die "pr tool not found at $PR_TOOL"
# The tap PR must pass the merge gate. The tap is outside the fleet reviewer's
# coverage (config.exclude), so no review ever lands there: for that case `pr`
# takes --self-reviewed, which it refuses for a covered repo. Try the reviewed
# gate first, then the self-reviewed one; this script's own checks above (cask
# version and sha256 match the DMG built from main's tree) are the statement.
TAP_GATE=()
SELF_REVIEW="release.sh verified: the cask carries version $VERSION and sha256 $SHA, the checksum of the DMG built from Yap main's tree $TREE."
if (cd "$TAP_DIR" && "$PR_TOOL" merge "$TAP_PR_NUM" --repo "$TAP_SLUG" --dry-run) >/dev/null 2>&1; then
  TAP_GATE=()
elif (cd "$TAP_DIR" && "$PR_TOOL" merge "$TAP_PR_NUM" --repo "$TAP_SLUG" --dry-run --self-reviewed "$SELF_REVIEW") >/dev/null 2>&1; then
  TAP_GATE=(--self-reviewed "$SELF_REVIEW")
else
  die "tap PR $TAP_PR fails the merge gate (reviewed or self-reviewed): run '$PR_TOOL merge $TAP_PR_NUM --repo $TAP_SLUG --dry-run' to see why"
fi

say "publish plan (verified)"
echo "  tag     $TAG at $MAIN_SHA (origin/main, tree $MAIN_TREE)"
echo "  asset   $DMG  sha256=$SHA"
echo "  tap     merge PR $TAP_PR in $TAP_SLUG via pr merge (review gate passed; cask $VERSION, same sha256)"
if [ "$DRY" = 1 ]; then say "DRY RUN: nothing published."; exit 0; fi
[ "$YES" = 1 ] || { echo "re-run with --yes to publish (release is owner-gated)"; exit 0; }

say "creating GitHub release $TAG"
gh release create "$TAG" "$DMG" -R "$(stamp_get "$STAMP" yap_slug)" --target "$MAIN_SHA" \
  --title "Yap $VERSION" "${NOTES_ARGS[@]}"
say "merging tap PR $TAP_PR"
(cd "$TAP_DIR" && "$PR_TOOL" merge "$TAP_PR_NUM" --repo "$TAP_SLUG" ${TAP_GATE[@]+"${TAP_GATE[@]}"})
say "done: $TAG published at $MAIN_SHA, cask points at it."
gh release view "$TAG" -R "$(stamp_get "$STAMP" yap_slug)" --json url -q .url
