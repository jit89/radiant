#!/usr/bin/env bash
#
# claude-implement.sh — one IMPLEMENTATION pass via headless Claude Code.
# Claude Haiku 5.5 implements; if Haiku's safeguards flag the pass or it
# declines the goal, the same pass runs ONCE on DeepSeek V4 Flash through the
# same harness (DeepSeek's Anthropic-compatible endpoint). Replaces
# deepseek-code.sh (Codex) as run-goal.sh's implementer.
#
# This file owns the implementer prompt. Do not fork it.
#
# Usage:
#   claude-implement.sh [--resume THREAD_ID] [--add-dir DIR]... <handoff.md>
#   claude-implement.sh --smoke     (IMPLEMENTER_SMOKE_PROVIDER=haiku|deepseek)
#
# Optional env:
#   IMPLEMENTER_MODEL           default claude-haiku-5-5
#   IMPLEMENTER_EFFORT          default xhigh
#   IMPLEMENTER_FALLBACK        deepseek (default) | none (empty also disables)
#   DEEPSEEK_MODEL              default deepseek-v4-flash
#   DEEPSEEK_ANTHROPIC_BASE_URL default https://api.deepseek.com/anthropic
#   IMPLEMENTER_ALLOWED_DOMAINS comma list the sandbox may reach (default none)
#   IMPLEMENTER_MAX_BUDGET_USD  passed as --max-budget-usd when set
#   IMPLEMENTER_DRY_RUN=1       print the command, call nothing
#   CW_OUT_DIR                  write raw output, .err and report there and
#                               delete none (run-goal.sh passes its run
#                               folder); unset, a new folder under
#                               ~/.cache/claude-coding-workflow/runs/, and an
#                               `ok` pass removes its raw output and .err
#   CW_KEEP_RAW=1               keep them after an `ok` pass anyway
#
# Result lines (stdout):
#   IMPLEMENTER_RESULT: ok | rate_limited (exit N) | declined (<provider>)
#                       | flagged (<provider>) | error (...) | dry_run
#   THREAD_ID: haiku:<uuid> | deepseek:<uuid>
#   IMPLEMENTER_STATUS: DONE | BLOCKED | DECLINED | MISSING
#   IMPLEMENTER_MODEL: <the model that produced the final result>
#   IMPLEMENTER_FALLBACK: haiku -> deepseek (<refusal|declined>)   only when it ran
#   IMPLEMENTER_COST_USD: <envelope total_cost_usd: a client-side estimate, and
#                         on a resumed thread the whole conversation's total>
#   IMPLEMENTER_TOKENS: in=<n> out=<n> cache_read=<n> cache_write=<n>
#   RETURN_HANDOFF / REPORT / LOG / stderr: paths
# `ok` covers DONE, BLOCKED and MISSING: the host assesses the tree either way.
# Exit: 0 ok, 75 rate_limited, 76 declined/flagged with no fallback left,
# 2 a thread this launcher does not own, else the error code.
#
# ISOLATION. Both providers run with:
#   - Claude Code's sandbox on: shell commands write only inside the repo, the
#     temp dir and --add-dir dirs; .git/hooks, .git/config and .claude/ settings
#     stay write-protected; network is off unless IMPLEMENTER_ALLOWED_DOMAINS
#     names hosts; no unsandboxed retry. Bash is allowed outright, because the
#     OS boundary holds every command (auto-approval alone refuses commands it
#     cannot read statically, such as a loop with ${x##*/}).
#   - every credential-like variable stripped from the child's environment. A
#     key the harness itself needs (ANTHROPIC_API_KEY for Haiku when set, the
#     DeepSeek key) reaches it through apiKeyHelper reading a 0600 file under
#     ~/.cache/claude-coding-workflow/keys/, removed on exit; the model's
#     commands and Read tool are denied that dir and the house .env files.
#   - Haiku: --safe-mode (no CLAUDE.md, skills, plugins, hooks, MCP: the target
#     repo's CLAUDE.md is the Architect's contract, which tells a reader not to
#     implement). DeepSeek: --bare (the same, and auth only from apiKeyHelper).
#
# Architect: never run this by hand on the happy path; run-goal.sh does.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOUSE="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/dotenv.sh"
# shellcheck disable=SC1091
source "$HERE/lib/cache.sh"

