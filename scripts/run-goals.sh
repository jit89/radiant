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
  if git diff --cached --quiet; then
    return 0
  fi
  git commit -m "chore: orchestrator refresh" || {
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
  if git diff --cached --quiet; then
    return 0
  fi
  git commit -m "$msg" || {
    echo "failed to commit journal" >&2
    exit 1
  }
}

# TUI sessions export NO_COLOR=1; default the walk bar to ANSI anyway.
export GOALS_COLOR="${GOALS_COLOR:-1}"

print_status() {
  echo "=== graph ==="
  "$GOALS_PY" GOALS.md graph
  echo "=== progress ==="
  "$GOALS_PY" GOALS.md progress
}

while :; do
  "$GOALS_PY" GOALS.md refresh
  commit_goals
  print_status
  id="$("$GOALS_PY" GOALS.md frontier | head -n1)"
  if [[ -z "$id" || "$id" == "(empty)" ]]; then
    echo "=== walk-end ==="
    journal_line "## $(utc) — ORCHESTRATOR walk-end"
    commit_journal "chore: orchestrator walk-end"
    exit 0
  fi

  journal_line "## $(utc) — ORCHESTRATOR walk ${id}"
  commit_journal "chore: orchestrator walk ${id}"
  echo "=== walk ${id} ==="
  out="$(mktemp "${TMPDIR:-/tmp}/run-goals-XXXXXX.out")"
  set +e
  set -o pipefail
  "$RUN_GOAL" "$id" | tee "$out"
  rc=$?
  set +o pipefail
  set -e
  stop="$(grep -E '^STOP_FILE:' "$out" | tail -n1 || true)"
  rm -f "$out"
  if [[ "$rc" -ne 0 ]]; then
    [[ -n "$stop" ]] && echo "$stop"
    exit "$rc"
  fi
done
