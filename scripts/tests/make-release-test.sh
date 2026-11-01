#!/usr/bin/env bash
# Self-test: scripts/make-release.sh builds the orphan `release` branch from
# main: the paths in release/MANIFEST from HEAD (tracked, committed files only)
# with release/overlay/ on top, in a worktree of its own; one commit per change,
# none when nothing changed; refusals for a dirty tree, a path HEAD lacks, a
# main-only path, a stale overlay source and a foreign worktree folder. A
# scratch repo; nothing is pushed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cw-make-release-XXXXXX")" && pwd)"
export TMPDIR="$TMP" HOME="$TMP/home"
mkdir -p "$HOME"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
fails=0
check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name: want [$want] got [$got]"
    fails=$((fails + 1))
  fi
}
has() { [[ "$2" == *"$1"* ]] && echo yes || echo "no: $2"; }

R="$TMP/main"
WT="$TMP/release-wt"
export CW_RELEASE_WORKTREE="$WT"
mkdir -p "$R/scripts/lib" "$R/skills/a" "$R/docs/features/x" "$R/release/overlay/docs/guides"
cp "$HERE/make-release.sh" "$R/scripts/"
printf 'echo run\n' >"$R/scripts/run.sh"
printf 'lib\n' >"$R/scripts/lib/x.py"
printf '# skill\n' >"$R/skills/a/SKILL.md"
printf '# plan\n' >"$R/docs/features/x/PLAN.md"
printf '# house readme\n' >"$R/README.md"
printf '# house claude\n' >"$R/CLAUDE.md"
printf '# Plan\n' >"$R/PLAN.md"
printf '*.local\n' >"$R/.gitignore"
printf '.gitignore\nscripts\nskills\n' >"$R/release/MANIFEST"
printf '# release readme\n' >"$R/release/overlay/README.md"
printf '# release claude\n' >"$R/release/overlay/CLAUDE.md"
printf '# guide\n' >"$R/release/overlay/docs/guides/start.md"
cd "$R"
git init -q -b main
printf 'tracked though it matches .gitignore\n' >scripts/kept.local
git add -A
git add -f scripts/kept.local
git commit -qm base
printf 'CLAUDE.md CLAUDE.md %s\n' "$(git rev-parse HEAD:CLAUDE.md)" >release/overlay/SOURCES
git add -A
git commit -qm sources
# An ignored file (a .env, a local key) is no dirt to git status, and a plain
# copy would ship it.
printf 'SECRET=1\n' >scripts/key.local
# An overlay draft ignored by a path-anchored rule: no dirt, and only a copy
# (not the archive) would ship it.
printf '/release/overlay/draft.md\n' >>.git/info/exclude
printf 'draft\n' >release/overlay/draft.md
run() { rc=0; out="$(bash "$R/scripts/make-release.sh" "$@" 2>&1)" || rc=$?; }
files() { git -C "$WT" ls-files | LC_ALL=C sort | paste -sd' ' -; }
# refs/heads/release, not release: release/ is also a folder.
commits() { git -C "$R" rev-list --count refs/heads/release -- 2>/dev/null || echo 0; }

echo "== 1. the first build"
head0="$(git rev-parse HEAD)"
run
check "built and committed" "0 yes" "$rc $(has 'committed' "$out")"
check "the manifest's paths and the overlay, nothing else" \
  ".gitignore CLAUDE.md README.md docs/guides/start.md scripts/kept.local scripts/lib/x.py scripts/make-release.sh scripts/run.sh skills/a/SKILL.md" "$(files)"
check "an orphan: one commit, no history shared with main" "1 no" \
  "$(commits) $(git merge-base main release >/dev/null 2>&1 && echo yes || echo no)"
check "the code byte-identical to main's; the overlay README in place" "yes # release readme" \
  "$(cmp -s scripts/run.sh "$WT/scripts/run.sh" && echo yes || echo no) $(cat "$WT/README.md")"
check "main untouched: its branch, HEAD and tree" "main $head0 yes" \
  "$(git rev-parse --abbrev-ref HEAD) $(git rev-parse HEAD) $([[ -f docs/features/x/PLAN.md && -f README.md ]] && echo yes || echo no)"

echo "== 2. again, nothing changed"
run
check "already up to date, no new commit" "0 yes 1" "$rc $(has 'already up to date' "$out") $(commits)"

echo "== 3. main moves on"
first="$(git rev-parse refs/heads/release)"
printf 'echo run v2\n' >scripts/run.sh
git rm -q scripts/lib/x.py
git commit -qam "v2"
run
check "one new release commit, on the first" "0 2 $first" "$rc $(commits) $(git rev-parse refs/heads/release^)"
check "  ...the change in, the deleted file gone" "echo run v2 no" \
  "$(cat "$WT/scripts/run.sh") $([[ -e "$WT/scripts/lib/x.py" ]] && echo yes || echo no)"