MODEL="${IMPLEMENTER_MODEL:-claude-haiku-5-5}"
EFFORT="${IMPLEMENTER_EFFORT:-xhigh}"
# `-` not `:-`: an explicitly empty value disables the fallback.
FALLBACK="${IMPLEMENTER_FALLBACK-deepseek}"
[[ "$FALLBACK" == "none" ]] && FALLBACK=""
DS_MODEL="${DEEPSEEK_MODEL:-deepseek-v4-flash}"
DS_BASE="${DEEPSEEK_ANTHROPIC_BASE_URL:-https://api.deepseek.com/anthropic}"
KEYS_DIR="$HOME/.cache/claude-coding-workflow/keys"

SMOKE=0
RESUME_ID=""
HANDOFF=""
ADD_DIRS=()

usage() {
  echo "usage: claude-implement.sh [--resume THREAD_ID] [--add-dir DIR]... <handoff.md>" >&2
  echo "       claude-implement.sh --smoke" >&2
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
      [[ -z "$HANDOFF" ]] || usage
      HANDOFF="$1"
      shift
      ;;
  esac
done

CLAUDE_BIN="${CLAUDE_REAL_BIN:-}"
[[ -z "$CLAUDE_BIN" && -x "$HOME/.local/bin/claude" ]] && CLAUDE_BIN="$HOME/.local/bin/claude"
[[ -z "$CLAUDE_BIN" ]] && CLAUDE_BIN="$(command -v claude || true)"
: "${CLAUDE_BIN:?could not find the claude binary (set CLAUDE_REAL_BIN)}"

# Keys the harness needs, read before the environment is stripped. Neither is
# ever printed; each reaches its child only through a key file.
ANTH_KEY=""
if load_key_from_files ANTHROPIC_API_KEY .env "$HOUSE/.env"; then
  ANTH_KEY="${ANTHROPIC_API_KEY:-}"
fi
DS_KEY=""
if load_key_from_files DEEPSEEK_API_KEY .env "$HOUSE/.env" "$HOME/.config/watch/.env"; then
  DS_KEY="${DEEPSEEK_API_KEY:-}"
fi

KEY_FILES=()
cleanup() {
  local f
  for f in "${KEY_FILES[@]+"${KEY_FILES[@]}"}"; do rm -f "$f"; done
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# Sets KEY_FILE to a fresh 0600 file holding $1.
KEY_FILE=""
make_key_file() {
  mkdir -p "$KEYS_DIR"
  chmod 700 "$KEYS_DIR"
  KEY_FILE="$(umask 077 && mktemp "$KEYS_DIR/key-XXXXXX")"
  KEY_FILES+=("$KEY_FILE")
  printf '%s\n' "$1" >"$KEY_FILE"
}

# `env -u` arguments for every exported variable named like a credential (a
# whole _-separated part KEY, APIKEY, TOKEN, SECRET, PASSWORD, PASSWD or
# CREDENTIAL(S)), except git's own GIT_CONFIG_*, plus ANTHROPIC_BASE_URL. The
# rule run-goal.sh's proof uses.
env_unsets() {
  local name
  printf '%s\n' -u ANTHROPIC_BASE_URL
  # The house's own folder settings are for this launcher, not the model's shell.
  printf '%s\n' -u CW_OUT_DIR -u CW_KEEP_RAW -u CW_PRUNE_DAYS
  for name in $(compgen -e); do
    [[ "$name" != GIT_CONFIG_* ]] || continue
    if grep -qiE '(^|_)(API)?KEY(_|$)|(^|_)(TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIALS?)(_|$)' <<<"$name"; then
      printf '%s\n' -u "$name"
    fi
  done
}

new_session_id() { uuidgen | tr '[:upper:]' '[:lower:]'; }

# settings_json KEYFILE — the --settings value: sandbox, read denials, and the
# apiKeyHelper when KEYFILE is set.
settings_json() {
  python3 - "$1" "${IMPLEMENTER_ALLOWED_DOMAINS:-}" \
    "$HOUSE/.env" "$HOME/.config/watch/.env" "$KEYS_DIR" <<'PY'
import json, os, shlex, sys
key_file, domains, *secrets = sys.argv[1:]
deny = []
for p in secrets:
    deny.append(f"Read(/{p})")
    if os.path.isdir(p):
        deny.append(f"Read(/{p}/**)")
settings = {
    "sandbox": {
        "enabled": True,
        "allowUnsandboxedCommands": False,
        "failIfUnavailable": True,
        "filesystem": {"denyRead": secrets},
        "network": {"allowedDomains": [d.strip() for d in domains.split(",") if d.strip()]},
    },
    "permissions": {"deny": deny},
}
if key_file:
    settings["apiKeyHelper"] = "/bin/cat " + shlex.quote(key_file)
print(json.dumps(settings))
PY
}

# run_pass PROVIDER SESSION_MODE(new|resume) SID PROMPT TOOLS
# out_dir — the folder this pass writes into, made on first use (a dry run
# makes none): the caller's CW_OUT_DIR, or a new private folder under runs/.
OUT_DIR=""
out_dir() {
  [[ -z "$OUT_DIR" ]] || return 0
  if [[ -n "${CW_OUT_DIR:-}" ]]; then
    [[ -d "$CW_OUT_DIR" ]] || { echo "CW_OUT_DIR is not a directory: $CW_OUT_DIR" >&2; exit 1; }
    OUT_DIR="$CW_OUT_DIR"
  else
    cw_cache_init || { echo "cannot create $CW_CACHE" >&2; exit 1; }
    OUT_DIR="$(mktemp -d "$CW_CACHE/runs/claude-implement-XXXXXX")"
  fi
}

# Sets RAW (envelope), ERRF (stderr), RC, CMD_SHOWN. RAWS keeps every pass's
# pair: the unsaved-thread retry and the DeepSeek fallback each make a new one.
RAW=""
ERRF=""
RAWS=()
RC=0
run_pass() {
  local provider="$1" mode="$2" sid="$3" prompt="$4" tools="$5"
  local key_file="" unsets=() u envs=() model_flags=()
  while IFS= read -r u; do unsets+=("$u"); done < <(env_unsets)
  mkdir -p "$KEYS_DIR"
  case "$provider" in
    haiku)
      if [[ -n "$ANTH_KEY" ]]; then
        make_key_file "$ANTH_KEY"
        key_file="$KEY_FILE"
      fi
      model_flags=(--model "$MODEL" --effort "$EFFORT" --safe-mode)
      ;;
    deepseek)
      make_key_file "$DS_KEY"
      key_file="$KEY_FILE"
      envs=("ANTHROPIC_BASE_URL=$DS_BASE")
      model_flags=(--bare --model "$DS_MODEL")
      ;;
  esac
  local session_flag=(--session-id "$sid")
  if [[ "$mode" == resume ]]; then session_flag=(--resume "$sid"); fi
  local add_flags=() d
  for d in "${ADD_DIRS[@]+"${ADD_DIRS[@]}"}"; do
    if [[ -d "$d" ]]; then add_flags+=(--add-dir "$d"); fi
  done
  local budget=()
  [[ -z "${IMPLEMENTER_MAX_BUDGET_USD:-}" ]] || budget=(--max-budget-usd "$IMPLEMENTER_MAX_BUDGET_USD")
  local allow=()
  [[ "$tools" != *Bash* ]] || allow=(--allowedTools Bash)
  local cmd=(
    "$CLAUDE_BIN" -p "$prompt"
    "${model_flags[@]}"
    --output-format json
    --permission-mode acceptEdits
    --permission-prompts none
    --tools "$tools"
    "${allow[@]+"${allow[@]}"}"
    "${add_flags[@]+"${add_flags[@]}"}"
    "${budget[@]+"${budget[@]}"}"
    --settings "$(settings_json "$key_file")"
    "${session_flag[@]}"
  )

  if [[ "${IMPLEMENTER_DRY_RUN:-0}" == "1" ]]; then
    echo "IMPLEMENTER_RESULT: dry_run"
    echo "THREAD_ID: ${provider}:${sid}"
    printf 'CMD:'
    printf ' %q' env "${unsets[@]}" "${envs[@]+"${envs[@]}"}" "${cmd[@]}"
    printf '\n'
    exit 0
  fi

  out_dir
  RAW="$(mktemp "$OUT_DIR/claude-implement-raw-XXXXXX")"
  ERRF="${RAW}.err"
  cw_private "$ERRF"
  RAWS+=("$RAW" "$ERRF")
  set +e
  env "${unsets[@]}" "${envs[@]+"${envs[@]}"}" "${cmd[@]}" </dev/null >"$RAW" 2>"$ERRF"
  RC=$?
  set -e
}

