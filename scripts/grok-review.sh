#!/usr/bin/env bash
#
# grok-review.sh — one adversarial PLAN-review round via headless Grok.
# The Architect (Claude Code) calls this after locking PLAN.md. Grok is
# read-only: it can read_file / grep_search / list_dir, it cannot edit,
# write, or shell. Same Grok session across rounds so it remembers its
# prior critiques (--resume).
#
# Grok attacks the plan precisely because Claude wrote it. Do not swap
# this launcher for a Claude one — that is the Architect grading its
# own homework.
#
# This file owns the review prompt. Do not fork it in CLAUDE.md or the
# crucible skill.
#
# Usage:
#   grok-review.sh [--resume SESSION_ID] [PLAN.md]
#   grok-review.sh --smoke
#
# Required: Grok CLI on PATH (or GROK_BIN / ~/.grok/bin/grok), signed in
# with `grok login`.
# Optional env:
#   GROK_REVIEW_MODEL     default: grok-4.7
#   GROK_REVIEW_EFFORT    default: high
#   GROK_REVIEW_DRY_RUN=1 print the command, skip the API call
#   GROK_REVIEW_OUT       override the verdict file path
#
# Result lines (stdout, parse these):
#   GROK_REVIEW_RESULT: ok | rate_limited | error | dry_run
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

MODEL="${GROK_REVIEW_MODEL:-grok-4.7}"
EFFORT="${GROK_REVIEW_EFFORT:-high}"
SMOKE=0
RESUME_ID=""
PLAN=""

usage() {
  echo "usage: grok-review.sh [--resume SESSION_ID] [PLAN.md]" >&2
  echo "       grok-review.sh --smoke" >&2
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

find_grok() {
  if [[ -n "${GROK_BIN:-}" && -x "$GROK_BIN" ]]; then
    printf '%s' "$GROK_BIN"; return 0
  fi
  local c
  c="$(command -v grok 2>/dev/null || true)"
  [[ -n "$c" ]] && { printf '%s' "$c"; return 0; }
  for c in "$HOME/.grok/bin/grok" "$HOME/.local/bin/grok" /opt/homebrew/bin/grok; do
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

GROK_BIN="$(find_grok)" || {
  echo "could not find the grok binary (install Grok CLI, or set GROK_BIN)" >&2
  exit 1
}

new_session_id() { uuidgen | tr '[:upper:]' '[:lower:]'; }

# Final line only, full "VERDICT: <TOKEN>" form; the grammar is lib/verdict.py.
verdict_of() {
  python3 "$HERE/lib/verdict.py" "$1" APPROVED REVISE
}

run_grok() {
  local prompt="$1"
  local session_flag=(--session-id "$SESSION_ID")
  if [[ -n "$RESUME_ID" ]]; then
    session_flag=(--resume "$RESUME_ID")
    SESSION_ID="$RESUME_ID"
  fi

  # read-only toolset: no bash, no search_replace, no web.
  local cmd=(
    "$GROK_BIN" -p "$prompt"
    --model "$MODEL"
    --reasoning-effort "$EFFORT"
    --output-format json
    --permission-mode plan
    --tools read_file,grep_search,list_dir
    --no-subagents
    --disable-web-search
    "${session_flag[@]}"
  )

  if [[ "${GROK_REVIEW_DRY_RUN:-0}" == "1" ]]; then
    echo "GROK_REVIEW_RESULT: dry_run"
    echo "SESSION_ID: ${SESSION_ID}"
    echo "VERDICT: MISSING"
    echo "VERDICT_FILE: (dry run — no file)"
    printf 'CMD:'
    printf ' %q' "${cmd[@]}"
    printf '\n'
    exit 0
  fi

  local raw rc
  raw="$(mktemp -t grok-review-raw-XXXXXX.json)"
  set +e
  "${cmd[@]}" >"$raw" 2>"${raw}.err"
  rc=$?
  set -e

  if is_transport_rate_limit "$rc" "${raw}.err" "$raw"; then
    echo "GROK_REVIEW_RESULT: rate_limited (exit ${rc})"
    echo "SESSION_ID: ${SESSION_ID}"
    echo "VERDICT: MISSING"
    echo "VERDICT_FILE: ${raw}"
    exit 75
  fi

  if [[ $rc -ne 0 ]]; then
    echo "GROK_REVIEW_RESULT: error (exit ${rc})"
    echo "SESSION_ID: ${SESSION_ID}"
    echo "VERDICT: MISSING"
    echo "VERDICT_FILE: ${raw}"
    cat "${raw}.err" >&2 || true
    exit "$rc"
  fi

  local parsed parsed_sid parsed_text
  parsed="$("$HERE/lib/agent-result.py" <"$raw")" || {
    echo "GROK_REVIEW_RESULT: error (unparseable JSON)"
    echo "SESSION_ID: ${SESSION_ID}"
    echo "VERDICT: MISSING"
    echo "VERDICT_FILE: ${raw}"
    exit 1
  }
  parsed_sid="${parsed%%$'\t'*}"
  parsed_text="${parsed#*$'\t'}"
  [[ -n "$parsed_sid" ]] && SESSION_ID="$parsed_sid"

  printf '%s\n' "$parsed_text" >"$OUT"
  echo "GROK_REVIEW_RESULT: ok"
  echo "SESSION_ID: ${SESSION_ID}"
  echo "VERDICT: $(verdict_of "$OUT")"
  echo "VERDICT_FILE: ${OUT}"
}

if [[ "$SMOKE" -eq 1 ]]; then
  EFFORT="low"
  SESSION_ID="$(new_session_id)"
  OUT="${GROK_REVIEW_OUT:-${TMPDIR:-/tmp}/grok-review-smoke-$$.md}"
  run_grok "You are a plan attacker. Reply with exactly:
PONG ${MODEL}
VERDICT: APPROVED"
  exit 0
fi

PLAN="${PLAN:-PLAN.md}"
[[ -f "$PLAN" ]] || { echo "plan not found: $PLAN" >&2; exit 1; }
PLAN_ABS="$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")"

if [[ -n "$RESUME_ID" ]]; then
  SESSION_ID="$RESUME_ID"
else
  SESSION_ID="$(new_session_id)"
fi
OUT="${GROK_REVIEW_OUT:-${TMPDIR:-/tmp}/grok-review-${SESSION_ID}-$(date -u +%Y%m%dT%H%M%SZ).md}"

if [[ -n "$RESUME_ID" ]]; then
  read -r -d '' PROMPT <<EOF || true
I revised the plan. Re-review the file at ${PLAN_ABS} (and CONTEXT.md / docs/adr / any repo files you need; you are read-only). Check whether your prior findings are addressed and flag anything new. Same rules as before. Do NOT modify any files. End your reply with EXACTLY one line: VERDICT: APPROVED or VERDICT: REVISE.
EOF
else
  read -r -d '' PROMPT <<EOF || true
You are an adversarial reviewer for an implementation plan written by a different model. Be skeptical and specific — your job is to find what breaks, not to be agreeable. Do not defer to the plan's confidence. Read the plan at ${PLAN_ABS} (and CONTEXT.md / ADRs for domain language, if present) and any repo files you need (you are read-only). Identify concrete flaws: security holes, race conditions, missing edge cases, schema conflicts, wrong assumptions, observability gaps, simpler alternatives. For each, give a one-line fix. Do NOT modify any files. End your reply with EXACTLY one line: VERDICT: APPROVED if the plan is sound enough to implement, or VERDICT: REVISE if it still has material problems.
EOF
fi

run_grok "$PROMPT"
