#!/usr/bin/env bash
# Self-test: the parallel walker (docs/features/parallel-walker/PLAN.md).
# Launchers are stubs; no model is called. Sections 6-7: worktree-mode gates,
# the trust checks of Amendments 2 and 3, and the rest of PLAN step 11. Split
# from parallel-walk-test.sh so run-all runs both side by side.
set -euo pipefail
PW_NAME=pwtrust
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/parallel-walk-lib.sh"

# --- 6. run-goal.sh --worktree gates (PLAN step 6, Amendment 3 A) -------------
echo "6. worktree mode gates"
pwalk_repo
base="$(git rev-parse HEAD)"
git worktree add -q -b cw/g1-a "$TMP/wt-g1" HEAD
: >"$TMP/deny"
rg_wt() {
  ( cd "$TMP/wt-g1" && CW_PIN_ADMIN="$(git rev-parse --absolute-git-dir)" CW_PIN_COMMON="$(cd "$TMP/prepo/.git" && pwd -P)" \
    "$HOUSE/scripts/run-goal.sh" --worktree "$TMP/prepo" "$@" g1-a ) >"$TMP/gout" 2>&1 && grc=0 || grc=$?
}
CW_DENY_WRITE_FILE="$TMP/deny" rg_wt --base "$base" --result "$TMP/res"
check "worktree mode: a goal not in_progress in the main GOALS.md is refused" 1 "$grc"
check "worktree mode: refusal says the walker sets in_progress" yes \
  "$(grep -q 'the walker sets in_progress' "$TMP/gout" && echo yes || echo no)"
check "worktree mode: no status written" ready "$(status_of g1-a)"
IMPLEMENTER=codex CW_DENY_WRITE_FILE="$TMP/deny" rg_wt --base "$base" --result "$TMP/res"
check "worktree mode: the codex launcher is refused" yes "$(grep -q 'cannot run worktree mode' "$TMP/gout" && echo yes || echo no)"
rg_wt --base "$base" --result "$TMP/res"
check "worktree mode: no deny list, refused" yes "$(grep -q 'needs CW_DENY_WRITE_FILE' "$TMP/gout" && echo yes || echo no)"
CW_DENY_WRITE_FILE="$TMP/deny" rg_wt --result "$TMP/res"
check "worktree mode: --base and --result are required together" 2 "$grc"
# A fresh start needs HEAD == cw/<goal> == the wave base.
"$GOALS_PY" GOALS.md set g1-a in_progress >/dev/null
git commit -qm "g1-a in_progress" -- GOALS.md
( cd "$TMP/wt-g1" && git commit -q --allow-empty -m "not the base" )
CW_DENY_WRITE_FILE="$TMP/deny" rg_wt --base "$(git rev-parse HEAD)" --result "$TMP/res"
check "worktree mode: a branch not at the wave base is refused" yes \
  "$(grep -q 'is not at the wave base' "$TMP/gout" && echo yes || echo no)"
( cd "$TMP/wt-g1" && CW_DENY_WRITE_FILE="$TMP/deny" "$HOUSE/scripts/run-goal.sh" --worktree "$TMP/prepo" --base "$base" --result "$TMP/res" g1-a ) >"$TMP/gout" 2>&1 && grc=0 || grc=$?
check "worktree mode: no pinned admin from the walker, refused" 2 "$grc"
git worktree remove --force "$TMP/wt-g1"
git branch -q -D cw/g1-a

# --- 7. trust checks and the rest of PLAN step 11 ----------------------------
echo "7. trust checks (Amendments 2 and 3) and the rest of PLAN step 11"
common() { git rev-parse --path-format=absolute --git-common-dir; }
impl_calls() { wc -l <"$CALLS/implement" 2>/dev/null | tr -d ' ' || echo 0; }
noconflict() { sed -i '' 's/^    conflicts_with: \[g1-a\]$/    conflicts_with: []/' GOALS.md; git commit -qam "no conflict"; }
stopfile_of() { sed -n "s/^- $1: [^ ]* — //p" "$pstop"; }

