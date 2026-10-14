#!/usr/bin/env bash
# Self-test: a resumed goal continues where the stopped run was — same
# implementer thread, same reviewer session, and the FIX findings it still
# owed — never a generic restart of the round (F-14). Launchers are stubs
# driven by a per-call script; nothing calls a model.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-state-XXXXXX")"
export TMPDIR="$TMP"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" EVENTS_CACHE="$TMP/cache" CALLS="$TMP/calls"
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
export DEEPSEEK_API_KEY=stub-not-a-key
unset ANTHROPIC_API_KEY MAX_FIX_ROUNDS
mkdir -p "$HOME"
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

HOUSE="$TMP/house"
mkdir -p "$HOUSE/scripts"
cp -R "$HERE/." "$HOUSE/scripts/"

# Call N of a stub does line N of $CALLS/<name>.plan. Each call is logged as
# "<name> <args>" in $CALLS/log, and the implementer's handoff (last arg) is
# kept as $CALLS/handoff-<N>.md.
cat >"$HOUSE/scripts/claude-implement.sh" <<'SH'
#!/usr/bin/env bash
n=$(( $(grep -c '^ds ' "$CALLS/log" 2>/dev/null || true) + 1 ))
echo "ds $*" >>"$CALLS/log"
cp "${!#}" "$CALLS/handoff-$n.md"
case "$(sed -n "${n}p" "$CALLS/ds.plan")" in
  ok)
    echo "$n" >>impl.txt && git add impl.txt && git commit -qm "wip: impl $n"
    printf '%s\n' "IMPLEMENTER_RESULT: ok" "THREAD_ID: t1" ;;
  rate)
    printf '%s\n' "IMPLEMENTER_RESULT: rate_limited (exit 75)" "THREAD_ID: t1"
    exit 75 ;;
  *) echo "IMPLEMENTER_RESULT: error (no plan for call $n)"; exit 1 ;;
esac
SH
cat >"$HOUSE/scripts/claude-goal-review.sh" <<'SH'
#!/usr/bin/env bash
n=$(( $(grep -c '^rv ' "$CALLS/log" 2>/dev/null || true) + 1 ))
echo "rv $*" >>"$CALLS/log"
step="$(sed -n "${n}p" "$CALLS/rv.plan")"
case "$step" in
  error)
    printf '%s\n' "CLAUDE_REVIEW_RESULT: error (exit 1)" "SESSION_ID: s1" \
      "VERDICT: MISSING" "VERDICT_FILE: /dev/null"
    exit 1 ;;
  fix-*)
    printf 'FIX: impl.txt:1 — wrong — apply %s\nVERDICT: FIX\n' "$step" >"$CALLS/verdict-$n.md"
    printf '%s\n' "CLAUDE_REVIEW_RESULT: ok" "SESSION_ID: s1" "VERDICT: FIX" \
      "VERDICT_FILE: $CALLS/verdict-$n.md" ;;
  *) echo "CLAUDE_REVIEW_RESULT: error (no plan)"; exit 1 ;;
esac
SH
chmod +x "$HOUSE/scripts/"*.sh

# fresh <ds plan> <rv plan>: new repo, new cache, run once.
fresh() {
  rm -rf "$TMP/repo" "$CALLS" "$HOME/.cache"
  mkdir -p "$TMP/repo/docs/journal" "$CALLS" && cd "$TMP/repo"
  git init -q
  cp "$HERE/../GOALS.example.md" GOALS.md
  printf '# Plan\n' >PLAN.md
  printf '# Journal: example\n' >docs/journal/example.md
  git add -A && git commit -q -m base
  printf '%s\n' $1 >"$CALLS/ds.plan"
  printf '%s\n' $2 >"$CALLS/rv.plan"
  run
}
run() {
  "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 || true
  local stop
  stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)"
  reason="$(sed -n 's/^- reason: //p' "$stop" 2>/dev/null || true)"
  detail="$(sed -n 's/^- detail: //p' "$stop" 2>/dev/null || true)"
}
calls() { grep -c "^$1 " "$CALLS/log" 2>/dev/null || true; }
nth_call() { grep "^$1 " "$CALLS/log" | sed -n "${2}p"; }
last_dispatch_round() {
  grep 'ORCHESTRATOR dispatch g1-store' docs/journal/example.md | tail -n1 |
    sed -n 's/.* r\([0-9]*\) .*/\1/p'
}
has() { grep -q "$1" "$2" 2>/dev/null && echo yes || echo no; }

