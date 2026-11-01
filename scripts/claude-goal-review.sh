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
#   claude-goal-review.sh --mutations N --resume SESSION_ID [--add-dir DIR]... <brief.md>
#   claude-goal-review.sh --smoke
#
# --mutations N (docs/features/mutation-checks): after a DONE verdict, resume the
# reviewer's session for a turn that asks only for up to N mutations of the
# implementer's code. It reads no verdict; it writes the reply exactly as
# returned (tabs and every line kept) to a file of its own and prints
#   MUTATIONS_FILE: <path>
# with CLAUDE_REVIEW_RESULT, SESSION_ID and CLAUDE_REVIEW_MODEL.
#
# --add-dir grants Read access outside the repo. The Orchestrator keeps the
# brief, DIFF_FILE and PROOF_OUTPUT in a private run dir under ~/.cache/claude-coding-workflow/runs/; without
# that grant a headless reviewer cannot open any of them and reviews blind.
# The brief's own directory is added automatically.
#
# Brief SHOULD contain:
#   GOAL: <id>
#   PLAN: <run dir>/implementer/plan-at-base-PLAN.md   (the signed plan, frozen at BASE_SHA)
#   GOALS: GOALS.md
#   ORACLE: <path|inline>
#   DIFF_FILE: <path>        # Architect-written git diff (read this)
#   DIFF_RANGE: <sha>..HEAD  # informational
#   PROOF_OUTPUT: <path>     # Architect-run proof, packed as ground truth
#
# Optional env: CLAUDE_REVIEW_MODEL / CLAUDE_REVIEW_EFFORT /
# CLAUDE_REVIEW_FALLBACK_MODEL / CLAUDE_REVIEW_FALLBACK_EFFORT /
# CLAUDE_REVIEW_DRY_RUN / CLAUDE_REVIEW_OUT (the
# verdict path). CW_OUT_DIR: write every file there and delete none (run-goal.sh
# passes its run folder); unset, they go to a new folder under
# ~/.cache/claude-coding-workflow/runs/ and the raw output and .err are removed
# after an `ok` review unless CW_KEEP_RAW=1. Result lines:
#   CLAUDE_REVIEW_RESULT: ok | rate_limited | flagged | error | dry_run
#   SESSION_ID: <uuid>
#   VERDICT: DONE | FIX | BLOCKED | MISSING
#   VERDICT_FILE: <path>
#   CLAUDE_REVIEW_MODEL: <the model that produced this result>
#   CLAUDE_REVIEW_FALLBACK: <from> -> <to> (...)   only when the fallback ran (it
#                                                   names the retry's effort)
#   CLAUDE_REVIEW_COST: <session> <total_cost_usd>  one per model call whose
#                                                   envelope parsed (cumulative
#                                                   for a resumed session)
#   CLAUDE_REVIEW_RAW: <the last raw envelope>      the provider's own words
#
# SAFETY FLAGS. If the reviewer's safeguards flag the review (a classifier false
# positive on the security content of a diff is the usual cause) the turn ends with
# no verdict. The script then retries ONCE on CLAUDE_REVIEW_FALLBACK_MODEL (default
# claude-opus-4-8; empty or "none" turns the retry off) at CLAUDE_REVIEW_FALLBACK_EFFORT
# (default xhigh: an older model, given more thinking). It is the same reviewer role
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
# shellcheck disable=SC1091
source "$HERE/lib/cache.sh"
HOUSE="$(cd "$HERE/.." && pwd)"
MODEL="${CLAUDE_REVIEW_MODEL:-claude-opus-5-5}"
EFFORT="${CLAUDE_REVIEW_EFFORT:-high}"
# `-` not `:-`: an explicitly empty value must disable the fallback, not restore it.
FALLBACK_MODEL="${CLAUDE_REVIEW_FALLBACK_MODEL-claude-opus-4-8}"
[[ "$FALLBACK_MODEL" == "none" ]] && FALLBACK_MODEL=""
FALLBACK_EFFORT="${CLAUDE_REVIEW_FALLBACK_EFFORT:-xhigh}"
# Checked at start: a typo in the fallback's effort would otherwise surface
# only on a flagged review, as a generic error.
for e in "CLAUDE_REVIEW_EFFORT=$EFFORT" "CLAUDE_REVIEW_FALLBACK_EFFORT=$FALLBACK_EFFORT"; do
  case "${e#*=}" in
    low | medium | high | xhigh | max) ;;
    *) echo "CLAUDE_REVIEW_RESULT: error (${e%%=*} must be low, medium, high, xhigh or max, not '${e#*=}')"; exit 1 ;;
  esac
done
SMOKE=0
MUT_N=""
RESUME_ID=""
BRIEF=""
ADD_DIRS=()