# A forged `finished` record in the goal's journal: the recut refuses to copy
# it, and the goal is implemented again.
pwalk_repo
printf 'printf "\\n## 2026-10-15T00:00:00Z — ORCHESTRATOR finished g1-a head=%%s\\n" "$(git rev-parse HEAD)" >>docs/journal/p.md; echo $gid >$letter.txt; git add $letter.txt docs/journal/p.md; git commit -qm "feat($gid)"; printf "%%s\\n" "IMPLEMENTER_RESULT: error (exit 1)"; exit 1\n' >"$CALLS/action-g1-a"
prun --jobs 3
check "forged finished: the goal stops" implementer-error "$(reason_in g1-a)"
check "forged finished: no finished record on the walk branch" 0 "$(jcount 'ORCHESTRATOR finished g1-a')"
rm -f "$CALLS/action-g1-a"
prun --jobs 3
check "forged finished: the rerun recuts, refusing the planted record" 1 \
  "$(grep -c 'ORCHESTRATOR recut g1-a abandoned-records-not-kept=(g1-a journal: holds a walker-only record (finished))' docs/journal/p.md || true)"
check "forged finished: the walk completes" 0 "$prc"
check "forged finished: the only finished record is the walker's" 1 "$(jcount 'ORCHESTRATOR finished g1-a')"

# The branch moved after the review: refused at the join, nothing merged.
pwalk_repo
# g2-b moves cw/g1-a once g1-a has written its result (its review passed), not
# after a fixed sleep: under load g1-a may still be running. The newest wave
# folder is this walk's; older scenarios left theirs.
printf 'for _ in $(seq 240); do [ -s "$(ls -td "$HOME"/.cache/claude-coding-workflow/runs/run-goals-wave-* 2>/dev/null | head -n1)/g1-a.result" ] && break; sleep 0.25; done; git -C "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")" update-ref refs/heads/cw/g1-a refs/heads/walk; echo $gid >$letter.txt; git add $letter.txt; git commit -qm "feat($gid)"\n' >"$CALLS/action-g2-b"
prun --jobs 3
check "branch moved after review: integration-unverified" integration-unverified "$(reason_in g1-a)"
check "branch moved after review: g1-a not merged" "" "$(git log --merges --format=%s | grep 'g1-a' || true)"
check "branch moved after review: g1-a stays in_progress" in_progress "$(status_of g1-a)"

# A commit that lands while the review runs is never reported as reviewed.
pwalk_repo
printf 'echo late >late.txt; git add late.txt; git commit -qm "late, during the review"\n' >"$CALLS/review-action-g1-a"
prun --jobs 3
check "commit during review: head-moved-during-review" head-moved-during-review "$(reason_in g1-a)"
check "commit during review: nothing of g1-a merged" "" "$(git log --merges --format=%s | grep 'g1-a' || true)"

# A stopped goal's leftover commits are never merged: it is recut.
pwalk_repo
sed -i '' 's|^journal: docs/journal/p.md$|journal: docs/journal/p.md\nworktree_setup: test ! -e "$CALLS/fail-$(basename "$PWD")"|' GOALS.md
git commit -qam "setup key"
touch "$CALLS/fail-g2-b"
prun --jobs 3
( cd "$(wt_of g2-b)" && echo sneaky >sneaky.txt && git add sneaky.txt && git commit -qm sneaky )
rm -f "$CALLS/fail-g2-b"
prun --jobs 3
check "leftover commits: the walk completes" 0 "$prc"
[[ "$prc" -eq 0 ]] || tail -20 "$TMP/pout" | sed 's/^/    | /'
check "leftover commits: never merged" "" "$(git log --format=%s | grep '^sneaky$' || true)"
check "leftover commits: the goal was recut" 1 "$(jcount 'ORCHESTRATOR recut g2-b')"

# A replace ref stops the walk before any merge.
pwalk_repo
printf 'git replace "$(git rev-parse refs/heads/walk)" "$(git rev-parse refs/heads/walk~1)"; echo $gid >$letter.txt; git add $letter.txt; git commit -qm "feat($gid)"\n' >"$CALLS/action-g1-a"
prun --jobs 3
check "replace ref: git-replace-ref in the combined stop" git-replace-ref "$(reason_in '(walk)')"
check "replace ref: nothing merged" 0 "$(git log --merges --oneline | wc -l | tr -d ' ')"
git replace -d "$(git rev-parse refs/heads/walk)" 2>/dev/null || true