# classify — sets KIND (ok|flagged|rate_limited|error|declined), STATUS,
# SESSION (from the envelope when present), ERR_DETAIL, and writes REPORT.
KIND=""
STATUS="MISSING"
SESSION=""
ERR_DETAIL=""
REPORT=""
classify() {
  local sid="$1" parsed text
  SESSION="$sid"
  STATUS="MISSING"
  ERR_DETAIL=""
  REPORT="${RAW}.md"
  cw_private "$REPORT"
  # Checked before the exit code: a flagged turn may exit non-zero, and must
  # not read as an error or a rate limit.
  if python3 "$HERE/lib/flagged-refusal.py" "$RAW" "$ERRF" >/dev/null 2>&1; then
    KIND="flagged"
    return 0
  fi
  if is_transport_rate_limit "$RC" "$ERRF" "$RAW"; then
    KIND="rate_limited"
    return 0
  fi
  if [[ "$RC" -ne 0 ]]; then
    KIND="error"
    ERR_DETAIL="exit $RC"
    return 0
  fi
  if ! parsed="$("$HERE/lib/agent-result.py" <"$RAW" 2>/dev/null)"; then
    KIND="error"
    ERR_DETAIL="unparseable JSON"
    return 0
  fi
  if [[ -n "${parsed%%$'\t'*}" ]]; then SESSION="${parsed%%$'\t'*}"; fi
  text="${parsed#*$'\t'}"
  printf '%s\n' "$text" >"$REPORT"
  if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("is_error") else 1)' "$RAW" 2>/dev/null; then
    KIND="error"
    ERR_DETAIL="the run ended in error"
    return 0
  fi
  STATUS="$(python3 "$HERE/lib/verdict.py" --key IMPLEMENTER_STATUS "$REPORT" DONE BLOCKED DECLINED)"
  if [[ "$STATUS" == DECLINED ]]; then
    KIND="declined"
  else
    KIND="ok"
  fi
}

