#!/usr/bin/env bash
# Self-test: a goal's soak (GOAL-FORMAT.md `soak:`): a long check started after
# a green host proof and run alongside the review; red or timed out, a fix round
# (on its own after a DONE, with the review's findings after a FIX). Nothing
# calls a model: the implementer and the reviewer are stubs.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-soak-XXXXXX")"
export TMPDIR="$TMP"
TMP="$(cd "$TMP" && pwd -P)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export HOME="$TMP/home" EVENTS_CACHE="$TMP/cache" CALLS="$TMP/calls"
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
export DEEPSEEK_API_KEY=stub-deepseek-key CW_MUTATIONS=0
unset MAX_FIX_ROUNDS PROOF_TIMEOUT SOAK_TIMEOUT CW_MUTATION_GAPS
mkdir -p "$HOME" "$CALLS"
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

HOUSE="$TMP/house"
mkdir -p "$HOUSE/scripts"
cp -R "$HERE/." "$HOUSE/scripts/"
# The implementer writes src/calc.sh, naming its pass.
cat >"$HOUSE/scripts/claude-implement.sh" <<'SH'
#!/usr/bin/env bash
echo implement >>"$CALLS/log"
for a in "$@"; do [[ -f "$a" ]] && cat "$a" >>"$CALLS/handoff-bodies"; done
mkdir -p src
n="$(grep -c implement "$CALLS/log")"
# $CALLS/nochange: every pass after the first changes nothing.
if [[ ! -f "$CALLS/nochange" || "$n" -eq 1 ]]; then
  printf '#!/usr/bin/env bash\n# calc (pass %s)\necho $(( $1 + $2 ))\n' "$n" >src/calc.sh
  git add src/calc.sh
  git -c commit.gpgSign=false commit -qm "feat(g1-store): calc pass $n"
fi
printf '%s\n' "IMPLEMENTER_RESULT: ok" "THREAD_ID: haiku:t1" "IMPLEMENTER_STATUS: DONE" "IMPLEMENTER_MODEL: stub"
SH
# The reviewer: a verdict from $CALLS/verdicts (one a call; DONE when none
# left); $CALLS/review-sleep seconds first; RATE_LIMITED fails the call.
cat >"$HOUSE/scripts/claude-goal-review.sh" <<'SH'
#!/usr/bin/env bash
echo review >>"$CALLS/log"
[[ ! -f "$CALLS/review-sleep" ]] || sleep "$(cat "$CALLS/review-sleep")"
v=DONE
if [[ -s "$CALLS/verdicts" ]]; then v="$(head -n1 "$CALLS/verdicts")"; sed -i '' 1d "$CALLS/verdicts"; fi
if [[ "$v" == RATE_LIMITED ]]; then
  printf '%s\n' "CLAUDE_REVIEW_RESULT: rate_limited (exit 1)" "SESSION_ID: s1" "VERDICT: MISSING"
  exit 75
fi
vf="$CW_OUT_DIR/verdict-$RANDOM.md"
if [[ "$v" == FIX ]]; then printf 'FIX: src/calc.sh:3 — REVIEW-NIT-9 — change it\nVERDICT: FIX\n' >"$vf"; else printf 'VERDICT: %s\n' "$v" >"$vf"; fi
printf '%s\n' "CLAUDE_REVIEW_RESULT: ok" "SESSION_ID: s1" "VERDICT: $v" "VERDICT_FILE: $vf" "CLAUDE_REVIEW_MODEL: stub"
SH
chmod +x "$HOUSE/scripts/"*.sh

ORACLE_OK='[ "$(bash src/calc.sh 2 3)" = 5 ] || { echo "want 5"; exit 1; }
echo ok'

