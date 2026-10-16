#!/usr/bin/env bash
#
# run-goal.sh — host Orchestrator for one GOALS.md id.
# The implementer (Haiku 5.5, DeepSeek on a refusal) implements, this script
# assesses, Opus reviews, this script routes. Models never read each other's
# raw output.
#
# Usage (from the target repo):
#   run-goal.sh <goal-id>
#   run-goal.sh --worktree <main-root> --base <sha> --result <file> <goal-id>
#                                          (run-goals.sh --jobs N only)
#
# Worktree mode: the goal runs in its own fresh worktree of a parallel walk
# (docs/features/parallel-walker/PLAN.md, Amendment 3). It writes no status
# (the walker is the single writer of GOALS.md; status is read from
# <main-root>/GOALS.md), never resumes, and exits 0 done, 3 bounced, 1 any
# other stop. On done it writes "reviewed=<sha>" and "done=<sha>" to <file>:
# the tip the reviewer judged and the journal-only commit on top of it.
#
# Exit 0 = goal DONE. Any other exit is a wake; last line is STOP_FILE:.
# Do not fork launcher prompts.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOUSE="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/dotenv.sh"
# shellcheck disable=SC1091
source "$HERE/lib/events.sh"
# shellcheck disable=SC1091
source "$HERE/lib/findings.sh"
# Defines git(): every git call below runs with hooks and fsmonitor off.
# shellcheck disable=SC1091
source "$HERE/lib/git-guard.sh"
# shellcheck disable=SC1091
source "$HERE/lib/orch-files.sh"
# shellcheck disable=SC1091
source "$HERE/lib/cache.sh"
# run_step, proof_exec, tree_snapshot, proof_moved: shared with run-goals.sh.
# shellcheck disable=SC1091
source "$HERE/lib/proof.sh"

GOALS_PY="$HERE/goals.py"
# IMPLEMENTER=claude (default): claude-implement.sh, Haiku 5.5 with a DeepSeek
# fallback on a refusal, both in the Claude Code harness. IMPLEMENTER=codex: the
# legacy DeepSeek-in-Codex launcher, kept until the new one has shipped goals.
IMPLEMENTER="${IMPLEMENTER:-claude}"
case "$IMPLEMENTER" in
  claude) IMPL_LAUNCHER="$HERE/claude-implement.sh" IMPL_KEY=IMPLEMENTER_RESULT ;;
  codex) IMPL_LAUNCHER="$HERE/deepseek-code.sh" IMPL_KEY=DEEPSEEK_RESULT ;;
  *)
    echo "IMPLEMENTER must be claude or codex, not '$IMPLEMENTER'" >&2
    exit 2
    ;;
esac
REVIEWER="$HERE/claude-goal-review.sh"

MAX_FIX_ROUNDS="${MAX_FIX_ROUNDS:-3}"
IMPL_SECS="${IMPLEMENTER_TIMEOUT:-${DEEPSEEK_TIMEOUT:-1200}}"
REVIEW_SECS="${CLAUDE_REVIEW_TIMEOUT:-600}"
PROOF_SECS="${PROOF_TIMEOUT:-600}"

GOAL_ID=""
# Worktree mode: the main checkout of the parallel walk (empty otherwise), the
# wave base the worktree was cut from, and the walker's result file.
WT_MAIN=""
WT_BASE_SHA=""
WT_RESULT=""
# HEAD when the review diff was cut: the only tip a DONE can stand for.
REVIEWED_HEAD=""
# Exit status of a wake: 1, or 3 for a bounce in worktree mode.
WAKE_RC=1
# --deny-write arguments for the implementer launcher (worktree mode).
DENY_ARGS=()
RUN_DIR=""
STOP_FILE=""
ART_DIR=""
JOURNAL=""
ORACLE=""
PROOF=""
PLAN_PATH=""
PLAN_FROZEN=""
BASE_SHA=""
THREAD_ID=""
SESSION_ID=""
ROUND=0
STOP_WRITTEN=0
LAST_IMPL=""
IMPL_MODEL=""
IMPL_FALLBACK=""
IMPL_STATUS=""
LAST_VERDICT=""
LAST_CLAUDE=""
VERDICT_FILE=""
PROOF_FILE=""
PROOF_EXIT=""
RETURN_HANDOFF=""
IMPL_LOG=""
IMPL_ERR=""
CLAUDE_META_SAVED=""
FIX_HASH=""
FIX_COUNT_N=0
PHASE="gate"
CHILD_PID=""
PENDING_FIX_ROUND=""
PENDING_FIX_HASH=""
PENDING_FIX_SOURCE=""
PENDING_FIX_HEAD=""
PENDING_FIX_STUCK=0
# The fix the round now running answers: its source (review|proof) and, for a
# proof fix, the HEAD it was issued at (the no-progress rule, PLAN step 2).
CUR_FIX_SOURCE=""
CUR_FIX_HEAD=""
# 1 on a resume after a proof fix's no-progress stop: prove before dispatching.
PROOF_FIRST=0
# The proof's private TMPDIR in worktree mode (parallel goals side by side);
# empty otherwise, which leaves the proof's environment as it always was.
PROOF_TMP=""
# 1 once GOALS.md and the journal hold nothing this workflow did not write;
# -1 when they were refused (then the stop leaves them, and HEAD, untouched).
ORCH_FILES_OK=0

usage() {
  echo "usage: run-goal.sh [--worktree <main-root>] <goal-id>" >&2
  exit 2
}

utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

die_gate() {
  echo "GATE: $*" >&2
  if [[ -n "${RUN_DIR:-}" && -d "${RUN_DIR:-}" ]]; then
    wake "gate" "$*"
  fi
  exit 1
}

on_exit() {
  local ec=$?
  trap - EXIT INT TERM
  stop_child
  if [[ "$ec" -ne 0 && "$STOP_WRITTEN" -eq 0 && -n "$RUN_DIR" ]]; then
    stop_unplanned "trap" "exit $ec during ${PHASE}"
    STOP_WRITTEN=1
  fi
  if [[ -n "$STOP_FILE" && -f "$STOP_FILE" ]]; then
    echo "STOP_FILE: $STOP_FILE"
    # run-goals.sh reads the path here to reprint it as its own last line.
    if [[ -n "${RUN_GOAL_STOP_PTR:-}" ]]; then
      printf '%s\n' "$STOP_FILE" >"$RUN_GOAL_STOP_PTR" || true
    fi
  fi
  exit "$ec"
}

# INT/TERM: bash runs this as soon as a `wait` is interrupted. Take the running
# step down, record the stop, and never let the exit status read as success.
on_signal() {
  local sig="$1" code="$2"
  trap - INT TERM
  stop_child
  if [[ "$STOP_WRITTEN" -eq 0 && -n "$RUN_DIR" ]]; then
    stop_unplanned "interrupted" "SIG${sig} during ${PHASE}"
  fi
  exit "$code"
}

# A stop no check led to (signal, crash) can land mid-step, before the .git
# check that follows it. Check first — no git runs until then — and let a
# change be the reason: the stop record's own git calls are skipped.
stop_unplanned() {
  local reason="$1" detail="$2"
  if [[ "$GIT_META_TAINTED" -eq 1 ]] ||
    { [[ -n "$GIT_META_SAVED" ]] && ! git_meta_verify "$GIT_META_SAVED"; }; then
    reason="git-metadata-tamper"
    detail="${detail}; .git changed: ${GIT_META_CHANGED}— $(git_meta_help)"
  fi
  write_stop "$reason" "$detail" || true
  record_wake "$reason" || true
}

git_meta_help() {
  echo "host git is off for this run. Inspect with cat / ls -la, not git. Revert anything you did not make, then re-baseline: rm $GIT_META_SAVED"
}

