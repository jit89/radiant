#!/usr/bin/env bash
# Self-test: the parallel walker recuts a goal after a plain merge conflict,
# once per goal per walk (docs/features/merge-conflict-recut/PLAN.md,
# parallel-walker Amendment 6). Launchers are stubs; no model is called.
set -euo pipefail
PW_NAME=pwrecut
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/parallel-walk-lib.sh"

echo "8. merge conflict: recut once per walk"
# Merge conflict (docs/features/merge-conflict-recut): both goals write the
# same file differently. The first integrates; the second is recut once and
# runs fresh from the new tip, where it merges cleanly; the walk goes on.
shared_action() {  # shared_action GOAL TEXT — the goal writes TEXT to shared.txt
  printf 'echo %s >shared.txt; echo $gid >$letter.txt; git add shared.txt $letter.txt; git commit -qm "feat($gid): $letter"\n' "$2" >"$CALLS/action-$1"
}
recut_records() { grep -c -- "^## .* — ORCHESTRATOR recut $1 reason=merge-conflict\$" docs/journal/p.md || true; }
events_of() { cat "$(find "$EVENTS_CACHE" -name p.jsonl | head -n1)" 2>/dev/null; }
pwalk_repo
shared_action g1-a one
shared_action g2-b two
# An evidence ref already there is never overwritten: the next one is /2.
git update-ref refs/cw-conflict/g2-b/1 "$(git rev-parse HEAD)"
pre="$(git rev-parse refs/cw-conflict/g2-b/1)"
# Nor is one of a goal whose id this one prefixes counted as its own.
git update-ref refs/cw-conflict/g2-bc/7 "$(git rev-parse HEAD)"
prun --jobs 3
check "merge conflict: the walk completes" 0 "$prc"
[[ "$prc" -eq 0 ]] || tail -20 "$TMP/pout" | sed 's/^/    | /'
check "merge conflict: every goal done" "done done done done" "$(for g in g1-a g2-b g3-c g4-d; do status_of "$g"; done | paste -sd ' ' -)"
check "merge conflict: one recut record, no path in it" 1 "$(recut_records g2-b)"
check "merge conflict: no second, plain recut record in the next wave" 1 "$(grep -c -- '^## .* — ORCHESTRATOR recut g2-b' docs/journal/p.md || true)"
check "merge conflict: g2-b ran twice (a fresh r0)" 2 "$(jcount 'ORCHESTRATOR dispatch g2-b r0 ')"
check "merge conflict: an existing evidence ref kept" "$pre" "$(git rev-parse refs/cw-conflict/g2-b/1)"
check "merge conflict: the attempt kept at the verified commit" \
  "$(sed -n 's/^## .* — ORCHESTRATOR finished g2-b head=\([0-9a-f]*\).*/\1/p' docs/journal/p.md | head -n1)" \
  "$(git rev-parse -q --verify refs/cw-conflict/g2-b/2 || echo none)"
check "merge conflict: an info recut event names the file" yes \
  "$(events_of | python3 -c 'import json,sys
rs=[json.loads(l) for l in sys.stdin if l.strip()]
print("yes" if any(r.get("event")=="recut" and r.get("severity")=="info" and r.get("goal_id")=="g2-b" and "shared.txt" in (r.get("payload") or {}).get("files",[]) for r in rs) else "no")')"
check "merge conflict: the walk end names it" yes "$(grep -q '^recut after a merge conflict: g2-b ' "$TMP/pout" && echo yes || echo no)"
check "merge conflict: members may not write refs/cw-conflict" yes \
  "$(grep -lq 'refs/cw-conflict' "$HOME/.cache/claude-coding-workflow/runs"/run-goals-wave-*/g1-a.deny 2>/dev/null && echo yes || echo no)"
check "merge conflict: tree clean" "" "$(git status --porcelain)"

# A new walk gets its own recut: the same two goals, handed back, conflict
# again (only these two: the others would rerun with no change).
for g in g1-a g2-b; do "$GOALS_PY" GOALS.md set "$g" ready >/dev/null; done
git commit -qam "again"
shared_action g1-a uno
shared_action g2-b dos
prun --jobs 3
check "merge conflict, a new walk: recut again and completes" "0 2" "$prc $(recut_records g2-b)"

