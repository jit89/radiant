#!/usr/bin/env bash
# Self-test: the parallel walker (docs/features/parallel-walker/PLAN.md).
# Launchers are stubs; no model is called.
# Section 6, worktree-mode gates, and section 7 part 1: forged records, moved
# branches and commits, leftover commits, replace refs, wave sizes.
# The trust checks are split in four files (parallel-walk-trust*-test.sh), so
# run-all runs them side by side; each scenario starts from a fresh repo.
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

echo
if [[ "$fails" -eq 0 ]]; then
  echo "parallel-walk-trust-test: all passed"
else
  echo "parallel-walk-trust-test: $fails failed"
  exit 1
fi
