#!/usr/bin/env bash
#
# claude-review.sh — one adversarial PLAN-review round via headless
# Claude Opus 5. The Architect (Grok) calls this after locking PLAN.md.
# Opus 5 is read-only: it can Read/Glob/Grep, it cannot edit, write, or
# shell. Same Claude session across rounds so it remembers its prior
# critiques (--resume).
#
# This file owns the review prompt. Do not fork it in AGENTS.md or the
# crucible skill.
#
# Usage:
#   claude-review.sh [--resume SESSION_ID] [PLAN.md]
#   claude-review.sh --smoke
#
# Required: Claude Code binary (see CLAUDE_REAL_BIN resolution below),
# authenticated via `claude login` or ANTHROPIC_API_KEY (real Anthropic).
# Optional env:
#   CLAUDE_REVIEW_MODEL    default: claude-opus-5
#   CLAUDE_REVIEW_EFFORT   default: high
#   CLAUDE_REVIEW_DRY_RUN=1   print the command, skip the API call
#   CLAUDE_REVIEW_OUT      override the verdict file path
#
# Result lines (stdout, parse these):
#   CLAUDE_REVIEW_RESULT: ok | rate_limited | error
#   SESSION_ID: <uuid>
#   VERDICT: APPROVED | REVISE | MISSING
#   VERDICT_FILE: <path>
#
# Architect: run from the target repo root. Foreground timeout 600000 ms.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/dotenv.sh"
HOUSE="$(cd "$HERE/.." && pwd)"

MODEL="${CLAUDE_REVIEW_MODEL:-claude-opus-5}"
EFFORT="${CLAUDE_REVIEW_EFFORT:-high}"
SMOKE=0
RESUME_ID=""
PLAN=""

usage() {
  echo "usage: claude-review.sh [--resume SESSION_ID] [PLAN.md]" >&2
  echo "       claude-review.sh --smoke" >&2
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
      [[ -z "$PLAN" ]] || usage
      PLAN="$1"
      shift
      ;;
  esac
done

# Resolve the REAL claude binary. The interactive `claude` wrapper is a
# provider switcher; we bypass it. Unset ANTHROPIC_BASE_URL so a leftover
# Kimi/Minimax/Z.AI redirect cannot steal this call.
CLAUDE_BIN="${CLAUDE_REAL_BIN:-}"
[[ -z "$CLAUDE_BIN" && -x "$HOME/.local/bin/claude" ]] && CLAUDE_BIN="$HOME/.local/bin/claude"
[[ -z "$CLAUDE_BIN" ]] && CLAUDE_BIN="$(command -v claude || true)"
: "${CLAUDE_BIN:?could not find the claude binary (set CLAUDE_REAL_BIN)}"
unset ANTHROPIC_BASE_URL || true

load_key_from_files ANTHROPIC_API_KEY .env "$HOUSE/.env" || true

new_session_id() {
  uuidgen | tr '[:upper:]' '[:lower:]'
}

extract_json() {
  "$HERE/lib/claude-result.py"
}

verdict_of() {
  local last
  last="$(grep -oE 'VERDICT:[[:space:]]*(APPROVED|REVISE)' "$1" | tail -n1 || true)"
  case "$last" in
    *APPROVED*) echo APPROVED ;;
    *REVISE*) echo REVISE ;;
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
  raw="$(mktemp -t claude-review-raw-XXXXXX.json)"
  set +e
  "${cmd[@]}" >"$raw" 2>"${raw}.err"
  rc=$?
  set -e

  if is_transport_rate_limit "$rc" "${raw}.err"; then
    echo "CLAUDE_REVIEW_RESULT: rate_limited (exit ${rc})"
    echo "SESSION_ID: ${SESSION_ID}"
    echo "VERDICT: MISSING"
    echo "VERDICT_FILE: ${raw}"
    echo "stderr: ${raw}.err"
    exit 75
  fi

  if [[ $rc -ne 0 ]]; then
    echo "CLAUDE_REVIEW_RESULT: error (exit ${rc})"
    echo "SESSION_ID: ${SESSION_ID}"
    echo "VERDICT: MISSING"
    echo "VERDICT_FILE: ${raw}"
    echo "stderr: ${raw}.err"
    cat "${raw}.err" >&2 || true
    exit "$rc"
  fi

  local parsed parsed_sid parsed_text
  parsed="$(extract_json <"$raw")" || {
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
  local verdict
  verdict="$(verdict_of "$OUT")"

  echo "CLAUDE_REVIEW_RESULT: ok"
  echo "SESSION_ID: ${SESSION_ID}"
  echo "VERDICT: ${verdict}"
  echo "VERDICT_FILE: ${OUT}"
}

# --- smoke -----------------------------------------------------------------
if [[ "$SMOKE" -eq 1 ]]; then
  EFFORT="low"
  SESSION_ID="$(new_session_id)"
  OUT="${CLAUDE_REVIEW_OUT:-${TMPDIR:-/tmp}/claude-review-smoke-$$.md}"
  run_claude "Reply with exactly this single line and nothing else:
PONG ${MODEL}
VERDICT: APPROVED"
  exit 0
fi
# ---------------------------------------------------------------------------

PLAN="${PLAN:-PLAN.md}"
[[ -f "$PLAN" ]] || { echo "plan not found: $PLAN" >&2; exit 1; }

if [[ -n "$RESUME_ID" ]]; then
  SESSION_ID="$RESUME_ID"
else
  SESSION_ID="$(new_session_id)"
fi
OUT="${CLAUDE_REVIEW_OUT:-${TMPDIR:-/tmp}/claude-review-${SESSION_ID}-$(date -u +%Y%m%dT%H%M%SZ).md}"

# Resolve to an absolute path so the attacker can open it regardless of
# how Claude Code interprets cwd under --safe-mode.
PLAN_ABS="$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")"

if [[ -n "$RESUME_ID" ]]; then
  read -r -d '' PROMPT <<EOF || true
I revised the plan. Re-review the file at ${PLAN_ABS} (and CONTEXT.md / docs/adr / any repo files you need; you are read-only). Check whether your prior findings are addressed and flag anything new. Same rules as before. Do NOT modify any files. End your reply with EXACTLY one line: VERDICT: APPROVED or VERDICT: REVISE.
EOF
else
  read -r -d '' PROMPT <<EOF || true
You are an adversarial reviewer for an implementation plan. Be skeptical and specific — your job is to find what breaks, not to be agreeable. Read the plan at ${PLAN_ABS} (and CONTEXT.md / ADRs for domain language, if present) and any repo files you need (you are read-only). Identify concrete flaws: security holes, race conditions, missing edge cases, schema conflicts, wrong assumptions, observability gaps, simpler alternatives. For each, give a one-line fix. Do NOT modify any files. End your reply with EXACTLY one line: VERDICT: APPROVED if the plan is sound enough to implement, or VERDICT: REVISE if it still has material problems.
EOF
fi

run_claude "$PROMPT"
