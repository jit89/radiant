#!/usr/bin/env bash
# Self-test: the parallel walker (docs/features/parallel-walker/PLAN.md).
# Launchers are stubs; no model is called. Sections 1-5; the trust checks are in
# parallel-walk-trust*-test.sh.
set -euo pipefail
# Mutation checks off here (docs/features/mutation-checks; mutation-test.sh turns them on).
export CW_MUTATIONS=0
PW_NAME=parallel
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/parallel-walk-lib.sh"
# --- 1. atomic GOALS.md writes (PLAN step 1) ---------------------------------
echo "1. atomic GOALS.md writes"
A="$TMP/atomic"
mkdir -p "$A"
cp "$HERE/../GOALS.example.md" "$A/GOALS.md"
chmod 640 "$A/GOALS.md"
# A reader in a loop while a writer flips a status 150 times: every read must
# carry the whole fence (the closing ``` after the last goal) and parse.
race="$(python3 - "$A/GOALS.md" "$GOALS_PY" <<'PY'
import subprocess, sys, threading
path, goals_py = sys.argv[1], sys.argv[2]
full = open(path).read()
torn = []
stop = threading.Event()
def reader():
    n = 0
    while not stop.is_set():
        t = open(path).read()
        n += 1
        # Both versions are the same length but for the status word.
        if abs(len(t) - len(full)) > 16 or not t.rstrip().endswith(full.rstrip()[-40:]):
            torn.append(len(t))
    print("reads", n >= 50)
th = threading.Thread(target=reader)
th.start()
for i in range(150):
    st = "done" if i % 2 == 0 else "ready"
    subprocess.run([goals_py, path, "set", "g1-store", st], check=True, capture_output=True)
stop.set()
th.join()
print("torn", len(torn))
PY
)"
check "reader ran throughout the writes" "reads True" "$(sed -n 1p <<<"$race")"
check "no torn read" "torn 0" "$(sed -n 2p <<<"$race")"
check "no temp file left beside GOALS.md" "GOALS.md" "$(ls -A "$A")"
check "mode kept" "640" "$(stat -f '%Lp' "$A/GOALS.md")"
"$GOALS_PY" "$A/GOALS.md" validate >/dev/null && v=ok || v=bad
check "file still validates" ok "$v"
# Written through a symlink, as write_text did: the link stays a link.
mkdir -p "$A/real"
mv "$A/GOALS.md" "$A/real/GOALS.md"
ln -s real/GOALS.md "$A/GOALS.md"
"$GOALS_PY" "$A/GOALS.md" set g1-store in_progress >/dev/null
check "symlink kept" "link" "$([[ -L "$A/GOALS.md" ]] && echo link || echo file)"
check "target updated" "in_progress" \
  "$("$GOALS_PY" "$A/real/GOALS.md" show g1-store | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
"$GOALS_PY" "$A/GOALS.md" refresh >/dev/null
check "refresh leaves no temp file" "GOALS.md" "$(ls -A "$A/real")"

# --- 2. journal-merge.py (PLAN step 7) ---------------------------------------
echo "2. journal resolve"
J="$TMP/jm"
mkdir -p "$J"
JM="$HERE/lib/journal-merge.py"
printf '# Journal: f\n\n## 2026-10-15T00:00:00Z — ORCHESTRATOR wave 1 g1-a,g2-b\n' >"$J/base"
cp "$J/base" "$J/ours"
cp "$J/base" "$J/theirs"
# The walk side already holds another goal's records (an earlier integration).
printf '\n## 2026-10-15T00:01:00Z — ORCHESTRATOR dispatch g1-a r0 BASE_SHA=x THREAD_ID=- SESSION_ID=-\n\n## 2026-10-15T00:02:00Z — IMPLEMENTER g1-a END\nnotes\n\n## 2026-10-15T00:03:00Z — ORCHESTRATOR integrated g1-a merge=abc\n' >>"$J/ours"
printf '\n## 2026-10-15T00:01:30Z — ORCHESTRATOR dispatch g2-b r0 BASE_SHA=x THREAD_ID=- SESSION_ID=-\n\n## 2026-10-15T00:02:30Z — IMPLEMENTER g2-b START\nplan\n\n## 2026-10-15T00:04:00Z — ORCHESTRATOR done g2-b r0\n' >>"$J/theirs"
jm() { rm -f "$J/out"; python3 "$JM" "$J/base" "$J/ours" "$J/$1" g2-b "$J/out"; }
jm theirs >/dev/null && r=ok || r=bad
check "both sides appended: joined" ok "$r"
check "joined = base + walk suffix + goal suffix" \
  "$(cat "$J/ours"; tail -c +$(($(wc -c <"$J/base") + 1)) "$J/theirs")" "$(cat "$J/out")"