# make_repo ORACLE [SOAK] — a one-goal repo; SOAK, when given, is the goal's soak:.
make_repo() {
  rm -rf "$TMP/repo" "$CALLS"/* "$HOME/.cache/claude-coding-workflow/run-goal-g1-store"
  mkdir -p "$TMP/repo/docs/journal" "$TMP/repo/tests/acceptance" && cd "$TMP/repo"
  git init -q
  sed -e '/id: g1-store/,/status:/{
s|proof: true|proof: bash tests/acceptance/g1-store.sh|
s|oracle: inline|oracle: tests/acceptance/g1-store.sh|
}' "$HERE/../GOALS.example.md" >GOALS.md
  if [[ -n "${2:-}" ]]; then
    SOAK_CMD="$2" python3 - <<'PYX'
import os, re
t = open("GOALS.md").read()
t, n = re.subn(r"(id: g1-store[\s\S]*?\n(\s+)proof: [^\n]*\n)", lambda m: m.group(1) + m.group(2) + "soak: " + os.environ["SOAK_CMD"] + "\n", t, count=1)
assert n == 1
open("GOALS.md", "w").write(t)
PYX
  fi
  printf '# Plan\n' >PLAN.md
  printf '%s\n' "$1" >tests/acceptance/g1-store.sh
  # The soak's script is a contract file too: tests/acceptance/.
  printf '%s\n' "${SOAK_BODY:-exit 0}" >tests/acceptance/g1-soak.sh
  printf '.gitignore\n' >.gitignore
  printf '# Journal: example\n' >docs/journal/example.md
  git add -A && git commit -q -m base
}
run() {
  "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 && rc=0 || rc=$?
  local stop
  stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)"
  reason="$(sed -n 's/^- reason: //p' "$stop" 2>/dev/null || true)"
  detail="$(cat "$stop" 2>/dev/null || true)"
}
status_of() { "$HERE/goals.py" GOALS.md show g1-store | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])'; }
records() { git show HEAD:docs/journal/example.md | sed -n 's/^## [^ ]* — ORCHESTRATOR \([a-z]*\) g1-store r\([0-9]*\).*/\1 r\2/p' | paste -sd ',' -; }
soak_lines() { git show HEAD:docs/journal/example.md | grep -c 'ORCHESTRATOR soak g1-store' || true; }
ART="$HOME/.cache/claude-coding-workflow/run-goal-g1-store"

echo "== no soak key: no soak record"
make_repo "$ORACLE_OK"
run
check "no soak: done, no soak record" "0 done 0" "$rc $(status_of) $(soak_lines)"

echo "== a green soak runs beside the review"
SOAK_BODY='grep -q "pass 1" src/calc.sh || exit 1; echo soak-green' make_repo "$ORACLE_OK" "bash tests/acceptance/g1-soak.sh"
run
check "green soak: done" "0 done" "$rc $(status_of)"
check "  ...one soak record, exit 0, read after the review" yes \
  "$(order="$(git show HEAD:docs/journal/example.md | grep -oE 'ORCHESTRATOR (soak|review) g1-store' | awk '{print $2}' | paste -sd ' ' -)"
     [[ "$order" == "review soak" ]] && git show HEAD:docs/journal/example.md | grep -q 'ORCHESTRATOR soak g1-store r0 exit=0 secs=' && echo yes || echo "no: $order")"
check "  ...its output kept for the Architect" yes "$(grep -q soak-green "$ART/soak-r0.out" 2>/dev/null && echo yes || echo no)"
check "  ...one implementer pass, one review" "implement review" "$(paste -sd ' ' - <"$CALLS/log")"

echo "== the soak and the review run side by side, and the soak is no stray"
# 4 s each: in series the goal takes 8 s or more. Still running when the review
# returns, the soak would be ended as a stray (reap_strays) and read red.
# A control run (the soak alone) prices the goal's own steps; the review's 4 s
# must add well under its length.
now() { python3 -c 'import time; print(f"{time.time():.2f}")'; }
SOAK_BODY='sleep 4; echo slept' make_repo "$ORACLE_OK" "bash tests/acceptance/g1-soak.sh"
t0="$(now)"; run; t1="$(now)"
control="$(python3 -c "print($t1 - $t0)")"
SOAK_BODY='sleep 4; echo slept' make_repo "$ORACLE_OK" "bash tests/acceptance/g1-soak.sh"
echo 4 >"$CALLS/review-sleep"
t0="$(now)"; run; t1="$(now)"
both="$(python3 -c "print($t1 - $t0)")"
check "side by side: done, one implementer pass" "0 done implement review" "$rc $(status_of) $(paste -sd ' ' - <"$CALLS/log")"
check "  ...a 4 s review beside a 4 s soak adds under 2.5 s" yes \
  "$(python3 -c "print('yes' if $both - $control < 2.5 else 'no: control %.1f s, both %.1f s' % ($control, $both))")"

