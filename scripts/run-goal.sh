#!/usr/bin/env bash
#
# run-goal.sh — host Orchestrator for one GOALS.md id.
# DeepSeek implements, this script assesses, Opus reviews, this script routes.
# Models never read each other's raw output.
#
# Usage (from the target repo):
#   run-goal.sh <goal-id>
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

GOALS_PY="$HERE/goals.py"
DEEPSEEK="$HERE/deepseek-code.sh"
REVIEWER="$HERE/claude-goal-review.sh"

MAX_FIX_ROUNDS="${MAX_FIX_ROUNDS:-3}"
IMPL_SECS="${DEEPSEEK_TIMEOUT:-1200}"
REVIEW_SECS="${CLAUDE_REVIEW_TIMEOUT:-600}"
PROOF_SECS="${PROOF_TIMEOUT:-600}"

GOAL_ID="${1:-}"
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
LAST_DEEPSEEK=""
LAST_VERDICT=""
LAST_CLAUDE=""
VERDICT_FILE=""
PROOF_FILE=""
PROOF_EXIT=""
RETURN_HANDOFF=""
DEEPSEEK_LOG=""
DEEPSEEK_ERR=""
FIX_HASH=""
FIX_COUNT_N=0
PHASE="gate"
CHILD_PID=""
PENDING_FIX_ROUND=""
PENDING_FIX_HASH=""

usage() {
  echo "usage: run-goal.sh <goal-id>" >&2
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
- DEEPSEEK_RESULT: ${LAST_DEEPSEEK:-}
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
- LOG: ${DEEPSEEK_LOG:-}
- stderr: ${DEEPSEEK_ERR:-}
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
  # Tainted: no git at all, so journal the line and leave it uncommitted.
  if [[ -n "${JOURNAL:-}" && -f "${JOURNAL}" ]] \
    && { [[ "$GIT_META_TAINTED" -eq 1 ]] || tracked_in_head "$JOURNAL"; }; then
    journal_line "## $(utc) — ORCHESTRATOR wake ${GOAL_ID:-?} r${ROUND} reason=${reason}"
  fi
  events_append --event wake --severity "$sev" \
    --goal "${GOAL_ID:-}" --round "${ROUND}" --reason "$reason" \
    --verdict "${LAST_VERDICT:-}" --base-sha "${BASE_SHA:-}" \
    --summary "wake ${GOAL_ID:-?} r${ROUND} reason=${reason}"
  if [[ "$GIT_META_TAINTED" -eq 0 && -n "${JOURNAL:-}" && -f "${JOURNAL}" ]] \
    && tracked_in_head "$JOURNAL"; then
    git add -- "$JOURNAL" || true
    if ! git diff --cached --quiet -- "$JOURNAL" 2>/dev/null; then
      git commit -m "chore(${GOAL_ID:-?}): orchestrator wake ${reason}" -- "$JOURNAL" || \
        echo "failed to commit wake journal line" >&2
    fi
  fi
  return 0
}

wake() {
  write_stop "$1" "${2:-}"
  record_wake "$1"
  exit 1
}