# usage_lines — cost and token lines from the envelope, when it parses.
usage_lines() {
  python3 - "$RAW" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
cost = d.get("total_cost_usd")
if cost is not None:
    print(f"IMPLEMENTER_COST_USD: {cost}")
u = d.get("usage") or {}
if u:
    print("IMPLEMENTER_TOKENS: in={} out={} cache_read={} cache_write={}".format(
        u.get("input_tokens", 0), u.get("output_tokens", 0),
        u.get("cache_read_input_tokens", 0), u.get("cache_creation_input_tokens", 0)))
PY
}

PROVIDER=""
FELL_BACK=""
RETURN_DOC=""
emit_and_exit() {
  local model="$MODEL"
  if [[ "$PROVIDER" == deepseek ]]; then model="$DS_MODEL"; fi
  case "$KIND" in
    ok) echo "IMPLEMENTER_RESULT: ok" ;;
    rate_limited) echo "IMPLEMENTER_RESULT: rate_limited (exit $RC)" ;;
    declined|flagged) echo "IMPLEMENTER_RESULT: $KIND ($PROVIDER)" ;;
    *) echo "IMPLEMENTER_RESULT: error (${ERR_DETAIL:-exit $RC})" ;;
  esac
  echo "THREAD_ID: ${PROVIDER}:${SESSION}"
  echo "IMPLEMENTER_STATUS: ${STATUS}"
  echo "IMPLEMENTER_MODEL: ${model}"
  [[ -z "$FELL_BACK" ]] || echo "IMPLEMENTER_FALLBACK: haiku -> deepseek (${FELL_BACK})"
  usage_lines
  # Standalone, an ok pass's report holds everything worth keeping; under
  # CW_OUT_DIR the caller decides (an ok pass can still end in a wake). After
  # usage_lines, which reads the envelope.
  local log="$RAW" errf="$ERRF"
  if [[ "$KIND" == ok && -z "${CW_OUT_DIR:-}" && "${CW_KEEP_RAW:-0}" != "1" ]]; then
    rm -f "${RAWS[@]}"
    # An earlier pass's empty report (a flagged pass's, before the fallback)
    # too. A declined pass's report holds Haiku's reason: it stays.
    local r
    for r in "${RAWS[@]}"; do
      [[ "$r.md" == "$REPORT" || -s "$r.md" ]] || rm -f "$r.md"
    done
    log="(removed)"
    errf="(removed)"
  fi
  echo "RETURN_HANDOFF: ${RETURN_DOC}"
  echo "REPORT: ${REPORT}"
  echo "LOG: ${log}"
  echo "stderr: ${errf}"
  case "$KIND" in
    ok) exit 0 ;;
    rate_limited) exit 75 ;;
    declined|flagged) exit 76 ;;
    *)
      tail -n 40 "$ERRF" >&2 2>/dev/null || true
      if [[ "$RC" -ne 0 ]]; then exit "$RC"; fi
      exit 1
      ;;
  esac
}

