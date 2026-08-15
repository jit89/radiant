#!/usr/bin/env bash
#
# claude-goal-review.sh — one GOAL REVIEW round via headless Claude
# Opus 5. This is NOT the plan attacker (see claude-review.sh). The
# reviewer judges an implementer's diff against a goal until DONE.
#
# This file owns the reviewer prompt. Do not fork it. Do not reuse the
# attacker prompt.
#
# Usage:
#   claude-goal-review.sh [--resume SESSION_ID] <brief.md>
#   claude-goal-review.sh --smoke
#
# Brief SHOULD contain:
#   GOAL: <id>
#   PLAN: PLAN.md
#   GOALS: GOALS.md
#   ORACLE: <path|inline>
#   DIFF_FILE: <path>        # Architect-written git diff (read this)
#   DIFF_RANGE: <sha>..HEAD  # informational
#   PROOF_OUTPUT: <path>     # Architect-run proof, packed as ground truth
#
# Optional env: same as claude-review.sh (CLAUDE_REVIEW_MODEL / EFFORT /
# DRY_RUN / OUT). Result lines:
#   CLAUDE_REVIEW_RESULT: ok | rate_limited | error | dry_run
#   SESSION_ID: <uuid>
#   VERDICT: DONE | FIX | BLOCKED | MISSING
#   VERDICT_FILE: <path>
#
# Architect: run from the target repo. Timeout 10 minutes (600000 ms).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/dotenv.sh"
HOUSE="$(cd "$HERE/.." && pwd)"
MODEL="${CLAUDE_REVIEW_MODEL:-claude-opus-5}"
EFFORT="${CLAUDE_REVIEW_EFFORT:-high}"
SMOKE=0
RESUME_ID=""
BRIEF=""

usage() {
  echo "usage: claude-goal-review.sh [--resume SESSION_ID] <brief.md>" >&2
  echo "       claude-goal-review.sh --smoke" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --smoke) SMOKE=1; shift ;;
    --resume)
      [[ $# -ge 2 ]] || usage
      RESUME_ID="$2"
      shift 2
      ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*) usage ;;
    *)
      [[ -z "$BRIEF" ]] || usage
      BRIEF="$1"
      shift
      ;;
  esac
done

CLAUDE_BIN="${CLAUDE_REAL_BIN:-}"
[[ -z "$CLAUDE_BIN" && -x "$HOME/.local/bin/claude" ]] && CLAUDE_BIN="$HOME/.local/bin/claude"
[[ -z "$CLAUDE_BIN" ]] && CLAUDE_BIN="$(command -v claude || true)"
: "${CLAUDE_BIN:?could not find the claude binary (set CLAUDE_REAL_BIN)}"
unset ANTHROPIC_BASE_URL || true

load_key_from_files ANTHROPIC_API_KEY .env "$HOUSE/.env" || true

new_session_id() { uuidgen | tr '[:upper:]' '[:lower:]'; }

verdict_of() {
  # Last non-empty line only. A quoted VERDICT: DONE in the body must not win.
  # The prompt's example is `VERDICT: DONE — goal is met…`; accept a suffix
  # after the token (bash case globs are not regex, so VERDICT:*DONE required
  # the line to *end* with DONE and treated the documented example as MISSING).
  local last token
  last="$(grep -Ev '^[[:space:]]*$' "$1" | tail -n1 | tr -d '\r' || true)"
  token="${last#VERDICT:}"
  token="${token#"${token%%[![:space:]]*}"}"
  token="${token%%[[:space:]—-]*}"
  case "$token" in
    DONE) echo DONE ;;
    FIX) echo FIX ;;
    BLOCKED) echo BLOCKED ;;
    *) echo MISSING ;;
  esac
}