# TERM the running step (its timeout wrapper stops the whole process group),
# KILL it if it outlives the wrapper's own grace period.
stop_child() {
  [[ -n "$CHILD_PID" ]] || return 0
  local pid="$CHILD_PID" i
  CHILD_PID=""
  kill -TERM "$pid" 2>/dev/null || return 0
  for i in $(seq 80); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

write_stop() {
  local reason="$1"
  local detail="${2:-}"
  STOP_FILE="${RUN_DIR:-${TMPDIR:-/tmp}}/stop.md"
  mkdir -p "$(dirname "$STOP_FILE")"
  cat >"$STOP_FILE" <<EOF
# Stop: ${GOAL_ID:-?}

- reason: ${reason}
- detail: ${detail}
- utc: $(utc)
- fix_count / round: ${ROUND}
- ${IMPL_KEY}: ${LAST_IMPL:-}
- IMPLEMENTER_STATUS: ${IMPL_STATUS:-}
- IMPLEMENTER_MODEL: ${IMPL_MODEL:-}${IMPL_FALLBACK:+ (fallback: ${IMPL_FALLBACK})}
- CLAUDE_REVIEW_RESULT: ${LAST_CLAUDE:-}
- VERDICT: ${LAST_VERDICT:-}
- VERDICT_FILE: ${VERDICT_FILE:-}
- THREAD_ID: ${THREAD_ID:--}
- SESSION_ID: ${SESSION_ID:--}
- BASE_SHA: ${BASE_SHA:-}
- HEAD: $(git rev-parse HEAD 2>/dev/null || echo none)
- proof: ${PROOF_FILE:-}
- proof_exit: ${PROOF_EXIT:-}
- RETURN_HANDOFF: ${RETURN_HANDOFF:-}
- LOG: ${IMPL_LOG:-}
- stderr: ${IMPL_ERR:-}
- artifacts: ${ART_DIR:-}
- unstick status: $HOUSE/scripts/goals.py GOALS.md set ${GOAL_ID:-id} ready
  or: $HOUSE/scripts/goals.py GOALS.md set ${GOAL_ID:-id} bounced
  or (inline done-refused): $HOUSE/scripts/goals.py GOALS.md set ${GOAL_ID:-id} done
- unstick tree: git status --porcelain
  git restore -- <paths>   # or commit / stash the in-flight cycle

## git status --porcelain
$(git status --porcelain 2>/dev/null || echo "(git skipped or unavailable)")
EOF
  STOP_WRITTEN=1
}

# One journal line + JSONL row. Commit the journal (no recurse into wake).
record_wake() {
  local reason="$1"
  local sev=error
  case "$reason" in
    rate_limited|reviewer-rate-limited) sev=warning ;;
  esac
  # The journal is written only once it holds nothing this workflow did not
  # write (checked here if the stop came before the run's own check). Tainted:
  # no git at all, so journal the line and leave it uncommitted.
  local journal_ok=0
  if [[ -n "${JOURNAL:-}" && -f "${JOURNAL}" ]]; then
    if [[ "$ORCH_FILES_OK" -eq 1 ]]; then
      journal_ok=1
    elif [[ "$ORCH_FILES_OK" -eq 0 && "$GIT_META_TAINTED" -eq 0 ]] && tracked_in_head "$JOURNAL" &&
      [[ -z "$(orch_staged_problems | grep -F "$JOURNAL:" || true; orch_journal_problems --none)" ]]; then
      journal_ok=1
    fi
  fi
  if [[ "$journal_ok" -eq 1 ]]; then
    journal_line "## $(utc) — ORCHESTRATOR wake ${GOAL_ID:-?} r${ROUND} reason=${reason}"
  fi
  events_append --event wake --severity "$sev" \
    --goal "${GOAL_ID:-}" --round "${ROUND}" --reason "$reason" \
    --verdict "${LAST_VERDICT:-}" --base-sha "${BASE_SHA:-}" \
    --summary "wake ${GOAL_ID:-?} r${ROUND} reason=${reason}"
  if [[ "$journal_ok" -eq 1 && "$GIT_META_TAINTED" -eq 0 ]]; then
    orch_commit_journal "chore(${GOAL_ID:-?}): orchestrator wake ${reason}" ||
      echo "failed to commit wake journal line" >&2
  fi
  return 0
}

wake() {
  write_stop "$1" "${2:-}"
  record_wake "$1"
  exit "$WAKE_RC"
}

succeed() {
  STOP_WRITTEN=1
  STOP_FILE=""
  git_meta_forget
  [[ -z "$CLAUDE_META_SAVED" ]] || rm -f "$CLAUDE_META_SAVED"
  # Nothing here is needed once the goal lands; verdicts and fix handoffs
  # were already copied to ART_DIR. On a wake we keep RUN_DIR — it is the
  # evidence the stop file points at.
  if [[ "${KEEP_RUN_DIR:-0}" != "1" && -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
    case "$RUN_DIR" in
      */run-goal-*) rm -rf "$RUN_DIR" ;;
    esac
  fi
  exit 0
}

# Value of the last "KEY: value" line in FILE, or empty. Never fails: a
# missing line is for the caller to classify, and under pipefail a no-match
# grep would otherwise abort the script as reason=trap before it can.
kv() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  { grep -E "^${key}:" "$file" || true; } | tail -n1 | sed -E "s/^${key}:[[:space:]]*//"
}

# kv, but keep the current value of VAR when the file has none — a launcher
# that died before printing its id must not erase the one to resume.
kv_keep() {
  local var="$1" val
  val="$(kv "$2" "$3")"
  if [[ -n "$val" ]]; then
    printf -v "$var" '%s' "$val"
  fi
}

is_non_command_proof() {
  case "${1:-}" in
    "" | true | inline | "(case table)") return 0 ;;
    *) return 1 ;;
  esac
}

# Wake if .git config/hooks/info differ from the saved manifest. git_meta_verify
# has already disabled host git by then, so the wake path runs none.
verify_git_meta() {
  git_meta_verify "$GIT_META_SAVED" && gitfile_verify && return 0
  wake "git-metadata-tamper" "changed $1: ${GIT_META_CHANGED}— $(git_meta_help)"
}

claude_meta_snapshot() {
  python3 "$HERE/lib/claude-meta.py"
}

# Paths under .claude/ or .mcp.json that differ from the baseline, comma-joined.
claude_meta_changed() {
  { diff "$CLAUDE_META_SAVED" <(claude_meta_snapshot) || true; } |
    sed -n 's/^[<>] \([^	][^	]*\).*/\1/p' | sort -u | paste -sd ',' -
}

# Wake if .claude/ or .mcp.json moved off the baseline (lib/claude-meta.py says
# why). Like the .git baseline, it outlives a stop, so a resume is held to it
# too. Nothing is restored: a planted hook is the person's to look at.
verify_claude_meta() {
  local changed
  changed="$(claude_meta_changed)"
  [[ -n "$changed" ]] || return 0
  wake "claude-config-tamper" "changed $1: ${changed} — Claude Code configuration (hooks, MCP servers, settings) that the next session in this repo would load. Inspect it with cat / ls -la before opening Claude Code here and revert what you did not make. If the change is yours, re-baseline: rm $CLAUDE_META_SAVED"
}

# Contract drift since BASE_SHA: the plan, this goal's file oracle,
# tests/acceptance/, and all of GOALS.md except this goal's status. Sets
# CONTRACT_PATHS and one-line lists, one per git state, each with its own
# remedy (contract_report): CONTRACT_COMMITTED (commits after BASE_SHA, listed
# in CONTRACT_COMMITS), CONTRACT_STAGED (HEAD → index), CONTRACT_UNSTAGED
# (index → worktree), CONTRACT_UNTRACKED, and CONTRACT_IGNORED (untracked but
# matching .gitignore — an artifact anywhere else, tampering here). Staging an
# edit and restoring the worktree copy hides it from a worktree-only
# comparison, and a later commit still publishes what the index holds. Needs
# BASE_SHA, PLAN_PATH and ORACLE from goals-base.md, and RUN_DIR.
contract_drift() {
  local drift goals_commit=0
  CONTRACT_PATHS=(tests/acceptance "$PLAN_PATH")
  if [[ "$ORACLE" != "inline" && -n "$ORACLE" ]]; then
    CONTRACT_PATHS+=("$ORACLE")
  fi
  CONTRACT_COMMITTED="$(git diff --name-only "$BASE_SHA" HEAD -- "${CONTRACT_PATHS[@]}" || true)"
  CONTRACT_STAGED="$(git diff --cached --name-only HEAD -- "${CONTRACT_PATHS[@]}" || true)"
  # Index against worktree, not HEAD against worktree: a change that is only
  # staged must not also be reported as an edit sitting in the worktree.
  CONTRACT_UNSTAGED="$(git diff --name-only -- "${CONTRACT_PATHS[@]}" || true)"
  CONTRACT_UNTRACKED="$(git ls-files --others --exclude-standard -- "${CONTRACT_PATHS[@]}" || true)"
  # .gitignore makes a file an artifact outside the contract; inside it, an
  # ignored file is invisible to the diff the reviewer reads, so it is drift.
  CONTRACT_IGNORED="$(git ls-files --others --ignored --exclude-standard -- "${CONTRACT_PATHS[@]}" || true)"
  # HEAD never carries this goal's status (committed only on done/bounced),
  # so HEAD's GOALS.md must match the base apart from it.
  # GOALS.md as the index holds it: staged is neither HEAD nor the worktree.
  if git cat-file -e :GOALS.md 2>/dev/null; then
    git show :GOALS.md >"$RUN_DIR/goals-index.md"
    if ! drift="$(goals_drift "$RUN_DIR/goals-index.md")"; then
      CONTRACT_STAGED="${CONTRACT_STAGED}"$'\n'"GOALS.md ($drift)"
    fi
  fi
  git show HEAD:GOALS.md >"$RUN_DIR/goals-head.md"
  if ! drift="$(goals_drift "$RUN_DIR/goals-head.md")"; then
    CONTRACT_COMMITTED="${CONTRACT_COMMITTED}"$'\n'"GOALS.md ($drift)"
    goals_commit=1
  fi
  if ! drift="$(goals_drift GOALS.md)"; then
    CONTRACT_UNSTAGED="${CONTRACT_UNSTAGED}"$'\n'"GOALS.md ($drift)"
  fi
  CONTRACT_COMMITTED="$(sed '/^$/d' <<<"$CONTRACT_COMMITTED" | sort -u | paste -sd ',' -)"
  CONTRACT_STAGED="$(sed '/^$/d' <<<"$CONTRACT_STAGED" | sort -u | paste -sd ',' -)"
  CONTRACT_UNSTAGED="$(sed '/^$/d' <<<"$CONTRACT_UNSTAGED" | sort -u | paste -sd ',' -)"
  CONTRACT_UNTRACKED="$(sed '/^$/d' <<<"$CONTRACT_UNTRACKED" | sort -u | paste -sd ',' -)"
  CONTRACT_IGNORED="$(sed '/^$/d' <<<"$CONTRACT_IGNORED" | sort -u | paste -sd ',' -)"
  CONTRACT_COMMITS=""
  if [[ -n "$CONTRACT_COMMITTED" ]]; then
    local log_paths=("${CONTRACT_PATHS[@]}")
    [[ "$goals_commit" -eq 0 ]] || log_paths+=(GOALS.md)
    CONTRACT_COMMITS="$(git log --format=%h "$BASE_SHA"..HEAD -- "${log_paths[@]}" | paste -sd ' ' -)"
  fi
}