# --- smoke -----------------------------------------------------------------
if [[ "$SMOKE" -eq 1 ]]; then
  PROVIDER="${IMPLEMENTER_SMOKE_PROVIDER:-haiku}"
  case "$PROVIDER" in
    haiku) EFFORT="low"; smoke_model="$MODEL" ;;
    deepseek)
      [[ -n "$DS_KEY" ]] || { echo "IMPLEMENTER_RESULT: error (no DeepSeek key: set DEEPSEEK_API_KEY in $HOUSE/.env)"; exit 1; }
      smoke_model="$DS_MODEL"
      ;;
    *) echo "IMPLEMENTER_SMOKE_PROVIDER must be haiku or deepseek" >&2; exit 2 ;;
  esac
  sid="$(new_session_id)"
  run_pass "$PROVIDER" new "$sid" "Reply with exactly: PONG ${smoke_model}" Read
  classify "$sid"
  emit_and_exit
fi
# ---------------------------------------------------------------------------

[[ -n "$HANDOFF" ]] || usage
[[ -f "$HANDOFF" ]] || { echo "handoff not found: $HANDOFF" >&2; exit 1; }
HANDOFF_DIR="$(cd "$(dirname "$HANDOFF")" && pwd)"
HANDOFF_ABS="$HANDOFF_DIR/$(basename "$HANDOFF")"
RETURN_DOC="$HANDOFF_DIR/return-$(basename "$HANDOFF")"
ADD_DIRS=("$HANDOFF_DIR" "${ADD_DIRS[@]+"${ADD_DIRS[@]}"}")

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "IMPLEMENTER_RESULT: error (not inside a git repo; checkpoints need commits)"
  exit 1
fi

read -r -d '' PROMPT <<EOF || true
You are the IMPLEMENTATION agent. You implement one goal; planning and review belong to other agents.