# The same goal conflicts twice in one walk: the second stops merge-conflict.
# Its fresh run (wave 2, beside a slow g3-c) finishes; a TERM in the join
# keeps it finished-not-integrated; the walk branch then moves under it, and
# the rerun's start-of-walk integration conflicts again.
pwalk_repo
shared_action g1-a one
shared_action g2-b two
echo 60 >"$CALLS/sleep-g3-c"
"$HOUSE/scripts/run-goals.sh" --jobs 3 >"$TMP/pout" 2>&1 &
wpid=$!
# One wave folder serves the whole run, so wait for g2-b's second call, then
# for a result written after it (not wave 1's).
for _ in $(seq 600); do [[ "$(grep -c '^g2-b$' "$CALLS/implement" 2>/dev/null || true)" -ge 2 ]] && break; sleep 0.25; done
touch "$TMP/after-recut"
for _ in $(seq 600); do
  [[ -n "$(find "$HOME/.cache/claude-coding-workflow/runs" -path '*/run-goals-wave-*/g2-b.result' -newer "$TMP/after-recut" 2>/dev/null)" ]] && break
  sleep 0.25
done
sleep 3
kill -TERM "$wpid"
wait "$wpid" || true
rm -f "$CALLS/sleep-g3-c"
echo three >shared.txt && git add shared.txt && git commit -qm "the walk branch moves"
prun --jobs 3
check "merge conflict twice in a walk: stops merge-conflict" merge-conflict "$(reason_in g2-b)"
check "  ...saying the recut was used" yes "$(grep -q 'automatic recut for a merge conflict was already used' "$(stopfile_of g2-b)" 2>/dev/null && echo yes || echo no)"

# A recut and another goal's stop in one wave (Q3): the recut is done first,
# the stop file lists it under Recut, not as a stop; a rerun finishes.
pwalk_repo
noconflict
shared_action g1-a one
shared_action g2-b two
printf 'exit 1\n' >"$CALLS/action-g3-c"
prun --jobs 3
check "merge conflict with another stop: the walk stops" 1 "$([[ "$prc" -ne 0 ]] && echo 1 || echo 0)"
check "  ...g2-b is not a stop" "" "$(reason_in g2-b)"
check "  ...listed under Recut" yes "$(sed -n '/^## Recut/,/^## /p' "$pstop" | grep -q '^- g2-b: recut (merge-conflict)' && echo yes || echo no)"
check "  ...recut recorded before the stop" 1 "$(recut_records g2-b)"
rm -f "$CALLS/action-g3-c"
prun --jobs 3
check "  ...a rerun finishes" "0 done done" "$prc $(status_of g2-b) $(status_of g3-c)"


# The recut works from the verified commit, not the live branch: g3-c's
# integration (its worktree_setup in the scratch tree) moves cw/g2-b after
# g2-b's result was checked; the evidence ref is still the reviewed commit.
setup_in_g3c_scratch() {  # setup_in_g3c_scratch CMD — worktree_setup that runs CMD only there
  python3 - "$1" <<'PY'
import sys
cmd = sys.argv[1]
t = open("GOALS.md").read()
line = "journal: docs/journal/p.md\n"
assert t.count(line) == 1
t = t.replace(line, line + 'worktree_setup: case "$PWD" in */.integrate/g3-c-*) ' + cmd + " ;; esac\n")
open("GOALS.md", "w").write(t)
PY
  git commit -qam "setup key"
}
pwalk_repo
noconflict
shared_action g1-a one
shared_action g2-b two
setup_in_g3c_scratch 'git update-ref refs/heads/cw/g2-b HEAD'
prun --jobs 3
check "a moved branch: the walk completes" 0 "$prc"
[[ "$prc" -eq 0 ]] || tail -20 "$TMP/pout" | sed 's/^/    | /'
check "a moved branch: the old attempt's journal records kept (from the verified commit)" 2 \
  "$(jcount 'ORCHESTRATOR dispatch g2-b r0 ')"
check "a moved branch: the evidence ref is the verified commit" \
  "$(sed -n 's/^## .* — ORCHESTRATOR finished g2-b head=\([0-9a-f]*\).*/\1/p' docs/journal/p.md | head -n1)" \
  "$(git rev-parse -q --verify refs/cw-conflict/g2-b/1 || echo none)"