# goals_drift FILE — print why FILE (a GOALS.md copy) is drift against the
# base, and return 1; nothing and 0 when it is not. Outside worktree mode only
# this goal's status may differ (status-only-id). In worktree mode the walker
# owns every status, so any difference at all is drift.
goals_drift() {
  if [[ -n "$WT_MAIN" ]]; then
    cmp -s "$1" "$RUN_DIR/goals-base.md" && return 0
    echo "differs from BASE_SHA (worktree mode: the walker writes every status)"
    return 1
  fi
  local out
  out="$("$GOALS_PY" "$1" status-only-id "$GOAL_ID" "$RUN_DIR/goals-base.md" 2>&1)" && return 0
  sed 1d <<<"$out" | paste -sd ';' -
  return 1
}

# True when any category of contract drift has something in it.
contract_any() {
  [[ -n "${CONTRACT_COMMITTED}${CONTRACT_STAGED}${CONTRACT_UNSTAGED}${CONTRACT_UNTRACKED}${CONTRACT_IGNORED}" ]]
}

# When every ignored contract path is Python bytecode, say so: the usual cause is
# a test run outside the host's PYTHONDONTWRITEBYTECODE (an Architect's own run,
# or a tool that ignores the variable), not a planted file (D-09).
contract_ignored_hint() {
  local p
  [[ -n "$CONTRACT_IGNORED" ]] || return 0
  while IFS= read -r p; do
    [[ "$p" == */__pycache__/*.pyc ]] || return 0
  done < <(tr ',' '\n' <<<"$CONTRACT_IGNORED")
  printf '%s' " — all Python bytecode caches: a test run without PYTHONDONTWRITEBYTECODE=1 (e.g. the Architect's own pytest before dispatch) wrote them; delete the __pycache__ directories and resume"
}

# Every category that has something, each with the command that undoes it.
# One place: a new category is a line here, not a new string to concatenate
# into four branches.
contract_report() {
  local out=""
  [[ -z "$CONTRACT_COMMITTED" ]] ||
    out="${out}committed: ${CONTRACT_COMMITTED} (revert commits: ${CONTRACT_COMMITS:-none}); "
  [[ -z "$CONTRACT_STAGED" ]] ||
    out="${out}staged in the index, so the worktree can look clean: ${CONTRACT_STAGED} (git restore --staged -- <paths>); "
  [[ -z "$CONTRACT_UNSTAGED" ]] ||
    out="${out}unstaged, index against worktree: ${CONTRACT_UNSTAGED} (git restore -- <paths> to take the index copy, git restore --source=HEAD -- <paths> to drop both); "
  [[ -z "$CONTRACT_UNTRACKED" ]] ||
    out="${out}new untracked files: ${CONTRACT_UNTRACKED} (delete them); "
  [[ -z "$CONTRACT_IGNORED" ]] ||
    out="${out}ignored but under a contract path, so absent from the review diff: ${CONTRACT_IGNORED} (delete it, or take the path out of .gitignore)$(contract_ignored_hint); "
  printf '%s' "${out%; }"
}

# no_change_since SHA — true when nothing outside GOALS.md and the journal
# changed between SHA and HEAD. Journal-only commits (the implementer's
# checkpoints, the host's stop commit) are not progress. An empty or unknown
# SHA counts as a change: there is nothing to judge against.
no_change_since() {
  [[ -n "$1" ]] || return 1
  local rc=0
  git diff --quiet "$1" HEAD -- . ':!GOALS.md' ":!${JOURNAL}" 2>/dev/null || rc=$?
  [[ "$rc" -eq 0 ]]
}

tracked_in_head() {
  git cat-file -e "HEAD:$1" 2>/dev/null
}

# orch_commit MSG ALLOW — commit GOALS.md and the journal, after checking that
# GOALS.md moved only by ALLOW (see orch_goals_problems) and the journal grew
# only by whole records of this goal (lib/orch-files.py).
orch_commit() {
  local msg="$1" allow="$2" problems
  problems="$({ orch_goals_problems "$allow"; orch_journal_problems --records "$GOAL_ID"; } | paste -sd ';' -)"
  if [[ -n "$problems" ]]; then
    wake "orchestration-files-changed" "not committed ($msg): $problems. Something other than this run edited them; review, then commit or restore."
  fi
  local files=()
  [[ -f GOALS.md ]] && files+=(GOALS.md)
  [[ -n "$JOURNAL" && -f "$JOURNAL" ]] && files+=("$JOURNAL")
  ((${#files[@]})) || return 0
  git add -- "${files[@]}"
  if git diff --cached --quiet -- "${files[@]}"; then
    return 0
  fi
  # Pathspec commit: anything else the user staged stays staged, uncommitted.
  git commit -m "$msg" -- "${files[@]}" || wake "commit-failed" "$msg"
}

# Commit the journal alone, if it grew only by whole records of this goal.
orch_commit_journal() {
  local problems
  [[ -n "$JOURNAL" && -f "$JOURNAL" ]] || return 0
  problems="$(orch_journal_problems --records "$GOAL_ID" | paste -sd ';' -)"
  if [[ -n "$problems" ]]; then
    echo "journal not committed: $problems" >&2
    return 1
  fi
  git add -- "$JOURNAL" || return 1
  git diff --cached --quiet -- "$JOURNAL" && return 0
  git commit -m "$1" -- "$JOURNAL"
}

journal_line() {
  local line="$1"
  [[ -n "$JOURNAL" ]] || return 0
  mkdir -p "$(dirname "$JOURNAL")"
  printf '\n%s\n' "$line" >>"$JOURNAL"
}

# Where this in_progress goal stopped, from the journal (lib/resume-state.py).
# Sets BASE_SHA, ROUND, THREAD_ID, SESSION_ID, PENDING_FIX_ROUND,
# PENDING_FIX_HASH, PENDING_FIX_SOURCE and PENDING_FIX_HEAD (empty when no FIX
# is owed) and PENDING_FIX_STUCK (1 when a proof fix's no-progress stop fired).
load_resume_state() {
  local state
  state="$(python3 "$HERE/lib/resume-state.py" "$JOURNAL" "$1")" || return 1
  [[ -n "$state" ]] || return 1
  IFS=$'\t' read -r BASE_SHA ROUND THREAD_ID SESSION_ID PENDING_FIX_ROUND PENDING_FIX_HASH \
    PENDING_FIX_SOURCE PENDING_FIX_HEAD PENDING_FIX_STUCK <<<"$state"
  local v
  for v in BASE_SHA THREAD_ID SESSION_ID PENDING_FIX_ROUND PENDING_FIX_HASH PENDING_FIX_SOURCE PENDING_FIX_HEAD; do
    [[ "${!v}" != "-" ]] || printf -v "$v" '%s' ""
  done
  [[ -n "$BASE_SHA" ]]
}

# One record per implementer pass: who produced it and what it cost. A fallback
# to DeepSeek must be visible in the journal and in `logs.sh warnings`, as a
# reviewer fallback is. COST_USD is the launcher's client-side estimate, and on
# a resumed thread the conversation's running total, not this pass alone.
journal_implemented() {
  local out="$1" status="$IMPL_STATUS" cost tokens sev=info payload
  cost="$(kv "$out" IMPLEMENTER_COST_USD)"
  tokens="$(kv "$out" IMPLEMENTER_TOKENS)"
  journal_line "## $(utc) — ORCHESTRATOR implemented ${GOAL_ID} r${ROUND} STATUS=${status:--} MODEL=${IMPL_MODEL:--}${IMPL_FALLBACK:+ FALLBACK=(${IMPL_FALLBACK})} COST_USD=${cost:--}"
  [[ -z "$IMPL_FALLBACK" ]] || sev=warning
  payload="$(python3 -c 'import json,sys; print(json.dumps(dict(zip(("status","model","fallback","cost_usd","tokens","thread"), sys.argv[1:]))))' \
    "${status:-}" "${IMPL_MODEL:-}" "${IMPL_FALLBACK:-}" "${cost:-}" "${tokens:-}" "${THREAD_ID:-}")"
  events_append --event implemented --severity "$sev" --goal "$GOAL_ID" --round "$ROUND" \
    --base-sha "$BASE_SHA" \
    --summary "implemented ${GOAL_ID} r${ROUND} STATUS=${status:--} MODEL=${IMPL_MODEL:--}${IMPL_FALLBACK:+ FALLBACK=(${IMPL_FALLBACK})}" \
    --payload "$payload"
}

# A phase change inside a round, for `events.py status` (the walk footer). The
# pid lets it tell a running goal from one whose process died without a wake.
event_phase() {
  events_append --event phase --severity info --goal "$GOAL_ID" --round "$ROUND" \
    --base-sha "$BASE_SHA" --summary "phase ${GOAL_ID} r${ROUND} $1" \
    --payload "$(printf '{"phase":"%s",%s}' "$1" "$(events_pid_json)")"
}

# Journal the thread/session ids as soon as a launcher returns them, so a
# resume after any later stop continues the same conversations.
JOURNALED_IDS=""
journal_ids() {
  local ids="THREAD_ID=${THREAD_ID:--} SESSION_ID=${SESSION_ID:--}"
  [[ "$ids" != "$JOURNALED_IDS" ]] || return 0
  journal_line "## $(utc) — ORCHESTRATOR ids ${GOAL_ID} r${ROUND} ${ids}"
  JOURNALED_IDS="$ids"
}

# --- start -----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree)
      [[ $# -ge 2 && -n "$2" ]] || usage
      WT_MAIN="$2"
      shift 2
      ;;
    --base)
      [[ $# -ge 2 && -n "$2" ]] || usage
      WT_BASE_SHA="$2"
      shift 2
      ;;
    --result)
      [[ $# -ge 2 && -n "$2" ]] || usage
      WT_RESULT="$2"
      shift 2
      ;;
    -h | --help) usage ;;
    -*) usage ;;
    *)
      [[ -z "$GOAL_ID" ]] || usage
      GOAL_ID="$1"
      shift
      ;;
  esac
done
[[ -n "$GOAL_ID" ]] || usage
if [[ -n "$WT_MAIN$WT_BASE_SHA$WT_RESULT" ]]; then
  [[ -n "$WT_MAIN" && -n "$WT_BASE_SHA" && -n "$WT_RESULT" ]] ||
    { echo "--worktree, --base and --result go together" >&2; exit 2; }
  [[ -f "$WT_MAIN/GOALS.md" ]] || { echo "--worktree $WT_MAIN has no GOALS.md" >&2; exit 2; }
  WT_MAIN="$(cd "$WT_MAIN" && pwd -P)"
  # Events go to the walk's index and walk file, keyed on the main checkout.
  export CW_EVENTS_ROOT="$WT_MAIN"
  # Host git pinned before its first call (Amendment 5), to the admin folder
  # and common dir the walker recorded when it cut this worktree.
  gitfile_pin "${CW_PIN_ADMIN:-}" "${CW_PIN_COMMON:-}" "$PWD" ||
    { echo "worktree mode needs CW_PIN_ADMIN and CW_PIN_COMMON from the walker (an admin folder under <common>/worktrees/)" >&2; exit 2; }
fi

trap on_exit EXIT
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die_gate "not a git repo"
cd "$ROOT"

# Under ~/.cache, not $TMPDIR: on a wake this folder is the evidence the stop
# file points at, and macOS clears idle $TMPDIR entries after ~3 days. Folders
# past CW_PRUNE_DAYS (14) go first. The two launchers write into it
# (CW_OUT_DIR, passed to each run_step below, not exported to the proof or the
# implementer's shell) and delete nothing there: succeed removes it, a wake
# keeps it.
cw_cache_init || die_gate "cannot create $CW_CACHE"
cw_prune
RUN_DIR="$(mktemp -d "$CW_CACHE/runs/run-goal-${GOAL_ID}-XXXXXX")"
chmod 700 "$RUN_DIR"
# The implementer's handoffs, and its return documents beside them. The
# launcher gives the implementer this folder (--add-dir of the handoff's
# folder), not RUN_DIR, which holds the raw proof logs, briefs and diffs.
IMPL_DIR="$RUN_DIR/implementer"
mkdir -m 700 "$IMPL_DIR"
if [[ -n "$WT_MAIN" ]]; then
  # Proofs of a wave run side by side: each gets its own TMPDIR.
  PROOF_TMP="$RUN_DIR/tmp"
  # The worktree's link files, saved before any implementer runs and checked
  # before every host git call from here on (lib/git-guard.sh, Amendment 4).
  [[ "$(pwd -P)" == "$GIT_PIN_TREE" ]] || die_gate "worktree mode: the toplevel $ROOT is not the pinned worktree $GIT_PIN_TREE"
  gitfile_init "$ROOT" || die_gate "worktree mode: $ROOT/.git does not name the admin folder the walker recorded ($GIT_PIN_DIR)"
fi
STOP_FILE="$RUN_DIR/stop.md"
ART_DIR="$HOME/.cache/claude-coding-workflow/run-goal-${GOAL_ID}"
mkdir -p "$ART_DIR"

# .git baseline, before any git command that can run a program. The saved
# manifest outlives a stop, so tampering is caught on resume and by the walker.
git_meta_init || die_gate "cannot locate the gitdir"
# Per repo and goal: ART_DIR is keyed by the goal id alone.
CLAUDE_META_SAVED="$ART_DIR/claude-meta-$(printf '%s' "$ROOT" | shasum -a 256 | cut -c1-16).txt"
verify_git_meta "since the last run in this repo"

[[ -f GOALS.md ]] || die_gate "GOALS.md missing — commit the DAG and oracles first"
git rev-parse --verify HEAD >/dev/null 2>&1 || die_gate "repo has no commits"

if ! "$GOALS_PY" GOALS.md validate; then
  die_gate "GOALS.md validate failed (need top-level plan: and journal:)"
fi

JOURNAL="$("$GOALS_PY" GOALS.md meta | python3 -c 'import json,sys; print(json.load(sys.stdin).get("journal") or "")')"
[[ -n "$JOURNAL" ]] || die_gate "GOALS.md has no journal: key"

if ! tracked_in_head GOALS.md || ! tracked_in_head "$JOURNAL"; then
  die_gate "commit GOALS.md, oracles, and the journal first"
fi

# Worktree mode: status comes from the main checkout's GOALS.md (read-only).
STATUS_SRC=GOALS.md
if [[ -n "$WT_MAIN" ]]; then
  [[ "$WT_MAIN" != "$(pwd -P)" ]] || die_gate "--worktree names this checkout itself; worktree mode runs in a goal's own worktree"
  [[ "$IMPLEMENTER" == claude ]] || die_gate "IMPLEMENTER=$IMPLEMENTER cannot run worktree mode: only claude-implement.sh takes the parallel walk's --deny-write list"
  STATUS_SRC="$WT_MAIN/GOALS.md"
  # The walker's deny list: shared .git paths that are the walker's or the
  # other wave members' (lib/proof.sh's sibling, run-goals.sh resolves them).
  [[ -n "${CW_DENY_WRITE_FILE:-}" && -f "$CW_DENY_WRITE_FILE" ]] ||
    die_gate "worktree mode needs CW_DENY_WRITE_FILE (the walker's deny list)"
  while IFS= read -r dw; do
    [[ -z "$dw" ]] || DENY_ARGS+=(--deny-write "$dw")
  done <"$CW_DENY_WRITE_FILE"
fi

# Before the first write to either orchestration file. A fresh run needs both
# as committed; a resume may carry what its stopped run left: this goal set
# in_progress, and the run's own ORCHESTRATOR lines.
if [[ -n "$WT_MAIN" ]]; then
  # A fresh cut: no status is ever written here, and nothing was left.
  orch_preflight "" --none || ORCH_FILES_OK=-1
elif [[ "$("$GOALS_PY" GOALS.md show "$GOAL_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')" == in_progress ]]; then
  orch_preflight "$GOAL_ID=*:in_progress" --records "$GOAL_ID" || ORCH_FILES_OK=-1
else
  orch_preflight "" --none || ORCH_FILES_OK=-1
fi
[[ "$ORCH_FILES_OK" -eq 0 ]] || die_gate "$(orch_refusal)"
ORCH_FILES_OK=1

# Cache walk_id until walk-end. Mint → one journal line, fail-closed commit.
# Before the dirty-tree gate so a later wake still has a walk_id.
# Worktree mode never mints a walk: the walker did, and events_append finds
# its walk file through CW_EVENTS_ROOT.
if [[ -z "$WT_MAIN" ]]; then
  events_ensure_walk
  events_journal_walk_start
  if [[ "${EVENTS_MINTED:-0}" -eq 1 ]]; then
    orch_commit_journal "chore: orchestrator walk-start" || wake "commit-failed" "walk-start"
  fi
fi

# refresh blocked→ready if this id's blockers are done
STATUS="$("$GOALS_PY" "$STATUS_SRC" show "$GOAL_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
if [[ -n "$WT_MAIN" && "$STATUS" != in_progress ]]; then
  die_gate "$GOAL_ID is $STATUS in $STATUS_SRC; in worktree mode the walker sets in_progress before it starts the goal"
fi
if [[ "$STATUS" == "blocked" ]]; then
  "$GOALS_PY" GOALS.md refresh >/dev/null
  orch_commit "chore(${GOAL_ID}): orchestrator refresh" "*=blocked:ready,*=ready:blocked"
  STATUS="$("$GOALS_PY" GOALS.md show "$GOAL_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
fi

case "$STATUS" in
  ready | in_progress) ;;
  *) die_gate "$GOAL_ID is $STATUS (need ready or in_progress)" ;;
esac

# A status is a cache of the edges, and can be stale or hand-edited. The walker
# never dispatches past an unfinished blocker; neither does a direct run.
OPEN_BLOCKERS="$("$GOALS_PY" "$STATUS_SRC" blockers "$GOAL_ID" | paste -sd ',' -)"
if [[ -n "$OPEN_BLOCKERS" ]]; then
  die_gate "$GOAL_ID has unfinished blockers: ${OPEN_BLOCKERS//,/, }. Finish them first, or remove the edge from blocked_by in GOALS.md and commit that decision."
fi

ORACLE="$("$GOALS_PY" GOALS.md show "$GOAL_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("oracle") or "")')"
PROOF="$("$GOALS_PY" GOALS.md show "$GOAL_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("proof") or "")')"

PLAN_PATH="$("$GOALS_PY" GOALS.md meta | python3 -c 'import json,sys; print(json.load(sys.stdin).get("plan") or "")')"
tracked_in_head "$PLAN_PATH" || die_gate "commit the signed plan $PLAN_PATH first (GOALS.md plan:)"

if [[ "$ORACLE" != "inline" ]]; then
  [[ -n "$ORACLE" ]] || die_gate "$GOAL_ID has empty oracle"
  tracked_in_head "$ORACLE" || die_gate "commit file oracle $ORACLE first"
fi

if [[ "$ORACLE" != "inline" ]] && is_non_command_proof "$PROOF"; then
  die_gate "file oracle + non-command proof ($PROOF) is rejected at the gate"
fi

RESUME=0
if [[ -n "$WT_MAIN" ]]; then
  # Worktree mode never resumes: the walker recuts a stopped goal and starts
  # it fresh, at the wave base it was cut from, on its own branch.
  [[ "$(git symbolic-ref -q HEAD || echo detached)" == "refs/heads/cw/$GOAL_ID" ]] ||
    die_gate "worktree HEAD is not refs/heads/cw/$GOAL_ID"
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse --verify -q "$WT_BASE_SHA^{commit}" || echo none)" ]] ||
    die_gate "cw/$GOAL_ID is not at the wave base $WT_BASE_SHA; a fresh start needs a fresh cut"
elif [[ "$STATUS" == "in_progress" ]]; then
  RESUME=1
fi

if [[ "$RESUME" -eq 0 ]]; then
  # -z: the line form C-quotes a name with `"`, `\` or a control character.
  # --no-renames: a rename is its two paths, each its own entry.
  dirty=()
  while IFS= read -r -d '' p; do
    p="${p:3}"
    if [[ "$p" == "GOALS.md" && -z "$WT_MAIN" ]]; then
      tmp="$(mktemp)"
      git show HEAD:GOALS.md >"$tmp"
      if "$GOALS_PY" GOALS.md status-only-id "$GOAL_ID" "$tmp" >/dev/null; then
        rm -f "$tmp"
        continue
      fi
      rm -f "$tmp"
    fi
    dirty+=("$p")
  done < <(git status --porcelain -z --no-renames)
  if ((${#dirty[@]})); then
    die_gate "working tree is not clean (fresh start). Offending paths: ${dirty[*]}"
  fi
else
  echo "RESUME: $GOAL_ID — tree may be dirty"
  git status --porcelain || true
  # The contract itself is checked once BASE_SHA is known, below.
fi

# The Claude launcher needs no key here: Haiku uses the Claude login, and the
# DeepSeek fallback loads its own key (a missing one only disables it).
if [[ "$IMPLEMENTER" == codex ]] && ! load_key_from_files DEEPSEEK_API_KEY .env "$HOUSE/.env"; then
  die_gate "DEEPSEEK_API_KEY is not set (target .env or $HOUSE/.env). Do not paste it."
fi

if [[ "$RESUME" -eq 1 ]]; then
  load_resume_state "$GOAL_ID" || die_gate "in_progress but no journaled BASE_SHA for $GOAL_ID"
  git merge-base --is-ancestor "$BASE_SHA" HEAD || \
    die_gate "journaled BASE_SHA $BASE_SHA is not an ancestor of HEAD"
else
  BASE_SHA="$(git rev-parse HEAD)"
  ROUND=0
  [[ -n "$WT_MAIN" ]] || "$GOALS_PY" GOALS.md set "$GOAL_ID" in_progress
fi

git show "$BASE_SHA:GOALS.md" >"$RUN_DIR/goals-base.md"
ORACLE="$("$GOALS_PY" "$RUN_DIR/goals-base.md" show "$GOAL_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("oracle") or "")')"
PROOF="$("$GOALS_PY" "$RUN_DIR/goals-base.md" show "$GOAL_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("proof") or "")')"
# The signed plan as it stood at BASE_SHA. Both agents read this copy: the live
# file is contract (contract_drift), and an edit to it must not become the
# spec the reviewer judges that same edit against.
PLAN_PATH="$("$GOALS_PY" "$RUN_DIR/goals-base.md" meta | python3 -c 'import json,sys; print(json.load(sys.stdin).get("plan") or "")')"
PLAN_FROZEN="$IMPL_DIR/plan-at-base-$(basename "$PLAN_PATH")"
git cat-file -e "$BASE_SHA:$PLAN_PATH" 2>/dev/null && git show "$BASE_SHA:$PLAN_PATH" >"$PLAN_FROZEN" ||
  die_gate "plan $PLAN_PATH is not committed at BASE_SHA ${BASE_SHA:0:12}"
chmod 400 "$PLAN_FROZEN"

# A run cut off before assess (timeout, quota, crash, Ctrl-C) can leave a
# changed contract behind, and a paused goal invites hand edits. Refuse now,
# before a paid dispatch hands the implementer the changed oracle.
if [[ "$RESUME" -eq 1 ]]; then
  contract_drift
  if contract_any; then
    die_gate "contract changed since BASE_SHA ${BASE_SHA:0:12}; nothing dispatched — $(contract_report). Revert it, or if the change is intended hand the goal back: $HOUSE/scripts/goals.py GOALS.md set $GOAL_ID bounced"
  fi
fi

# The .claude/ baseline every implementer pass is checked against. A fresh run
# takes it now; a resume is held to the one its stopped run took.
if [[ "$RESUME" -eq 1 && -f "$CLAUDE_META_SAVED" ]]; then
  claude_changed="$(claude_meta_changed)"
  if [[ -n "$claude_changed" ]]; then
    die_gate "Claude Code configuration changed while $GOAL_ID was paused: ${claude_changed}; nothing dispatched. Inspect it with cat / ls -la and revert what you did not make; if the change is yours, re-baseline: rm $CLAUDE_META_SAVED"
  fi
else
  claude_meta_snapshot >"$CLAUDE_META_SAVED"
fi

# A resume owing FIX findings continues that fix round with those findings,
# verified against the hash the journal recorded when they were issued.
FIX_HANDOFF=""
if [[ "$RESUME" -eq 1 && -n "$PENDING_FIX_ROUND" ]]; then
  pending_fix="$ART_DIR/fix-r${PENDING_FIX_ROUND}.md"
  # The journaled hash is of the findings, which the handoff carries verbatim
  # after its "## Findings" line.
  pending_hash="$({ awk 'found { print } /^## Findings$/ { found = 1 }' "$pending_fix" 2>/dev/null || true; } |
    shasum -a 256 | awk '{print $1}')"
  if [[ ! -f "$pending_fix" || "$pending_hash" != "$PENDING_FIX_HASH" ]]; then
    die_gate "FIX findings for r${PENDING_FIX_ROUND} are missing or do not match the journaled hash ($pending_fix). Resuming would drop them; re-review instead: $HOUSE/scripts/goals.py GOALS.md set $GOAL_ID bounced"
  fi
  CUR_FIX_SOURCE="${PENDING_FIX_SOURCE:-review}"
  CUR_FIX_HEAD="$PENDING_FIX_HEAD"
  # ROUND is the pending repair's number (resume-state.py): same rule as the loop.
  if [[ "$ROUND" -gt "$MAX_FIX_ROUNDS" ]]; then
    if [[ "$CUR_FIX_SOURCE" == proof ]]; then
      wake "max-fix-rounds" "MAX_FIX_ROUNDS=$MAX_FIX_ROUNDS; proof fix r${PENDING_FIX_ROUND} still pending, after a red proof: $pending_fix. Rerun with a higher MAX_FIX_ROUNDS to apply it."
    fi
    wake "max-fix-rounds" "MAX_FIX_ROUNDS=$MAX_FIX_ROUNDS; FIX r${PENDING_FIX_ROUND} still pending. Rerun with a higher MAX_FIX_ROUNDS to apply it."
  fi
  FIX_HANDOFF="$IMPL_DIR/handoff-${GOAL_ID}-fix-r${PENDING_FIX_ROUND}.md"
  cp "$pending_fix" "$FIX_HANDOFF"
  # A resume after the no-progress stop proves before it dispatches (PLAN 2a):
  # a person may have fixed the host; if not, another pass would change nothing.
  if [[ "$CUR_FIX_SOURCE" == proof && "$PENDING_FIX_STUCK" == 1 ]]; then
    PROOF_FIRST=1
  fi
fi

# --- implement / review loop ----------------------------------------------
while :; do
  if [[ "$PROOF_FIRST" -eq 1 ]]; then
    # PLAN 2a: a resume after the no-progress stop dispatches nothing this
    # time round. The checks and the proof below judge the tree that stuck
    # proof fix left; FIX_HANDOFF stays pending for the red case.
    IMPL_STATUS=""
  else
    if [[ -n "$FIX_HANDOFF" ]]; then
      HAND="$FIX_HANDOFF"
      FIX_HANDOFF=""
    else
      HAND="$IMPL_DIR/handoff-${GOAL_ID}-r${ROUND}.md"
      {
        echo "# Handoff: $GOAL_ID"
        echo
        echo "- Goal id: \`$GOAL_ID\`"
        echo "- PLAN (signed, frozen at BASE_SHA): \`$PLAN_FROZEN\` — read this copy. \`$PLAN_PATH\` in the repo is READ-ONLY."
        echo "- GOALS: GOALS.md (read fence from BASE_SHA)"
        echo "- Journal: \`$JOURNAL\` — stage it by path with each checkpoint commit"
        echo "- Oracle (READ-ONLY): \`$ORACLE\`"
        echo "- tests/acceptance/ is READ-ONLY, every file in it. One that looks wrong is a blocker to report, not an edit."
        echo "- BASE_SHA: \`$BASE_SHA\`"
        echo "- Proof: \`$PROOF\`"
        echo "- Suggested skills: tdd"
        echo
        "$GOALS_PY" "$RUN_DIR/goals-base.md" body "$GOAL_ID" 2>/dev/null || \
          echo "(no markdown body for $GOAL_ID in goals-base.md)"
      } >"$HAND"
    fi

    journal_line "## $(utc) — ORCHESTRATOR dispatch ${GOAL_ID} r${ROUND} BASE_SHA=${BASE_SHA} THREAD_ID=${THREAD_ID:--} SESSION_ID=${SESSION_ID:--}"
    JOURNALED_IDS="THREAD_ID=${THREAD_ID:--} SESSION_ID=${SESSION_ID:--}"
    events_append --event dispatch --severity info --goal "$GOAL_ID" --round "$ROUND" \
      --base-sha "$BASE_SHA" \
      --summary "dispatch ${GOAL_ID} r${ROUND} BASE_SHA=${BASE_SHA}" \
      --payload "$(printf '{"thread_id":"%s","session_id":"%s",%s}' "${THREAD_ID:--}" "${SESSION_ID:--}" "$(events_pid_json)")"

    DS_OUT="$RUN_DIR/implementer-r${ROUND}.out"
    PHASE="implementer r${ROUND}"
    set +e
    if [[ -n "$THREAD_ID" ]]; then
      run_step "$IMPL_SECS" "$DS_OUT" "$DS_OUT.wrap" env CW_OUT_DIR="$RUN_DIR" "$IMPL_LAUNCHER" "${DENY_ARGS[@]+"${DENY_ARGS[@]}"}" --resume "$THREAD_ID" "$HAND"
    else
      run_step "$IMPL_SECS" "$DS_OUT" "$DS_OUT.wrap" env CW_OUT_DIR="$RUN_DIR" "$IMPL_LAUNCHER" "${DENY_ARGS[@]+"${DENY_ARGS[@]}"}" "$HAND"
    fi
    ds_rc=$?
    set -e
    PHASE="assess r${ROUND}"
    verify_git_meta "during implementer r${ROUND}"
    LAST_IMPL="$(kv "$DS_OUT" "$IMPL_KEY")"
    kv_keep THREAD_ID "$DS_OUT" THREAD_ID
    journal_ids
    RETURN_HANDOFF="$(kv "$DS_OUT" RETURN_HANDOFF)"
    IMPL_LOG="$(kv "$DS_OUT" LOG)"
    IMPL_ERR="$(kv "$DS_OUT" stderr)"
    IMPL_MODEL="$(kv "$DS_OUT" IMPLEMENTER_MODEL)"
    IMPL_FALLBACK="$(kv "$DS_OUT" IMPLEMENTER_FALLBACK)"
    IMPL_STATUS="$(kv "$DS_OUT" IMPLEMENTER_STATUS)"
    [[ -s "$DS_OUT.wrap" ]] && cat "$DS_OUT.wrap" >&2 || true
    verify_claude_meta "during implementer r${ROUND}"

    # Only the result line is required; the other lines are diagnostics.
    if [[ "$ds_rc" -eq 124 ]]; then
      wake "implementer-timeout" "no result after ${IMPL_SECS}s (IMPLEMENTER_TIMEOUT). stderr: $DS_OUT.wrap"
    fi
    if [[ "$ds_rc" -eq 75 || "$LAST_IMPL" == rate_limited* ]]; then
      wake "rate_limited" "${IMPL_KEY}=$LAST_IMPL"
    fi
    if [[ "$ds_rc" -eq 76 || "$LAST_IMPL" == declined* || "$LAST_IMPL" == flagged* ]]; then
      wake "implementer-declined" "${IMPL_KEY}=$LAST_IMPL — the implementer refused or declined this goal and no fallback was left (IMPLEMENTER_FALLBACK, a DeepSeek key). Nothing was assessed. Report: $(kv "$DS_OUT" REPORT)"
    fi
    if [[ -z "$LAST_IMPL" ]]; then
      wake "implementer-error" "no ${IMPL_KEY} line (rc=$ds_rc). stderr: $DS_OUT.wrap"
    fi
    if [[ "$ds_rc" -ne 0 || "$LAST_IMPL" != ok ]]; then
      wake "implementer-error" "rc=$ds_rc ${IMPL_KEY}=$LAST_IMPL"
    fi
    journal_implemented "$DS_OUT"
  fi

  # --- host assess --------------------------------------------------------
  git status --porcelain
  git log --oneline -15

  contract_drift
  if [[ -n "$CONTRACT_COMMITTED" ]]; then
    wake "contract-tamper-committed" "$(contract_report)"
  fi
  if [[ -n "$CONTRACT_STAGED" ]]; then
    # Not restored: the index is the user's to keep or drop, and overwriting
    # it would destroy work the refusal is asking them to look at.
    wake "contract-tamper-staged" "$(contract_report)"
  fi
  if [[ -n "$CONTRACT_IGNORED" ]]; then
    wake "contract-tamper-ignored" "$(contract_report)"
  fi
  if [[ -n "$CONTRACT_UNSTAGED$CONTRACT_UNTRACKED" ]]; then
    # Rendered before the restore below rewrites what it describes. Not
    # `local`: this runs in the main loop, not in a function.
    contract_msg="$(contract_report)"
    # Per path: one pathspec absent at BASE_SHA must not block the others.
    for p in "${CONTRACT_PATHS[@]}"; do
      git checkout "$BASE_SHA" -- "$p" 2>/dev/null || true
    done
    wake "contract-tamper-worktree" "$contract_msg"
  fi

  # The implementer's own word that it hit a blocker (a contract that looks
  # wrong, behaviour another goal owns, a spec with two readings). After the
  # contract checks, which keep priority; before the dirty-tree check, since a
  # blocked pass leaves its red tests uncommitted by design (the stop file lists
  # them). Nothing is reviewed or proved; the goal stays in_progress for the
  # Architect to fix the spec or bounce it.
  if [[ "$IMPL_STATUS" == BLOCKED ]]; then
    wake "implementer-blocked" "the implementer reported a blocker; its question is in the journal END record and the return handoff: ${RETURN_HANDOFF:-none}. Fix the spec or oracle and resume, or bounce: $HOUSE/scripts/goals.py GOALS.md set $GOAL_ID bounced"
  fi

  unexpected=()
  while IFS= read -r -d '' p; do
    p="${p:3}"
    if [[ "$p" == "GOALS.md" && -z "$WT_MAIN" ]]; then
      if "$GOALS_PY" GOALS.md status-only-id "$GOAL_ID" "$RUN_DIR/goals-base.md" >/dev/null; then
        continue
      fi
    fi
    if [[ "$p" == "$JOURNAL" ]]; then
      continue
    fi
    unexpected+=("$p")
  done < <(git status --porcelain -z --no-renames)
  if ((${#unexpected[@]})); then
    wake "dirty-tree" "unexpected paths: ${unexpected[*]}"
  fi

  # The journal is the one file the implementer shares with the host, and the
  # host commits it under its own name. Check its shape here, before review
  # and before any commit, not only at commit time.
  journal_problems="$(orch_journal_problems --records "$GOAL_ID" | paste -sd ';' -)"
  if [[ -n "$journal_problems" ]]; then
    wake "journal-tamper" "$journal_problems — the journal grew by something other than this goal's records. Review those lines, then commit or restore them."
  fi


  PROOF_FILE="$RUN_DIR/proof-${GOAL_ID}-r${ROUND}.txt"
  if is_non_command_proof "$PROOF"; then
    echo "PROOF: none (no executable proof)" >"$PROOF_FILE"
    PROOF_EXIT=0
    PROOF_NONE=1
  else
    PROOF_NONE=0
    set +e
    PHASE="proof r${ROUND}"
    event_phase proof
    tree_snapshot >"$RUN_DIR/tree-before-proof.txt"
    # lib/proof.sh: plain bash -c, credential variables stripped,
    # PYTHONDONTWRITEBYTECODE. PROOF_TMP is empty unless worktree mode set it.
    proof_exec "$PROOF_SECS" "$PROOF_FILE" "$PROOF_TMP" "$PROOF"
    PROOF_EXIT=$?
    set -e
    PHASE="assess r${ROUND}"
    verify_git_meta "during proof r${ROUND}"
    if [[ "$PROOF_EXIT" -eq 124 ]]; then
      wake "proof-timeout" "proof ran past ${PROOF_SECS}s (PROOF_TIMEOUT). Output: $PROOF_FILE"
    fi
    # The checks above ran before the proof; proof code could have changed
    # what they approved. Nothing is restored: the stop file says what moved.
    tree_snapshot >"$RUN_DIR/tree-after-proof.txt"
    contract_drift
    moved=()
    while IFS= read -r m; do
      [[ -z "$m" ]] || moved+=("$m")
    done < <(proof_moved "$RUN_DIR/tree-before-proof.txt" "$RUN_DIR/tree-after-proof.txt")
    contract_any && moved+=("contract — $(contract_report)")
    if ((${#moved[@]})); then
      wake "proof-tamper" "the proof changed the repo — $(printf '%s; ' "${moved[@]}")output: $PROOF_FILE"
    fi
    if [[ "$PROOF_EXIT" -ne 0 ]] || grep -q 'Ran 0 tests' "$PROOF_FILE"; then
      # A proof fix round that changed nothing outside the journal: the
      # implementer saw nothing to change (its sandboxed proof is likely
      # green), so another round cannot help (PLAN step 2).
      if [[ "$CUR_FIX_SOURCE" == proof ]] && no_change_since "$CUR_FIX_HEAD"; then
        wake "proof-red" "no change since the red proof at r$((ROUND - 1)); the host and the sandbox may disagree. Output: $PROOF_FILE"
      fi
      if [[ "$PROOF_FIRST" -eq 1 ]]; then
        # Changed since the stuck fix (PLAN 2a): dispatch the pending fix.
        PROOF_FIRST=0
        continue
      fi
      # Red: a proof fix round, inside the shared MAX_FIX_ROUNDS (PLAN 3-7).
      FINDINGS="$RUN_DIR/findings-r${ROUND}.txt"
      # Bounded like the proof: a pathological log must not stall the walk.
      set +e
      run_step "$PROOF_SECS" "$FINDINGS" "$FINDINGS.err" \
        python3 "$HERE/lib/proof-excerpt.py" "$PROOF_FILE" "$PROOF" "$PROOF_EXIT"
      excerpt_rc=$?
      set -e
      if [[ "$excerpt_rc" -ne 0 ]]; then
        wake "proof-excerpt-error" "host proof exit $PROOF_EXIT; the excerpt for a proof fix could not be built (rc=$excerpt_rc, $FINDINGS.err). Output: $PROOF_FILE"
      fi
      FIX_HEAD="$(git rev-parse HEAD)"
      FIX_HASH="$(shasum -a 256 "$FINDINGS" | awk '{print $1}')"
      FIXH="$IMPL_DIR/handoff-${GOAL_ID}-fix-r${ROUND}.md"
      {
        echo "# Fix handoff: $GOAL_ID (after round $ROUND: red host proof)"
        echo
        echo "Oracle is READ-ONLY. Do not edit \`$ORACLE\` or tests/acceptance/."
        echo "BASE_SHA remains \`$BASE_SHA\`. Do not redo passing tests."
        echo
        echo "The host ran the goal's proof after your last pass and it failed. Make it pass"
        echo "without changing any contract file. If you believe the oracle or the case table"
        echo "is wrong, do not work around it: report BLOCKED with the exact question (the"
        echo "blocker rule). If the proof passes in your sandbox and you have nothing to"
        echo "change, say so in the journal END record and the return handoff and report"
        echo "DONE without changing any file."
        echo
        echo "## Findings"
        cat "$FINDINGS"
      } >"$FIXH"
      # Saved before the journal names their hash, as for a review fix.
      cp -f "$FIXH" "$ART_DIR/fix-r${ROUND}.md"
      journal_line "## $(utc) — ORCHESTRATOR fix ${GOAL_ID} r${ROUND} count=1 hash=${FIX_HASH} source=proof head=${FIX_HEAD}"
      events_append --event fix --severity warning --goal "$GOAL_ID" --round "$ROUND" \
        --verdict FIX --base-sha "$BASE_SHA" \
        --summary "fix ${GOAL_ID} r${ROUND} count=1 hash=${FIX_HASH} source=proof" \
        --payload "$(printf '{"fix_count":1,"fix_hash":"%s","source":"proof"}' "$FIX_HASH")"
      ROUND=$((ROUND + 1))
      if [[ "$ROUND" -gt "$MAX_FIX_ROUNDS" ]]; then
        wake "max-fix-rounds" "MAX_FIX_ROUNDS=$MAX_FIX_ROUNDS; after a red proof; output: $PROOF_FILE"
      fi
      FIX_HANDOFF="$FIXH"
      CUR_FIX_SOURCE=proof
      CUR_FIX_HEAD="$FIX_HEAD"
      continue
    fi
  fi
  PROOF_FIRST=0

  DIFF="$RUN_DIR/diff-${GOAL_ID}-r${ROUND}.patch"
  REVIEWED_HEAD="$(git rev-parse HEAD)"
  git diff --no-ext-diff --no-textconv "$BASE_SHA".."$REVIEWED_HEAD" -- . ':!GOALS.md' ":!${JOURNAL}" >"$DIFF"
  if [[ ! -s "$DIFF" ]]; then
    wake "empty-diff" "no implementer changes in $BASE_SHA..HEAD"
  fi

  BRIEF="$RUN_DIR/review-${GOAL_ID}-r${ROUND}.md"
  cat >"$BRIEF" <<EOF
GOAL: ${GOAL_ID}
PLAN: ${PLAN_FROZEN}
GOALS: GOALS.md
ORACLE: ${ORACLE}
DIFF_FILE: ${DIFF}
DIFF_RANGE: ${BASE_SHA}..HEAD
PROOF_OUTPUT: ${PROOF_FILE}

Findings: the FIX: line format in your instructions. Numbered lists are not parsed.
Do not ask the implementer to edit the oracle or tests/acceptance/.
EOF

  RV_OUT="$RUN_DIR/reviewer-r${ROUND}.out"
  PHASE="review r${ROUND}"
  event_phase review
  set +e
  # --add-dir $RUN_DIR or the reviewer cannot open BRIEF / DIFF_FILE /
  # PROOF_OUTPUT at all: headless Claude denies reads outside the repo and
  # there is nobody to approve the prompt. It then reviews on no evidence.
  if [[ -n "$SESSION_ID" ]]; then
    run_step "$REVIEW_SECS" "$RV_OUT" "$RV_OUT.wrap" env CW_OUT_DIR="$RUN_DIR" "$REVIEWER" --resume "$SESSION_ID" --add-dir "$RUN_DIR" "$BRIEF"
  else
    run_step "$REVIEW_SECS" "$RV_OUT" "$RV_OUT.wrap" env CW_OUT_DIR="$RUN_DIR" "$REVIEWER" --add-dir "$RUN_DIR" "$BRIEF"
  fi
  rv_rc=$?
  set -e
  PHASE="route r${ROUND}"
  [[ -s "$RV_OUT.wrap" ]] && cat "$RV_OUT.wrap" >&2 || true
  LAST_CLAUDE="$(kv "$RV_OUT" CLAUDE_REVIEW_RESULT)"
  kv_keep SESSION_ID "$RV_OUT" SESSION_ID
  journal_ids
  VERDICT_FILE="$(kv "$RV_OUT" VERDICT_FILE)"
  if [[ -n "$VERDICT_FILE" ]]; then
    cp -f "$VERDICT_FILE" "$ART_DIR/verdict-r${ROUND}.md" 2>/dev/null || true
  fi

  if [[ "$rv_rc" -eq 124 ]]; then
    LAST_VERDICT="MISSING"
    wake "reviewer-timeout" "no result after ${REVIEW_SECS}s (CLAUDE_REVIEW_TIMEOUT). stderr: $RV_OUT.wrap"
  fi
  if [[ "$rv_rc" -eq 75 || "$LAST_CLAUDE" == rate_limited* ]]; then
    wake "reviewer-rate-limited" "$LAST_CLAUDE"
  fi
  if [[ "$rv_rc" -eq 76 || "$LAST_CLAUDE" == flagged* ]]; then
    LAST_VERDICT="MISSING"
    wake "reviewer-flagged" "$LAST_CLAUDE — the reviewer's safeguards flagged this review and no fallback cleared it (CLAUDE_REVIEW_FALLBACK_MODEL is off, or was flagged too). Nothing was judged. Review: $VERDICT_FILE"
  fi
  if [[ -z "$LAST_CLAUDE" ]]; then
    LAST_VERDICT="MISSING"
    wake "reviewer-error" "no CLAUDE_REVIEW_RESULT line (rc=$rv_rc). stderr: $RV_OUT.wrap"
  fi
  if [[ "$LAST_CLAUDE" != "ok" ]]; then
    LAST_VERDICT="MISSING"
    wake "reviewer-error" "CLAUDE_REVIEW_RESULT=$LAST_CLAUDE rc=$rv_rc"
  fi
  LAST_VERDICT="$(kv "$RV_OUT" VERDICT)"
  # Which model judged. The workflow names Opus 5.5 as the reviewer, so a fallback
  # to another model must be visible in the journal and in `logs.sh warnings`.
  REVIEW_MODEL="$(kv "$RV_OUT" CLAUDE_REVIEW_MODEL)"
  REVIEW_FALLBACK="$(kv "$RV_OUT" CLAUDE_REVIEW_FALLBACK)"
  review_note="MODEL=${REVIEW_MODEL:--}"
  [[ -z "$REVIEW_FALLBACK" ]] || review_note+=" FALLBACK=(${REVIEW_FALLBACK})"

  journal_line "## $(utc) — ORCHESTRATOR review ${GOAL_ID} r${ROUND} VERDICT=${LAST_VERDICT} ${review_note}"
  review_sev=info
  case "$LAST_VERDICT" in
    FIX) review_sev=warning ;;
    BLOCKED|MISSING) review_sev=error ;;
  esac
  [[ -z "$REVIEW_FALLBACK" || "$review_sev" != info ]] || review_sev=warning
  events_append --event review --severity "$review_sev" --goal "$GOAL_ID" --round "$ROUND" \
    --verdict "$LAST_VERDICT" --base-sha "$BASE_SHA" \
    --summary "review ${GOAL_ID} r${ROUND} VERDICT=${LAST_VERDICT} ${review_note}"

  case "$LAST_VERDICT" in
    DONE)
      if [[ "${PROOF_NONE:-0}" -eq 1 ]]; then
        wake "done-refused" "PROOF: none cannot auto-done. Review: $VERDICT_FILE"
      fi
      if [[ -n "$WT_MAIN" ]]; then
        # The walker sets done after it integrates this branch. Only the tip the
        # reviewer judged may be reported: a commit that landed during the
        # review (a process left running) was never reviewed.
        [[ "$(git rev-parse HEAD)" == "$REVIEWED_HEAD" ]] ||
          wake "head-moved-during-review" "HEAD is $(git rev-parse --short HEAD), not ${REVIEWED_HEAD:0:12}, the tip the reviewer judged; $(git log --format=%h "$REVIEWED_HEAD"..HEAD | paste -sd ' ' -) arrived during the review."
        journal_line "## $(utc) — ORCHESTRATOR done ${GOAL_ID} r${ROUND}"
        orch_commit "chore(${GOAL_ID}): orchestrator done" ""
        done_head="$(git rev-parse HEAD)"
        [[ "$(git rev-parse "$done_head^")" == "$REVIEWED_HEAD" &&
          "$(git -c core.quotePath=false diff --name-only "$REVIEWED_HEAD" "$done_head")" == "$JOURNAL" ]] ||
          wake "head-moved-during-review" "the done commit $done_head is not a journal-only commit on ${REVIEWED_HEAD:0:12}"
        # The walker reads this file, in its own run folder, and checks it
        # against cw/<goal> before it records the goal as finished.
        printf 'reviewed=%s\ndone=%s\n' "$REVIEWED_HEAD" "$done_head" >"$WT_RESULT.tmp" &&
          mv -f "$WT_RESULT.tmp" "$WT_RESULT" || wake "result-write-failed" "$WT_RESULT"
        # Display only (the /walk pane shows the goal as integrating).
        event_phase integrate
      else
        "$GOALS_PY" GOALS.md set "$GOAL_ID" done
        journal_line "## $(utc) — ORCHESTRATOR done ${GOAL_ID} r${ROUND}"
        events_append --event done --severity info --goal "$GOAL_ID" --round "$ROUND" \
          --verdict DONE --base-sha "$BASE_SHA" \
          --summary "done ${GOAL_ID} r${ROUND}"
        orch_commit "chore(${GOAL_ID}): orchestrator done" "$GOAL_ID=*:done"
      fi
      echo "GOAL $GOAL_ID DONE"
      succeed
      ;;
    FIX)
      FINDINGS="$RUN_DIR/findings-r${ROUND}.txt"
      TARGETS="$RUN_DIR/targets-r${ROUND}.txt"
      FIX_COUNT_N="$(extract_findings "$VERDICT_FILE" "$FINDINGS" "$TARGETS")"
      if [[ "$FIX_COUNT_N" -eq 0 ]]; then
        wake "fix-unparseable" "VERDICT=FIX but no FIX: lines. $VERDICT_FILE"
      fi
      if findings_touch_oracle "$TARGETS"; then
        if [[ -n "$WT_MAIN" ]]; then
          # The walker sets bounced; the record ends this attempt (exit 3).
          journal_line "## $(utc) — ORCHESTRATOR bounced ${GOAL_ID} r${ROUND}"
          orch_commit "chore(${GOAL_ID}): orchestrator bounced" ""
          WAKE_RC=3
        else
          "$GOALS_PY" GOALS.md set "$GOAL_ID" bounced
          orch_commit "chore(${GOAL_ID}): orchestrator bounced" "$GOAL_ID=*:bounced"
        fi
        wake "blocked-oracle-edit" "a FIX finding names the oracle / tests/acceptance"
      fi
      FIX_HASH="$(shasum -a 256 "$FINDINGS" | awk '{print $1}')"
      FIXH="$IMPL_DIR/handoff-${GOAL_ID}-fix-r${ROUND}.md"
      {
        echo "# Fix handoff: $GOAL_ID (round $ROUND)"
        echo
        echo "Oracle is READ-ONLY. Do not edit \`$ORACLE\` or tests/acceptance/."
        echo "BASE_SHA remains \`$BASE_SHA\`. Do not redo passing tests."
        echo
        echo "## Findings"
        cat "$FINDINGS"
      } >"$FIXH"
      # Saved before the journal names their hash: a resume rebuilds the
      # fix round from these (never from the journal, which the implementer
      # reads and which must not carry finding text).
      cp -f "$FIXH" "$ART_DIR/fix-r${ROUND}.md"
      journal_line "## $(utc) — ORCHESTRATOR fix ${GOAL_ID} r${ROUND} count=${FIX_COUNT_N} hash=${FIX_HASH} source=review"
      events_append --event fix --severity warning --goal "$GOAL_ID" --round "$ROUND" \
        --verdict FIX --base-sha "$BASE_SHA" \
        --summary "fix ${GOAL_ID} r${ROUND} count=${FIX_COUNT_N} hash=${FIX_HASH}" \
        --payload "$(printf '{"fix_count":%s,"fix_hash":"%s","source":"review"}' "$FIX_COUNT_N" "$FIX_HASH")"
      ROUND=$((ROUND + 1))
      # ROUND is now the number of the repair these findings need; the first
      # implementation is round 0, not a repair. MAX_FIX_ROUNDS=N allows
      # repairs 1..N. The resume check below uses the same rule.
      if [[ "$ROUND" -gt "$MAX_FIX_ROUNDS" ]]; then
        wake "max-fix-rounds" "MAX_FIX_ROUNDS=$MAX_FIX_ROUNDS"
      fi
      FIX_HANDOFF="$FIXH"
      CUR_FIX_SOURCE=review
      CUR_FIX_HEAD=""
      continue
      ;;
    BLOCKED)
      [[ -n "$WT_MAIN" ]] || "$GOALS_PY" GOALS.md set "$GOAL_ID" bounced
      journal_line "## $(utc) — ORCHESTRATOR bounced ${GOAL_ID} r${ROUND}"
      events_append --event bounced --severity error --goal "$GOAL_ID" --round "$ROUND" \
        --verdict BLOCKED --base-sha "$BASE_SHA" \
        --summary "bounced ${GOAL_ID} r${ROUND}"
      if [[ -n "$WT_MAIN" ]]; then
        # The walker sets bounced from the exit status.
        orch_commit "chore(${GOAL_ID}): orchestrator bounced" ""
        WAKE_RC=3
      else
        orch_commit "chore(${GOAL_ID}): orchestrator bounced" "$GOAL_ID=*:bounced"
      fi
      wake "blocked" "reviewer BLOCKED. $VERDICT_FILE"
      ;;
    *)
      wake "missing-verdict" "VERDICT=$LAST_VERDICT"
      ;;
  esac
done
