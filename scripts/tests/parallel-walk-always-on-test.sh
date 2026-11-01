#!/usr/bin/env bash
# Self-test: the parallel walker's always-on gate (docs/features/always-on,
# step 9): with CW_ALWAYS_ON_LEDGER set, a spend ceiling or the kill file stops
# the walk before a wave is committed, and a wave's members carry the ledger
# and the entry, so their costs reach it. Launchers are stubs; no model is called.
set -euo pipefail
# Mutation checks off here (docs/features/mutation-checks; mutation-test.sh turns them on).
export CW_MUTATIONS=0
PW_NAME=pwalwayson
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/parallel-walk-lib.sh"

stopped() { grep -q "^- reason: $1\$" "$pstop" 2>/dev/null && echo yes || echo "no: $(sed -n 's/^- reason: //p' "$pstop" 2>/dev/null)"; }
calls_now() { if [[ -f "$CALLS/implement" ]]; then wc -l <"$CALLS/implement" | tr -d ' '; else echo 0; fi; }
SPEND="$HERE/lib/always-on-spend.py"

echo "the parallel walker's always-on gate"

# Over the day's ceiling before the walk: stopped before the first wave.
pwalk_repo
L="$TMP/ao1/spend.jsonl"
python3 "$SPEND" observe "$L" e1 x big 11
CW_ALWAYS_ON_LEDGER="$L" CW_ALWAYS_ON_ENTRY=e1 prun --jobs 3
check "over the ceiling: the walk stops budget before any wave" "yes 0 0" \
  "$(stopped budget) $(calls_now) $(grep -c 'ORCHESTRATOR wave ' docs/journal/p.md || true)"

# The kill file: always-on-stop before the first wave.
pwalk_repo
mkdir -p "$TMP/ao2"
touch "$TMP/ao2/STOP"
CW_ALWAYS_ON_LEDGER="$TMP/ao2/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1 CW_ALWAYS_ON_STOP="$TMP/ao2/STOP" prun --jobs 3
check "the kill file: the walk stops always-on-stop, nothing dispatched" "yes 0" "$(stopped always-on-stop) $(calls_now)"

# Under the ceilings: the walk runs, and each member sees the ledger and entry.
pwalk_repo
for g in g1-a g2-b g3-c g4-d; do
  printf 'echo "$CW_ALWAYS_ON_ENTRY $CW_ALWAYS_ON_LEDGER" >"$CALLS/ao-%s"; echo %s >%s.txt; git add %s.txt && git commit -qm "feat(%s): %s"\n' \
    "$g" "$g" "${g#*-}" "${g#*-}" "$g" "${g#*-}" >"$CALLS/action-$g"
done
CW_ALWAYS_ON_LEDGER="$TMP/ao3/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1 prun --jobs 3
check "under the ceilings: the walk completes" "0 done done done done" \
  "$prc $(for g in g1-a g2-b g3-c g4-d; do status_of "$g"; done | paste -sd ' ' -)"
check "  ...each member carried the entry and the ledger" "e1 $TMP/ao3/spend.jsonl" "$(cat "$CALLS/ao-g2-b" 2>/dev/null)"

# A wave whose spend crosses the ceiling: the members' costs reach the ledger,
# and the next wave is refused before any of its members is dispatched. Wave 1
# is g1-a and g2-b (g3-c conflicts with g1-a, g4-d waits on both): each reports
# $6 on its thread, $12 in all, over the $10 day.
pwalk_repo
for g in g1-a g2-b; do
  printf 'echo %s >%s.txt; git add %s.txt && git commit -qm "feat(%s): %s"; printf "%%s\\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: haiku:t-%s" "IMPLEMENTER_STATUS: DONE" "IMPLEMENTER_MODEL: stub" "IMPLEMENTER_COST_USD: 6" "IMPLEMENTER_COST_BASIS: thread"; exit 0\n' \
    "$g" "${g#*-}" "${g#*-}" "$g" "${g#*-}" "$g" >"$CALLS/action-$g"
done
L4="$TMP/ao4/spend.jsonl"
CW_ALWAYS_ON_LEDGER="$L4" CW_ALWAYS_ON_ENTRY=e1 prun --jobs 3
check "a wave over the ceiling: its members' costs in the ledger" 12.0 \
  "$(python3 "$SPEND" sum "$L4" e1 | python3 -c 'import json,sys; print(round(json.load(sys.stdin)["entry_usd"], 2))')"
check "  ...the next wave refused budget, never dispatched" "yes no no" \
  "$(stopped budget) $(grep -qx g3-c "$CALLS/implement" && echo yes || echo no) $(grep -qx g4-d "$CALLS/implement" && echo yes || echo no)"
check "  ...wave 1 integrated" "done done" "$(status_of g1-a) $(status_of g2-b)"

echo
if [[ "$fails" -eq 0 ]]; then
  echo "parallel-walk-always-on-test: all passed"
else
  echo "parallel-walk-always-on-test: $fails failed"
  exit 1
fi