# 1. Round 0 implementer and reviewer both return ids, then review fails.
fresh "ok ok" "error error"
check "1: first run woke on reviewer" "reviewer-error" "$reason"
run
check "1: resume reuses the implementer thread" "ds --resume t1" \
  "$(nth_call ds 2 | cut -d' ' -f1-3)"
check "1: resume reuses the reviewer session" "rv --resume s1" \
  "$(nth_call rv 2 | cut -d' ' -f1-3)"

# 2. FIX at r0; the r1 implementer is rate-limited before it can apply it.
fresh "ok rate ok" "fix-A error"
check "2: first run woke on rate limit" "rate_limited" "$reason"
run
check "2: resume dispatched the implementer" "3" "$(calls ds)"
check "2: resume handoff carries the r0 findings" "yes" "$(has 'apply fix-A' "$CALLS/handoff-3.md")"
check "2: resume stays in round 1" "1" "$(last_dispatch_round)"
check "2: no finding text in the journal" "no" "$(has 'apply fix-A' docs/journal/example.md)"

# 3. A later FIX supersedes the earlier one.
fresh "ok ok rate ok" "fix-A fix-B error"
run
check "3: resume handoff carries the newest findings" "yes" "$(has 'apply fix-B' "$CALLS/handoff-4.md")"
check "3: not the superseded ones" "no" "$(has 'apply fix-A' "$CALLS/handoff-4.md")"
check "3: resume stays in round 2" "2" "$(last_dispatch_round)"

# 4. MAX_FIX_ROUNDS=N allows exactly N repair implementations (F2-07). The
#    reviewer always says FIX; the first implementation is not a repair.
for cap in 0 1 2 3; do
  export MAX_FIX_ROUNDS=$cap
  fresh "ok ok ok ok ok ok" "fix-A fix-B fix-C fix-D fix-E fix-F"
  check "4: cap $cap: wakes on the cap" "max-fix-rounds" "$reason"
  check "4: cap $cap: $cap repair implementation(s)" "$((cap + 1))" "$(calls ds)"
done

# 4b. Interrupted before the repair ran: the resume runs that same repair.
export MAX_FIX_ROUNDS=1
fresh "ok rate ok ok" "fix-A fix-B fix-C"
check "4b: first run woke on rate limit" "rate_limited" "$reason"
run
check "4b: resume ran repair 1, then woke on the cap" "max-fix-rounds" "$reason"
check "4b: no repair 2" "1" "$(last_dispatch_round)"

# 4c. Interrupted after the repair ran, before its review: redoing it does not
#     spend a second repair.
fresh "ok ok ok ok" "fix-A error fix-B"
check "4c: first run woke on the review" "reviewer-error" "$reason"
run
check "4c: resume redid repair 1 and woke on the cap" "max-fix-rounds" "$reason"
check "4c: still round 1" "1" "$(last_dispatch_round)"

# 4d. Stopped at the cap with FIX pending: the same cap wakes again, a raised
#     cap runs exactly the newly allowed repair, from the pending findings.
export MAX_FIX_ROUNDS=0
fresh "ok ok ok" "fix-A fix-B"
check "4d: first run hit the cap" "max-fix-rounds" "$reason"
run
check "4d: same cap on resume: wakes again" "max-fix-rounds" "$reason"
check "4d: same cap on resume: no dispatch" "1" "$(calls ds)"
MAX_FIX_ROUNDS=1 run
check "4d: raised cap: dispatches repair 1" "2" "$(calls ds)"
check "4d: raised cap: handoff carries the findings" "yes" "$(has 'apply fix-A' "$CALLS/handoff-2.md")"
check "4d: raised cap: wakes before repair 2" "max-fix-rounds" "$reason"
unset MAX_FIX_ROUNDS