cp "$J/base" "$J/same"
jm same >/dev/null && r="$(cmp -s "$J/out" "$J/ours" && echo walk || echo other)" || r=bad
check "goal appended nothing: the walk journal" walk "$r"
sed 's/wave 1/wave 9/' "$J/theirs" >"$J/rewrote"
check "goal rewrote an earlier line: refused" \
  "g2-b journal: committed text was edited, not appended to" "$(jm rewrote || true)"
check "refused: nothing written" absent "$([[ -e "$J/out" ]] && echo present || echo absent)"
{ cat "$J/theirs"; printf '\n## 2026-10-15T00:05:00Z — IMPLEMENTER g1-a END\nx\n'; } >"$J/other"
check "goal suffix carries another goal's record: refused" \
  "g2-b journal: appended line 9 is a record for g1-a, not g2-b" "$(jm other || true)"
{ cat "$J/theirs"; printf 'loose note\n'; } >"$J/loose"
check "goal suffix loose text: refused" \
  "g2-b journal: appended line 8 follows a one-line ORCHESTRATOR record: 'loose note'" "$(jm loose || true)"
cp "$J/ours" "$J/ours.keep"
sed 's/wave 1/wave 7/' "$J/ours.keep" >"$J/ours"
check "walk side rewritten: refused" \
  "walk branch journal: committed text was edited, not appended to" "$(jm theirs || true)"
cp "$J/ours.keep" "$J/ours"
# A goal suffix holding a record only the walker writes is refused (Amendment 3).
{ cat "$J/theirs"; printf '\n## 2026-10-15T00:06:00Z — ORCHESTRATOR finished g2-b head=%040d\n' 0; } >"$J/forged"
check "goal suffix with a walker-only record: refused" \
  "g2-b journal: holds a walker-only record (finished)" "$(jm forged || true)"
{ cat "$J/theirs"; printf '\n## 2026-10-15T00:06:00Z — ORCHESTRATOR overrides walk proof-sandbox=off\n'; } >"$J/forged"
check "goal suffix with the walker's overrides record: refused" \
  "g2-b journal: holds a walker-only record (overrides walk)" "$(jm forged || true)"
# Already joined (a bounce appended the records, then a recut): no duplicate.
cat "$J/ours" >"$J/joined"
tail -c +$(($(wc -c <"$J/base") + 1)) "$J/theirs" >>"$J/joined"
rm -f "$J/out"
python3 "$JM" "$J/base" "$J/joined" "$J/theirs" g2-b "$J/out" >/dev/null && r=ok || r=bad
check "suffix already on the walk side: no duplicate" "ok same" "$r $(cmp -s "$J/out" "$J/joined" && echo same || echo differs)"

# --- 3. events (PLAN step 6) -------------------------------------------------
echo "3. events"
E="$TMP/ev"
mkdir -p "$E/main" "$E/wt"
( cd "$E/main" && git init -q && mkdir -p docs/journal && : >docs/journal/f.md )
( cd "$E/wt" && mkdir -p docs/journal && : >docs/journal/f.md )
main_id="$(python3 -c 'import hashlib,sys,pathlib; print(hashlib.sha256(str(pathlib.Path(sys.argv[1]).resolve()).encode()).hexdigest()[:16])' "$E/main")"
( cd "$E/wt" && CW_EVENTS_ROOT="$E/main" python3 "$HERE/events.py" append docs/journal/f.md \
  --event phase --severity info --goal g1-a --summary "from a worktree" )
check "worktree event lands in the main checkout's index" "from a worktree" \
  "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["summary"])' "$EVENTS_CACHE/$main_id/f.jsonl" 2>/dev/null || echo missing)"
# Four writers, 150 lines each: every line parses. A regression check only: the
# code before the flock also wrote each line in one write(2) and passes it too;
# the lock guards a short write, which a test cannot force.
for w in 1 2 3 4; do
  ( cd "$E/main" && for i in $(seq 150); do
      python3 "$HERE/events.py" append docs/journal/f.md --event phase --severity info \
        --goal "g$w-x" --summary "writer $w line $i $(printf 'x%.0s' $(seq 150))"
    done ) &