echo "== a red soak after a DONE is a fix round of its own; the fixed pass goes green"
SOAK_BODY='grep -q "pass 2" src/calc.sh || { echo "SOAK-CASE-17 failed"; exit 1; }' make_repo "$ORACLE_OK" "bash tests/acceptance/g1-soak.sh"
run
check "red then green: done after one fix round" "0 done" "$rc $(status_of)"
check "  ...implement, review (DONE, soak red), implement, review" "implement review implement review" "$(paste -sd ' ' - <"$CALLS/log")"
check "  ...the fix handoff says red soak and carries the failing case" "yes yes" \
  "$(grep -q '^# Fix handoff: g1-store (after round 0: red soak)' "$CALLS/handoff-bodies" 2>/dev/null && echo yes || echo no) $(grep -q 'SOAK-CASE-17' "$CALLS/handoff-bodies" 2>/dev/null && echo yes || echo no)"
check "  ...the fix record names the soak" yes "$(git show HEAD:docs/journal/example.md | grep -q 'ORCHESTRATOR fix g1-store r0 count=1 .* source=proof .*step=soak' && echo yes || echo no)"
check "  ...two soak records, exit 1 then 0" "2" "$(soak_lines)"

echo "== a soak red every time spends the fix budget"
SOAK_BODY='echo never; exit 1' make_repo "$ORACLE_OK" "bash tests/acceptance/g1-soak.sh"
MAX_FIX_ROUNDS=1 run
check "always red: max-fix-rounds after a red soak" "1 max-fix-rounds yes" "$rc $reason $(has 'after a red soak' "$detail")"
check "  ...each pass reviewed beside its soak" "implement review implement review" "$(paste -sd ' ' - <"$CALLS/log")"

echo "== a soak past SOAK_TIMEOUT is red, with the timeout named"
SOAK_BODY='grep -q "pass 2" src/calc.sh || sleep 30' make_repo "$ORACLE_OK" "bash tests/acceptance/g1-soak.sh"
SOAK_TIMEOUT=3 run
check "timeout: a fix round, then done" "0 done" "$rc $(status_of)"
check "  ...the handoff names the timeout" yes "$(grep -q 'ran past 3s' "$CALLS/handoff-bodies" 2>/dev/null && echo yes || echo no)"

echo "== a red soak beside a FIX: one fix round with both findings"
SOAK_BODY='grep -q "pass 2" src/calc.sh || { echo "SOAK-CASE-23 failed"; exit 1; }' make_repo "$ORACLE_OK" "bash tests/acceptance/g1-soak.sh"
echo FIX >"$CALLS/verdicts"
run
check "FIX and a red soak: done after one fix round" "0 done implement review implement review" "$rc $(status_of) $(paste -sd ' ' - <"$CALLS/log")"
check "  ...one handoff carries the review's finding and the soak's case" "yes yes" \
  "$(grep -q 'REVIEW-NIT-9' "$CALLS/handoff-bodies" && echo yes || echo no) $(grep -q 'SOAK-CASE-23' "$CALLS/handoff-bodies" && echo yes || echo no)"
check "  ...the fix record counts both, from the review, with the soak" yes \
  "$(git show HEAD:docs/journal/example.md | grep -q 'ORCHESTRATOR fix g1-store r0 count=2 hash=[0-9a-f]* source=review step=soak' && echo yes || echo no)"