# A bounce first in the join, then a clean integration of the next goal.
pwalk_repo
echo BLOCKED >"$CALLS/verdict-g1-a"
prun --jobs 3
check "bounce then merge: g1-a bounced" bounced "$(status_of g1-a)"
check "bounce then merge: g2-b integrated in the same join" done "$(status_of g2-b)"
check "bounce then merge: tree clean" "" "$(git status --porcelain)"

# Wave sizes: a three-goal wave, a single-goal wave, the --jobs 2 cap.
pwalk_repo
noconflict
prun --jobs 3
check "three-goal wave" 1 "$(grep -c 'ORCHESTRATOR wave 1 g1-a,g2-b,g3-c$' docs/journal/p.md)"
check "single-goal wave, still through a worktree" 1 "$(grep -c 'ORCHESTRATOR wave 2 g4-d$' docs/journal/p.md)"
check "single-goal wave: merged --no-ff" 1 "$(git log --merges --format=%s | grep -c 'chore(g4-d): orchestrator integrate')"
pwalk_repo
noconflict
rm -rf "$EVENTS_CACHE"
prun --jobs 2
check "--jobs 2 caps the wave" 1 "$(grep -c 'ORCHESTRATOR wave 1 g1-a,g2-b$' docs/journal/p.md)"
check "--jobs 2: the rest in wave 2" 1 "$(grep -c 'ORCHESTRATOR wave 2 g3-c,g4-d$' docs/journal/p.md)"
# join_wait rows of this walk only (the index was cleared before it): exactly
# one per wave, walker-owned, each member's wait.
check "join_wait: one row per wave, no goal, each member's wait" "2 none g1-a,g2-b g3-c,g4-d" "$(python3 - "$EVENTS_CACHE" <<'PY'
import json, pathlib, sys
rows = []
for f in pathlib.Path(sys.argv[1]).glob("*/p.jsonl"):
    rows += [json.loads(l) for l in f.read_text().splitlines()]
rows = [r for r in rows if r.get("event") == "join_wait"]
print(len(rows), "none" if all(not r.get("goal_id") for r in rows) else "goal",
      " ".join(",".join(sorted(r["payload"]["waits"])) for r in rows))
PY
)"

# The second of three members fails setup; the other two run; the rerun recuts
# it (its worktree, junk and all, is replaced).
pwalk_repo
noconflict
sed -i '' 's|^journal: docs/journal/p.md$|journal: docs/journal/p.md\nworktree_setup: test ! -e "$CALLS/fail-$(basename "$PWD")"|' GOALS.md
git commit -qam "setup key"
touch "$CALLS/fail-g2-b"
prun --jobs 3
check "second of three fails setup: it stops" worktree-setup-failed "$(reason_in g2-b)"
check "second of three fails setup: the others integrated" "done done" "$(status_of g1-a) $(status_of g3-c)"
echo junk >"$(wt_of g2-b)/junk.txt"
echo keep >untracked-in-main.txt
rm -f "$CALLS/fail-g2-b"
prun --jobs 3
check "after a setup failure: the rerun integrates nothing while the main checkout is dirty" integration-dirty "$(reason_in g2-b)"
check "the main checkout's own file untouched" keep "$(cat untracked-in-main.txt 2>/dev/null)"
check "integration-dirty: the stop says not to move HEAD" yes \
  "$(grep -q 'Do not move HEAD' "$(stopfile_of g2-b)" && echo yes || echo no)"
rm -f untracked-in-main.txt
prun --jobs 3
check "after cleaning the main checkout: the walk completes" 0 "$prc"
[[ "$prc" -eq 0 ]] || tail -20 "$TMP/pout" | sed 's/^/    | /'
check "the recut goal's old worktree junk is gone" no "$(ls "$WTROOT"/*/g2-b/junk.txt >/dev/null 2>&1 && echo yes || echo no)"

# Setup timeout.
pwalk_repo
sed -i '' 's|^journal: docs/journal/p.md$|journal: docs/journal/p.md\nworktree_setup: if test -e "$CALLS/slow-$(basename "$PWD")"; then sleep 8; fi|' GOALS.md
git commit -qam "setup key"
touch "$CALLS/slow-g2-b"
PROOF_TIMEOUT=2 prun --jobs 3
check "setup timeout: worktree-setup-failed" worktree-setup-failed "$(reason_in g2-b)"