done
wait
check "concurrent appends: every line parses (regression check)" "601 0" "$(python3 - "$EVENTS_CACHE/$main_id/f.jsonl" <<'PY2'
import json, sys
n = bad = 0
for line in open(sys.argv[1]):
    n += 1
    try:
        json.loads(line)
    except ValueError:
        bad += 1
print(n, bad)
PY2
)"
# The integrating state: a goal that wrote `phase integrate` and exited.
live() {
  python3 - "$HERE/events.py" "$1" "$2" <<'PY2'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("events", sys.argv[1])
ev = importlib.util.module_from_spec(spec); spec.loader.exec_module(ev)
walker, goal = int(sys.argv[2]), int(sys.argv[3])
rows = [
    {"event": "walk", "goal_id": "g1-a", "payload": {"pid": walker}},
    {"event": "dispatch", "goal_id": "g1-a", "payload": {"pid": goal}},
    {"event": "phase", "goal_id": "g1-a", "payload": {"phase": "integrate", "pid": goal}},
    {"event": "join_wait", "payload": {"waits": {"g1-a": 3}}},
]
print(ev.live_goals(rows).get("g1-a", {}).get("phase", "not-live"))
PY2
}
sleep 300 & alive=$!
( exit 0 ) & dead=$!
wait "$dead" 2>/dev/null || true
check "goal exited, walker alive: integrating" integrate "$(live "$alive" "$dead")"
check "goal exited, walker gone: not live (paused)" not-live "$(live "$dead" "$dead")"
kill "$alive" 2>/dev/null || true
wait "$alive" 2>/dev/null || true

# --- 4. a parallel walk end to end (PLAN steps 2-9) ---------------------------
echo "4. parallel walk"
pwalk_repo
prun --jobs 3
check "walk: exit 0" 0 "$prc"
[[ "$prc" -eq 0 ]] || sed 's/^/    | /' "$TMP/pout" | tail -40
check "walk: every goal done" "done done done done" "$(for g in g1-a g2-b g3-c g4-d; do status_of "$g"; done | paste -sd ' ' -)"
check "walk: two waves" "2" "$(jcount 'ORCHESTRATOR wave ')"
check "walk: wave 1 is g1-a and g2-b" "1" "$(grep -c 'ORCHESTRATOR wave 1 g1-a,g2-b$' docs/journal/p.md)"
check "walk: wave 2 is g3-c and g4-d" "1" "$(grep -c 'ORCHESTRATOR wave 2 g3-c,g4-d$' docs/journal/p.md)"
check "walk: four integrate merges" "4" "$(git log --merges --format=%s | grep -c 'orchestrator integrate')"
check "walk: each goal's commit reachable" "4" "$(git log --format=%s | grep -c '^feat(g')"
check "walk: every goal's records in the main journal" "4" "$(grep -c 'ORCHESTRATOR done g[0-9]-[a-z] r0' docs/journal/p.md)"
check "walk: journal committed, tree clean" "" "$(git status --porcelain)"
check "walk: no cw branch left" "" "$(git branch --list 'cw/*')"
check "walk: no worktree left" "1" "$(git worktree list | wc -l | tr -d ' ')"
check "walk: deny list names the walk branch" "yes" \
  "$([[ "$(cat "$CALLS/args-g1-a")" == *".git/refs/heads/walk "* ]] && echo yes || echo no)"
check "walk: deny list names the other member's branch" "yes" \
  "$([[ "$(cat "$CALLS/args-g1-a")" == *".git/refs/heads/cw/g2-b "* ]] && echo yes || echo no)"
check "walk: packed-refs.lock not denied" "no" \
  "$([[ "$(cat "$CALLS"/args-*)" == *packed-refs.lock* ]] && echo yes || echo no)"
check "walk: walk-end journaled" "1" "$(jcount 'ORCHESTRATOR walk-end')"

# --- 5. parallel walk: stops, integration failures, resume -------------------
echo "5. parallel walk: stops and recovery"

# --jobs validation
pwalk_repo
prun --jobs 5
check "--jobs 5 refused" 2 "$prc"
prun --jobs x
check "--jobs x refused" 2 "$prc"