# A recut still queued when the wave stops another way: g3-c's scratch setup
# dirties the main checkout once, so its fast-forward stops the wave
# (integration-dirty, status 2) after g2-b's conflict was queued. wave_stop
# recuts g2-b first and lists it under Recut; a rerun finishes.
pwalk_repo
noconflict
shared_action g1-a one
shared_action g2-b two
setup_in_g3c_scratch "[ -e $TMP/dirtied ] || { touch $TMP/dirtied; touch $TMP/prepo/dirt.txt; }"
rm -f "$TMP/dirtied"
prun --jobs 3
check "a recut queued at another stop: the wave stops on g3-c" integration-dirty "$(reason_in g3-c)"
check "  ...g2-b recut first, not a stop" "1 " "$(recut_records g2-b) $(reason_in g2-b)"
check "  ...listed under Recut" yes "$(sed -n '/^## Recut/,/^## /p' "$pstop" | grep -q '^- g2-b: recut (merge-conflict)' && echo yes || echo no)"
rm -f dirt.txt
prun --jobs 3
check "  ...a rerun finishes" "0 done done" "$prc $(status_of g2-b) $(status_of g3-c)"

# A recut refused inside wave_stop: g3-c's scratch setup plants a replace ref
# after g2-b's conflict was queued, so the walker refuses every write from
# then on (git-replace-ref). wave_stop still writes the combined stop, with
# g2-b a merge-conflict stop naming why; once the ref is gone, a rerun
# recuts g2-b (its budget unused) and finishes.
pwalk_repo
noconflict
shared_action g1-a one
shared_action g2-b two
setup_in_g3c_scratch "git update-ref refs/replace/0000000000000000000000000000000000000001 HEAD"
prun --jobs 3
check "a recut refused in wave_stop: the combined stop is written" yes "$([[ -s "$pstop" ]] && echo yes || echo no)"
check "  ...g2-b a merge-conflict stop" merge-conflict "$(reason_in g2-b)"
check "  ...saying its recut failed" yes "$(grep -q 'automatic recut failed' "$(stopfile_of g2-b)" 2>/dev/null && echo yes || echo no)"
git update-ref -d refs/replace/0000000000000000000000000000000000000001
python3 - <<'PY'
t = open("GOALS.md").read()
t = "\n".join(l for l in t.split("\n") if not l.startswith("worktree_setup:"))
open("GOALS.md", "w").write(t)
PY
git commit -qam "no setup"
prun --jobs 3
check "  ...a rerun recuts it and finishes" "0 1" "$prc $(recut_records g2-b)"

# A first conflict at a rerun's start (PLAN step 6): g1-a and g2-b finish in
# wave 1 beside a slow g3-c, a TERM in the join keeps both finished, the walk
# branch then gains shared.txt, and the rerun's start-of-walk integration of
# g2-b conflicts: it is recut there, before any wave, and the walk finishes.
pwalk_repo
noconflict
printf 'echo $gid >$letter.txt; git add $letter.txt; git commit -qm "feat($gid): $letter"\n' >"$CALLS/action-g1-a"
shared_action g2-b two
echo 60 >"$CALLS/sleep-g3-c"
touch "$TMP/start-mark"
"$HOUSE/scripts/run-goals.sh" --jobs 3 >"$TMP/pout" 2>&1 &
wpid=$!
for _ in $(seq 600); do
  [[ -n "$(wave_result_after "$TMP/start-mark" g1-a)" && -n "$(wave_result_after "$TMP/start-mark" g2-b)" ]] && break
  sleep 0.25
done
sleep 3
kill -TERM "$wpid"
wait "$wpid" || true
rm -f "$CALLS/sleep-g3-c"
echo three >shared.txt && git add shared.txt && git commit -qm "the walk branch gains shared.txt"
prun --jobs 3
check "a conflict at a rerun's start: recut there, the walk finishes" "0 1" "$prc $(recut_records g2-b)"
# Recut at the start, before any wave of the rerun: one recut record in all
# (a recut left to the first wave's join would add the builder's plain one).
check "  ...one recut record, before the rerun's first wave" yes \
  "$(awk '/ORCHESTRATOR recut g2-b/ { n++; r = NR } /ORCHESTRATOR wave-stop/ { w = 0 } /ORCHESTRATOR wave [0-9]/ && !w { w = NR }
      END { print (n == 1 && r < w) ? "yes" : "no: " n " " r " " w }' docs/journal/p.md)"
[[ "$prc" -eq 0 ]] || tail -20 "$TMP/pout" | sed 's/^/    | /'

if [[ "$fails" -eq 0 ]]; then
  echo "parallel-walk-recut-test: all passed"
else
  echo "parallel-walk-recut-test: $fails failed" >&2
  exit 1
fi
