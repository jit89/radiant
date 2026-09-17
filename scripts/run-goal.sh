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

GOALS_PY="$HERE/goals.py"
DEEPSEEK="$HERE/deepseek-code.sh"
REVIEWER="$HERE/claude-goal-review.sh"

MAX_FIX_ROUNDS="${MAX_FIX_ROUNDS:-3}"
IMPL_SECS="${DEEPSEEK_TIMEOUT:-1200}"
REVIEW_SECS="${CLAUDE_REVIEW_TIMEOUT:-600}"

GOAL_ID="${1:-}"
RUN_DIR=""
STOP_FILE=""
ART_DIR=""
JOURNAL=""
ORACLE=""
PROOF=""
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
  if [[ "$ec" -ne 0 && "$STOP_WRITTEN" -eq 0 && -n "$RUN_DIR" ]]; then
    write_stop "trap" "exit $ec" || true
    record_wake "trap" || true
    STOP_WRITTEN=1
  fi
  if [[ -n "$STOP_FILE" && -f "$STOP_FILE" ]]; then
    echo "STOP_FILE: $STOP_FILE"
  fi
  exit "$ec"
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
$(git status --porcelain 2>/dev/null || echo "(no git)")
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
  if [[ -n "${JOURNAL:-}" && -f "${JOURNAL}" ]] && tracked_in_head "$JOURNAL"; then
    journal_line "## $(utc) — ORCHESTRATOR wake ${GOAL_ID:-?} r${ROUND} reason=${reason}"
  fi
  events_append --event wake --severity "$sev" \
    --goal "${GOAL_ID:-}" --round "${ROUND}" --reason "$reason" \
    --verdict "${LAST_VERDICT:-}" --base-sha "${BASE_SHA:-}" \
    --summary "wake ${GOAL_ID:-?} r${ROUND} reason=${reason}"
  if [[ -n "${JOURNAL:-}" && -f "${JOURNAL}" ]] && tracked_in_head "$JOURNAL"; then
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

kv() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  grep -E "^${key}:" "$file" | tail -n1 | sed -E "s/^${key}:[[:space:]]*//"
}

is_non_command_proof() {
  case "${1:-}" in
    "" | true | inline | "(case table)") return 0 ;;
    *) return 1 ;;
  esac
}

run_timeout() {
  local secs="$1"
  shift
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout --kill-after=5 "$secs" "$@"
    return
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=5 "$secs" "$@"
    return
  fi
  python3 - "$secs" "$@" <<'PY'
import os, signal, subprocess, sys
secs = int(sys.argv[1])
cmd = sys.argv[2:]
p = subprocess.Popen(cmd, start_new_session=True)
try:
    rc = p.wait(timeout=secs)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGTERM)
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait()
    sys.exit(124)
sys.exit(rc)
PY
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

parse_last_dispatch() {
  local gid="$1"
  [[ -f "$JOURNAL" ]] || return 1
  local line
  line="$(grep -E "ORCHESTRATOR dispatch ${gid} " "$JOURNAL" | tail -n1 || true)"
  [[ -n "$line" ]] || return 1
  BASE_SHA="$(sed -n 's/.*BASE_SHA=\([^ ]*\).*/\1/p' <<<"$line")"
  THREAD_ID="$(sed -n 's/.*THREAD_ID=\([^ ]*\).*/\1/p' <<<"$line")"
  SESSION_ID="$(sed -n 's/.*SESSION_ID=\([^ ]*\).*/\1/p' <<<"$line")"
  ROUND="$(sed -n 's/.* r\([0-9][0-9]*\) .*/\1/p' <<<"$line")"
  [[ "$THREAD_ID" == "-" ]] && THREAD_ID=""
  [[ "$SESSION_ID" == "-" ]] && SESSION_ID=""
  [[ -n "$BASE_SHA" ]]
}

# --- start -----------------------------------------------------------------
[[ -n "$GOAL_ID" && "$GOAL_ID" != "-h" && "$GOAL_ID" != "--help" ]] || usage

trap on_exit EXIT INT TERM

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die_gate "not a git repo"
cd "$ROOT"

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/run-goal-${GOAL_ID}-XXXXXX")"
chmod 700 "$RUN_DIR"
STOP_FILE="$RUN_DIR/stop.md"
ART_DIR="$HOME/.cache/claude-coding-workflow/run-goal-${GOAL_ID}"
mkdir -p "$ART_DIR"

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

ORACLE="$("$GOALS_PY" GOALS.md show "$GOAL_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("oracle") or "")')"
PROOF="$("$GOALS_PY" GOALS.md show "$GOAL_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("proof") or "")')"

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
  if [[ "$ORACLE" != "inline" ]] && ! git diff --quiet -- "$ORACLE"; then
    die_gate "file oracle $ORACLE is dirty on resume"
  fi
  if [[ -d tests/acceptance ]] && ! git diff --quiet -- tests/acceptance; then
    die_gate "tests/acceptance/ is dirty on resume"
  fi
