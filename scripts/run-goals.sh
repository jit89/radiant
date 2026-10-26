#!/usr/bin/env bash
#
# run-goals.sh — walk GOALS.md. Calls run-goal.sh as a subprocess.
# Keys on exit code only. Stop file is payload, not a walk signal.
#
# Usage (from the target repo):
#   run-goals.sh              one goal at a time, in the main checkout
#   run-goals.sh --jobs N     N from 2 to 4: fork-join waves, each goal in its
#                             own worktree (lib/wave-walk.sh)

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
# shellcheck disable=SC1091
source "$HERE/lib/cache.sh"
cw_keep_awake

JOBS=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs)
      [[ $# -ge 2 && "$2" =~ ^[1-4]$ ]] || { echo "--jobs takes an integer from 1 to 4" >&2; exit 2; }
      JOBS="$2"
      shift 2
      ;;
    *)
      echo "usage: run-goals.sh [--jobs N]   (N from 1 to 4)" >&2
      exit 2
      ;;
  esac
done

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
# Stop folders live under ~/.cache/claude-coding-workflow/runs/ (macOS clears
# idle $TMPDIR entries); entries past CW_PRUNE_DAYS go first.
cw_cache_init || { echo "cannot create $CW_CACHE" >&2; exit 1; }
cw_prune

# walk_stop REASON DETAIL — nonzero stop that writes and commits nothing in the
# repo: the reasons that use it are ones where a commit is unsafe.
walk_stop() {
  local dir stop
  dir="$(mktemp -d "$CW_CACHE/runs/run-goals-stop-XXXXXX")"
  chmod 700 "$dir"
  stop="$dir/stop.md"
  printf '# Stop: walk\n\n- reason: %s\n- detail: %s\n- utc: %s\n' "$1" "$2" "$(utc)" >"$stop"
  echo "=== $1 ==="
  events_append --event wake --severity error --reason "$1" --summary "walk $1: $2"
  echo "STOP_FILE: $stop"
  exit 1
}

# ao_config_check — under the always-on supervisor, before the walk records
# anything: the legacy implementer prints no cost (run-goal.sh refuses it too,
# as a backstop), so the walk stops with its own reason, no record, no wave.
ao_config_check() {
  [[ -n "${CW_ALWAYS_ON_LEDGER:-}" ]] || return 0
  [[ "${IMPLEMENTER:-claude}" != codex ]] ||
    walk_stop always-on-config "IMPLEMENTER=codex prints no cost, so it cannot run under the always-on supervisor; unset IMPLEMENTER"
}

# ao_gate — under the always-on supervisor (CW_ALWAYS_ON_LEDGER set), before a
# goal or a wave is dispatched: the kill file stops the walk always-on-stop,
# a spend ceiling (or a ledger it cannot read) stops it budget; both are class
# A to the supervisor (docs/features/always-on, step 9). No effect otherwise.
ao_gate() {
  [[ -n "${CW_ALWAYS_ON_LEDGER:-}" ]] || return 0
  local out rc=0 ceil=()
  [[ -z "${CW_ALWAYS_ON_DAY:-}" ]] || ceil+=(--day "$CW_ALWAYS_ON_DAY")
  [[ -z "${CW_ALWAYS_ON_WALK:-}" ]] || ceil+=(--walk "$CW_ALWAYS_ON_WALK")
  [[ -z "${CW_ALWAYS_ON_WEEK:-}" ]] || ceil+=(--week "$CW_ALWAYS_ON_WEEK")
  out="$(python3 "$HERE/lib/always-on-spend.py" check "$CW_ALWAYS_ON_LEDGER" "${CW_ALWAYS_ON_ENTRY:-}" \
    --stop "${CW_ALWAYS_ON_STOP:-$HOME/.config/cw-always-on/STOP}" "${ceil[@]+"${ceil[@]}"}" 2>&1)" || rc=$?
  case "$rc" in
    0) return 0 ;;
    4) walk_stop always-on-stop "$out" ;;
    *) walk_stop budget "${out:-the spend check failed (rc=$rc)}" ;;
  esac
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
ao_config_check
JOURNAL_EXPECT="$(mktemp "${TMPDIR:-/tmp}/run-goals-journal-XXXXXX")"
trap 'rm -f "$JOURNAL_EXPECT"' EXIT

# A parallel walk's worktrees: ~/.cache/claude-coding-workflow/worktrees/<id>/,
# <id> hashed from the main checkout's physical path (lib/wave-walk.sh too).
REPO_ID="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:16])' "$(pwd -P)")"

# A parallel walk that stopped leaves goals in their own worktrees; this
# one-at-a-time loop would implement them again in the main checkout.
parallel_left=()
while IFS= read -r g; do
  [[ -n "$g" ]] || continue
  if git show-ref --verify --quiet "refs/heads/cw/$g" || [[ -e "$CW_CACHE/worktrees/$REPO_ID/$g" ]]; then
    parallel_left+=("$g")
  fi