1. Read the handoff document: ${HANDOFF_ABS}
2. Read every artifact it references: the PLAN copy it names, GOALS.md (the named goal only),
   ADRs (docs/adr/), GLOSSARY.md (or a legacy CONTEXT.md), the journal (docs/journal/<slug>.md),
   and any measurement the goal cites under docs/findings/.
   The PLAN plus the goal's case table or oracle are the contract, and ADRs bind.
   A finding is evidence: it tells you why a decision was made and what was already
   measured, so you build on it rather than re-derive it.
   Read the journal first so you continue from past work.
3. JOURNAL: append (never overwrite) a START record naming the goal:
   "## <UTC from: date -u +%Y-%m-%dT%H:%M:%SZ> — IMPLEMENTER start <goal-id>"
   Every record you append (start, checkpoint, end) is a heading in exactly that shape,
   naming THIS goal id, followed by its own lines. Under START write your understanding of
   the goal. When you finish or stop, append an END record: outcome, commit shas, test
   result, blockers. Keep every line you add inside one of your records. Stage the journal
   by path in each checkpoint commit; lines other agents added ride along, which is
   expected. The host commits whatever you leave uncommitted, so the END record needs no
   commit of its own.
4. CHECKPOINT YOUR WORK. Commit after every green test with a "wip(<goal-id>): <behavior>"
   message, staging only the files you created or modified for this goal, by explicit
   path (git add <path>...). Staging everything (git add -A, git add ., git commit -a)
   would sweep in the Architect's unrelated work in this shared tree, so name each path.
   Progress is durable this way: if you are cut off, only the in-flight cycle is lost
   and the next pass resumes from the last commit.
5. THE ACCEPTANCE GATE IS A CONTRACT. The handoff names it as one of:
     (a) ACCEPTANCE TESTS at a named path, read-only: make them pass exactly as written.
     (b) A CASE TABLE in the goal body: implement exactly those cases, encoding them as
         tests via TDD, with the cases as given.
   Everything under tests/acceptance/ stays exactly as you found it. A contract test that
   looks wrong is a blocker to report (step 8). Your own finer unit tests sit on top.
6. TDD: see each test or check fail before the code that makes it pass, in small steps,
   testing behavior through the seams the handoff names. Where the oracle is one
   executable, the next failing check is the next red. You are headless, so take those
   seams as agreed. Stop at green:
   refactoring belongs to the review stage. Write the least code that passes: reuse,
   then stdlib, then native, then an already-installed dependency, then a one-liner,
   then minimal new code. Keep input validation at trust boundaries, error handling that
   prevents data loss, security and accessibility whole. Scope is fixed by the plan and
   the goal. Mark load-bearing known ceilings in exactly this form:
     # ponytail: <limitation>; upgrade = <path>
   Re-read the goal's out-of-scope list before finishing.
7. SCOPE is the goal and the plan. Two kinds of change fall outside it:
   - A DEVIATION: a minimal change outside the stated scope that meeting the contract
     exactly requires (wiring an existing call site so passing tests stay green,
     correcting a comment this goal makes false, pinning a dev tool so the suite runs).
     Make it, and record each one (file, change, why the contract required it) under
     "Deviations" in the journal END record and the return handoff.
   - A BLOCKER (step 8): changing a contract (an acceptance test, a case table, or a PLAN
     decision, interface or signature); building behavior another goal owns; adding a
     runtime dependency the plan does not name; choosing between readings of the spec.
8. REPORT HONESTLY. Every test you touch stays a real test, and you claim done only with
   the proof green. If you are BLOCKED (a step 7 blocker, a test you cannot make pass, or
   an unknown the codebase, plan and docs cannot settle), stop there: record what you
   tried, your hypotheses and the exact question for the Architect in the journal and the
   return handoff, leave the tests honestly red, and finish. A bounced blocker is a
   success; a gamed test is a failure.
9. Run the goal's PROOF command, then the full test suite if one exists, and report the
   real result.
10. RESUMABILITY: keep a return handoff at ${RETURN_DOC}. Write it early and update it
    after each commit with Status (done / in-progress / remaining + last commit sha).
11. When finished, finalize ${RETURN_DOC} (changes, decisions, deviations, test summary,
    open questions and blockers, secrets redacted).