fi

if ! load_key_from_files DEEPSEEK_API_KEY .env "$HOUSE/.env"; then
  die_gate "DEEPSEEK_API_KEY is not set (target .env or $HOUSE/.env). Do not paste it."
fi

if [[ "$RESUME" -eq 1 ]]; then
  parse_last_dispatch "$GOAL_ID" || die_gate "in_progress but no journaled BASE_SHA for $GOAL_ID"
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

# --- implement / review loop ----------------------------------------------
FIX_HANDOFF=""
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
      echo "- PLAN: PLAN.md"
      echo "- GOALS: GOALS.md (read fence from BASE_SHA)"
      echo "- Journal: \`$JOURNAL\` — git add this path on every checkpoint"
      echo "- Oracle (READ-ONLY): \`$ORACLE\`"
      echo "- BASE_SHA: \`$BASE_SHA\`"
      echo "- Proof: \`$PROOF\`"
      echo "- Suggested skills: tdd"
      echo
      "$GOALS_PY" "$RUN_DIR/goals-base.md" body "$GOAL_ID" 2>/dev/null || \
        echo "(no markdown body for $GOAL_ID in goals-base.md)"
    } >"$HAND"
  fi

  journal_line "## $(utc) — ORCHESTRATOR dispatch ${GOAL_ID} r${ROUND} BASE_SHA=${BASE_SHA} THREAD_ID=${THREAD_ID:--} SESSION_ID=${SESSION_ID:--}"
  events_append --event dispatch --severity info --goal "$GOAL_ID" --round "$ROUND" \
    --base-sha "$BASE_SHA" \
    --summary "dispatch ${GOAL_ID} r${ROUND} BASE_SHA=${BASE_SHA}" \
    --payload "$(printf '{"thread_id":"%s","session_id":"%s"}' "${THREAD_ID:--}" "${SESSION_ID:--}")"

  DS_OUT="$RUN_DIR/deepseek-r${ROUND}.out"
  set +e
  if [[ -n "$THREAD_ID" ]]; then
    run_timeout "$IMPL_SECS" "$DEEPSEEK" --resume "$THREAD_ID" "$HAND" >"$DS_OUT" 2>"$DS_OUT.wrap"
  else
    run_timeout "$IMPL_SECS" "$DEEPSEEK" "$HAND" >"$DS_OUT" 2>"$DS_OUT.wrap"
  fi
  ds_rc=$?
  set -e
  LAST_DEEPSEEK="$(kv "$DS_OUT" DEEPSEEK_RESULT)"
  THREAD_ID="$(kv "$DS_OUT" THREAD_ID)"
  RETURN_HANDOFF="$(kv "$DS_OUT" RETURN_HANDOFF)"
  DEEPSEEK_LOG="$(kv "$DS_OUT" LOG)"
  DEEPSEEK_ERR="$(kv "$DS_OUT" stderr)"
  [[ -s "$DS_OUT.wrap" ]] && cat "$DS_OUT.wrap" >&2 || true

  if [[ "$ds_rc" -eq 75 || "$LAST_DEEPSEEK" == rate_limited* ]]; then
    wake "rate_limited" "DEEPSEEK_RESULT=$LAST_DEEPSEEK"
  fi
  if [[ "$ds_rc" -ne 0 || "$LAST_DEEPSEEK" == error* ]]; then
    wake "implementer-error" "rc=$ds_rc DEEPSEEK_RESULT=$LAST_DEEPSEEK"
  fi

  # --- host assess --------------------------------------------------------
  git status --porcelain
  git log --oneline -15

  contract_paths=()
  [[ "$ORACLE" != "inline" && -n "$ORACLE" ]] && contract_paths+=("$ORACLE")
  [[ -d tests/acceptance ]] && contract_paths+=("tests/acceptance")

  committed_touch=""
  worktree_touch=""
  if ((${#contract_paths[@]})); then
    committed_touch="$(git diff --name-only "$BASE_SHA" HEAD -- "${contract_paths[@]}" || true)"
    worktree_touch="$(git diff --name-only HEAD -- "${contract_paths[@]}" || true)"
  fi
  if [[ "$ORACLE" == "inline" ]]; then
    "$GOALS_PY" "$RUN_DIR/goals-base.md" body "$GOAL_ID" >"$RUN_DIR/body-base.md" || true
    if "$GOALS_PY" GOALS.md body "$GOAL_ID" >"$RUN_DIR/body-now.md" 2>/dev/null; then
      if ! cmp -s "$RUN_DIR/body-base.md" "$RUN_DIR/body-now.md"; then
        worktree_touch="${worktree_touch}"$'\n'"GOALS.md (inline body)"
      fi
    fi
  fi
  if ! "$GOALS_PY" GOALS.md status-only-id "$GOAL_ID" "$RUN_DIR/goals-base.md" >/dev/null; then
    worktree_touch="${worktree_touch}"$'\n'"GOALS.md (fence beyond this id status)"
  fi

  if [[ -n "$(echo "$committed_touch" | sed '/^$/d')" ]]; then
    wake "contract-tamper-committed" "revert: git revert $(git rev-parse HEAD)  (touched: $committed_touch)"
  fi
  if [[ -n "$(echo "$worktree_touch" | sed '/^$/d')" ]]; then
    if ((${#contract_paths[@]})); then
      git checkout "$BASE_SHA" -- "${contract_paths[@]}" || true
      git restore --staged "${contract_paths[@]}" || true
    fi
    wake "contract-tamper-worktree" "$worktree_touch"
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
    bash -c "$PROOF" >"$PROOF_FILE" 2>&1
    PROOF_EXIT=$?
    set -e
    if [[ "$PROOF_EXIT" -ne 0 ]] || grep -q 'Ran 0 tests' "$PROOF_FILE"; then
      if [[ "$LAST_DEEPSEEK" == ok* ]]; then
        wake "proof-red" "host proof exit $PROOF_EXIT after DEEPSEEK_RESULT=ok"
      fi
      wake "proof-red" "host proof exit $PROOF_EXIT"
    fi
  fi

  DIFF="$RUN_DIR/diff-${GOAL_ID}-r${ROUND}.patch"
  git diff "$BASE_SHA"..HEAD -- . ':!GOALS.md' ":!${JOURNAL}" >"$DIFF"
  if [[ ! -s "$DIFF" ]]; then
    wake "empty-diff" "no implementer changes in $BASE_SHA..HEAD"
  fi

  BRIEF="$RUN_DIR/review-${GOAL_ID}-r${ROUND}.md"
  cat >"$BRIEF" <<EOF
GOAL: ${GOAL_ID}
PLAN: PLAN.md
GOALS: GOALS.md
ORACLE: ${ORACLE}
DIFF_FILE: ${DIFF}
DIFF_RANGE: ${BASE_SHA}..HEAD
PROOF_OUTPUT: ${PROOF_FILE}

Number FIX findings as "1. file:line — defect — what to change".
Do not ask the implementer to edit the oracle or tests/acceptance/.
EOF

  RV_OUT="$RUN_DIR/reviewer-r${ROUND}.out"
  set +e
  # --add-dir $RUN_DIR or the reviewer cannot open BRIEF / DIFF_FILE /
  # PROOF_OUTPUT at all: headless Claude denies reads outside the repo and
  # there is nobody to approve the prompt. It then reviews on no evidence.
  if [[ -n "$SESSION_ID" ]]; then
    run_timeout "$REVIEW_SECS" "$REVIEWER" --resume "$SESSION_ID" --add-dir "$RUN_DIR" "$BRIEF" >"$RV_OUT" 2>"$RV_OUT.wrap"
  else
    run_timeout "$REVIEW_SECS" "$REVIEWER" --add-dir "$RUN_DIR" "$BRIEF" >"$RV_OUT" 2>"$RV_OUT.wrap"
  fi
  rv_rc=$?
  set -e
  [[ -s "$RV_OUT.wrap" ]] && cat "$RV_OUT.wrap" >&2 || true
  LAST_CLAUDE="$(kv "$RV_OUT" CLAUDE_REVIEW_RESULT)"
  SESSION_ID="$(kv "$RV_OUT" SESSION_ID)"
  VERDICT_FILE="$(kv "$RV_OUT" VERDICT_FILE)"
  cp -f "$VERDICT_FILE" "$ART_DIR/verdict-r${ROUND}.md" 2>/dev/null || true

  if [[ "$rv_rc" -eq 75 || "$LAST_CLAUDE" == rate_limited* ]]; then
    wake "reviewer-rate-limited" "$LAST_CLAUDE"
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
      journal_line "## $(utc) — ORCHESTRATOR fix ${GOAL_ID} r${ROUND} count=${FIX_COUNT_N} hash=${FIX_HASH}"
      events_append --event fix --severity warning --goal "$GOAL_ID" --round "$ROUND" \
        --verdict FIX --base-sha "$BASE_SHA" \
        --summary "fix ${GOAL_ID} r${ROUND} count=${FIX_COUNT_N} hash=${FIX_HASH}" \
        --payload "$(printf '{"fix_count":%s,"fix_hash":"%s"}' "$FIX_COUNT_N" "$FIX_HASH")"
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
      cp -f "$FIXH" "$ART_DIR/fix-r${ROUND}.md"
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