succeed() {
  STOP_WRITTEN=1
  STOP_FILE=""
  git_meta_forget
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

# run_step SECS OUT ERR CMD... — CMD under a timeout (0 = none), in its own
# process group, in the background. Waiting with `wait` rather than in the
# foreground is what lets INT/TERM act now instead of when CMD ends. ERR equal
# to OUT merges the streams.
run_step() {
  local secs="$1" out="$2" err="$3"
  shift 3
  local timer=(python3 "$HERE/lib/run-timeout.py" "$secs")
  if command -v gtimeout >/dev/null 2>&1; then
    timer=(gtimeout --kill-after=5 "$secs")
  elif command -v timeout >/dev/null 2>&1; then
    timer=(timeout --kill-after=5 "$secs")
  fi
  if [[ "$err" == "$out" ]]; then
    "${timer[@]}" "$@" >"$out" 2>&1 &
  else
    "${timer[@]}" "$@" >"$out" 2>"$err" &
  fi
  CHILD_PID=$!
  local rc=0
  wait "$CHILD_PID" || rc=$?
  CHILD_PID=""
  return "$rc"
}

# Wake if .git config/hooks/info differ from the saved manifest. git_meta_verify
# has already disabled host git by then, so the wake path runs none.
verify_git_meta() {
  git_meta_verify "$GIT_META_SAVED" && return 0
  wake "git-metadata-tamper" "changed $1: ${GIT_META_CHANGED}— $(git_meta_help)"
}

# Contract drift since BASE_SHA: the plan, this goal's file oracle,
# tests/acceptance/, and all of GOALS.md except this goal's status. Sets CONTRACT_PATHS and
# one-line lists CONTRACT_COMMITTED (changed by commits after BASE_SHA, which
# are listed in CONTRACT_COMMITS) and CONTRACT_UNCOMMITTED (staged, unstaged,
# or untracked). Needs BASE_SHA, PLAN_PATH and ORACLE from goals-base.md, and
# RUN_DIR.
contract_drift() {
  local drift goals_commit=0
  CONTRACT_PATHS=(tests/acceptance "$PLAN_PATH")
  if [[ "$ORACLE" != "inline" && -n "$ORACLE" ]]; then
    CONTRACT_PATHS+=("$ORACLE")
  fi
  CONTRACT_COMMITTED="$(git diff --name-only "$BASE_SHA" HEAD -- "${CONTRACT_PATHS[@]}" || true)"
  CONTRACT_UNCOMMITTED="$(git diff --name-only HEAD -- "${CONTRACT_PATHS[@]}" || true)
$(git ls-files --others --exclude-standard -- "${CONTRACT_PATHS[@]}" || true)"
  # HEAD never carries this goal's status (committed only on done/bounced),
  # so HEAD's GOALS.md must match the base apart from it.
  git show HEAD:GOALS.md >"$RUN_DIR/goals-head.md"
  if ! drift="$("$GOALS_PY" "$RUN_DIR/goals-head.md" status-only-id "$GOAL_ID" "$RUN_DIR/goals-base.md" 2>&1)"; then
    CONTRACT_COMMITTED="${CONTRACT_COMMITTED}"$'\n'"GOALS.md ($(sed 1d <<<"$drift" | paste -sd ';' -))"
    goals_commit=1
  fi
  if ! drift="$("$GOALS_PY" GOALS.md status-only-id "$GOAL_ID" "$RUN_DIR/goals-base.md" 2>&1)"; then
    CONTRACT_UNCOMMITTED="${CONTRACT_UNCOMMITTED}"$'\n'"GOALS.md ($(sed 1d <<<"$drift" | paste -sd ';' -))"
  fi
  CONTRACT_COMMITTED="$(sed '/^$/d' <<<"$CONTRACT_COMMITTED" | sort -u | paste -sd ',' -)"
  CONTRACT_UNCOMMITTED="$(sed '/^$/d' <<<"$CONTRACT_UNCOMMITTED" | sort -u | paste -sd ',' -)"
  CONTRACT_COMMITS=""
  if [[ -n "$CONTRACT_COMMITTED" ]]; then
    local log_paths=("${CONTRACT_PATHS[@]}")
    [[ "$goals_commit" -eq 0 ]] || log_paths+=(GOALS.md)
    CONTRACT_COMMITS="$(git log --format=%h "$BASE_SHA"..HEAD -- "${log_paths[@]}" | paste -sd ' ' -)"
  fi
}

# `env -u` arguments for every exported variable named like a credential — a
# whole _-separated part KEY, APIKEY, TOKEN, SECRET, PASSWORD, PASSWD or
# CREDENTIAL(S) — except names in PROOF_ENV_KEEP and git's own GIT_CONFIG_*.
# The proof runs implementer-written code on the host; it gets PATH and the
# rest, not the keys.
proof_env_unsets() {
  local name keep=" ${PROOF_ENV_KEEP:-} "
  for name in $(compgen -e); do
    [[ "$keep" != *" $name "* && "$name" != GIT_CONFIG_* ]] || continue
    if grep -qiE '(^|_)(API)?KEY(_|$)|(^|_)(TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIALS?)(_|$)' <<<"$name"; then
      printf '%s\n' -u "$name"
    fi
  done
}

# HEAD, tracked and staged changes, and every untracked path not ignored —
# what a proof must leave as it found. Artifact policy: output a project
# declares in .gitignore (caches, reports, coverage) is the proof's to write,
# and the next goal's clean-tree gate does not see it. Anything else a proof
# creates — source, config, a symlink — nobody reviews and it can steer the
# proof, so it is tampering.
tree_snapshot() {
  git rev-parse HEAD
  git status --porcelain --untracked-files=all
}

tracked_in_head() {
  git cat-file -e "HEAD:$1" 2>/dev/null
}

orch_commit() {
  local msg="$1"
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

journal_line() {
  local line="$1"
  [[ -n "$JOURNAL" ]] || return 0
  mkdir -p "$(dirname "$JOURNAL")"
  printf '\n%s\n' "$line" >>"$JOURNAL"
}

# Where this in_progress goal stopped, from the journal (lib/resume-state.py).
# Sets BASE_SHA, ROUND, THREAD_ID, SESSION_ID, PENDING_FIX_ROUND and
# PENDING_FIX_HASH (the last two empty when no FIX is owed).
load_resume_state() {
  local state
  state="$(python3 "$HERE/lib/resume-state.py" "$JOURNAL" "$1")" || return 1
  [[ -n "$state" ]] || return 1
  IFS=$'\t' read -r BASE_SHA ROUND THREAD_ID SESSION_ID PENDING_FIX_ROUND PENDING_FIX_HASH <<<"$state"
  local v
  for v in BASE_SHA THREAD_ID SESSION_ID PENDING_FIX_ROUND PENDING_FIX_HASH; do
    [[ "${!v}" != "-" ]] || printf -v "$v" '%s' ""
  done
  [[ -n "$BASE_SHA" ]]
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
[[ -n "$GOAL_ID" && "$GOAL_ID" != "-h" && "$GOAL_ID" != "--help" ]] || usage

trap on_exit EXIT
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die_gate "not a git repo"
cd "$ROOT"

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/run-goal-${GOAL_ID}-XXXXXX")"
chmod 700 "$RUN_DIR"
STOP_FILE="$RUN_DIR/stop.md"
ART_DIR="$HOME/.cache/claude-coding-workflow/run-goal-${GOAL_ID}"
mkdir -p "$ART_DIR"

# .git baseline, before any git command that can run a program. The saved
# manifest outlives a stop, so tampering is caught on resume and by the walker.
git_meta_init || die_gate "cannot locate the gitdir"
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

# Cache walk_id until walk-end. Mint → one journal line, fail-closed commit.
# Before the dirty-tree gate so a later wake still has a walk_id.
events_ensure_walk
events_journal_walk_start
if [[ "${EVENTS_MINTED:-0}" -eq 1 ]]; then
  git add -- "$JOURNAL"
  if ! git diff --cached --quiet -- "$JOURNAL"; then
    git commit -m "chore: orchestrator walk-start" -- "$JOURNAL" || wake "commit-failed" "walk-start"
  fi
fi

# refresh blocked→ready if this id's blockers are done
STATUS="$("$GOALS_PY" GOALS.md show "$GOAL_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
if [[ "$STATUS" == "blocked" ]]; then
  "$GOALS_PY" GOALS.md refresh >/dev/null
  orch_commit "chore(${GOAL_ID}): orchestrator refresh"
  STATUS="$("$GOALS_PY" GOALS.md show "$GOAL_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
fi

case "$STATUS" in
  ready | in_progress) ;;
  *) die_gate "$GOAL_ID is $STATUS (need ready or in_progress)" ;;
esac

# A status is a cache of the edges, and can be stale or hand-edited. The walker
# never dispatches past an unfinished blocker; neither does a direct run.
OPEN_BLOCKERS="$("$GOALS_PY" GOALS.md blockers "$GOAL_ID" | paste -sd ',' -)"
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
if [[ "$STATUS" == "in_progress" ]]; then
  RESUME=1
fi

if [[ "$RESUME" -eq 0 ]]; then
  dirty=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    p="${line:3}"
    p="${p#\"}"
    p="${p%\"}"
    if [[ "$p" == "GOALS.md" ]]; then
      tmp="$(mktemp)"
      git show HEAD:GOALS.md >"$tmp"
      if "$GOALS_PY" GOALS.md status-only-id "$GOAL_ID" "$tmp" >/dev/null; then
        rm -f "$tmp"
        continue
      fi
      rm -f "$tmp"
    fi
    dirty+=("$p")
  done < <(git status --porcelain)
  if ((${#dirty[@]})); then
    die_gate "working tree is not clean (fresh start). Offending paths: ${dirty[*]}"
  fi
else
  echo "RESUME: $GOAL_ID — tree may be dirty"
  git status --porcelain || true
  # The contract itself is checked once BASE_SHA is known, below.
fi

if ! load_key_from_files DEEPSEEK_API_KEY .env "$HOUSE/.env"; then
  die_gate "DEEPSEEK_API_KEY is not set (target .env or $HOUSE/.env). Do not paste it."
fi

if [[ "$RESUME" -eq 1 ]]; then
  load_resume_state "$GOAL_ID" || die_gate "in_progress but no journaled BASE_SHA for $GOAL_ID"
  git merge-base --is-ancestor "$BASE_SHA" HEAD || \
    die_gate "journaled BASE_SHA $BASE_SHA is not an ancestor of HEAD"
else
  BASE_SHA="$(git rev-parse HEAD)"
  ROUND=0
  "$GOALS_PY" GOALS.md set "$GOAL_ID" in_progress
fi

git show "$BASE_SHA:GOALS.md" >"$RUN_DIR/goals-base.md"
ORACLE="$("$GOALS_PY" "$RUN_DIR/goals-base.md" show "$GOAL_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("oracle") or "")')"
PROOF="$("$GOALS_PY" "$RUN_DIR/goals-base.md" show "$GOAL_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("proof") or "")')"
# The signed plan as it stood at BASE_SHA. Both agents read this copy: the live
# file is contract (contract_drift), and an edit to it must not become the
# spec the reviewer judges that same edit against.
PLAN_PATH="$("$GOALS_PY" "$RUN_DIR/goals-base.md" meta | python3 -c 'import json,sys; print(json.load(sys.stdin).get("plan") or "")')"
PLAN_FROZEN="$RUN_DIR/plan-at-base-$(basename "$PLAN_PATH")"
git cat-file -e "$BASE_SHA:$PLAN_PATH" 2>/dev/null && git show "$BASE_SHA:$PLAN_PATH" >"$PLAN_FROZEN" ||
  die_gate "plan $PLAN_PATH is not committed at BASE_SHA ${BASE_SHA:0:12}"
chmod 400 "$PLAN_FROZEN"

# A run cut off before assess (timeout, quota, crash, Ctrl-C) can leave a
# changed contract behind, and a paused goal invites hand edits. Refuse now,
# before a paid dispatch hands the implementer the changed oracle.
if [[ "$RESUME" -eq 1 ]]; then
  contract_drift
  if [[ -n "$CONTRACT_COMMITTED$CONTRACT_UNCOMMITTED" ]]; then
    die_gate "contract changed since BASE_SHA ${BASE_SHA:0:12}; nothing dispatched — committed: ${CONTRACT_COMMITTED:-none} (commits: ${CONTRACT_COMMITS:-none}); uncommitted: ${CONTRACT_UNCOMMITTED:-none}. Revert it, or if the change is intended hand the goal back: $HOUSE/scripts/goals.py GOALS.md set $GOAL_ID bounced"
  fi
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
  if [[ "$ROUND" -ge "$MAX_FIX_ROUNDS" ]]; then
    wake "max-fix-rounds" "MAX_FIX_ROUNDS=$MAX_FIX_ROUNDS; FIX r${PENDING_FIX_ROUND} still pending. Rerun with a higher MAX_FIX_ROUNDS to apply it."
  fi
  FIX_HANDOFF="$RUN_DIR/handoff-${GOAL_ID}-fix-r${PENDING_FIX_ROUND}.md"
  cp "$pending_fix" "$FIX_HANDOFF"
fi

# --- implement / review loop ----------------------------------------------
while :; do
  if [[ -n "$FIX_HANDOFF" ]]; then
    HAND="$FIX_HANDOFF"
    FIX_HANDOFF=""
  else
    HAND="$RUN_DIR/handoff-${GOAL_ID}-r${ROUND}.md"
    {
      echo "# Handoff: $GOAL_ID"
      echo
      echo "- Goal id: \`$GOAL_ID\`"
      echo "- PLAN (signed, frozen at BASE_SHA): \`$PLAN_FROZEN\` — read this copy. \`$PLAN_PATH\` in the repo is READ-ONLY."
      echo "- GOALS: GOALS.md (read fence from BASE_SHA)"
      echo "- Journal: \`$JOURNAL\` — git add this path on every checkpoint"
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
    --payload "$(printf '{"thread_id":"%s","session_id":"%s"}' "${THREAD_ID:--}" "${SESSION_ID:--}")"

  DS_OUT="$RUN_DIR/deepseek-r${ROUND}.out"
  PHASE="implementer r${ROUND}"
  set +e
  if [[ -n "$THREAD_ID" ]]; then
    run_step "$IMPL_SECS" "$DS_OUT" "$DS_OUT.wrap" "$DEEPSEEK" --resume "$THREAD_ID" "$HAND"
  else
    run_step "$IMPL_SECS" "$DS_OUT" "$DS_OUT.wrap" "$DEEPSEEK" "$HAND"
  fi
  ds_rc=$?
  set -e
  PHASE="assess r${ROUND}"
  verify_git_meta "during implementer r${ROUND}"
  LAST_DEEPSEEK="$(kv "$DS_OUT" DEEPSEEK_RESULT)"
  kv_keep THREAD_ID "$DS_OUT" THREAD_ID
  journal_ids
  RETURN_HANDOFF="$(kv "$DS_OUT" RETURN_HANDOFF)"
  DEEPSEEK_LOG="$(kv "$DS_OUT" LOG)"
  DEEPSEEK_ERR="$(kv "$DS_OUT" stderr)"
  [[ -s "$DS_OUT.wrap" ]] && cat "$DS_OUT.wrap" >&2 || true

  # Only DEEPSEEK_RESULT is required; the other lines are diagnostics.
  if [[ "$ds_rc" -eq 124 ]]; then
    wake "implementer-timeout" "no result after ${IMPL_SECS}s (DEEPSEEK_TIMEOUT). stderr: $DS_OUT.wrap"
  fi
  if [[ "$ds_rc" -eq 75 || "$LAST_DEEPSEEK" == rate_limited* ]]; then
    wake "rate_limited" "DEEPSEEK_RESULT=$LAST_DEEPSEEK"
  fi
  if [[ -z "$LAST_DEEPSEEK" ]]; then
    wake "implementer-error" "no DEEPSEEK_RESULT line (rc=$ds_rc). stderr: $DS_OUT.wrap"
  fi
  if [[ "$ds_rc" -ne 0 || "$LAST_DEEPSEEK" != ok ]]; then
    wake "implementer-error" "rc=$ds_rc DEEPSEEK_RESULT=$LAST_DEEPSEEK"
  fi

  # --- host assess --------------------------------------------------------
  git status --porcelain
  git log --oneline -15

  contract_drift
  if [[ -n "$CONTRACT_COMMITTED" ]]; then
    wake "contract-tamper-committed" "committed: $CONTRACT_COMMITTED — revert commits: $CONTRACT_COMMITS"
  fi
  if [[ -n "$CONTRACT_UNCOMMITTED" ]]; then
    # Per path: one pathspec absent at BASE_SHA must not block the others.
    for p in "${CONTRACT_PATHS[@]}"; do
      git checkout "$BASE_SHA" -- "$p" 2>/dev/null || true
    done
    wake "contract-tamper-worktree" "uncommitted: $CONTRACT_UNCOMMITTED"
  fi

  unexpected=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    p="${line:3}"
    p="${p#\"}"
    p="${p%\"}"
    if [[ "$p" == "GOALS.md" ]]; then
      if "$GOALS_PY" GOALS.md status-only-id "$GOAL_ID" "$RUN_DIR/goals-base.md" >/dev/null; then
        continue
      fi
    fi
    if [[ "$p" == "$JOURNAL" ]]; then
      continue
    fi
    unexpected+=("$p")
  done < <(git status --porcelain)
  if ((${#unexpected[@]})); then
    wake "dirty-tree" "unexpected paths: ${unexpected[*]}"
  fi

  PROOF_FILE="$RUN_DIR/proof-${GOAL_ID}-r${ROUND}.txt"
  if is_non_command_proof "$PROOF"; then
    echo "PROOF: none (no executable proof)" >"$PROOF_FILE"
    PROOF_EXIT=0
    PROOF_NONE=1
  else
    PROOF_NONE=0
    set +e
    # Plain -c, not -lc: the gate must not depend on the user's interactive
    # profile (aliases, PATH edits, version managers) being loaded.
    PHASE="proof r${ROUND}"
    tree_snapshot >"$RUN_DIR/tree-before-proof.txt"
    unsets=()
    while IFS= read -r u; do unsets+=("$u"); done < <(proof_env_unsets)
    run_step "$PROOF_SECS" "$PROOF_FILE" "$PROOF_FILE" \
      env "${unsets[@]+"${unsets[@]}"}" bash -c "$PROOF"
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
    if [[ "$(head -n1 "$RUN_DIR/tree-before-proof.txt")" != "$(head -n1 "$RUN_DIR/tree-after-proof.txt")" ]]; then
      moved+=("HEAD moved: $(git log --format=%h "$(head -n1 "$RUN_DIR/tree-before-proof.txt")"..HEAD | paste -sd ' ' -)")
    fi
    changed="$({ diff <(sed 1d "$RUN_DIR/tree-before-proof.txt") <(sed 1d "$RUN_DIR/tree-after-proof.txt") || true; } |
      sed -n 's/^[<>] //p' | sort -u)"
    created="$({ grep '^?? ' <<<"$changed" || true; } | cut -c4- | paste -sd ',' -)"
    changed="$({ grep -v '^?? ' <<<"$changed" || true; } | cut -c4- | sed '/^$/d' | sort -u | paste -sd ',' -)"
    [[ -z "$changed" ]] || moved+=("tracked changes: $changed")
    [[ -z "$created" ]] || moved+=("new files not in .gitignore: $created (declare build output in .gitignore; anything else is unreviewed code)")
    [[ -z "$CONTRACT_COMMITTED$CONTRACT_UNCOMMITTED" ]] ||
      moved+=("contract: ${CONTRACT_COMMITTED}${CONTRACT_COMMITTED:+,}${CONTRACT_UNCOMMITTED}")
    if ((${#moved[@]})); then
      wake "proof-tamper" "the proof changed the repo — $(printf '%s; ' "${moved[@]}")output: $PROOF_FILE"
    fi
    if [[ "$PROOF_EXIT" -ne 0 ]] || grep -q 'Ran 0 tests' "$PROOF_FILE"; then
      if [[ "$LAST_DEEPSEEK" == ok* ]]; then
        wake "proof-red" "host proof exit $PROOF_EXIT after DEEPSEEK_RESULT=ok"
      fi
      wake "proof-red" "host proof exit $PROOF_EXIT"
    fi
  fi

  DIFF="$RUN_DIR/diff-${GOAL_ID}-r${ROUND}.patch"
  git diff --no-ext-diff --no-textconv "$BASE_SHA"..HEAD -- . ':!GOALS.md' ":!${JOURNAL}" >"$DIFF"
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
  set +e
  # --add-dir $RUN_DIR or the reviewer cannot open BRIEF / DIFF_FILE /
  # PROOF_OUTPUT at all: headless Claude denies reads outside the repo and
  # there is nobody to approve the prompt. It then reviews on no evidence.
  if [[ -n "$SESSION_ID" ]]; then
    run_step "$REVIEW_SECS" "$RV_OUT" "$RV_OUT.wrap" "$REVIEWER" --resume "$SESSION_ID" --add-dir "$RUN_DIR" "$BRIEF"
  else
    run_step "$REVIEW_SECS" "$RV_OUT" "$RV_OUT.wrap" "$REVIEWER" --add-dir "$RUN_DIR" "$BRIEF"
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
  if [[ -z "$LAST_CLAUDE" ]]; then
    LAST_VERDICT="MISSING"
    wake "reviewer-error" "no CLAUDE_REVIEW_RESULT line (rc=$rv_rc). stderr: $RV_OUT.wrap"
  fi
  if [[ "$LAST_CLAUDE" != "ok" ]]; then
    LAST_VERDICT="MISSING"
    wake "reviewer-error" "CLAUDE_REVIEW_RESULT=$LAST_CLAUDE rc=$rv_rc"
  fi
  LAST_VERDICT="$(kv "$RV_OUT" VERDICT)"

  journal_line "## $(utc) — ORCHESTRATOR review ${GOAL_ID} r${ROUND} VERDICT=${LAST_VERDICT}"
  review_sev=info
  case "$LAST_VERDICT" in
    FIX) review_sev=warning ;;
    BLOCKED|MISSING) review_sev=error ;;
  esac
  events_append --event review --severity "$review_sev" --goal "$GOAL_ID" --round "$ROUND" \
    --verdict "$LAST_VERDICT" --base-sha "$BASE_SHA" \
    --summary "review ${GOAL_ID} r${ROUND} VERDICT=${LAST_VERDICT}"

  case "$LAST_VERDICT" in
    DONE)
      if [[ "${PROOF_NONE:-0}" -eq 1 ]]; then
        wake "done-refused" "PROOF: none cannot auto-done. Review: $VERDICT_FILE"
      fi
      "$GOALS_PY" GOALS.md set "$GOAL_ID" done
      journal_line "## $(utc) — ORCHESTRATOR done ${GOAL_ID} r${ROUND}"
      events_append --event done --severity info --goal "$GOAL_ID" --round "$ROUND" \
        --verdict DONE --base-sha "$BASE_SHA" \
        --summary "done ${GOAL_ID} r${ROUND}"
      orch_commit "chore(${GOAL_ID}): orchestrator done"
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
        "$GOALS_PY" GOALS.md set "$GOAL_ID" bounced
        orch_commit "chore(${GOAL_ID}): orchestrator bounced"
        wake "blocked-oracle-edit" "a FIX finding names the oracle / tests/acceptance"
      fi
      FIX_HASH="$(shasum -a 256 "$FINDINGS" | awk '{print $1}')"
      FIXH="$RUN_DIR/handoff-${GOAL_ID}-fix-r${ROUND}.md"
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
      journal_line "## $(utc) — ORCHESTRATOR fix ${GOAL_ID} r${ROUND} count=${FIX_COUNT_N} hash=${FIX_HASH}"
      events_append --event fix --severity warning --goal "$GOAL_ID" --round "$ROUND" \
        --verdict FIX --base-sha "$BASE_SHA" \
        --summary "fix ${GOAL_ID} r${ROUND} count=${FIX_COUNT_N} hash=${FIX_HASH}" \
        --payload "$(printf '{"fix_count":%s,"fix_hash":"%s"}' "$FIX_COUNT_N" "$FIX_HASH")"
      ROUND=$((ROUND + 1))
      # ROUND counts fix rounds already spent, so >= gives exactly
      # MAX_FIX_ROUNDS of them (was > — one extra implementer pass).
      if [[ "$ROUND" -ge "$MAX_FIX_ROUNDS" ]]; then
        wake "max-fix-rounds" "MAX_FIX_ROUNDS=$MAX_FIX_ROUNDS"
      fi
      FIX_HANDOFF="$FIXH"
      continue
      ;;
    BLOCKED)
      "$GOALS_PY" GOALS.md set "$GOAL_ID" bounced
      journal_line "## $(utc) — ORCHESTRATOR bounced ${GOAL_ID} r${ROUND}"
      events_append --event bounced --severity error --goal "$GOAL_ID" --round "$ROUND" \
        --verdict BLOCKED --base-sha "$BASE_SHA" \
        --summary "bounced ${GOAL_ID} r${ROUND}"
      orch_commit "chore(${GOAL_ID}): orchestrator bounced"
      wake "blocked" "reviewer BLOCKED. $VERDICT_FILE"
      ;;
    *)
      wake "missing-verdict" "VERDICT=$LAST_VERDICT"
      ;;
  esac
done
