#!/usr/bin/env bash
#
# claude-goal-review.sh — one GOAL REVIEW round via headless Claude
# Opus 5.5. This is NOT the plan attacker (see grok-review.sh). The
# reviewer judges an implementer's diff against a goal until DONE.
#
# This file owns the reviewer prompt. Do not fork it. Do not reuse the
# attacker prompt.
#
# Usage:
#   claude-goal-review.sh [--resume SESSION_ID] [--add-dir DIR]... <brief.md>
#   claude-goal-review.sh --smoke
#
# --add-dir grants Read access outside the repo. The Orchestrator keeps the
# brief, DIFF_FILE and PROOF_OUTPUT in a private run dir under TMPDIR; without
# that grant a headless reviewer cannot open any of them and reviews blind.
# The brief's own directory is added automatically.
#
# Brief SHOULD contain:
#   GOAL: <id>
#   PLAN: <run dir>/plan-at-base-PLAN.md   (the signed plan, frozen at BASE_SHA)
#   GOALS: GOALS.md
#   ORACLE: <path|inline>
#   DIFF_FILE: <path>        # Architect-written git diff (read this)
#   DIFF_RANGE: <sha>..HEAD  # informational
#   PROOF_OUTPUT: <path>     # Architect-run proof, packed as ground truth
#
# Optional env: CLAUDE_REVIEW_MODEL / CLAUDE_REVIEW_EFFORT /
# CLAUDE_REVIEW_FALLBACK_MODEL / DRY_RUN / OUT). Result lines:
#   CLAUDE_REVIEW_RESULT: ok | rate_limited | flagged | error | dry_run
#   SESSION_ID: <uuid>
#   VERDICT: DONE | FIX | BLOCKED | MISSING
#   VERDICT_FILE: <path>
#   CLAUDE_REVIEW_MODEL: <the model that produced this result>
#   CLAUDE_REVIEW_FALLBACK: <from> -> <to> (...)   only when the fallback ran
#
# SAFETY FLAGS. If the reviewer's safeguards flag the review (a classifier false
# positive on the security content of a diff is the usual cause) the turn ends with
# no verdict. The script then retries ONCE on CLAUDE_REVIEW_FALLBACK_MODEL (default
# claude-opus-4-8; empty or "none" turns the retry off). It is the same reviewer role
# on a different model, so it is never silent: CLAUDE_REVIEW_MODEL and
# CLAUDE_REVIEW_FALLBACK name it, and run-goal.sh journals both. If the retry is
# flagged too, or the fallback is off, the result is `flagged`, the verdict MISSING
# and the exit code 76 — fail closed, never a guessed DONE. Only the safeguards
# notice and stop_reason "refusal" count (lib/flagged-refusal.py); a Usage Policy
# refusal is not retried. A fresh review retries on a new session; a --resume round
# keeps its session so the review conversation survives the switch.
#
# Architect: run from the target repo. Timeout 10 minutes (600000 ms).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/dotenv.sh"
HOUSE="$(cd "$HERE/.." && pwd)"
MODEL="${CLAUDE_REVIEW_MODEL:-claude-opus-5-5}"
EFFORT="${CLAUDE_REVIEW_EFFORT:-high}"
# `-` not `:-`: an explicitly empty value must disable the fallback, not restore it.
FALLBACK_MODEL="${CLAUDE_REVIEW_FALLBACK_MODEL-claude-opus-4-8}"
[[ "$FALLBACK_MODEL" == "none" ]] && FALLBACK_MODEL=""
SMOKE=0
RESUME_ID=""
BRIEF=""
ADD_DIRS=()