run_claude() {
  local prompt="$1"
  local session_flag=(--session-id "$SESSION_ID")
  if [[ -n "$RESUME_ID" ]]; then
    session_flag=(--resume "$RESUME_ID")
    SESSION_ID="$RESUME_ID"
  fi

  local cmd=(
    "$CLAUDE_BIN" -p "$prompt"
    --model "$MODEL"
    --effort "$EFFORT"
    --output-format json
    --permission-mode plan
    --tools Read,Glob,Grep
    --safe-mode
    "${session_flag[@]}"
  )

  if [[ "${CLAUDE_REVIEW_DRY_RUN:-0}" == "1" ]]; then
    echo "CLAUDE_REVIEW_RESULT: dry_run"
    echo "SESSION_ID: ${SESSION_ID}"
    echo "VERDICT: MISSING"
    echo "VERDICT_FILE: (dry run — no file)"
    printf 'CMD:'
    printf ' %q' "${cmd[@]}"
    printf '\n'
    exit 0
  fi

  local raw rc
  raw="$(mktemp -t claude-goal-raw-XXXXXX.json)"
  set +e
  "${cmd[@]}" >"$raw" 2>"${raw}.err"
  rc=$?
  set -e

  if is_transport_rate_limit "$rc" "${raw}.err"; then
    echo "CLAUDE_REVIEW_RESULT: rate_limited (exit ${rc})"
    echo "SESSION_ID: ${SESSION_ID}"
    echo "VERDICT: MISSING"
    echo "VERDICT_FILE: ${raw}"
    exit 75
  fi

  if [[ $rc -ne 0 ]]; then
    echo "CLAUDE_REVIEW_RESULT: error (exit ${rc})"
    echo "SESSION_ID: ${SESSION_ID}"
    echo "VERDICT: MISSING"
    echo "VERDICT_FILE: ${raw}"
    cat "${raw}.err" >&2 || true
    exit "$rc"
  fi

  local parsed parsed_sid parsed_text
  parsed="$("$HERE/lib/claude-result.py" <"$raw")" || {
    echo "CLAUDE_REVIEW_RESULT: error (unparseable JSON)"
    echo "SESSION_ID: ${SESSION_ID}"
    echo "VERDICT: MISSING"
    echo "VERDICT_FILE: ${raw}"
    exit 1
  }
  parsed_sid="${parsed%%$'\t'*}"
  parsed_text="${parsed#*$'\t'}"
  [[ -n "$parsed_sid" ]] && SESSION_ID="$parsed_sid"

  printf '%s\n' "$parsed_text" >"$OUT"
  echo "CLAUDE_REVIEW_RESULT: ok"
  echo "SESSION_ID: ${SESSION_ID}"
  echo "VERDICT: $(verdict_of "$OUT")"
  echo "VERDICT_FILE: ${OUT}"
}

if [[ "$SMOKE" -eq 1 ]]; then
  EFFORT="low"
  SESSION_ID="$(new_session_id)"
  OUT="${CLAUDE_REVIEW_OUT:-${TMPDIR:-/tmp}/claude-goal-smoke-$$.md}"
  run_claude "You are a goal reviewer, not a plan attacker. Reply with exactly:
PONG ${MODEL}
VERDICT: DONE"
  exit 0
fi

[[ -n "$BRIEF" ]] || usage
[[ -f "$BRIEF" ]] || { echo "brief not found: $BRIEF" >&2; exit 1; }
BRIEF_ABS="$(cd "$(dirname "$BRIEF")" && pwd)/$(basename "$BRIEF")"

if [[ -n "$RESUME_ID" ]]; then
  SESSION_ID="$RESUME_ID"
else
  SESSION_ID="$(new_session_id)"
fi
OUT="${CLAUDE_REVIEW_OUT:-${TMPDIR:-/tmp}/claude-goal-${SESSION_ID}-$(date -u +%Y%m%dT%H%M%SZ).md}"

if [[ -n "$RESUME_ID" ]]; then
  read -r -d '' PROMPT <<EOF || true
I applied your last FIX list (or the Architect bounced a blocker). Re-review the same goal. Read the brief at ${BRIEF_ABS} first (GOAL / PLAN / GOALS / ORACLE / DIFF_FILE / PROOF_OUTPUT), then the DIFF_FILE. Same rules. You do not edit files. End with EXACTLY one line: VERDICT: DONE or VERDICT: FIX or VERDICT: BLOCKED.
EOF
else
  read -r -d '' PROMPT <<EOF || true
You are the GOAL REVIEWER (model: ${MODEL}), not the plan attacker and not the implementer. You judge whether one goal is done. You do not write production code and you do not re-litigate product decisions locked in PLAN.md.

Read the brief at ${BRIEF_ABS}. It names:
- GOAL — the id in GOALS.md
- PLAN, GOALS, ORACLE
- DIFF_FILE — the Architect-written git diff. This is the change. Read it.
- DIFF_RANGE — informational (the range used to produce DIFF_FILE)
- PROOF_OUTPUT — actual output of the proof command the Architect already ran. Treat it as ground truth. Do not invent a different test result.

Then read GOALS.md (that goal only), PLAN.md, the oracle file if it is not "inline", CONTEXT.md, coding-standards.md if present, and DIFF_FILE. Identify:

1. SPEC — does the diff implement this goal and only this goal?
2. ORACLE — is the acceptance file unmodified? A touch is CRITICAL.
3. TESTS — do the implementer's own tests cover the case table? Assertions exact? Name one plausible bug the suite would miss.
4. FAKE SUCCESS — weakened/skipped/deleted tests, assert-true, over-mocking.
5. CEILINGS — load-bearing simplifications missing a ponytail comment.
6. SMELLS — Fowler list as judgement calls, never hard violations; coding-standards.md overrides.

You are read-only. Do not edit files.

End the body with EXACTLY one line:
- VERDICT: DONE — goal is met, oracle green and untouched, no critical findings.
- VERDICT: FIX — material problems the implementer can fix. Number them (file:line, defect, what to change).
- VERDICT: BLOCKED — the spec/oracle/goal is wrong or ambiguous. This is for the Architect, not another implementer pass.
EOF
fi

run_claude "$PROMPT"