# Setup in the scratch tree after a merge: failing, then dirty. The walk
# branch never moves.
pwalk_repo
sed -i '' 's|^journal: docs/journal/p.md$|journal: docs/journal/p.md\nworktree_setup: case "$PWD" in */.integrate/*) test ! -e "$CALLS/fail-int" \&\& { test ! -e "$CALLS/dirty-int" \|\| touch dirt.txt; } ;; esac|' GOALS.md
git commit -qam "setup key"
touch "$CALLS/fail-int"
prun --jobs 3
check "scratch setup fails: worktree-setup-failed" worktree-setup-failed "$(reason_in g1-a)"
check "scratch setup fails: nothing merged" "" "$(git log --merges --format=%s | grep 'g1-a' || true)"
check "scratch setup fails: main tree clean" "" "$(git status --porcelain)"
rm -f "$CALLS/fail-int"
touch "$CALLS/dirty-int"
prun --jobs 3
check "scratch setup dirty: worktree-setup-dirty" worktree-setup-dirty "$(reason_in g1-a)"
check "scratch setup dirty: nothing merged" "" "$(git log --merges --format=%s | grep 'g1-a' || true)"
rm -f "$CALLS/dirty-int"
before="$(impl_calls)"
prun --jobs 3
check "after setup is fixed: the walk completes" 0 "$prc"
check "after setup is fixed: g1-a not dispatched again" 0 \
  "$(tail -n +$((before + 1)) "$CALLS/implement" | grep -c '^g1-a$' || true)"
check "after setup is fixed: the merged commit is the recorded one" \
  "$(grep 'ORCHESTRATOR finished g1-a head=' docs/journal/p.md | head -n1 | sed 's/.*head=//')" \
  "$(git log --merges --format='%P %s' | grep 'chore(g1-a): orchestrator integrate' | awk '{print $2}')"

# integration-dirty before the fast-forward names the restore, not a reset.
pwalk_repo
printf 'echo dirt >"$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/dirt.txt"; echo $gid >$letter.txt; git add $letter.txt; git commit -qm "feat($gid)"\n' >"$CALLS/action-g1-a"
prun --jobs 3
check "integration-dirty: stop" integration-dirty "$(reason_in g1-a)"
check "integration-dirty: the stop restores to HEAD, does not move it" yes \
  "$(grep -q 'git restore --staged --worktree' "$(stopfile_of g1-a)" && grep -q 'Do not move HEAD' "$(stopfile_of g1-a)" && echo yes || echo no)"
check "integration-dirty: nothing merged" 0 "$(git log --merges --oneline | wc -l | tr -d ' ')"
check "integration-dirty: the sibling is finished-not-integrated" finished-not-integrated "$(reason_in g2-b)"
rm -f dirt.txt "$CALLS/action-g1-a"
before="$(impl_calls)"
prun --jobs 3
check "after integration-dirty: the walk completes" 0 "$prc"
check "after integration-dirty: no new dispatch for the finished goals" 0 \
  "$(tail -n +$((before + 1)) "$CALLS/implement" | grep -c '^g[12]-[ab]$' || true)"

# A finished commit that cannot land (a stray lock): the result copies let the
# next start record and integrate both goals without dispatch.
pwalk_repo
printf ': >"$(git rev-parse --path-format=absolute --git-common-dir)/refs/heads/walk.lock"; echo $gid >$letter.txt; git add $letter.txt; git commit -qm "feat($gid)"\n' >"$CALLS/action-g1-a"
prun --jobs 3
check "walk ref lock: git-lock-stray" git-lock-stray "$(reason_in '(walk)')"
check "walk ref lock: the finished commit did not land" 0 "$(jcount 'ORCHESTRATOR finished ')"
rm -f "$(common)/refs/heads/walk.lock" "$CALLS/action-g1-a"
before="$(impl_calls)"
prun --jobs 3
check "result copies: the walk completes" 0 "$prc"
[[ "$prc" -eq 0 ]] || tail -20 "$TMP/pout" | sed 's/^/    | /'
check "result copies: g1-a and g2-b not dispatched again" 0 \
  "$(tail -n +$((before + 1)) "$CALLS/implement" | grep -c '^g[12]-[ab]$' || true)"
