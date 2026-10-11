#!/usr/bin/env bash
#
# grok-review.sh — one adversarial review round via headless Grok: of a
# locked PLAN (Phase 2), or with --oracle of the acceptance oracles cut from it
# (Phase 3).
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
#   grok-review.sh --oracle [--resume ORACLE_SESSION_ID] <PLAN.md>
#   grok-review.sh --smoke
#
# --oracle reviews the acceptance oracles of the GOALS.md in the current
# directory (Phase 3), not the plan: the files lib/oracle-files.py lists (each
# non-inline `oracle:`, plus the tests/acceptance/ paths in Acceptance-edits
# sections). Round 1 is always a fresh session seeded with the plan and the
# PLAN-REVIEW-LOG.md beside it; it never resumes or forks the plan-attack
# session, whose context a few rounds bring near Grok's compaction threshold.
# Later oracle rounds --resume the oracle session.
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
# Architect: run from the target repo root, in the background (run_in_background:
# true): a first round can take ~20 minutes, past the 10-minute foreground ceiling.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/dotenv.sh"
HOUSE="$(cd "$HERE/.." && pwd)"

MODEL="${GROK_REVIEW_MODEL:-grok-4.7}"
EFFORT="${GROK_REVIEW_EFFORT:-high}"
SMOKE=0
ORACLE=0
RESUME_ID=""
PLAN=""

usage() {
  echo "usage: grok-review.sh [--resume SESSION_ID] [PLAN.md]" >&2
  echo "       grok-review.sh --oracle [--resume ORACLE_SESSION_ID] <PLAN.md>" >&2
  echo "       grok-review.sh --smoke" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --smoke) SMOKE=1; shift ;;
    --oracle) ORACLE=1; shift ;;
    --fork) echo "--fork is not supported: plan rounds use --resume; oracle reviews always start fresh" >&2; usage ;;
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

# Usage errors before anything else, so they read the same with or without Grok.
if [[ "$ORACLE" -eq 1 && "$SMOKE" -eq 1 ]]; then
  echo "--smoke and --oracle do not combine" >&2
  usage
fi
if [[ "$ORACLE" -eq 1 && -z "$PLAN" ]]; then
  echo "--oracle needs the plan path" >&2
  usage
fi

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
  # A turn that did not end normally carries no review, only whatever Grok
  # said before it stopped: on the oracle-review crucible a call to a tool
  # outside the read-only set was refused and ended the turn `cancelled`
  # with a 255-byte preamble, reported as `ok`. Anything but end_turn is an
  # error the Architect sees (VERDICT_FILE keeps the partial text).
  local stop
  stop="$(python3 -c 'import json,sys
raw = sys.stdin.read().strip()
try:
    d = json.loads(raw)
except ValueError:  # NDJSON: the last object on a line, as agent-result.py reads it
    d = {}
    for line in reversed(raw.splitlines()):
        try:
            d = json.loads(line)
            break
        except ValueError:
            continue
print((d.get("stopReason") or d.get("stop_reason") or "") if isinstance(d, dict) else "")' <"$raw" 2>/dev/null || true)"
  if [[ -n "$stop" && "$stop" != end_turn ]]; then
    echo "GROK_REVIEW_RESULT: error (turn stopped: ${stop})"
    echo "SESSION_ID: ${SESSION_ID}"
    echo "VERDICT: MISSING"
    echo "VERDICT_FILE: ${OUT}"
    exit 1
  fi
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
if [[ ! -f "$PLAN" ]]; then
  echo "plan not found: $PLAN" >&2
  [[ "$ORACLE" -eq 1 ]] && exit 2
  exit 1
fi
PLAN_ABS="$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")"

if [[ "$ORACLE" -eq 1 ]]; then
  LOG_ABS="$(dirname "$PLAN_ABS")/PLAN-REVIEW-LOG.md"
  [[ -f "$LOG_ABS" ]] || { echo "no PLAN-REVIEW-LOG.md beside $PLAN" >&2; exit 2; }
  [[ -f GOALS.md ]] || { echo "no GOALS.md in $(pwd)" >&2; exit 2; }
  GOALS_ABS="$(pwd)/GOALS.md"
  # The GOALS.md under review must be the one cut from this plan.
  goals_plan="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import goals; from pathlib import Path; print(goals.load(Path("GOALS.md"))[1].get("plan") or "")' "$HERE" 2>/dev/null || true)"
  if [[ -n "$goals_plan" && "$(cd "$(dirname "$goals_plan")" 2>/dev/null && pwd)/$(basename "$goals_plan")" != "$PLAN_ABS" ]]; then
    echo "GOALS.md names plan: $goals_plan, not $PLAN" >&2
    exit 2
  fi
  # Its own exit code: 2 for a usage error, anything else is a crash to see.
  ORACLE_FILES="$("$HERE/lib/oracle-files.py" GOALS.md)" || exit $?
  if [[ -n "$ORACLE_FILES" ]]; then
    FILE_LIST="$(printf '%s\n' "$ORACLE_FILES" | paste -sd ',' - | sed 's/,/, /g')"
  else
    FILE_LIST="none: every goal's oracle is inline, so review the case tables in ${GOALS_ABS}"
  fi