# A member stops (implementer error) while the other integrates; resume.
pwalk_repo
printf 'printf "%%s\\n" "IMPLEMENTER_RESULT: error (exit 1)"; exit 1\n' >"$CALLS/action-g2-b"
prun --jobs 3
check "member stop: nonzero" yes "$([[ $prc -ne 0 ]] && echo yes || echo no)"
check "member stop: the other member integrated" done "$(status_of g1-a)"
check "member stop: the stopped goal stays in_progress" in_progress "$(status_of g2-b)"
check "member stop: combined stop names it" implementer-error "$(reason_in g2-b)"
check "member stop: its worktree kept" yes "$([[ -d "$(wt_of g2-b)" ]] && echo yes || echo no)"
check "member stop: no second wave" 1 "$(jcount 'ORCHESTRATOR wave ')"
check "member stop: main tree clean" "" "$(git status --porcelain)"
prun
check "--jobs 1 after a parallel stop: refused" orchestration-files-dirty "$(sed -n 's/^- reason: //p' "$pstop")"
check "--jobs 1 refusal says rerun with --jobs" yes "$(grep -q 'Rerun with --jobs N' "$pstop" && echo yes || echo no)"
rm -f "$CALLS/action-g2-b"
prun --jobs 3
check "rerun: walk completes" 0 "$prc"
[[ "$prc" -eq 0 ]] || tail -20 "$TMP/pout" | sed 's/^/    | /'
# A stopped goal is recut and starts fresh (Amendment 3 C): its abandoned
# attempt's records are kept, and the new attempt has a new base.
check "rerun: the stopped goal was recut" 1 "$(jcount 'ORCHESTRATOR recut g2-b')"
check "rerun: two attempts, two bases" 2 \
  "$(grep 'ORCHESTRATOR dispatch g2-b r0' docs/journal/p.md | sed 's/.*BASE_SHA=\([0-9a-f]*\).*/\1/' | sort -u | wc -l | tr -d ' ')"
check "rerun: all done" "done done done done" "$(for g in g1-a g2-b g3-c g4-d; do status_of "$g"; done | paste -sd ' ' -)"

# Bounce (exit 3), then the Architect resets it: recut fresh.
pwalk_repo
echo BLOCKED >"$CALLS/verdict-g2-b"
prun --jobs 3
check "bounce: goal bounced" bounced "$(status_of g2-b)"
check "bounce: combined stop names it" bounced "$(reason_in g2-b)"
check "bounce: its records reached the walk journal" 1 "$(jcount 'ORCHESTRATOR bounced g2-b r0')"
check "bounce: no code merged" "" "$(git log --format=%s | grep 'feat(g2-b)' || true)"
check "bounce: worktree kept" yes "$([[ -d "$(wt_of g2-b)" ]] && echo yes || echo no)"
check "bounce: main tree clean" "" "$(git status --porcelain)"
rm -f "$CALLS/verdict-g2-b"
"$GOALS_PY" GOALS.md set g2-b ready >/dev/null
git commit -qm "architect: unbounce g2-b" -- GOALS.md
prun --jobs 3
check "recut: walk completes" 0 "$prc"
[[ "$prc" -eq 0 ]] || tail -20 "$TMP/pout" | sed 's/^/    | /'
check "recut: a fresh attempt (a second dispatch r0)" 2 "$(grep -c 'ORCHESTRATOR dispatch g2-b r0' docs/journal/p.md)"
# A resume of the old attempt would dispatch r0 again under the old base: the
# new base must differ from it and be a wave commit after the bounce.
check "recut: the fresh attempt's base is a new wave base" yes \
  "$(b1="$(grep 'ORCHESTRATOR dispatch g2-b r0' docs/journal/p.md | head -n1 | sed 's/.*BASE_SHA=\([0-9a-f]*\).*/\1/')"
     b2="$(grep 'ORCHESTRATOR dispatch g2-b r0' docs/journal/p.md | tail -n1 | sed 's/.*BASE_SHA=\([0-9a-f]*\).*/\1/')"
     [[ "$b1" != "$b2" && "$(git log -1 --format=%s "$b2")" == "chore: orchestrator wave"* ]] &&
       git merge-base --is-ancestor "$(git log -1 --format=%H --grep='orchestrator bounced')" "$b2" && echo yes || echo no)"

# Merge conflict: parallel-walk-recut-test.sh (docs/features/merge-conflict-recut).

