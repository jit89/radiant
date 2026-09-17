#!/usr/bin/env bash
# Self-test: run-goal.sh refuses a goal whose blockers are not all done,
# whatever its own status says (F-12). Launchers are stubs.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
GOALS_PY="$HERE/goals.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-blockers-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" EVENTS_CACHE="$TMP/cache" STUBS="$TMP/stubs"
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
# No background auto-maintenance: a detached repack still writing .git/objects
# races the next scenario's rm -rf of the repo.
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
export DEEPSEEK_API_KEY=stub-not-a-key
unset ANTHROPIC_API_KEY
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

# --- goals.py blockers ------------------------------------------------------
# GOALS.example.md: g2-ack is blocked_by g1-store; g3-other has no blockers.
cp "$HERE/../GOALS.example.md" "$TMP/g.md"
check "unfinished blocker listed with status" "g1-store (ready)" \
  "$("$GOALS_PY" "$TMP/g.md" blockers g2-ack)"
check "no blockers: empty" "" "$("$GOALS_PY" "$TMP/g.md" blockers g3-other)"
"$GOALS_PY" "$TMP/g.md" set g1-store done >/dev/null
check "done blocker: empty" "" "$("$GOALS_PY" "$TMP/g.md" blockers g2-ack)"

# --- run-goal.sh ------------------------------------------------------------
HOUSE="$TMP/house"
mkdir -p "$HOUSE/scripts"
cp -R "$HERE/." "$HOUSE/scripts/"
stub() {
  printf '#!/usr/bin/env bash\necho "%s reached" >>"$STUBS"\n%s\n' "$1" "$2" \
    >"$HOUSE/scripts/$1"
  chmod +x "$HOUSE/scripts/$1"
}
stub deepseek-code.sh 'echo impl >impl.txt && git add impl.txt && git commit -qm "wip: impl"
printf "%s\n" "DEEPSEEK_RESULT: ok" "THREAD_ID: t1"'
stub claude-goal-review.sh 'printf "%s\n" "CLAUDE_REVIEW_RESULT: error (exit 1)" \
  "SESSION_ID: s1" "VERDICT: MISSING" "VERDICT_FILE: /dev/null"; exit 1'

# run_goal <g1-store status> <g2-ack status>
run_goal() {
  rm -rf "$TMP/repo" "$STUBS"
  mkdir -p "$TMP/repo/docs/journal" && cd "$TMP/repo"
  git init -q
  cp "$HERE/../GOALS.example.md" GOALS.md
  "$GOALS_PY" GOALS.md set g1-store "$1" >/dev/null
  "$GOALS_PY" GOALS.md set g2-ack "$2" >/dev/null
  printf '# Journal: example\n' >docs/journal/example.md
  git add -- GOALS.md docs/journal/example.md
  git commit -q -m base
  "$HOUSE/scripts/run-goal.sh" g2-ack >"$TMP/out" 2>&1 || true
  local stop
  stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)"
  reason="$(sed -n 's/^- reason: //p' "$stop" 2>/dev/null || true)"
  detail="$(sed -n 's/^- detail: //p' "$stop" 2>/dev/null || true)"
  dispatched="$(cat "$STUBS" 2>/dev/null | grep -c deepseek-code.sh || true)"
}
names() { [[ "$detail" == *"$1"* ]] && echo yes || echo "no: $detail"; }

run_goal ready ready
check "ready goal, blocker ready: gate" "gate" "$reason"
check "gate names blocker and status" "yes" "$(names 'g1-store (ready)')"
check "gate says how to proceed" "yes" "$(names 'blocked_by')"
check "nothing dispatched" "0" "$dispatched"

run_goal bounced in_progress
check "resume, blocker bounced: gate" "gate" "$reason"
check "gate names bounced blocker" "yes" "$(names 'g1-store (bounced)')"
check "resume dispatched nothing" "0" "$dispatched"

run_goal done ready
check "blocker done: dispatches" "1" "$dispatched"
check "blocker done: reaches review" "reviewer-error" "$reason"

if [[ "$fails" -eq 0 ]]; then
  echo "blockers: OK"
else
  echo "blockers: $fails FAILURE(S)" >&2
  exit 1
fi