You run in a sandbox. Shell commands can write inside the repo and under \$TMPDIR; put
scratch drivers, copies and planted-bug builds under \$TMPDIR. Writes to .git/hooks,
.git/config and .claude/ are blocked, and network access is off. The Read, Edit and Write
tools reach only the repo and the handoff's folder, so handle scratch files from the shell.
None of this is a blocker to report.

End your reply with one line of the form IMPLEMENTER_STATUS: <WORD>, nothing after it.
WORD is DONE when the goal's proof passes, BLOCKED when you stopped on a step 8 blocker
(recorded in the journal and the return handoff), or DECLINED when you will not do this
task; after DECLINED add " — " and one line saying why. For example:
IMPLEMENTER_STATUS: DONE
EOF

TOOLS="Bash,Read,Edit,Write,Glob,Grep,TodoWrite"

if [[ -n "$RESUME_ID" ]]; then
  case "$RESUME_ID" in
    haiku:*) PROVIDER=haiku ;;
    deepseek:*) PROVIDER=deepseek ;;
    *)
      echo "IMPLEMENTER_RESULT: error (thread $RESUME_ID belongs to another implementer; set IMPLEMENTER=codex to resume it)"
      exit 2
      ;;
  esac
  SID="${RESUME_ID#*:}"
  MODE=resume
  if [[ "$PROVIDER" == deepseek && -z "$DS_KEY" ]]; then
    echo "IMPLEMENTER_RESULT: error (thread $RESUME_ID needs DeepSeek and no DEEPSEEK_API_KEY is set)"
    exit 1
  fi
else
  PROVIDER=haiku
  SID="$(new_session_id)"
  MODE=new
fi

# A resumed thread already holds the full instructions; it needs only the new handoff.
PASS_PROMPT="$PROMPT"
if [[ "$MODE" == resume ]]; then
  PASS_PROMPT="Next pass for the same goal. Read the handoff: ${HANDOFF_ABS}
Keep the return handoff at ${RETURN_DOC}. The rules from your first message still apply.
Append a new START record for this pass and an END record when you stop, in the same
heading shape, naming the goal id. Run the goal's proof before claiming DONE.
End your reply with one line IMPLEMENTER_STATUS: DONE, BLOCKED or DECLINED (after
DECLINED add \" — \" and one line saying why), nothing after it."
fi
run_pass "$PROVIDER" "$MODE" "$SID" "$PASS_PROMPT" "$TOOLS"

# A thread whose first request never landed (a rate limit, a crash) was never
# saved, and resuming it fails the same way every time. Start the same
# provider afresh: the commits and the journal carry the goal's state.
if [[ "$MODE" == resume && "$RC" -ne 0 ]] && grep -q 'No conversation found with session ID' "$ERRF" 2>/dev/null; then
  echo "claude-implement: thread ${RESUME_ID} was never saved; starting a fresh ${PROVIDER} session" >&2
  SID="$(new_session_id)"
  MODE=new
  run_pass "$PROVIDER" new "$SID" "Your previous session for this goal was lost. Continue from the current HEAD; read the journal and git log first.

${PROMPT}" "$TOOLS"
fi
classify "$SID"

# One fallback, Haiku to DeepSeek, on a safety flag or a decline only. A rate
# limit, an error, or a resumed DeepSeek thread gets none.
if [[ "$PROVIDER" == haiku && ( "$KIND" == flagged || "$KIND" == declined ) \
  && "$FALLBACK" == deepseek && -n "$DS_KEY" ]]; then
  if [[ "$KIND" == flagged ]]; then FELL_BACK="refusal"; else FELL_BACK="declined"; fi
  echo "claude-implement: ${MODEL} ${KIND} this goal; running it once on ${DS_MODEL}" >&2
  PROVIDER=deepseek
  SID="$(new_session_id)"
  run_pass deepseek new "$SID" "A previous implementer declined this goal. Continue from the current HEAD; read the journal and git log first.

${PROMPT}" "$TOOLS"
  classify "$SID"
fi

emit_and_exit