check "result copies: removed once integrated" 0 "$(ls "$WTROOT"/*/.results 2>/dev/null | wc -l | tr -d ' ')"

# A stopped goal whose worktree folder vanished is simply recut.
pwalk_repo
printf 'printf "%%s\\n" "IMPLEMENTER_RESULT: error (exit 1)"; exit 1\n' >"$CALLS/action-g2-b"
prun --jobs 3
rm -rf "$(wt_of g2-b)" "$CALLS/action-g2-b"
prun --jobs 3
check "missing worktree: the rerun recuts and completes" 0 "$prc"

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

# Ctrl-C in wave 2: a goal that already exited there is kept, not recut.
pwalk_repo
echo 30 >"$CALLS/sleep-g4-d"
touch "$TMP/started"
sleep 1
"$HOUSE/scripts/run-goals.sh" --jobs 3 >"$TMP/pout" 2>&1 &
wpid=$!
for _ in $(seq 600); do
  [[ -z "$(wave_result_after "$TMP/started" g3-c)" ]] || break
  sleep 0.25
done
sleep 2
kill -TERM "$wpid"
wait "$wpid" && prc=0 || prc=$?
pstop="$(sed -n 's/^STOP_FILE: //p' <<<"$(tail -n1 "$TMP/pout")")"
check "Ctrl-C in wave 2: g3-c listed finished-not-integrated" finished-not-integrated "$(reason_in g3-c)"
check "Ctrl-C in wave 2: g4-d listed interrupted" interrupted "$(reason_in g4-d)"
rm -f "$CALLS/sleep-g4-d"
before="$(grep -c '^g3-c$' "$CALLS/implement" || true)"
prun --jobs 3
check "Ctrl-C in wave 2: the rerun completes" 0 "$prc"
check "Ctrl-C in wave 2: g3-c not dispatched again" "$before" "$(grep -c '^g3-c$' "$CALLS/implement" || true)"

# Pinning (Amendment 5): after the cut, something rewrites g1-a's commondir to
# a fake common dir whose config defines a filter driver. Host git, pinned to
# the recorded dirs, never reads it, so the filter never runs. (g1-a's stub
# makes no change of its own, so no git of the stub's touches the fake dir.)
pwalk_repo
FAKE="$TMP/fakecommon"
rm -rf "$FAKE" "$CALLS/pwned"
git init -q --bare "$FAKE"
git -C "$FAKE" config filter.pw.clean "touch '$CALLS/pwned'; cat"
git -C "$FAKE" config filter.pw.smudge cat
mkdir -p "$FAKE/info" && printf '* filter=pw\n' >"$FAKE/info/attributes"
sed -i '' 's|^journal: docs/journal/p.md$|journal: docs/journal/p.md\nworktree_setup: case "$PWD" in */g1-a) printf "%s\\n" "'"$FAKE"'" >"$(git rev-parse --absolute-git-dir)/commondir"; touch -t 202001010000 PLAN.md ;; esac|' GOALS.md
git commit -qam "setup key"
printf ':\n' >"$CALLS/action-g1-a"
prun --jobs 3
# The touched PLAN.md makes any status re-hash it, so an unpinned host git
# would have to run the fake dir's clean filter (not left to racy timing).
check "rewritten commondir: the filter in the fake common dir never ran" no "$([[ -e "$CALLS/pwned" ]] && echo yes || echo no)"
check "rewritten commondir: g1-a stopped (it made no change)" yes "$([[ -n "$(reason_in g1-a)" ]] && echo yes || echo no)"
check "rewritten commondir: g2-b still integrated" done "$(status_of g2-b)"

