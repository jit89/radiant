#!/usr/bin/env bash
# Self-test: the parallel walker (docs/features/parallel-walker/PLAN.md).
# Launchers are stubs; no model is called.
# Amendment 4 and the first of Amendment 5: an early
# join, signals, a moved scratch HEAD, invalid UTF-8, link files, stale admin
# folders, a shared file, a tampered integrate tree.
# The trust checks are split in four files (parallel-walk-trust*-test.sh), so
# run-all runs them side by side; each scenario starts from a fresh repo.
set -euo pipefail
PW_NAME=pwtrust3
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/parallel-walk-lib.sh"

echo "7. trust checks, part 3: Amendments 4 and 5"
# --- Amendment 4 ---------------------------------------------------------------
# A join that ends early still records every other outcome: a bounce is not
# turned into a recut and a re-implementation.
pwalk_repo
printf 'echo dirt >"$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/dirt.txt"; echo $gid >$letter.txt; git add $letter.txt; git commit -qm "feat($gid)"\n' >"$CALLS/action-g1-a"
echo BLOCKED >"$CALLS/verdict-g2-b"
prun --jobs 3
check "join ends early: g1-a integration-dirty" integration-dirty "$(reason_in g1-a)"
check "join ends early: g2-b still bounced" bounced "$(status_of g2-b)"
rm -f dirt.txt

# A signal in the join: a goal that already exited with a passed review is
# kept (its result copied, listed finished-not-integrated) and integrated by the
# rerun without dispatch.
pwalk_repo
echo 30 >"$CALLS/sleep-g2-b"
touch "$TMP/started"
sleep 1
"$HOUSE/scripts/run-goals.sh" --jobs 3 >"$TMP/pout" 2>&1 &
wpid=$!
for _ in $(seq 600); do
  [[ -z "$(wave_result_after "$TMP/started" g1-a)" ]] || break
  sleep 0.25
