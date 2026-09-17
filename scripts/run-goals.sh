#!/usr/bin/env bash
#
# run-goals.sh — walk GOALS.md. Calls run-goal.sh as a subprocess.
# Keys on exit code only. Stop file is payload, not a walk signal.
#
# Usage (from the target repo):
#   run-goals.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GOALS_PY="$HERE/goals.py"
RUN_GOAL="$HERE/run-goal.sh"
# shellcheck disable=SC1091
source "$HERE/lib/events.sh"
# Defines git(): hooks and fsmonitor off. run-goal.sh checks .git itself.
# shellcheck disable=SC1091
source "$HERE/lib/git-guard.sh"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "not a git repo" >&2
  exit 1
}
cd "$ROOT"

[[ -f GOALS.md ]] || { echo "GOALS.md missing" >&2; exit 1; }
"$GOALS_PY" GOALS.md validate

JOURNAL="$("$GOALS_PY" GOALS.md meta | python3 -c 'import json,sys; print(json.load(sys.stdin).get("journal") or "")')"

utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

journal_line() {
  [[ -n "$JOURNAL" && -f "$JOURNAL" ]] || return 0
  printf '\n%s\n' "$1" >>"$JOURNAL"
}

commit_goals() {
  git add -- GOALS.md
  if git diff --cached --quiet -- GOALS.md; then
    return 0
  fi
  # Pathspec commit: anything else the user staged stays staged, uncommitted.
  git commit -m "chore: orchestrator refresh" -- GOALS.md || {
    echo "failed to commit GOALS.md after refresh" >&2
    exit 1
  }
}

# Journal appends are Orchestrator records. Commit them before run-goal.sh:
# its fresh-start gate treats an uncommitted journal as unexpected dirt.
commit_journal() {
  local msg="${1:-chore: orchestrator journal}"
  [[ -n "$JOURNAL" && -f "$JOURNAL" ]] || return 0
  git add -- "$JOURNAL"
  if git diff --cached --quiet -- "$JOURNAL"; then
    return 0
  fi
  git commit -m "$msg" -- "$JOURNAL" || {
    echo "failed to commit journal" >&2
    exit 1
  }
}

events_ensure_walk
events_journal_walk_start
if [[ "${EVENTS_MINTED:-0}" -eq 1 ]]; then
  commit_journal "chore: orchestrator walk-start"
fi

RG_PID=""
STOP_PTR=""

print_child_stop() {
  local stop
  stop="$(cat "$STOP_PTR" 2>/dev/null || true)"
  [[ -n "$stop" ]] && echo "STOP_FILE: $stop"
  rm -f "$STOP_PTR"
  return 0
}

# INT/TERM: stop the running goal (it records its own stop), reprint its stop
# file, end the walk nonzero. A child started with & ignores terminal INT, so
# it is always told with TERM.
on_signal() {
  local sig="$1" code="$2"
  trap - INT TERM
  if [[ -n "$RG_PID" ]]; then
    kill -TERM "$RG_PID" 2>/dev/null || true
    wait "$RG_PID" 2>/dev/null || true
    print_child_stop
  fi
  echo "=== walk interrupted (SIG${sig}) ===" >&2
  exit "$code"
}
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

print_status() {
  echo "=== graph ==="
  "$GOALS_PY" GOALS.md graph
}

while :; do
  "$GOALS_PY" GOALS.md refresh
  commit_goals
  print_status
  id="$("$GOALS_PY" GOALS.md frontier | head -n1)"
  if [[ -z "$id" || "$id" == "(empty)" ]]; then
    echo "=== walk-end ==="
    journal_line "## $(utc) — ORCHESTRATOR walk-end"
    events_append --event walk_end --severity info --summary "walk-end"
    commit_journal "chore: orchestrator walk-end"
    events_end_walk
    exit 0
  fi

  journal_line "## $(utc) — ORCHESTRATOR walk ${id}"
  events_append --event walk --severity info --goal "$id" --summary "walk ${id}"
  commit_journal "chore: orchestrator walk ${id}"
  echo "=== walk ${id} ==="
  STOP_PTR="$(mktemp "${TMPDIR:-/tmp}/run-goals-stop-XXXXXX")"
  # Background + wait, not a foreground call: a signal to the walker is
  # handled now, and $RG_PID is the goal itself to pass it on to.
  RUN_GOAL_STOP_PTR="$STOP_PTR" "$RUN_GOAL" "$id" &
  RG_PID=$!
  rc=0
  wait "$RG_PID" || rc=$?
  RG_PID=""
  if [[ "$rc" -ne 0 ]]; then
    print_child_stop
    exit "$rc"
  fi
  rm -f "$STOP_PTR"
done
