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
# Defines git(): hooks and fsmonitor off, .git checked before each call.
# shellcheck disable=SC1091
source "$HERE/lib/git-guard.sh"
# shellcheck disable=SC1091
source "$HERE/lib/orch-files.sh"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "not a git repo" >&2
  exit 1
}
cd "$ROOT"
utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Arms the .git check in git(). The baseline is shared with run-goal.sh: a goal
# that stopped on tampering leaves it behind, and the walker checks it before
# its first commit — a planted filter would otherwise run on that commit.
git_meta_init || { echo "cannot locate the gitdir" >&2; exit 1; }

# walk_stop REASON DETAIL — nonzero stop that writes and commits nothing in the
# repo: the reasons that use it are ones where a commit is unsafe.
walk_stop() {
  local dir stop
  dir="$(mktemp -d "${TMPDIR:-/tmp}/run-goals-stop-XXXXXX")"
  chmod 700 "$dir"
  stop="$dir/stop.md"
  printf '# Stop: walk\n\n- reason: %s\n- detail: %s\n- utc: %s\n' "$1" "$2" "$(utc)" >"$stop"
  echo "=== $1 ==="
  events_append --event wake --severity error --reason "$1" --summary "walk $1: $2"
  echo "STOP_FILE: $stop"
  exit 1
}

# A .git change is a nonzero stop of its own, before any git command: with the
# check failed, the git() wrapper refuses to run, so nothing here is committed.
meta_stop() {
  git_meta_verify "$GIT_META_SAVED" && return 0
  walk_stop git-metadata-tamper ".git changed $1: ${GIT_META_CHANGED}— host git is off for this walk. Inspect with cat / ls -la, not git. Revert anything you did not make, then re-baseline: rm $GIT_META_SAVED"
}

[[ -f GOALS.md ]] || { echo "GOALS.md missing" >&2; exit 1; }
"$GOALS_PY" GOALS.md validate

JOURNAL="$("$GOALS_PY" GOALS.md meta | python3 -c 'import json,sys; print(json.load(sys.stdin).get("journal") or "")')"

# JOURNAL_EXPECT is the journal as this walker last saw it plus every line it
# has appended since: at commit time the file must be exactly that.
JOURNAL_EXPECT=""
journal_line() {
  [[ -n "$JOURNAL" && -f "$JOURNAL" ]] || return 0
  printf '\n%s\n' "$1" >>"$JOURNAL"
  printf '\n%s\n' "$1" >>"$JOURNAL_EXPECT"
}

# Nothing the walker did not write: check before the first write and after
# each goal (which commits its own), then start expecting from there.
# GOALS_INFLIGHT permits the in_progress a stopped goal leaves uncommitted,
# until the first refresh commit takes it, and --records permits that same
# goal's journal records. A walk runs one goal at a time, so there is one
# such goal or none; more than one is a state this walk did not make.
GOALS_INFLIGHT=""
orch_baseline() {
  local when="$1" jmode=--none goal="" inflight=() g
  GOALS_INFLIGHT=""
  if [[ "$when" == start ]]; then
    while IFS= read -r g; do
      [[ -z "$g" ]] || inflight+=("$g")
    done < <("$GOALS_PY" GOALS.md graph | awk '$2 == "in_progress" { print $1 }')
    if ((${#inflight[@]} > 1)); then
      walk_stop orchestration-files-dirty "GOALS.md marks ${#inflight[@]} goals in_progress (${inflight[*]}), and a walk runs one at a time. Finish or reset all but one, commit GOALS.md, then rerun."
    fi
    if ((${#inflight[@]} == 1)); then
      goal="${inflight[0]}"
      GOALS_INFLIGHT="$goal=*:in_progress"
      jmode=--records
    fi
  fi
  orch_preflight "$GOALS_INFLIGHT" "$jmode" "$goal" ||
    walk_stop orchestration-files-dirty "$([[ "$when" == start ]] || echo "after goal $when: ")$(orch_refusal)"
  if [[ -n "$JOURNAL" && -f "$JOURNAL" ]]; then
    cp "$JOURNAL" "$JOURNAL_EXPECT"
  fi
}

commit_goals() {
  local problems
  problems="$({ orch_staged_problems | grep '^GOALS.md:' || true; orch_goals_problems "*=blocked:ready,*=ready:blocked${GOALS_INFLIGHT:+,$GOALS_INFLIGHT}"; } | paste -sd ';' -)"
  [[ -z "$problems" ]] ||
    walk_stop orchestration-files-changed "GOALS.md not committed: $problems. Something other than the walker edited it; review, then commit or restore."
  GOALS_INFLIGHT=""
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
  if ! cmp -s "$JOURNAL" "$JOURNAL_EXPECT" || ! git diff --cached --quiet -- "$JOURNAL"; then
    walk_stop orchestration-files-changed "$JOURNAL not committed ($msg): it holds more than the walker appended. Review, then commit or restore."
  fi
  git add -- "$JOURNAL"
  if git diff --cached --quiet -- "$JOURNAL"; then
    return 0
  fi
  git commit -m "$msg" -- "$JOURNAL" || {
    echo "failed to commit journal" >&2
    exit 1
  }
}

meta_stop "since the last run in this repo"
JOURNAL_EXPECT="$(mktemp "${TMPDIR:-/tmp}/run-goals-journal-XXXXXX")"
trap 'rm -f "$JOURNAL_EXPECT"' EXIT
orch_baseline start

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

# Nothing left to run but goals are not all done — bounced, or blocked behind
# one that can't finish. Not a success: stop like a wake, keep the walk id
# (the restart after the fix is the same job).
walk_stuck() {
  local remaining="$1" dir stop
  dir="$(mktemp -d "${TMPDIR:-/tmp}/run-goals-stuck-XXXXXX")"
  chmod 700 "$dir"
  stop="$dir/stop.md"
  cat >"$stop" <<EOF
# Stop: walk

- reason: walk-stuck
- detail: nothing left to run; $(wc -l <<<"$remaining" | tr -d ' ') goal(s) not done
- utc: $(utc)
- unstick bounced: the Architect fixes the goal's spec or oracle and commits, then
  $GOALS_PY GOALS.md set <id> ready   (commit GOALS.md) and rerun run-goals
- unstick blocked: finish the blocker, or drop the edge from blocked_by in GOALS.md and commit

## Not done
$(sed 's/^/- /' <<<"$remaining")

## graph
$("$GOALS_PY" GOALS.md graph)
EOF
  echo "=== walk-stuck ==="
  journal_line "## $(utc) — ORCHESTRATOR walk-stuck $(paste -sd ';' - <<<"$remaining")"
  events_append --event wake --severity error --reason walk-stuck \
    --summary "walk-stuck: $(paste -sd ';' - <<<"$remaining")"
  commit_journal "chore: orchestrator walk-stuck"
  echo "STOP_FILE: $stop"
  exit 1
}

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
    remaining="$("$GOALS_PY" GOALS.md remaining)"
    [[ -z "$remaining" ]] || walk_stuck "$remaining"
    echo "=== walk-end ==="
    journal_line "## $(utc) — ORCHESTRATOR walk-end"
    events_append --event walk_end --severity info --summary "walk-end"
    commit_journal "chore: orchestrator walk-end"
    events_end_walk
    git_meta_forget
    exit 0
  fi

  journal_line "## $(utc) — ORCHESTRATOR walk ${id}"
  events_append --event walk --severity info --goal "$id" --summary "walk ${id}" \
    --payload "{$(events_pid_json)}"
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
  meta_stop "during goal $id"
  orch_baseline "$id"
done