done < <("$GOALS_PY" GOALS.md graph | awk '$2 == "in_progress" { print $1 }')
if [[ "$JOBS" -eq 1 ]] && ((${#parallel_left[@]})); then
  walk_stop orchestration-files-dirty "a parallel walk stopped here: ${parallel_left[*]} in_progress with a cw/<goal> branch or worktree. Rerun with --jobs N (N from 2 to 4), which re-attaches them."
fi

# --jobs N > 1 does its own start (lib/wave-walk.sh): it commits every status
# itself, so it allows no in-flight edit and as many in_progress goals as it
# left worktrees for.
if [[ "$JOBS" -eq 1 ]]; then
  orch_baseline start

  events_ensure_walk
  events_journal_walk_start
  if [[ "${EVENTS_MINTED:-0}" -eq 1 ]]; then
    commit_journal "chore: orchestrator walk-start"
  fi
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
  dir="$(mktemp -d "$CW_CACHE/runs/run-goals-stuck-XXXXXX")"
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

# --- mutation checks (docs/features/mutation-checks) ---------------------
# The committed journal's length when this invocation started: strict mode
# counts only the survivors recorded after it, so a rerun carries on.
MUT_SINCE="$(git show "HEAD:$JOURNAL" 2>/dev/null | wc -c | tr -d ' ')"
MUT_SINCE="${MUT_SINCE:-0}"

# mutation_survivors MODE — the `mutations` records with survivors in the
# committed journal, "<goal> survived=<n>" a line: MODE "since" those after
# MUT_SINCE, MODE "walk" those after this walk's walk-start. (A heredoc: the
# em dash must not depend on the locale.)
mutation_survivors() {
  local f
  f="$(mktemp "${TMPDIR:-/tmp}/cw-mut-journal-XXXXXX")"
  git show "HEAD:$JOURNAL" >"$f" 2>/dev/null || : >"$f"
  python3 - "$1" "$MUT_SINCE" "${WALK_ID:-}" "$f" <<'PY' || true
import re, sys
mode, since, wid, path = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
data = open(path, "rb").read()
if mode == "since":
    data = data[since:]
text = data.decode("utf-8", "replace")
out = []
for line in text.split("\n"):
    if mode == "walk" and re.match(r"^## \S+ \u2014 ORCHESTRATOR walk-start walk_id=" + re.escape(wid) + r"(\s|$)", line):
        out = []
    m = re.match(r"^## \S+ \u2014 ORCHESTRATOR mutations (\S+) r\d+ .*\bsurvived=([1-9]\d*)\b", line)
    if m:
        out.append(f"{m.group(1)} survived={m.group(2)}")
print("\n".join(out))
PY
  rm -f "$f"
}

# mutation_walk_summary — one line per goal of this walk with survivors.
mutation_walk_summary() {
  local l
  while IFS= read -r l; do
    [[ -z "$l" ]] || echo "mutations survived the oracle: $l (the diffs: ~/.cache/claude-coding-workflow/run-goal-${l%% *}/mutation-*.diff)"
  done < <(mutation_survivors walk)
}

# mutation_gaps_stop — CW_MUTATION_GAPS=stop: survivors recorded in this
# invocation stop the walk after their goals landed (oracle-gap).
mutation_gaps_stop() {
  local gaps
  [[ "${CW_MUTATION_GAPS:-}" == stop ]] || return 0
  gaps="$(mutation_survivors since | paste -sd ',' -)"
  [[ -n "$gaps" ]] || return 0
  walk_stop oracle-gap "mutations survived the oracle (CW_MUTATION_GAPS=stop): $gaps. Those goals are done; each kept diff is in ~/.cache/claude-coding-workflow/run-goal-<goal>/mutation-*.diff. Strengthen the oracle, then rerun."
}

print_status() {
  echo "=== graph ==="
  "$GOALS_PY" GOALS.md graph
}

if [[ "$JOBS" -gt 1 ]]; then
  # shellcheck disable=SC1091
  source "$HERE/lib/wave-walk.sh"
  exit 1  # wave-walk.sh exits itself; reaching here is a bug
fi

while :; do
  "$GOALS_PY" GOALS.md refresh
  commit_goals
  print_status
  id="$("$GOALS_PY" GOALS.md frontier | head -n1)"
  if [[ -z "$id" || "$id" == "(empty)" ]]; then
    remaining="$("$GOALS_PY" GOALS.md remaining)"
    [[ -z "$remaining" ]] || walk_stuck "$remaining"
    echo "=== walk-end ==="
    mutation_walk_summary
    journal_line "## $(utc) — ORCHESTRATOR walk-end"
    events_append --event walk_end --severity info --summary "walk-end"
    commit_journal "chore: orchestrator walk-end"
    events_end_walk
    git_meta_forget
    exit 0
  fi

  ao_gate
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
  mutation_gaps_stop
done