done
sleep 2
kill -TERM "$wpid"
wait "$wpid" && prc=0 || prc=$?
pstop="$(sed -n 's/^STOP_FILE: //p' <<<"$(tail -n1 "$TMP/pout")")"
check "signal in the join: exit 143" 143 "$prc"
check "signal in the join: the exited goal listed finished-not-integrated" finished-not-integrated "$(reason_in g1-a)"
check "signal in the join: its result kept" yes "$([[ -s "$(ls -d "$WTROOT"/*/.results/g1-a 2>/dev/null | head -n1)" ]] && echo yes || echo no)"
rm -f "$CALLS/sleep-g2-b"
before="$(grep -c '^g1-a$' "$CALLS/implement" || true)"
prun --jobs 3
check "signal in the join: the rerun completes" 0 "$prc"
[[ "$prc" -eq 0 ]] || tail -20 "$TMP/pout" | sed 's/^/    | /'
check "signal in the join: g1-a not dispatched again" "$before" "$(grep -c '^g1-a$' "$CALLS/implement" || true)"
# The rerun's merged proofs ran unsandboxed (this file's CW_PROOF_SANDBOX=off):
# its own overrides record is committed before g1-a's merge (FUTURE-WORK item 12).
check "signal in the join: the rerun journals its overrides before merging g1-a" yes \
  "$(git log --reverse --format=%s | awk '/^chore: orchestrator overrides$/ { n++; o = NR } /^chore\(g1-a\): orchestrator integrate$/ { m = NR } END { print (n == 2 && o < m) ? "yes" : "no: " n " " o " " m }')"

# Something moves the scratch tree's HEAD after the merge commit: refused, the
# walk branch never fast-forwards onto it.
pwalk_repo
sed -i '' 's|^journal: docs/journal/p.md$|journal: docs/journal/p.md\nworktree_setup: case "$PWD" in */.integrate/*) git commit -q --allow-empty -m evil ;; esac|' GOALS.md
git commit -qam "setup key"
prun --jobs 3
check "scratch HEAD moved: integration-tamper" integration-tamper "$(reason_in g1-a)"
check "scratch HEAD moved: nothing merged" 0 "$(git log --merges --oneline | wc -l | tr -d ' ')"
check "scratch HEAD moved: no evil commit on the walk branch" "" "$(git log --format=%s | grep '^evil$' || true)"

# Invalid UTF-8 merged from a goal record does not break later walks.
pwalk_repo
printf 'printf "\\n## 2026-10-15T00:00:00Z — IMPLEMENTER g1-a END\\nbytes \\377\\376 here\\n" >>docs/journal/p.md; echo $gid >$letter.txt; git add $letter.txt docs/journal/p.md; git commit -qm "feat($gid)"\n' >"$CALLS/action-g1-a"
printf 'printf "%%s\\n" "IMPLEMENTER_RESULT: error (exit 1)"; exit 1\n' >"$CALLS/action-g2-b"
LC_ALL=en_US.UTF-8 prun --jobs 3
check "invalid UTF-8: g1-a integrated" done "$(status_of g1-a)"
check "invalid UTF-8: its bytes reached the walk journal" yes \
  "$(git show HEAD:docs/journal/p.md | LC_ALL=C grep -q $'\377\376' && echo yes || echo no)"
rm -f "$CALLS/action-g1-a" "$CALLS/action-g2-b"
LC_ALL=en_US.UTF-8 prun --jobs 3
check "invalid UTF-8: the rerun reads the walk journal and completes" 0 "$prc"
[[ "$prc" -eq 0 ]] || tail -20 "$TMP/pout" | sed 's/^/    | /'

# The goal's own worktree link files: denied, and a rewrite stops the goal
# before the host runs git through it.
pwalk_repo
printf 'echo $gid >$letter.txt; git add $letter.txt; git commit -qm "feat($gid)"; mkdir -p fakegit; printf "gitdir: %%s/fakegit\\n" "$PWD" >.git\n' >"$CALLS/action-g1-a"
prun --jobs 3
check "gitfile rewritten: the goal stops git-metadata-tamper" git-metadata-tamper "$(reason_in g1-a)"
check "gitfile rewritten: nothing of g1-a merged" "" "$(git log --merges --format=%s | grep 'g1-a' || true)"
check "deny list: the goal's own .git" yes "$([[ "$(cat "$CALLS/args-g1-a")" == *"/g1-a/.git "* ]] && echo yes || echo no)"
check "deny list: its own commondir" yes "$([[ "$(cat "$CALLS/args-g1-a")" == *"/worktrees/g1-a/commondir "* ]] && echo yes || echo no)"

# A stale, locked admin folder makes git name the new one g2-b1; the deny list
# follows git's name, not a guess.
pwalk_repo
mkdir -p .git/worktrees/g2-b
printf 'gitdir: /nonexistent/g2-b/.git\n' >.git/worktrees/g2-b/gitdir
printf '../..\n' >.git/worktrees/g2-b/commondir
printf 'ref: refs/heads/stale\n' >.git/worktrees/g2-b/HEAD
: >.git/worktrees/g2-b/locked
prun --jobs 3
check "stale admin folder: g2-b's admin is g2-b1, denied to g1-a" yes \
  "$([[ "$(cat "$CALLS/args-g1-a")" == *"/.git/worktrees/g2-b1 "* ]] && echo yes || echo no)"
rm -rf .git/worktrees/g2-b

# Amendment 5: two goals edit different parts of one file; git merges them
# cleanly, and the integration must accept that three-way result.
pwalk_repo
noconflict
printf 'one\n\n\n\n\n\nmiddle\n\n\n\n\n\nthree\n' >shared.txt
git add shared.txt && git commit -qm "shared file"
printf 'sed -i "" "s/^one$/ONE/" shared.txt; echo $gid >$letter.txt; git add shared.txt $letter.txt; git commit -qm "feat($gid)"\n' >"$CALLS/action-g1-a"
printf 'sed -i "" "s/^three$/THREE/" shared.txt; echo $gid >$letter.txt; git add shared.txt $letter.txt; git commit -qm "feat($gid)"\n' >"$CALLS/action-g2-b"
prun --jobs 3
check "shared file, different hunks: the walk completes" 0 "$prc"
[[ "$prc" -eq 0 ]] || tail -20 "$TMP/pout" | sed 's/^/    | /'
check "shared file: both edits on the walk branch" "ONE THREE" "$(sed -n '1p;13p' shared.txt | paste -sd ' ' -)"

# A tampered integrate tree: a merge driver that writes other content only
# when it runs in a scratch worktree (the walker's merge), not in the main
# checkout (git merge-tree). Only the tree comparison can see the difference.
pwalk_repo
noconflict
printf 'one\n\n\n\n\n\nmiddle\n\n\n\n\n\nthree\n' >shared.txt
printf 'shared.txt merge=split\n' >.gitattributes
git add shared.txt .gitattributes && git commit -qm "shared file, merge driver"
printf 'sed -i "" "s/^one$/ONE/" shared.txt; echo $gid >$letter.txt; git add shared.txt $letter.txt; git commit -qm "feat($gid)"\n' >"$CALLS/action-g1-a"
printf 'sed -i "" "s/^three$/THREE/" shared.txt; echo $gid >$letter.txt; git add shared.txt $letter.txt; git commit -qm "feat($gid)"\n' >"$CALLS/action-g2-b"
GIT_CONFIG_COUNT=4 GIT_CONFIG_KEY_2=merge.split.driver \
  GIT_CONFIG_VALUE_2='case "$PWD" in */.integrate/*) printf "TAMPERED\n" >%A ;; *) git merge-file %A %O %B ;; esac' \
  GIT_CONFIG_KEY_3=merge.split.name GIT_CONFIG_VALUE_3=split prun --jobs 3
check "tampered integrate tree: refused" integration-tamper "$(reason_in g2-b)"
check "tampered integrate tree: the stop says the tree differs" yes \
  "$(grep -q "tree is not the merge" "$(stopfile_of g2-b)" && echo yes || echo no)"
check "tampered integrate tree: nothing tampered on the walk branch" "" "$(grep TAMPERED shared.txt || true)"

echo
if [[ "$fails" -eq 0 ]]; then
  echo "parallel-walk-trust3-test: all passed"
else
  echo "parallel-walk-trust3-test: $fails failed"
  exit 1
fi
