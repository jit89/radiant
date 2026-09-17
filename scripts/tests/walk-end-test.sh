#!/usr/bin/env bash
# Self-test: run-goals.sh exits 0 only when every goal is done. A frontier
# that empties with goals still bounced or blocked is a walk-stuck stop (D-01).
# run-goal.sh is a stub that marks its goal done; nothing calls a model.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
GOALS_PY="$HERE/goals.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-walkend-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" EVENTS_CACHE="$TMP/cache"
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
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
cat >"$HOUSE/scripts/run-goal.sh" <<'SH'
#!/usr/bin/env bash
echo "$1" >>"$HOME/dispatched"
"$(dirname "$0")/goals.py" GOALS.md set "$1" done >/dev/null
git commit -qm "done $1" -- GOALS.md
SH
chmod +x "$HOUSE/scripts/run-goal.sh"

# walk "<id>=<status> ...": fresh repo with those statuses, run the walker.
walk() {
  rm -rf "$TMP/repo" "$HOME/dispatched"
  mkdir -p "$TMP/repo/docs/journal" && cd "$TMP/repo"
  git init -q
  cp "$HERE/../GOALS.example.md" GOALS.md
  local pair
  for pair in $1; do
    "$GOALS_PY" GOALS.md set "${pair%%=*}" "${pair#*=}" >/dev/null
  done
  printf '# Journal: example\n' >docs/journal/example.md
  git add -A && git commit -q -m base
  rerun
}
rerun() {
  "$HOUSE/scripts/run-goals.sh" >"$TMP/out" 2>&1 && rc=0 || rc=$?
  last="$(tail -n1 "$TMP/out")"
  stop="$(sed -n 's/^STOP_FILE: //p' <<<"$last")"
  reason="$(sed -n 's/^- reason: //p' "$stop" 2>/dev/null || true)"
  # The "Not done" section only; the graph below it lists every goal.
  stuck="$(sed -n '/^## Not done$/,/^## graph$/p' "$stop" 2>/dev/null || true)"
}
journal_count() { grep -c "$1" docs/journal/example.md || true; }
names() { [[ "$stuck" == *"$1"* ]] && echo yes || echo "no"; }

# 1. Every goal finishes: success.
walk ""
check "all done: exit 0" "0" "$rc"
check "all done: no stop file" "" "$stop"
check "all done: walk-end journaled" "1" "$(journal_count 'ORCHESTRATOR walk-end')"

# 2. A bounced goal leaves its dependent blocked; the sibling still runs.
walk "g1-store=bounced"
check "bounced: nonzero" "yes" "$([[ $rc -ne 0 ]] && echo yes || echo no)"
check "bounced: independent sibling still walked" "g3-other" "$(cat "$HOME/dispatched")"
check "bounced: last line is STOP_FILE" "yes" "$([[ -n "$stop" && -f "$stop" ]] && echo yes || echo no)"
check "bounced: reason walk-stuck" "walk-stuck" "$reason"
check "bounced: names the bounced goal" "yes" "$(names 'g1-store: bounced')"
check "bounced: names what it blocks" "yes" "$(names 'g2-ack: blocked by g1-store (bounced)')"
check "bounced: done goals not listed" "no" "$(names 'g3-other')"
check "bounced: walk-stuck journaled" "1" "$(journal_count 'ORCHESTRATOR walk-stuck')"
check "bounced: no walk-end" "0" "$(journal_count 'ORCHESTRATOR walk-end')"
check "bounced: journal committed" "" "$(git status --porcelain docs/journal)"

# 3. Rerun without fixing: still stuck, and the same walk (no new walk-start).
rerun
check "rerun: still walk-stuck" "walk-stuck" "$reason"
check "rerun: walk id kept" "1" "$(journal_count 'ORCHESTRATOR walk-start')"

# 4. Fix the bounce and rerun: completes.
"$GOALS_PY" GOALS.md set g1-store ready >/dev/null
git commit -qm "architect: unbounce" -- GOALS.md
rerun
check "after fix: exit 0" "0" "$rc"
check "after fix: one walk for the whole job" "1" "$(journal_count 'ORCHESTRATOR walk-start')"

# 5. An in_progress goal behind a bounced blocker is stuck, not complete.
walk "g1-store=bounced g2-ack=in_progress g3-other=done"
check "deadlocked in_progress: walk-stuck" "walk-stuck" "$reason"
check "names the in_progress goal" "yes" "$(names 'g2-ack: in_progress, blocked by g1-store (bounced)')"

if [[ "$fails" -eq 0 ]]; then
  echo "walk-end: OK"
else
  echo "walk-end: $fails FAILURE(S)" >&2
  exit 1
fi