# integration-red: g2-b is green alone, red with g1-a merged.
pwalk_repo
sed -i '' 's/^    proof: test -f b.txt$/    proof: test -f b.txt \&\& ! test -f a.txt/' GOALS.md
git commit -qam "proof: b without a"
prun --jobs 3
check "integration-red: stop reason" integration-red "$(reason_in g2-b)"
check "integration-red: g1-a still done" done "$(status_of g1-a)"
check "integration-red: g2-b not merged, nothing reset" no "$(git merge-base --is-ancestor cw/g2-b HEAD && echo yes || echo no)"
check "integration-red: g2-b's finished record kept" 1 "$(jcount 'ORCHESTRATOR finished g2-b ')"
check "integration-red: tree clean" "" "$(git status --porcelain)"
check "integration-red: branch kept" yes "$(git show-ref --verify --quiet refs/heads/cw/g2-b && echo yes || echo no)"
check "integration-red: the scratch tree kept as evidence" yes \
  "$(s="$(sed -n 's/^- scratch worktree (evidence, kept): //p' "$(sed -n 's/^- g2-b: integration-red — //p' "$pstop")")"; [[ -n "$s" && -d "$s" ]] && echo yes || echo no)"

# integration-tamper once (in the scratch tree), then a rerun integrates the
# same reviewed commit again, without dispatch.
pwalk_repo
sed -i '' 's|^    proof: test -f b.txt$|    proof: test -f b.txt \&\& { if test -f a.txt \&\& test ! -e "$CALLS/once"; then touch "$CALLS/once" stray.txt; fi; true; }|' GOALS.md
git commit -qam "proof: tamper once"
prun --jobs 3
check "integration-tamper: stop reason" integration-tamper "$(reason_in g2-b)"
check "integration-tamper: the walk branch not moved" no "$(git merge-base --is-ancestor cw/g2-b HEAD && echo yes || echo no)"
check "integration-tamper: the main checkout untouched" "" "$(git status --porcelain)"
check "integration-tamper: g2-b not done" in_progress "$(status_of g2-b)"
before="$(grep -c '^g2-b$' "$CALLS/implement" || true)"
prun --jobs 3
check "after a tamper: the rerun finishes the walk" 0 "$prc"
[[ "$prc" -eq 0 ]] || tail -20 "$TMP/pout" | sed 's/^/    | /'
check "after a tamper: g2-b integrated without a new dispatch" "$before" "$(grep -c '^g2-b$' "$CALLS/implement" || true)"
check "after a tamper: g2-b merged once" 1 "$(git log --merges --format=%s | grep -c 'chore(g2-b): orchestrator integrate')"

# walk-branch-moved: a goal switches the main checkout's branch mid-wave.
pwalk_repo
printf 'git -C "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")" checkout -q -b elsewhere; echo $gid >$letter.txt; git add $letter.txt; git commit -qm "feat($gid)"\n' >"$CALLS/action-g1-a"
prun --jobs 3
check "walk-branch-moved: in the combined stop" walk-branch-moved "$(reason_in '(walk)')"
check "walk-branch-moved: nothing integrated" ready-or-in_progress \
  "$([[ "$(status_of g1-a)" != done && "$(status_of g2-b)" != done ]] && echo ready-or-in_progress || echo integrated)"
git checkout -q walk

# git-lock-stray: a goal leaves packed-refs.lock behind.
pwalk_repo
printf ': >"$(git rev-parse --path-format=absolute --git-common-dir)/packed-refs.lock"; echo $gid >$letter.txt; git add $letter.txt; git commit -qm "feat($gid)"\n' >"$CALLS/action-g1-a"
prun --jobs 3
check "git-lock-stray: in the combined stop" git-lock-stray "$(reason_in '(walk)')"
check "git-lock-stray: the lock is named, not deleted" yes \
  "$([[ -e "$(git rev-parse --path-format=absolute --git-common-dir)/packed-refs.lock" ]] && grep -q packed-refs.lock "$(sed -n 's/^- (walk): git-lock-stray — //p' "$pstop")" && echo yes || echo no)"
rm -f "$(git rev-parse --path-format=absolute --git-common-dir)/packed-refs.lock"

# A GOALS.md edit inside a worktree is contract drift there.
pwalk_repo
# A status-only edit: status-only-id would allow it; worktree mode must not.
printf '"$STUB_GOALS" GOALS.md set g1-a done >/dev/null; echo $gid >$letter.txt; git add $letter.txt; git commit -qm "feat($gid)"\n' >"$CALLS/action-g1-a"
prun --jobs 3
check "status-only GOALS.md edit in a worktree: contract stop" contract-tamper-worktree "$(reason_in g1-a)"