# 5. Pending findings lost from the cache: refuse rather than guess.
fresh "ok rate ok" "fix-A error"
rm -f "$HOME/.cache/claude-coding-workflow/run-goal-g1-store/"fix-r0.md
run
check "5: missing findings: gate" "gate" "$reason"
check "5: gate names the round" "yes" \
  "$([[ "$detail" == *"FIX findings for r0"* ]] && echo yes || echo "no: $detail")"
check "5: nothing dispatched" "2" "$(calls ds)"

# 6. Cached findings that are not the ones journaled (another repo with the
#    same goal id, or an edit): refuse.
fresh "ok rate ok" "fix-A error"
sed -i.bak 's/apply fix-A/apply something else/' \
  "$HOME/.cache/claude-coding-workflow/run-goal-g1-store/fix-r0.md"
run
check "6: altered findings: gate" "gate" "$reason"
check "6: nothing dispatched" "2" "$(calls ds)"

# 7. The pending fix's source, head and stuck flag (docs/features/proof-fix
#    step 7): fields 7-9, read straight from journals written here.
state() {
  local j="$TMP/state-journal.md"
  printf '%s\n' "$@" >"$j"
  python3 "$HERE/lib/resume-state.py" "$j" g1-store | cut -f7-9
}
D0='## t — ORCHESTRATOR dispatch g1-store r0 BASE_SHA=abc THREAD_ID=- SESSION_ID=-'
D1='## t — ORCHESTRATOR dispatch g1-store r1 BASE_SHA=abc THREAD_ID=t1 SESSION_ID=-'
PF='## t — ORCHESTRATOR fix g1-store r0 count=1 hash=h0 source=proof head=h3ad'
check "7: an old fix line: no source, head or stuck" $'-\t-\t0' \
  "$(state "$D0" '## t — ORCHESTRATOR fix g1-store r0 count=2 hash=h0')"
check "7: a review fix" $'review\t-\t0' \
  "$(state "$D0" '## t — ORCHESTRATOR fix g1-store r0 count=2 hash=h0 source=review')"
check "7: a proof fix" $'proof\th3ad\t0' "$(state "$D0" "$PF")"
check "7: implemented is not stuck" $'proof\th3ad\t0' \
  "$(state "$D0" "$PF" "$D1" '## t — ORCHESTRATOR implemented g1-store r1 STATUS=DONE MODEL=m COST_USD=-')"
check "7: a blocked stop is not stuck" $'proof\th3ad\t0' \
  "$(state "$D0" "$PF" "$D1" '## t — ORCHESTRATOR wake g1-store r1 reason=implementer-blocked')"
check "7: a proof-red stop of r1 is stuck" $'proof\th3ad\t1' \
  "$(state "$D0" "$PF" "$D1" '## t — ORCHESTRATOR wake g1-store r1 reason=proof-red')"
check "7: a proof-red stop of another round is not" $'proof\th3ad\t0' \
  "$(state "$D0" "$PF" '## t — ORCHESTRATOR wake g1-store r0 reason=proof-red')"
check "7: a review clears it" $'-\t-\t0' \
  "$(state "$D0" "$PF" "$D1" '## t — ORCHESTRATOR wake g1-store r1 reason=proof-red' \
    '## t — ORCHESTRATOR review g1-store r1 VERDICT=DONE MODEL=m')"
check "7: a later dispatch clears stuck (the pending fix ran again)" $'proof\th3ad\t0' \
  "$(state "$D0" "$PF" "$D1" '## t — ORCHESTRATOR wake g1-store r1 reason=proof-red' "$D1" \
    '## t — ORCHESTRATOR wake g1-store r1 reason=implementer-blocked')"
check "7: a newer fix resets stuck" $'proof\thn3w\t0' \
  "$(state "$D0" "$PF" "$D1" '## t — ORCHESTRATOR wake g1-store r1 reason=proof-red' \
    '## t — ORCHESTRATOR fix g1-store r1 count=1 hash=h1 source=proof head=hn3w')"

if [[ "$fails" -eq 0 ]]; then
  echo "resume-state: OK"
else
  echo "resume-state: $fails FAILURE(S)" >&2
  exit 1
fi