echo "== a wake during the review takes the running soak down"
# The soak records its own pid, then becomes the sleep: the check looks at that
# one process, not at every command line that mentions a sleep.
SOAK_BODY='echo $$ >soak.pid; exec sleep 37' make_repo "$ORACLE_OK" "bash tests/acceptance/g1-soak.sh"
echo RATE_LIMITED >"$CALLS/verdicts"
echo 1 >"$CALLS/review-sleep"
run
sleep 1
soak_pid="$(cat "$TMP/repo/soak.pid" 2>/dev/null || true)"
check "  ...the soak had started" yes "$([[ -n "$soak_pid" ]] && echo yes || echo no)"
check "a failed review wakes; no soak left running" "1 gone" \
  "$rc $( [[ -n "$soak_pid" ]] && kill -0 "$soak_pid" 2>/dev/null && echo "alive: $(ps -o command= -p "$soak_pid")" || echo gone)"

echo "== a soak fix round that changes nothing stops (soak-red), as a red proof's does"
SOAK_BODY='echo never; exit 1' make_repo "$ORACLE_OK" "bash tests/acceptance/g1-soak.sh"
touch "$CALLS/nochange"
run
check "no change: soak-red after the second red soak" "1 soak-red" "$rc $reason"
check "  ...two passes, two reviews" "implement review implement review" "$(paste -sd ' ' - <"$CALLS/log")"

echo "== a soak that rewrites the journal's existing text wakes"
SOAK_BODY="sed -i '' '1s/.*/# Journal: rewritten/' docs/journal/example.md" make_repo "$ORACLE_OK" "bash tests/acceptance/g1-soak.sh"
run
check "journal rewritten: soak-tamper naming the journal" "1 soak-tamper yes" "$rc $reason $(has 'its existing text changed' "$detail")"

echo "== a soak a stopped run left running is ended at the next soak; a reused pid is not"
SOAK_BODY='exit 0' make_repo "$ORACLE_OK" "bash tests/acceptance/g1-soak.sh"
mkdir -p "$ART"
sleep 47 & stale=$!
sleep 49 & reused=$!
sleep 0.3
printf '%s %s\n' "$stale" "$(ps -o lstart= -p "$stale" | tr -s ' ')" >"$ART/soak.pid"
run
alive() { kill -0 "$1" 2>/dev/null && echo alive || echo gone; }
check "stale: the recorded soak ended, the goal done" "0 done gone" "$rc $(status_of) $(alive "$stale")"
SOAK_BODY='exit 0' make_repo "$ORACLE_OK" "bash tests/acceptance/g1-soak.sh"
mkdir -p "$ART"
printf '%s %s\n' "$reused" "Thu Jan  1 00:00:00 1970" >"$ART/soak.pid"
run
check "reused pid: another start time, the process left alone" "0 alive" "$rc $(alive "$reused")"
kill "$stale" "$reused" 2>/dev/null || true

echo "== a soak that changes the repo wakes"
SOAK_BODY='echo x >src/planted.txt' make_repo "$ORACLE_OK" "bash tests/acceptance/g1-soak.sh"
run
check "tamper: soak-tamper" "1 soak-tamper" "$rc $reason"

echo "== a red proof runs no soak"
SOAK_BODY='echo soak-ran >&2; exit 0' make_repo 'exit 1' "bash tests/acceptance/g1-soak.sh"
MAX_FIX_ROUNDS=0 run
check "red proof: no soak record, max-fix-rounds after a red proof" "0 yes" "$(soak_lines) $(has 'after a red proof' "$detail")"

echo "== validate"
make_repo "$ORACLE_OK" "[a, b]"
v="$("$HERE/goals.py" GOALS.md validate 2>&1 || true)"
check "validate: a soak list is refused" yes "$(has 'soak must be one shell command' "$v")"
make_repo "$ORACLE_OK" "bash tests/acceptance/g1-soak.sh"
check "validate: a soak command is accepted" 0 "$("$HERE/goals.py" GOALS.md validate >/dev/null 2>&1; echo $?)"

if [[ "$fails" -eq 0 ]]; then
  echo "soak-test: all passed"
else
  echo "soak-test: $fails failed"
  exit 1
fi