# worktree-exists: a planted branch keeps the goal ready and out of the wave.
pwalk_repo
git branch cw/g2-b
prun --jobs 3
check "worktree-exists: stop names it" worktree-exists "$(reason_in g2-b)"
check "worktree-exists: goal stays ready" ready "$(status_of g2-b)"
check "worktree-exists: the other goal still integrated" done "$(status_of g1-a)"
prun --jobs 3
prun --jobs 3
check "worktree-exists: still stopped later (sticky, never loops)" worktree-exists "$(reason_in g2-b)"
check "worktree-exists: still ready" ready "$(status_of g2-b)"

# worktree_setup: runs in each worktree and in the main checkout after a merge;
# one member's failure stops only that member; a rerun sets it up again.
pwalk_repo
sed -i '' 's|^journal: docs/journal/p.md$|journal: docs/journal/p.md\nworktree_setup: test ! -e "$CALLS/fail-$(basename "$PWD")" \&\& echo "$PWD" >>"$CALLS/setup"|' GOALS.md
git commit -qam "setup key"
touch "$CALLS/fail-g2-b"
prun --jobs 3
check "setup: the failing member stops worktree-setup-failed" worktree-setup-failed "$(reason_in g2-b)"
check "setup: the other member ran and integrated" done "$(status_of g1-a)"
check "setup: ran in g1-a's worktree" 1 "$(grep -c '/g1-a$' "$CALLS/setup")"
check "setup: ran in a scratch tree after the merge" 1 "$(grep -c '/\.integrate/g1-a-' "$CALLS/setup")"
check "setup: g2-b never dispatched" 0 "$(grep -c '^g2-b$' "$CALLS/implement" 2>/dev/null || true)"
rm -f "$CALLS/fail-g2-b"
prun --jobs 3
check "setup: rerun sets g2-b up again and finishes" 0 "$prc"
[[ "$prc" -eq 0 ]] || tail -20 "$TMP/pout" | sed 's/^/    | /'

# TERM to the walker mid-wave.
pwalk_repo
echo 6 >"$CALLS/sleep-g1-a"
echo 6 >"$CALLS/sleep-g2-b"
"$HOUSE/scripts/run-goals.sh" --jobs 3 >"$TMP/pout" 2>&1 &
wpid=$!
# Both goals running (each stub has logged its call) before the signal.
for _ in $(seq 240); do [[ "$(wc -l <"$CALLS/implement" 2>/dev/null | tr -d ' ')" -ge 2 ]] && break; sleep 0.25; done
kill -TERM "$wpid"
wait "$wpid" && prc=0 || prc=$?
pstop="$(sed -n 's/^STOP_FILE: //p' <<<"$(tail -n1 "$TMP/pout")")"
check "TERM: exit 143" 143 "$prc"
check "TERM: combined stop names both goals" 2 "$(grep -c '^- g[12]-[ab]: interrupted' "$pstop" 2>/dev/null || true)"
[[ "$(grep -c '^- g[12]-[ab]: interrupted' "$pstop" 2>/dev/null || true)" == 2 ]] || { tail -30 "$TMP/pout"; cat "$pstop" 2>/dev/null; } | sed 's/^/    | /'
check "TERM: nothing integrated" 0 "$(git log --merges --oneline | wc -l | tr -d ' ')"

# An earlier goal's proof red only once a later goal is merged: the merged
# proofs cover every goal done in this walk, not only the one merging.
pwalk_repo
sed -i '' 's/^    proof: test -f a.txt$/    proof: test -f a.txt \&\& ! test -f b.txt/' GOALS.md
git commit -qam "proof: a without b"
prun --jobs 3
check "earlier goal red after a later merge: integration-red" integration-red "$(reason_in g2-b)"
check "earlier goal red: the stop names g1-a's proof" yes \
  "$(grep -q 'g1-a (exit' "$(sed -n 's/^- g2-b: integration-red — //p' "$pstop")" && echo yes || echo no)"

echo "== the proof sandbox in a walk (house item 12)"
# sprun: prun with the proof sandbox on.
sprun() { CW_PROOF_SANDBOX= prun "$@"; }