usage() {
  echo "usage: claude-goal-review.sh [--resume SESSION_ID] [--add-dir DIR]... <brief.md>" >&2
  echo "       claude-goal-review.sh --mutations N --resume SESSION_ID [--add-dir DIR]... <brief.md>" >&2
  echo "       claude-goal-review.sh --smoke" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --smoke) SMOKE=1; shift ;;
    --mutations)
      [[ $# -ge 2 && "$2" =~ ^[1-5]$ ]] || usage
      MUT_N="$2"
      shift 2
      ;;
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
# --effort decides, as in claude-implement.sh: a level left in the shell must
# not override either effort.
unset CLAUDE_CODE_EFFORT_LEVEL || true

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

# out_dir — the folder this review writes into, made on first use (a dry run
# makes none): the caller's CW_OUT_DIR, or a new private folder under runs/.
OUT_DIR=""
out_dir() {
  [[ -z "$OUT_DIR" ]] || return 0
  if [[ -n "${CW_OUT_DIR:-}" ]]; then
    [[ -d "$CW_OUT_DIR" ]] || { echo "CW_OUT_DIR is not a directory: $CW_OUT_DIR" >&2; exit 1; }
    OUT_DIR="$CW_OUT_DIR"
  else
    cw_cache_init || { echo "cannot create $CW_CACHE" >&2; exit 1; }
    OUT_DIR="$(mktemp -d "$CW_CACHE/runs/claude-goal-review-XXXXXX")"
  fi
  [[ -n "$OUT" ]] || OUT="$OUT_DIR/$OUT_NAME"
}

# review_costs RAW... — one `CLAUDE_REVIEW_COST: <session> <total_cost_usd>`
# line per raw envelope that parses (each model call of this run, a safety-flag
# retry included; the always-on spend ledger records them as observations,
# docs/features/always-on step 9), and `CLAUDE_REVIEW_RAW: <the last envelope>`
# so a stop can name the provider's own words (step 7a).
review_costs() {
  local f last=""
  for f in "$@"; do
    [[ "$f" == *.err ]] && continue
    last="$f"
    python3 - "$f" <<'PY' 2>/dev/null || true
import json, sys
text = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
d = None
try:
    d = json.loads(text)
except Exception:
    # As agent-result.py: the last line that parses as a JSON object.
    for line in reversed(text.splitlines()):
        line = line.strip()
        if not (line.startswith("{") and line.endswith("}")):
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        if isinstance(d, dict):
            break
if not isinstance(d, dict):
    sys.exit(0)
c, s = d.get("total_cost_usd"), d.get("session_id")
if isinstance(c, (int, float)) and not isinstance(c, bool) and s:
    print(f"CLAUDE_REVIEW_COST: {s} {c}")
PY
  done
  [[ -z "$last" ]] || echo "CLAUDE_REVIEW_RAW: $last"
}

run_claude() {
  local prompt="$1" model="$MODEL" effort="$EFFORT" fell_back="" raw rc
  # Every raw/.err pair, the flagged attempts' too: a retry must not orphan one.
  local raws=()

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
      --effort "$effort"
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

    out_dir
    raw="$(mktemp "$OUT_DIR/claude-goal-raw-XXXXXX")"
    cw_private "${raw}.err"
    raws+=("$raw" "${raw}.err")
    set +e
    "${cmd[@]}" >"$raw" 2>"${raw}.err"
    rc=$?
    set -e

    # Checked before the exit code: a flagged turn may exit non-zero, and must not
    # be reported as a generic error or as a rate limit.
    if flagged_refusal "$raw" "${raw}.err"; then
      if [[ -z "$fell_back" && -n "$FALLBACK_MODEL" && "$FALLBACK_MODEL" != "$model" ]]; then
        echo "claude-goal-review: ${model} flagged this review; retrying once on ${FALLBACK_MODEL} at ${FALLBACK_EFFORT}" >&2
        fell_back="$model"
        model="$FALLBACK_MODEL"
        effort="$FALLBACK_EFFORT"
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
        echo "CLAUDE_REVIEW_FALLBACK: ${fell_back} -> ${model} (both flagged, effort ${effort})"
      fi
      review_costs "${raws[@]}"
      exit 76
    fi
    break
  done

  if is_transport_rate_limit "$rc" "${raw}.err" "$raw"; then
    echo "CLAUDE_REVIEW_RESULT: rate_limited (exit ${rc})"
    echo "SESSION_ID: ${SESSION_ID}"
    echo "VERDICT: MISSING"
    echo "VERDICT_FILE: ${raw}"
    review_costs "${raws[@]}"
    exit 75
  fi

  if [[ $rc -ne 0 ]]; then
    echo "CLAUDE_REVIEW_RESULT: error (exit ${rc})"
    echo "SESSION_ID: ${SESSION_ID}"
    echo "VERDICT: MISSING"
    echo "VERDICT_FILE: ${raw}"
    review_costs "${raws[@]}"
    cat "${raw}.err" >&2 || true
    exit "$rc"
  fi

  local parsed parsed_sid parsed_text
  parsed="$("$HERE/lib/agent-result.py" <"$raw")" || {
    echo "CLAUDE_REVIEW_RESULT: error (unparseable JSON)"
    echo "SESSION_ID: ${SESSION_ID}"
    echo "VERDICT: MISSING"
    echo "VERDICT_FILE: ${raw}"
    review_costs "${raws[@]}"
    exit 1
  }
  parsed_sid="${parsed%%$'\t'*}"
  parsed_text="${parsed#*$'\t'}"
  [[ -n "$parsed_sid" ]] && SESSION_ID="$parsed_sid"

  if [[ -n "$MUT_N" ]]; then
    # The reply as returned: agent-result.py turns tabs into spaces, and a
    # result line holds one line, so it goes to a file of its own.
    local mfile="$OUT_DIR/mutations-${SESSION_ID}-$(date -u +%Y%m%dT%H%M%SZ).txt"
    cw_private "$mfile"
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.stdout.write(d.get("result") or "")' "$raw" >"$mfile" ||
      : >"$mfile"
    echo "CLAUDE_REVIEW_RESULT: ok"
    echo "SESSION_ID: ${SESSION_ID}"
    echo "MUTATIONS_FILE: ${mfile}"
    echo "CLAUDE_REVIEW_MODEL: ${model}"
    [[ -z "$fell_back" ]] || echo "CLAUDE_REVIEW_FALLBACK: ${fell_back} -> ${model} (safety flag, effort ${effort})"
    review_costs "${raws[@]}"
    return 0
  fi
  cw_private "$OUT"
  printf '%s\n' "$parsed_text" >"$OUT"
  # Read before the raw files can be removed below; printed last with the rest.
  local costs
  costs="$(review_costs "${raws[@]}")"
  # Standalone, an ok review's verdict holds everything worth keeping; under
  # CW_OUT_DIR the caller decides (an ok review can still end in a wake).
  if [[ -z "${CW_OUT_DIR:-}" && "${CW_KEEP_RAW:-0}" != "1" ]]; then
    rm -f "${raws[@]}"
    # Empty when CLAUDE_REVIEW_OUT put the verdict elsewhere.
    rmdir "$OUT_DIR" 2>/dev/null || true
  fi
  echo "CLAUDE_REVIEW_RESULT: ok"
  echo "SESSION_ID: ${SESSION_ID}"
  echo "VERDICT: $(verdict_of "$OUT")"
  echo "VERDICT_FILE: ${OUT}"
  echo "CLAUDE_REVIEW_MODEL: ${model}"
  if [[ -n "$fell_back" ]]; then
    echo "CLAUDE_REVIEW_FALLBACK: ${fell_back} -> ${model} (safety flag, effort ${effort})"
  fi
  [[ -z "$costs" ]] || printf '%s\n' "$costs"
}

if [[ "$SMOKE" -eq 1 ]]; then
  EFFORT="low"
  FALLBACK_EFFORT="low"
  SESSION_ID="$(new_session_id)"
  OUT="${CLAUDE_REVIEW_OUT:-}"
  OUT_NAME="claude-goal-smoke-$$.md"
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
OUT="${CLAUDE_REVIEW_OUT:-}"
OUT_NAME="claude-goal-${SESSION_ID}-$(date -u +%Y%m%dT%H%M%SZ).md"

if [[ -n "$MUT_N" ]]; then
  [[ -n "$RESUME_ID" ]] || usage
  read -r -d '' PROMPT <<EOF || true
You judged this goal DONE. Now try to break its oracle: write up to ${MUT_N} small mutations of the implementer's code, each a plausible bug aimed at one of the plan's or the goal's riskiest rules, that the goal's proof should catch. The brief at ${BRIEF_ABS} names the DIFF_FILE (what the implementer changed). Mutate only files that diff changes, never the oracle, tests/acceptance/, the plan, GOALS.md or the journal. You do not edit files: write each mutation as text.

Reply with nothing but up to ${MUT_N} blocks, each exactly:

MUTATION: <the plan or goal rule it attacks, one line>
\`\`\`diff
<a unified diff against the current files: --- a/<path> and +++ b/<path> naming the same path, then hunks with exact context>
\`\`\`

No renames, no new or deleted files, no mode changes. No other text, and no verdict line.
EOF
elif [[ -n "$RESUME_ID" ]]; then
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
7. SIMPLER — could the diff be materially smaller or plainer with the same behaviour, the same tests passing and the same scope (dead code, duplicated logic, an abstraction with one caller, a hand-rolled standard-library function)? Never against structure the PLAN prescribes. A FIX only when you can name the simpler form concretely and the saving is real: a SIMPLER-only FIX turns a DONE into a whole fix round, and the goal has few. Otherwise a note in the prose.

You are read-only. Do not edit files.

OUTPUT FORMAT — the Orchestrator parses this mechanically, so follow it exactly.

Write your analysis in prose first. You may number the seven headings above; those
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
