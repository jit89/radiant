#!/usr/bin/env bash
# make-release.sh — build the `release` branch from main (run in the main
# checkout, on a clean tree).
#
#   scripts/make-release.sh [--dry-run]
#
# The release branch is the installable workflow without its design history:
# the paths in release/MANIFEST, taken from HEAD with `git archive` (tracked,
# committed files only), with release/overlay/ laid on top (the user-facing
# README.md, CLAUDE.md, LICENSE and docs/guides/). It has its own history (an
# orphan branch): each run that changes something is one commit
# "release: from main <sha>". The code on it is byte-identical to main's.
#
# The branch is built in a worktree of its own
# (~/.cache/claude-coding-workflow/release-worktree, or CW_RELEASE_WORKTREE),
# never in this checkout. Nothing is pushed: `git push origin release` is the
# person's step.
#
# release/overlay/SOURCES pairs each overlay file with the main file it was
# adapted from and that file's blob at the last sync; a main file that has
# changed since is reported (WARN), so the overlay is brought up to date first.
# --dry-run builds and reports, then leaves the worktree uncommitted.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
WT="${CW_RELEASE_WORKTREE:-$HOME/.cache/claude-coding-workflow/release-worktree}"
BRANCH=release
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1
[[ $# -le 1 && ( $# -eq 0 || "$DRY" -eq 1 ) ]] || { echo "usage: make-release.sh [--dry-run]" >&2; exit 2; }

die() { echo "make-release: $*" >&2; exit 1; }
WT="${WT%/}"
[[ "$WT" == /* ]] || die "CW_RELEASE_WORKTREE must be an absolute path"
[[ -f release/MANIFEST && -d release/overlay ]] || die "run it in the main checkout (release/MANIFEST, release/overlay)"
[[ -z "$(git status --porcelain)" ]] || die "the tree is not clean: commit first (the release is built from HEAD)"
[[ "$(git rev-parse --abbrev-ref HEAD)" != "$BRANCH" ]] || die "run it from main, not from the release branch"
git cat-file -e HEAD:release/overlay 2>/dev/null || die "release/overlay is not committed"

# One run at a time: two would empty and fill the same worktree.
LOCK="$WT.lock"
mkdir -p "$(dirname "$WT")"
mkdir "$LOCK" 2>/dev/null || die "another make-release is running (or one died: rmdir \"$LOCK\")"
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

paths=()
while IFS= read -r p; do paths+=("$p"); done < <(grep -vE '^[[:space:]]*(#|$)' release/MANIFEST)
((${#paths[@]})) || die "release/MANIFEST lists nothing"
for p in "${paths[@]}"; do
  git cat-file -e "HEAD:$p" 2>/dev/null || die "release/MANIFEST names $p, which HEAD does not have"
done

# Stale overlay sources: a main file changed since its overlay was synced; a
# line naming an overlay file that no longer exists is refused (it would watch
# nothing).
stale=0
if git cat-file -e HEAD:release/overlay/SOURCES 2>/dev/null; then
  while read -r overlay src blob; do
    [[ -z "$overlay" || "$overlay" == \#* ]] && continue
    git cat-file -e "HEAD:release/overlay/$overlay" 2>/dev/null ||
      die "release/overlay/SOURCES names $overlay, which release/overlay does not have"
    now="$(git rev-parse -q --verify "HEAD:$src" 2>/dev/null || echo missing)"
    if [[ "$now" != "$blob" ]]; then
      echo "make-release: WARN $overlay was adapted from $src, which changed since (blob $blob -> $now): update the overlay, then its SOURCES line"
      stale=1
    fi
  done < <(git show HEAD:release/overlay/SOURCES)
fi

head_sha="$(git rev-parse --short HEAD)"
common="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
# The worktree: a linked worktree of this repo (never the main checkout, whose
# git dir is the common dir), at its top, on the release branch.
git worktree prune
if [[ -e "$WT" ]]; then
  top="$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)"
  wt_common="$(cd "$WT" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P || true)"
  wt_gitdir="$(cd "$WT" 2>/dev/null && cd "$(git rev-parse --git-dir 2>/dev/null)" 2>/dev/null && pwd -P || true)"
  [[ -n "$top" && "$(cd "$top" && pwd -P)" == "$(cd "$WT" && pwd -P)" && "$wt_common" == "$common" && "$wt_gitdir" != "$common" ]] ||
    die "$WT exists and is not a linked worktree of this repo: move it away (or set CW_RELEASE_WORKTREE)"
else
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git worktree add -q "$WT" "$BRANCH"
  elif git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
    # A fresh clone of main: build on the published history, never beside it.
    git worktree add -q -b "$BRANCH" "$WT" "origin/$BRANCH"
  else
    git worktree add -q --detach "$WT"
    git -C "$WT" checkout -q --orphan "$BRANCH"
  fi
fi
# symbolic-ref, not rev-parse: a fresh orphan branch has no commit yet.
if [[ "$(git -C "$WT" symbolic-ref --short HEAD 2>/dev/null)" != "$BRANCH" ]]; then
  # A run that died between the worktree and its orphan branch left it
  # detached, pristine and on a commit a branch holds; anything else there
  # (work, ignored files, detached commits, the checkout this runs in) is
  # someone's.
  if ! git show-ref --verify --quiet "refs/heads/$BRANCH" && ! git -C "$WT" symbolic-ref -q HEAD >/dev/null &&
    [[ -z "$(git -C "$WT" status --porcelain --ignored)" ]] &&
    [[ "$(cd "$WT" && pwd -P)" != "$(pwd -P)" ]] &&
    [[ -n "$(git for-each-ref --count=1 --contains "$(git -C "$WT" rev-parse HEAD)" refs/heads refs/remotes)" ]]; then
    if git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
      git -C "$WT" checkout -q -b "$BRANCH" "origin/$BRANCH"
    else
      git -C "$WT" checkout -q --orphan "$BRANCH"
    fi
  else
    die "$WT is not on the $BRANCH branch: inspect it; if nothing there is yours, git worktree remove -f \"$WT\" and rerun (or set CW_RELEASE_WORKTREE)"
  fi
fi

# Empty the worktree (its .git file aside; a fresh orphan's index still holds
# the checkout's files), then lay the release out: the manifest's paths and the
# overlay, both from HEAD (tracked, committed files only; never the working tree).
git -C "$WT" rm -rq --cached . >/dev/null 2>&1 || true
find "$WT" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
git archive --format=tar HEAD -- "${paths[@]}" | tar -x -C "$WT"
git archive --format=tar HEAD:release/overlay | tar -x -C "$WT"
rm -f "$WT/SOURCES"

# Only what the manifest and the overlay name: an allowlist of top-level
# entries, and docs/ holding guides/ alone.
tops=""
for p in "${paths[@]}"; do tops="$tops ${p%%/*}"; done
allowed=" .git $tops $(git ls-tree --name-only HEAD:release/overlay | grep -vx SOURCES | tr '\n' ' ') "
for e in "$WT"/.[!.]* "$WT"/*; do
  [[ -e "$e" ]] || continue
  b="$(basename "$e")"
  [[ "$allowed" == *" $b "* ]] || die "the release would ship $b, which neither release/MANIFEST nor release/overlay names"
done
if [[ -d "$WT/docs" ]]; then
  for e in "$WT"/docs/.[!.]* "$WT"/docs/*; do
    [[ -e "$e" ]] || continue
    [[ "$(basename "$e")" == guides ]] || die "the release would ship docs/$(basename "$e") (main only): only docs/guides ships"
  done
fi

# -f: the shipped .gitignore must not drop a tracked file from the release.
git -C "$WT" add -A -f
# A stale overlay is refused even when nothing else changed: the release's
# docs would describe a main that has moved on.
[[ "$stale" -eq 0 || "$DRY" -eq 1 ]] || die "not committed: update the stale overlay files first (WARN above)"
if git -C "$WT" rev-parse -q --verify HEAD >/dev/null && git -C "$WT" diff --cached --quiet; then
  echo "make-release: $BRANCH is already up to date with main $head_sha"
  exit 0
fi
echo "make-release: $BRANCH built from main $head_sha in $WT ($(git -C "$WT" diff --cached --name-only | wc -l | tr -d ' ') path(s) changed)"
if [[ "$DRY" -eq 1 ]]; then
  echo "make-release: --dry-run: not committed (inspect \"$WT\"; the next run rebuilds it from scratch)"
  exit 0
fi
git -C "$WT" commit -q -m "release: from main $head_sha"
echo "make-release: committed $(git -C "$WT" rev-parse --short HEAD) on $BRANCH; push it with: git push origin $BRANCH"