pwalk_repo
deps_before="$(ls "$HOME/.cache/claude-coding-workflow/deps" 2>/dev/null | grep -c '^walk-' || true)"
# Each self-test leaves a line: who ran it (a member has --worktree).
cp "$HOUSE/scripts/lib/proof-sandbox.sh" "$TMP/psb.sh.orig"
cat >>"$HOUSE/scripts/lib/proof-sandbox.sh" <<'SH'
eval "orig_$(declare -f proof_sandbox_selftest)"
proof_sandbox_selftest() {
  if [[ " $(ps -o command= -p $$) " == *" --worktree "* ]]; then echo member; else echo walker; fi >>"$CALLS/selftest"
  orig_proof_sandbox_selftest
}
SH
sprun --jobs 3
cp "$TMP/psb.sh.orig" "$HOUSE/scripts/lib/proof-sandbox.sh"
check "sandbox: a plain walk completes" 0 "$prc"
check "sandbox: nothing overridden, no overrides record" 0 "$(git show HEAD:docs/journal/p.md | grep -c 'ORCHESTRATOR overrides' || true)"
check "sandbox: the self-test ran once, in the walker, not in its members" walker "$(paste -sd ' ' - <"$CALLS/selftest" 2>/dev/null)"
check "sandbox: every goal done" "done done done done" "$(for g in g1-a g2-b g3-c g4-d; do status_of "$g"; done | paste -sd ' ' -)"
check "sandbox: the walk's dependency folder is removed at the end" "$deps_before" "$(ls "$HOME/.cache/claude-coding-workflow/deps" 2>/dev/null | grep -c '^walk-' || true)"

# The dependency folder: worktree_setup writes it, a proof reads it and cannot
# write it (npm_config_cache points into it).
pwalk_repo
sed -i '' 's|^journal: docs/journal/p.md$|journal: docs/journal/p.md\nworktree_setup: mkdir -p "$npm_config_cache" \&\& echo dep >"$npm_config_cache/dep.txt"|' GOALS.md
sed -i '' 's|^    proof: test -f b.txt$|    proof: test -f b.txt \&\& test -f "$npm_config_cache/dep.txt" \&\& ! touch "$npm_config_cache/proof-wrote"|' GOALS.md
git commit -qam "setup writes deps; g2-b's proof reads them"
sprun --jobs 3
check "sandbox deps: the walk completes" 0 "$prc"
[[ "$prc" -eq 0 ]] || tail -15 "$TMP/pout" | sed 's/^/    | /'
check "sandbox deps: g2-b done (it read the dependency and could not write there)" done "$(status_of g2-b)"

# tool_path (docs/features/rust-toolchain-gates): worktree_setup, run by the
# walker under the sandbox, finds `cargo-clippy` through the GOALS.md tool
# folder only. The folder sits in the house checkout: the sandbox cannot read
# a temp area, and goals.py rejects one.
TROOT="${CW_TEST_TOOLS_ROOT:-$HERE/../.test-tools}"; mkdir -p "$TROOT" && TOOLS="$(mktemp -d "$TROOT/toolpath-XXXXXX")"
trap '[[ -n "${KEEP_TMP:-}" ]] || rm -rf "$TMP" "$TOOLS"' EXIT
printf '%s\n' '#!/bin/sh' 'sub="$1"; shift' \
  'p="$(command -v "cargo-$sub")" || { echo "error: no such command: $sub" >&2; exit 101; }' \
  'exec "$p" "$@"' >"$TOOLS/cargo"
printf '%s\n' '#!/bin/sh' 'mkdir -p "$npm_config_cache" && echo linted >"$npm_config_cache/clippy.txt"' >"$TOOLS/cargo-clippy"
chmod +x "$TOOLS/cargo" "$TOOLS/cargo-clippy"
pwalk_repo
sed -i '' "s|^journal: docs/journal/p.md\$|journal: docs/journal/p.md\\
tool_path: [$TOOLS]\\
worktree_setup: $TOOLS/cargo clippy|" GOALS.md
sed -i '' 's|^    proof: test -f b.txt$|    proof: test -f b.txt \&\& test -f "$npm_config_cache/clippy.txt"|' GOALS.md
git commit -qam "setup runs cargo clippy through tool_path"
sprun --jobs 3
check "sandbox tool_path: the walk completes" 0 "$prc"
[[ "$prc" -eq 0 ]] || tail -15 "$TMP/pout" | sed 's/^/    | /'
check "sandbox tool_path: g2-b done (worktree_setup's cargo found cargo-clippy)" done "$(status_of g2-b)"