echo "== 4. refusals"
printf 'dirt\n' >>scripts/run.sh
run
check "a dirty tree: refused" "1 yes 2" "$rc $(has 'not clean' "$out") $(commits)"
git checkout -q -- scripts/run.sh
printf 'nosuchdir\n' >>release/MANIFEST
git commit -qam "a manifest path HEAD lacks"
run
check "a manifest path HEAD does not have: refused" "1 yes 2" "$rc $(has 'which HEAD does not have' "$out") $(commits)"
git revert --no-edit HEAD >/dev/null
mkdir -p release/overlay/docs/features/x
printf 'leak\n' >release/overlay/docs/features/x/PLAN.md
git add -A
git commit -qm "an overlay shipping a main-only path"
run
check "a main-only path in the release: refused" "1 yes 2" "$rc $(has 'docs/features (main only)' "$out") $(commits)"
git revert --no-edit HEAD >/dev/null
printf '# house claude, changed\n' >CLAUDE.md
git commit -qam "a source changed"
run --dry-run
check "a stale overlay source: WARN on a dry run" "0 yes 2" "$rc $(has 'WARN CLAUDE.md was adapted from CLAUDE.md' "$out" | cut -c1-3) $(commits)"
run
check "  ...and refused for real, nothing committed" "1 yes 2" "$rc $(has 'update the stale overlay' "$out") $(commits)"
printf 'CLAUDE.md CLAUDE.md %s\n' "$(git rev-parse HEAD:CLAUDE.md)" >release/overlay/SOURCES
printf '# release readme v2\n' >release/overlay/README.md
git commit -qam "overlay synced"
run --dry-run
check "--dry-run: built, not committed" "0 yes 2 # release readme v2" "$rc $(has 'not committed' "$out") $(commits) $(cat "$WT/README.md")"
run
check "  ...then committed" "0 3" "$rc $(commits)"
# Other paths, so the real worktree stays registered (a prune drops a moved one).
mkdir -p "$TMP/plain"
rc=0; out="$(CW_RELEASE_WORKTREE="$TMP/plain" bash "$R/scripts/make-release.sh" 2>&1)" || rc=$?
check "a folder at the worktree path that is not one: refused" "1 yes" "$rc $(has 'is not a linked worktree of this repo' "$out")"
git clone -q -b release "$R" "$TMP/clone"
rc=0; out="$(CW_RELEASE_WORKTREE="$TMP/clone" bash "$R/scripts/make-release.sh" 2>&1)" || rc=$?
check "a separate clone on release at the worktree path: refused" "1 yes" "$rc $(has 'is not a linked worktree of this repo' "$out")"
rc=0; out="$(CW_RELEASE_WORKTREE="$WT/scripts" bash "$R/scripts/make-release.sh" 2>&1)" || rc=$?
check "a subfolder of the real worktree: refused" "1 yes" "$rc $(has 'is not a linked worktree of this repo' "$out")"
rc=0; out="$(CW_RELEASE_WORKTREE="$R" bash "$R/scripts/make-release.sh" 2>&1)" || rc=$?
check "the main checkout as the worktree: refused, main untouched" "1 yes yes" \
  "$rc $(has 'is not a linked worktree of this repo' "$out") $([[ -f "$R/scripts/key.local" && -f "$R/docs/features/x/PLAN.md" ]] && echo yes || echo no)"
rc=0; out="$(CW_RELEASE_WORKTREE="$WT/" bash "$R/scripts/make-release.sh" 2>&1)" || rc=$?
check "a trailing slash on the worktree path: the same worktree" "0 yes" "$rc $(has 'already up to date' "$out")"
rc=0; out="$(CW_RELEASE_WORKTREE=rel-wt bash "$R/scripts/make-release.sh" 2>&1)" || rc=$?
check "a relative worktree path: refused" "1 yes" "$rc $(has 'must be an absolute path' "$out")"
mkdir "$WT.lock"
run
check "another run holding the lock: refused, nothing committed" "1 yes 3" "$rc $(has 'another make-release is running' "$out") $(commits)"
rmdir "$WT.lock"
git mv release/overlay/CLAUDE.md release/overlay/AGENTS.md
git commit -qm "an overlay renamed under its SOURCES line"
run
check "a SOURCES line naming an overlay file that is gone: refused" "1 yes 3" "$rc $(has 'which release/overlay does not have' "$out") $(commits)"
git mv release/overlay/AGENTS.md release/overlay/CLAUDE.md
git commit -qm "renamed back"