# A non-ASCII journal path: git quotes such names unless told not to.
pwalk_repo
git mv docs/journal/p.md "docs/journal/é.md"
sed -i '' 's|^journal: docs/journal/p.md$|journal: docs/journal/é.md|' GOALS.md
git commit -qam "non-ASCII journal"
prun --jobs 3
check "non-ASCII journal path: the walk completes" 0 "$prc"
[[ "$prc" -eq 0 ]] || tail -20 "$TMP/pout" | sed 's/^/    | /'
check "non-ASCII journal path: every goal done" "done done done done" "$(for g in g1-a g2-b g3-c g4-d; do status_of "$g"; done | paste -sd ' ' -)"

# Deny paths when the main checkout is itself a linked worktree.
pwalk_repo
git worktree add -q -b walk2 "$TMP/linked" HEAD
( cd "$TMP/linked" && "$HOUSE/scripts/run-goals.sh" --jobs 3 >"$TMP/pout" 2>&1 ) || true
check "linked main checkout: HEAD denied under worktrees/linked" yes \
  "$([[ "$(cat "$CALLS/args-g1-a")" == *"/.git/worktrees/linked/HEAD "* ]] && echo yes || echo no)"
check "linked main checkout: its branch denied" yes \
  "$([[ "$(cat "$CALLS/args-g1-a")" == *"/.git/refs/heads/walk2 "* ]] && echo yes || echo no)"
check "the other member's admin folder denied, as git named it" yes \
  "$([[ "$(cat "$CALLS/args-g1-a")" == *"/.git/worktrees/g2-b "* ]] && echo yes || echo no)"
git worktree remove --force "$TMP/linked"

# Three goals live at once read as running in the pane.
check "three live goals" 3 "$(python3 - "$HERE/events.py" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("events", sys.argv[1])
ev = importlib.util.module_from_spec(spec); spec.loader.exec_module(ev)
me = os.getpid()
rows = [{"event": "walk", "goal_id": g, "payload": {"pid": me}} for g in ("g1-a", "g2-b", "g3-c")]
rows += [{"event": "dispatch", "goal_id": g, "payload": {"pid": me}} for g in ("g1-a", "g2-b", "g3-c")]
print(len(ev.live_goals(rows)))
PY
)"

# --jobs 1 makes the same commits and journal records as the walker before the
# parallel walker (pinned: 547d770, item 6's plan amendment, the last commit
# before its build; HEAD would compare the new walker with itself).
PRE_ITEM6=547d770
if ! git -C "$HERE/.." cat-file -e "$PRE_ITEM6^{commit}" 2>/dev/null; then
  # A copy of scripts/ outside the house repo, or a shallow clone.
  check "--jobs 1 equivalence: the pinned walker $PRE_ITEM6 is in the house repo" yes no
else
  OLD="$TMP/oldhouse"
  rm -rf "$OLD" && mkdir -p "$OLD"
  git -C "$HERE/.." archive "$PRE_ITEM6" scripts | tar -x -C "$OLD"
  cp "$HOUSE/scripts/claude-implement.sh" "$HOUSE/scripts/claude-goal-review.sh" "$OLD/scripts/"
  norm() {
    git log --reverse --format=%s
    sed -E 's/^## [0-9TZ:-]+ — /## T — /; s/(BASE_SHA|walk_id|merge)=[0-9a-f-]+/\1=X/g' docs/journal/p.md
  }
  pwalk_repo
  "$OLD/scripts/run-goals.sh" >"$TMP/pout-old" 2>&1 && orc=0 || orc=$?
  old_done="$(for g in g1-a g2-b g3-c g4-d; do status_of "$g"; done | paste -sd ' ' -)"
  norm >"$TMP/norm-old"
  pwalk_repo
  "$HOUSE/scripts/run-goals.sh" >"$TMP/pout-new" 2>&1 && nrc=0 || nrc=$?
  new_done="$(for g in g1-a g2-b g3-c g4-d; do status_of "$g"; done | paste -sd ' ' -)"
  norm >"$TMP/norm-new"
  check "--jobs 1: both walks succeed and finish every goal" "0 0 done done done done done done done done" \
    "$orc $nrc $old_done $new_done"
  check "--jobs 1: same commits and journal records as the walker at 547d770" "" "$(diff "$TMP/norm-old" "$TMP/norm-new")"
fi

echo
if [[ "$fails" -eq 0 ]]; then
  echo "parallel-walk-trust-test: all passed"
else
  echo "parallel-walk-trust-test: $fails failed"
  exit 1
fi