# The proof sandbox stopping the walker's own steps (FUTURE-WORK item 12): a
# hard link to a file outside every tree appears in the walk's dependency
# folder after g1-a's own proof passed (its reviewer plants it), so g1-a's
# integration meets it. (g2-b, proving at the same time, may meet it too.)
# The folder is found by name, not through a variable the reviewer happens to
# inherit; pwalk_repo clears $CALLS, so the action makes the outside file.
plant_link='echo outside >"$CALLS/outside" && ln "$CALLS/outside" "$(ls -td "$HOME/.cache/claude-coding-workflow/deps/walk-"* | head -n1)/pulled-$RANDOM"'
pwalk_repo
printf '%s\n' "$plant_link" >"$CALLS/review-action-g1-a"
sprun --jobs 3
check "sandbox: a merged proof the sandbox stops is the integration's stop" proof-hardlink "$(reason_in g1-a)"
check "  ...naming the merged proof" yes "$(grep -q 'stopped the merged proof of g1-a' "$(stopfile_of g1-a)" && echo yes || echo no)"
check "  ...nothing merged" 0 "$(git log --merges --oneline | wc -l | tr -d ' ')"
pwalk_repo
sed -i '' 's|^journal: docs/journal/p.md$|journal: docs/journal/p.md\nworktree_setup: true|' GOALS.md
git commit -qam "setup key"
printf '%s\n' "$plant_link" >"$CALLS/review-action-g1-a"
sprun --jobs 3
check "sandbox: a scratch worktree_setup the sandbox stops is the integration's stop" proof-hardlink "$(reason_in g1-a)"
check "  ...naming the setup" yes "$(grep -q 'worktree_setup in the scratch tree after merging g1-a' "$(stopfile_of g1-a)" && echo yes || echo no)"

# A live .env in the main checkout stops the walk before any worktree is cut.
pwalk_repo
printf '.env.local\n' >>.gitignore && git add .gitignore && git commit -qm "ignore .env.local"
echo 'TOKEN=x' >.env.local
sprun --jobs 3
check "secrets-in-checkout: the walk stops" secrets-in-checkout "$(sed -n 's/^- reason: //p' "$pstop" 2>/dev/null)"
check "secrets-in-checkout: the stop names the file" yes "$(grep -q '\.env\.local' "$pstop" && echo yes || echo no)"
check "secrets-in-checkout: no worktree was cut" "" "$(ls "$WTROOT"/*/ 2>/dev/null | grep -E '^g[0-9]' || true)"
CW_ALLOW_DOTENV=1 sprun --jobs 3
check "CW_ALLOW_DOTENV=1: the walk goes ahead" 0 "$prc"
check "CW_ALLOW_DOTENV=1: the header says so" yes "$(grep -q 'CW_ALLOW_DOTENV=1' "$TMP/pout" && echo yes || echo no)"
check "CW_ALLOW_DOTENV=1: the walker journals it (committed)" 1 "$(git show HEAD:docs/journal/p.md | grep -c '^## .* — ORCHESTRATOR overrides walk dotenv=allowed$' || true)"
rm -f .env.local
# A .env inside another worktree of the repo stops the walk too.
pwalk_repo
git worktree add -q "$TMP/extra-wt" -b extra-branch
echo 'TOKEN=y' >"$TMP/extra-wt/.env"
sprun --jobs 3
check "secrets-in-checkout: a .env in another worktree stops the walk" secrets-in-checkout "$(sed -n 's/^- reason: //p' "$pstop" 2>/dev/null)"
check "  ...naming it" yes "$(grep -q 'extra-wt/.env' "$pstop" && echo yes || echo no)"
git worktree remove --force "$TMP/extra-wt"; git branch -q -D extra-branch

# The sandbox cannot be made: the walk stops before any worktree is cut.
pwalk_repo
mv "$HOUSE/scripts/lib/proof-sandbox.py" "$HOUSE/scripts/lib/proof-sandbox.py.away"
sprun --jobs 3
mv "$HOUSE/scripts/lib/proof-sandbox.py.away" "$HOUSE/scripts/lib/proof-sandbox.py"
check "proof-sandbox-unavailable: the walk stops" proof-sandbox-unavailable "$(sed -n 's/^- reason: //p' "$pstop" 2>/dev/null)"
check "proof-sandbox-unavailable: no worktree was cut" "" "$(ls "$WTROOT"/*/ 2>/dev/null | grep -E '^g[0-9]' || true)"
CW_PROOF_SANDBOX=off prun --jobs 3
check "CW_PROOF_SANDBOX=off: the walk goes ahead" 0 "$prc"

echo
if [[ "$fails" -eq 0 ]]; then
  echo "parallel-walk-test: all passed"
else
  echo "parallel-walk-test: $fails failed"
  exit 1
fi