usage() {
  echo "usage: claude-goal-review.sh [--resume SESSION_ID] [--add-dir DIR]... <brief.md>" >&2
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
    --add-dir)
      [[ $# -ge 2 ]] || usage
      ADD_DIRS+=("$2")
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

# Final line only, full "VERDICT: <TOKEN>" form; the grammar is lib/verdict.py.
verdict_of() {
  python3 "$HERE/lib/verdict.py" "$1" DONE FIX BLOCKED
}

# True when the turn was stopped by a safety flag rather than by a verdict.
flagged_refusal() {
  python3 "$HERE/lib/flagged-refusal.py" "$1" "$2" >/dev/null 2>&1
}

run_claude() {
  local prompt="$1" model="$MODEL" fell_back="" raw rc

  while :; do
    local session_flag=(--session-id "$SESSION_ID")
    if [[ -n "$RESUME_ID" ]]; then
      session_flag=(--resume "$RESUME_ID")
      SESSION_ID="$RESUME_ID"
    fi

    local add_flags=()
    local d
    for d in "${ADD_DIRS[@]+"${ADD_DIRS[@]}"}"; do
      [[ -d "$d" ]] || continue
      add_flags+=(--add-dir "$d")
    done

    local cmd=(
      "$CLAUDE_BIN" -p "$prompt"
      --model "$model"
      --effort "$EFFORT"
      --output-format json
      --permission-mode plan
      --tools Read,Glob,Grep
      --safe-mode
      "${add_flags[@]+"${add_flags[@]}"}"
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

    raw="$(mktemp -t claude-goal-raw-XXXXXX.json)"
    set +e
    "${cmd[@]}" >"$raw" 2>"${raw}.err"
    rc=$?
    set -e

    # Checked before the exit code: a flagged turn may exit non-zero, and must not
    # be reported as a generic error or as a rate limit.
    if flagged_refusal "$raw" "${raw}.err"; then
      if [[ -z "$fell_back" && -n "$FALLBACK_MODEL" && "$FALLBACK_MODEL" != "$model" ]]; then
        echo "claude-goal-review: ${model} flagged this review; retrying once on ${FALLBACK_MODEL}" >&2
        fell_back="$model"
        model="$FALLBACK_MODEL"
        # Model names are [a-z0-9.-], so they are safe inside a sed pattern.
        prompt="$(printf '%s' "$prompt" | sed "s/(model: ${fell_back})/(model: ${model})/")"
        [[ -n "$RESUME_ID" ]] || SESSION_ID="$(new_session_id)"
        continue
      fi
      echo "CLAUDE_REVIEW_RESULT: flagged (${model})"
      echo "SESSION_ID: ${SESSION_ID}"
      echo "VERDICT: MISSING"
      echo "VERDICT_FILE: ${raw}"
      echo "CLAUDE_REVIEW_MODEL: ${model}"
      if [[ -n "$fell_back" ]]; then
        echo "CLAUDE_REVIEW_FALLBACK: ${fell_back} -> ${model} (both flagged)"
      fi
      exit 76
    fi
    break
  done

  if is_transport_rate_limit "$rc" "${raw}.err" "$raw"; then
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
  parsed="$("$HERE/lib/agent-result.py" <"$raw")" || {
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
  echo "CLAUDE_REVIEW_MODEL: ${model}"
  if [[ -n "$fell_back" ]]; then
    echo "CLAUDE_REVIEW_FALLBACK: ${fell_back} -> ${model} (safety flag)"
  fi
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
BRIEF_DIR="$(cd "$(dirname "$BRIEF")" && pwd)"
BRIEF_ABS="$BRIEF_DIR/$(basename "$BRIEF")"
# The brief names DIFF_FILE / PROOF_OUTPUT as siblings; grant that dir.
ADD_DIRS+=("$BRIEF_DIR")

if [[ -n "$RESUME_ID" ]]; then
  SESSION_ID="$RESUME_ID"
else
  SESSION_ID="$(new_session_id)"
fi
OUT="${CLAUDE_REVIEW_OUT:-${TMPDIR:-/tmp}/claude-goal-${SESSION_ID}-$(date -u +%Y%m%dT%H%M%SZ).md}"

if [[ -n "$RESUME_ID" ]]; then
  read -r -d '' PROMPT <<EOF || true
I applied your last FIX list (or the Architect bounced a blocker). Re-review the same goal. Read the brief at ${BRIEF_ABS} first (GOAL / PLAN / GOALS / ORACLE / DIFF_FILE / PROOF_OUTPUT), then the DIFF_FILE. Same rules and the same output format: every defect on its own line starting "FIX: <path>:<line> — <defect> — <what to change>", never opening with the oracle path. You do not edit files. End with EXACTLY one line: VERDICT: DONE or VERDICT: FIX or VERDICT: BLOCKED.
EOF
else
  read -r -d '' PROMPT <<EOF || true
You are the GOAL REVIEWER (model: ${MODEL}), not the plan attacker and not the implementer. You judge whether one goal is done. You do not write production code and you do not re-litigate product decisions locked in the plan.

Read the brief at ${BRIEF_ABS}. It names:
- GOAL — the id in GOALS.md
- PLAN, GOALS, ORACLE
- DIFF_FILE — the Architect-written git diff. This is the change. Read it.
- DIFF_RANGE — informational (the range used to produce DIFF_FILE)
- PROOF_OUTPUT — actual output of the proof command the Architect already ran. Treat it as ground truth. Do not invent a different test result.

Then read GOALS.md (that goal only), the PLAN file the brief names (the signed plan as of BASE_SHA; judge against it, not the repo's copy), the oracle file if it is not "inline", GLOSSARY.md (or a legacy CONTEXT.md), coding-standards.md if present, and DIFF_FILE. Identify:

1. SPEC — does the diff implement this goal and only this goal?
2. ORACLE — is the acceptance file unmodified? A touch is CRITICAL.
3. TESTS — do the implementer's own tests cover the case table? Assertions exact? Name one plausible bug the suite would miss.
4. FAKE SUCCESS — weakened/skipped/deleted tests, assert-true, over-mocking.
5. CEILINGS — load-bearing simplifications missing a ponytail comment.
6. SMELLS — Fowler list as judgement calls, never hard violations; coding-standards.md overrides.

You are read-only. Do not edit files.

OUTPUT FORMAT — the Orchestrator parses this mechanically, so follow it exactly.

Write your analysis in prose first. You may number the six headings above; those
numbered lines are NOT findings and are ignored.

Then, if and only if the verdict is FIX, list each defect on its own line
starting with the literal token "FIX:", in this shape:

FIX: <path>:<line> — <defect> — <what to change>

The path must be the file YOU want the implementer to change, and it must be
the first thing after "FIX:". Never open a FIX line with the oracle path or
anything under tests/acceptance/ — those are read-only, and doing so bounces
the goal to the Architect. Referring to the oracle later in the sentence is
fine ("... to satisfy tests/acceptance/test_x.py").

End the body with EXACTLY one line:
- VERDICT: DONE — goal is met, oracle green and untouched, no critical findings.
- VERDICT: FIX — material problems the implementer can fix, each on a FIX: line.
- VERDICT: BLOCKED — the spec/oracle/goal is wrong or ambiguous. This is for the Architect, not another implementer pass.
EOF
fi

run_claude "$PROMPT"