fi

if [[ -n "$RESUME_ID" ]]; then
  SESSION_ID="$RESUME_ID"
else
  SESSION_ID="$(new_session_id)"
fi
OUT="${GROK_REVIEW_OUT:-${TMPDIR:-/tmp}/grok-review-${SESSION_ID}-$(date -u +%Y%m%dT%H%M%SZ).md}"

TOOLS="Your only tools are read_file, grep_search and list_dir: there is no shell, and calling any other tool ends the review with nothing recorded."
if [[ "$ORACLE" -eq 1 && -n "$RESUME_ID" ]]; then
  read -r -d '' PROMPT <<EOF || true
I revised the oracles. Re-review exactly these files, relative to $(pwd): ${FILE_LIST}. The plan is ${PLAN_ABS}, its review log ${LOG_ABS}, the goals ${GOALS_ABS}; you are read-only. ${TOOLS} Check whether your prior findings are addressed and flag anything new, under the same rules: re-derive expected values from the plan, and start a finding with PLAN: when the defect is in the plan rather than the oracle. Do NOT modify any files. End your reply with EXACTLY one line: VERDICT: APPROVED or VERDICT: REVISE.
EOF
elif [[ "$ORACLE" -eq 1 ]]; then
  read -r -d '' PROMPT <<EOF || true
You are an adversarial reviewer of acceptance oracles written by a different model, for the signed plan at ${PLAN_ABS}. The plan's review log at ${LOG_ABS} records what an earlier attack on the plan raised and how each point was settled. The goals and their proof commands are in ${GOALS_ABS}. Review exactly these oracle files, relative to $(pwd), and nothing else under tests/acceptance/: ${FILE_LIST}. You are read-only. ${TOOLS} Be skeptical and specific: re-derive every expected value from the plan instead of trusting it. Find, each with a one-line fix: plan claims or cases that no assertion covers; expected values that do not follow from the plan; cases the plan leaves ambiguous; ways a proof could pass without the code working (an oracle the proof never runs, a tautology, a differential that cancels its own term, an invented symbol, a pin on a private signature, an assertion that never runs, a test that expects the stub's own exception); harness defects. Start a finding with PLAN: when the defect is in the plan, not the oracle. Do NOT modify any files. End your reply with EXACTLY one line: VERDICT: APPROVED if the oracles are sound enough to implement against, or VERDICT: REVISE if they still have material problems.
EOF
elif [[ -n "$RESUME_ID" ]]; then
  read -r -d '' PROMPT <<EOF || true
I revised the plan. Re-review the file at ${PLAN_ABS} (and GLOSSARY.md or CONTEXT.md / docs/adr / any repo files you need; you are read-only). ${TOOLS} Check whether your prior findings are addressed and flag anything new. Same rules as before. Do NOT modify any files. End your reply with EXACTLY one line: VERDICT: APPROVED or VERDICT: REVISE.
EOF
else
  read -r -d '' PROMPT <<EOF || true
You are an adversarial reviewer for an implementation plan written by a different model. Be skeptical and specific — your job is to find what breaks, not to be agreeable. Do not defer to the plan's confidence. Read the plan at ${PLAN_ABS} (and GLOSSARY.md or CONTEXT.md / ADRs for domain language, if present) and any repo files you need (you are read-only). ${TOOLS} Identify concrete flaws: security holes, race conditions, missing edge cases, schema conflicts, wrong assumptions, observability gaps, simpler alternatives. For each, give a one-line fix. Do NOT modify any files. End your reply with EXACTLY one line: VERDICT: APPROVED if the plan is sound enough to implement, or VERDICT: REVISE if it still has material problems.
EOF
fi

run_grok "$PROMPT"