echo "== 5. a leftover detached worktree (a run that died before its branch)"
L="$TMP/left"
mkdir -p "$L"
git -C "$L" init -q -b main
cp -R "$R/scripts" "$R/skills" "$R/release" "$R/.gitignore" "$R/CLAUDE.md" "$L/"
rm -f "$L/scripts/key.local" "$L/release/overlay/draft.md"
git -C "$L" add -A
git -C "$L" add -f scripts/kept.local
git -C "$L" commit -qm base
git -C "$L" worktree add -q --detach "$TMP/left-wt"
rc=0; out="$(cd "$L" && CW_RELEASE_WORKTREE="$TMP/left-wt" bash scripts/make-release.sh 2>&1)" || rc=$?
check "pristine and detached, no release branch: taken over, one release commit" "0 1" \
  "$rc $(git -C "$L" rev-list --count refs/heads/release -- 2>/dev/null || echo 0)"
# The release branch gone again (its worktree first), then a detached worktree
# holding someone's work at the path.
git -C "$L" worktree remove -f "$TMP/left-wt"
git -C "$L" branch -q -D release
git -C "$L" worktree add -q --detach "$TMP/left-wt2"
printf 'KEY=mine\n' >"$TMP/left-wt2/work.local" # ignored: the .env case
rc=0; out="$(cd "$L" && CW_RELEASE_WORKTREE="$TMP/left-wt2" bash scripts/make-release.sh 2>&1)" || rc=$?
check "detached with someone's ignored file in it: refused, the file kept" "1 yes KEY=mine" \
  "$rc $(has 'is not on the release branch' "$out") $(cat "$TMP/left-wt2/work.local")"
rm "$TMP/left-wt2/work.local"
git -C "$TMP/left-wt2" -c user.name=m -c user.email=m@l commit -q --allow-empty -m "a detached commit"
rc=0; out="$(cd "$L" && CW_RELEASE_WORKTREE="$TMP/left-wt2" bash scripts/make-release.sh 2>&1)" || rc=$?
check "detached on a commit no branch holds: refused" "1 yes" "$rc $(has 'is not on the release branch' "$out")"
# The checkout this runs in (L's copy of the script, run from inside it).
git -C "$L" worktree add -q --detach "$TMP/left-self"
rc=0; out="$(cd "$TMP/left-self" && CW_RELEASE_WORKTREE="$TMP/left-self" bash "$L/scripts/make-release.sh" 2>&1)" || rc=$?
check "the checkout this runs in: refused, its files kept" "1 yes yes" \
  "$rc $(has 'is not on the release branch' "$out") $([[ -f "$TMP/left-self/release/MANIFEST" ]] && echo yes || echo no)"

echo "== 6. a fresh clone of main builds on the published release"
F="$TMP/fresh"
git clone -q "$R" "$F"
git -C "$F" config user.name mock
git -C "$F" config user.email mock@localhost
printf 'echo run v3\n' >"$F/scripts/run.sh"
git -C "$F" commit -qam v3
# The trailing slash on a path not made yet: the lock must not land inside it.
rc=0; out="$(cd "$F" && CW_RELEASE_WORKTREE="$TMP/fresh-wt/" bash scripts/make-release.sh 2>&1)" || rc=$?
check "no local release, origin/release exists: a commit on top of it, not a new history" "0 $(git -C "$R" rev-parse refs/heads/release)" \
  "$rc $(git -C "$F" rev-parse refs/heads/release^ 2>/dev/null)"
# A pristine leftover in a fresh clone: the recovery continues the published history too.
F2="$TMP/fresh2"
git clone -q "$R" "$F2"
git -C "$F2" config user.name mock
git -C "$F2" config user.email mock@localhost
printf 'echo run v4\n' >"$F2/scripts/run.sh"
git -C "$F2" commit -qam v4
git -C "$F2" worktree add -q --detach "$TMP/fresh2-wt"
rc=0; out="$(cd "$F2" && CW_RELEASE_WORKTREE="$TMP/fresh2-wt" bash scripts/make-release.sh 2>&1)" || rc=$?
check "a pristine leftover in a fresh clone: recovered onto origin/release" "0 $(git -C "$R" rev-parse refs/heads/release)" \
  "$rc $(git -C "$F2" rev-parse refs/heads/release^ 2>/dev/null)"

echo
if [[ "$fails" -eq 0 ]]; then
  echo "make-release-test: all passed"
else
  echo "make-release-test: $fails failed"
  exit 1
fi
