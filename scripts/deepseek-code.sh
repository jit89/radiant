#!/usr/bin/env bash
#
# deepseek-code.sh — one IMPLEMENTATION pass via Codex CLI pointed at
# DeepSeek V4 Flash (OpenAI-compatible Responses API).
#
# Isolated CODEX_HOME — does not rewrite ~/.codex/config.toml, so
# interactive Codex/ChatGPT stays untouched.
#
# This file owns the implementer prompt. Do not fork it.
#
# Usage:
#   deepseek-code.sh [--resume THREAD_ID] <handoff.md>
#   deepseek-code.sh --smoke
#
# Required:
#   DEEPSEEK_API_KEY   from the environment, the target repo .env, or
#                      ~/claude-coding-workflow/.env
# Optional:
#   DEEPSEEK_BASE_URL  default: https://api.deepseek.com/
#   DEEPSEEK_MODEL     default: deepseek-v4-flash
#   DEEPSEEK_DRY_RUN=1 print the command, skip the API call
#   CODEX_BIN          override binary path
#   DEEPSEEK_CODEX_HOME  isolated Codex state
#                      (default: ~/.cache/claude-coding-workflow/codex)
#   DEEPSEEK_REQUIRE_GIT=0  allow a non-git cwd (default: require git)
#
# Result lines:
#   DEEPSEEK_RESULT: ok | rate_limited | error | dry_run
#   THREAD_ID: <id>
#   RETURN_HANDOFF: <path>
#
# Architect: run from the target repo. Foreground timeout 20 minutes
# (1200000 ms). Recovery: see skills/run-goal/SKILL.md §6.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOUSE="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/dotenv.sh"
MODEL="${DEEPSEEK_MODEL:-deepseek-v4-flash}"
BASE_URL="${DEEPSEEK_BASE_URL:-https://api.deepseek.com/}"
CODEX_HOME_DIR="${DEEPSEEK_CODEX_HOME:-$HOME/.cache/claude-coding-workflow/codex}"
SMOKE=0
RESUME_ID=""
HANDOFF=""
THREAD_ID=""
RETURN_DOC=""
OUT=""

usage() {
  echo "usage: deepseek-code.sh [--resume THREAD_ID] <handoff.md>" >&2
  echo "       deepseek-code.sh --smoke" >&2
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
      [[ -z "$HANDOFF" ]] || usage
      HANDOFF="$1"
      shift
      ;;
  esac
done

load_key() {
  load_key_from_files DEEPSEEK_API_KEY .env "$HOUSE/.env"
}

find_codex() {
  if [[ -n "${CODEX_BIN:-}" && -x "$CODEX_BIN" ]]; then
    printf '%s' "$CODEX_BIN"
    return 0
  fi
  local c
  c="$(command -v codex 2>/dev/null || true)"
  if [[ -n "$c" ]]; then
    printf '%s' "$c"
    return 0
  fi
  local nvm_latest
  nvm_latest="$(ls -1d "$HOME"/.nvm/versions/node/*/bin/codex 2>/dev/null | tail -n1 || true)"
  if [[ -n "$nvm_latest" && -x "$nvm_latest" ]]; then
    printf '%s' "$nvm_latest"
    return 0
  fi
  for c in "$HOME/.local/bin/codex" /opt/homebrew/bin/codex /usr/local/bin/codex; do
    if [[ -x "$c" ]]; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

CODEX_BIN="$(find_codex)" || {
  echo "could not find the codex binary (install Codex CLI, or set CODEX_BIN)" >&2
  exit 1
}
export PATH="$(dirname "$CODEX_BIN"):$PATH"

if ! load_key; then
  if [[ "${DEEPSEEK_DRY_RUN:-0}" != "1" ]]; then
    echo "DEEPSEEK_API_KEY is not set. Put it in the target .env or $HOUSE/.env" >&2
    echo "(see $HOUSE/.env.example). Do not paste the key into chat." >&2
    exit 1
  fi
fi

mkdir -p "$CODEX_HOME_DIR"
export CODEX_HOME="$CODEX_HOME_DIR"

# config.toml is rewritten per invocation (model, effort, and this repo's
# gitdir), but CODEX_HOME is shared so `--resume THREAD_ID` can find the
# thread. Two concurrent runs would therefore read each other's config —
# a second repo's writable_roots, or a smoke run's low effort. Serialize
# on an exclusive lock: mkdir is atomic, and a lock whose owner is gone is
# reaped. Concurrency is not silently wrong, just queued.
LOCK_DIR="$CODEX_HOME_DIR/.lock"
LOCK_HELD=0
LOCK_WAIT="${DEEPSEEK_LOCK_WAIT:-1800}"

release_lock() {
  [[ "$LOCK_HELD" -eq 1 ]] || return 0
  rm -rf "$LOCK_DIR"
  LOCK_HELD=0
}

acquire_lock() {
  local waited=0 owner
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
      echo "deepseek-code: reaping stale Codex lock from pid $owner" >&2
      rm -rf "$LOCK_DIR"
      continue
    fi
    if (( waited >= LOCK_WAIT )); then
      echo "deepseek-code: timed out after ${LOCK_WAIT}s waiting for the Codex" >&2
      echo "  home lock held by pid ${owner:-unknown} ($LOCK_DIR)." >&2
      echo "  Another run-goal is in flight; runs are sequential by design." >&2
      exit 1
    fi
    if (( waited == 0 )); then
      echo "deepseek-code: waiting for the Codex home lock (pid ${owner:-unknown})…" >&2
    fi
    sleep 2
    waited=$((waited + 2))
  done
  LOCK_HELD=1
  printf '%s' "$$" >"$LOCK_DIR/pid"
  trap 'release_lock' EXIT INT TERM
}

acquire_lock
cp "$HERE/lib/codex-models.deepseek.json" "$CODEX_HOME/models.json"

# Isolated config. Rewritten on every invocation so a previous repo's
# .git path does not linger. GIT_WRITABLE_ROOTS is a TOML array or empty.
GIT_WRITABLE_ROOTS=""

toml_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# Codex workspace-write remounts <root>/.git read-only on purpose
# (hooks would otherwise run unsandboxed the next time a human runs
# git). Naming the gitdir itself in writable_roots is an explicit
# rule and skips that carve-out, so `git commit` can create
# index.lock without require_escalated. Linked worktrees need both
# the per-worktree gitdir and the common gitdir.
# That hands the model hooks and config too. run-goal.sh closes the
# gap: lib/git-guard.sh runs host git with hooks off and wakes if
# .git config / hooks / info changed during the pass.
compute_git_writable_roots() {
  local git_dir common
  git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null || true)"
  [[ -n "$git_dir" ]] || { GIT_WRITABLE_ROOTS=""; return 0; }
  common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [[ -n "$common" && "$common" != /* ]]; then
    common="$(cd "$common" && pwd)"
  fi
  if [[ -z "$common" || "$git_dir" == "$common" ]]; then
    GIT_WRITABLE_ROOTS="[$(toml_quote "$git_dir")]"
  else
    GIT_WRITABLE_ROOTS="[$(toml_quote "$git_dir"),$(toml_quote "$common")]"
  fi
}

write_codex_config() {
  local effort="${1:-${SMOKE_EFFORT:-high}}"
  local roots="${GIT_WRITABLE_ROOTS:-[]}"
  [[ -n "$roots" ]] || roots="[]"
  cat >"$CODEX_HOME/config.toml" <<EOF
model = "${MODEL}"
model_provider = "deepseek"
preferred_auth_method = "apikey"
forced_login_method = "api"
model_reasoning_effort = "${effort}"
model_catalog_json = "${CODEX_HOME}/models.json"
sandbox_mode = "workspace-write"
approval_policy = "never"

[sandbox_workspace_write]
writable_roots = ${roots}

[model_providers.deepseek]
name = "deepseek"
base_url = "${BASE_URL}"
wire_api = "responses"
env_key = "DEEPSEEK_API_KEY"
EOF
}

write_codex_config

parse_thread_id() {
  python3 -c '
import json, sys
tid = ""
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue
    t = obj.get("type") or ""
    if t == "thread.started" and obj.get("thread_id"):
        tid = obj["thread_id"]
        break
    if not tid:
        tid = obj.get("thread_id") or obj.get("session_id") or obj.get("sessionId") or tid
print(tid)
'
}

git_guard() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi
  if [[ "${DEEPSEEK_REQUIRE_GIT:-1}" == "0" ]]; then
    echo "WARNING: not inside a git repo and DEEPSEEK_REQUIRE_GIT=0." >&2
    echo "  Checkpoints and resume-after-interruption are DISABLED." >&2
    return 0
  fi
  echo "ERROR: not inside a git repo (recovery needs commits)." >&2
  echo "  Set DEEPSEEK_REQUIRE_GIT=0 to override." >&2
  exit 1
}

# One Codex invocation. Sets LAST_RC, LAST_KIND (ok|rate_limited|error),
# LAST_JSONL. Updates THREAD_ID. Dry-run exits the process.
codex_once() {
  local prompt="$1"
  shift || true
  local extra=("$@")
  local prompt_file jsonl
  prompt_file="$(mktemp -t deepseek-prompt-XXXXXX.txt)"
  jsonl="$(mktemp -t deepseek-jsonl-XXXXXX.jsonl)"
  LAST_JSONL="$jsonl"
  printf '%s\n' "$prompt" >"$prompt_file"

  local cmd=("$CODEX_BIN" exec)
  # Implement path: --approve-for-me on first exec AND resume.
  # Codex 0.147 rejects combining -s with --approve-for-me, so we
  # never pass -s here; isolated config.toml sets workspace-write.
  # Flags go before `resume` so clap treats them as exec options.
  # Do NOT pass approval_policy=never on resume: that forbids the
  # require_escalated retry Codex uses when .git is still carved
  # read-only (g2-fix dogfood: index.lock Operation not permitted).
  # Smoke passes -s read-only in extra[] and must not add write flags.
  if [[ "$SMOKE" -eq 1 ]]; then
    :
  else
    cmd+=(--approve-for-me)
    if [[ -n "$GIT_WRITABLE_ROOTS" ]]; then
      cmd+=(-c "sandbox_workspace_write.writable_roots=${GIT_WRITABLE_ROOTS}")
    fi
  fi
  cmd+=(--json -o "$OUT" -m "$MODEL")
  if [[ -n "$RESUME_ID" ]]; then
    cmd+=(resume "$RESUME_ID")
    THREAD_ID="$RESUME_ID"
  fi
  if ((${#extra[@]})); then
    cmd+=("${extra[@]}")
  fi

  if [[ "${DEEPSEEK_DRY_RUN:-0}" == "1" ]]; then
    echo "DEEPSEEK_RESULT: dry_run"
    echo "THREAD_ID: ${THREAD_ID}"
    echo "RETURN_HANDOFF: ${RETURN_DOC}"
    printf 'CMD:'
    printf ' %q' "${cmd[@]}" -
    printf '\n'
    echo "PROMPT_FILE: $prompt_file"
    exit 0
  fi

  set +e
  "${cmd[@]}" - <"$prompt_file" >"$jsonl" 2>"${jsonl}.err"
  LAST_RC=$?
  set -e

  local parsed
  parsed="$(parse_thread_id <"$jsonl" || true)"
  [[ -n "$parsed" ]] && THREAD_ID="$parsed"

  if is_transport_rate_limit "$LAST_RC" "${jsonl}.err"; then
    LAST_KIND="rate_limited"
    return 0
  fi
  if [[ $LAST_RC -ne 0 ]]; then
    LAST_KIND="error"
    return 0
  fi
  LAST_KIND="ok"
}

emit_and_exit() {
  local kind="$1"
  if [[ "$kind" == "ok" ]]; then
    echo "DEEPSEEK_RESULT: ok"
  else
    echo "DEEPSEEK_RESULT: ${kind} (exit ${LAST_RC:-1})"
  fi
  echo "THREAD_ID: ${THREAD_ID}"
  echo "RETURN_HANDOFF: ${RETURN_DOC}"
  if [[ -n "${OUT}" ]]; then
    echo "REPORT: ${OUT}"
  fi
  if [[ -n "${LAST_JSONL:-}" ]]; then
    echo "LOG: ${LAST_JSONL}"
    echo "stderr: ${LAST_JSONL}.err"
  fi
  case "$kind" in
    ok|dry_run) exit 0 ;;
    rate_limited) exit 75 ;;
    *) exit "${LAST_RC:-1}" ;;
  esac
}

# --- smoke -----------------------------------------------------------------
if [[ "$SMOKE" -eq 1 ]]; then
  SMOKE_EFFORT="low"
  # Rewrite config with low effort now that SMOKE_EFFORT is set.
  sed -i.bak 's/^model_reasoning_effort = .*/model_reasoning_effort = "low"/' \
    "$CODEX_HOME/config.toml" && rm -f "$CODEX_HOME/config.toml.bak"
  OUT="${TMPDIR:-/tmp}/deepseek-smoke-$$.txt"
  : >"$OUT"
  LAST_RC=0
  LAST_KIND=""
  MAX_RETRIES="${DEEPSEEK_MAX_RETRIES:-3}"
  attempt=1
  while :; do
    codex_once "Reply with exactly this single line and nothing else:
PONG ${MODEL}" --skip-git-repo-check -s read-only
    case "$LAST_KIND" in
      ok) emit_and_exit ok ;;
      rate_limited)
        if (( attempt >= MAX_RETRIES )); then
          emit_and_exit rate_limited
        fi
        sleep $((10 * attempt))
        attempt=$((attempt + 1))
        ;;
      *)
        tail -n 40 "${LAST_JSONL}.err" >&2 || true
        emit_and_exit error
        ;;
    esac
  done
fi
# ---------------------------------------------------------------------------

[[ -n "$HANDOFF" ]] || usage
[[ -f "$HANDOFF" ]] || { echo "handoff not found: $HANDOFF" >&2; exit 1; }
HANDOFF_ABS="$(cd "$(dirname "$HANDOFF")" && pwd)/$(basename "$HANDOFF")"
git_guard
compute_git_writable_roots
write_codex_config "${SMOKE_EFFORT:-high}"

RETURN_DOC="${TMPDIR:-/tmp}/return-$(basename "$HANDOFF")"
OUT="${TMPDIR:-/tmp}/deepseek-report-$(basename "$HANDOFF")"
: >"$OUT"
THREAD_ID="${RESUME_ID:-}"

read -r -d '' PROMPT <<EOF || true
You are the IMPLEMENTATION agent (model: ${MODEL}, Codex harness). You only implement.

1. Read the handoff document: ${HANDOFF_ABS}
2. Read every artifact it references — the PLAN copy it names, GOALS.md (the named goal only),
   ADRs (docs/adr/), CONTEXT.md, and the journal (docs/journal/<slug>.md).
   Treat that PLAN + the goal's case table / oracle as the contract. ADRs bind.
   Read the journal before starting so you do not repeat past work.
3. JOURNAL — append (never overwrite) a START entry:
   "## <UTC from: date -u +%Y-%m-%dT%H:%M:%SZ> — IMPLEMENTER start"
   with the goal id and your understanding. Append an END entry when you
   finish/stop: outcome, commit shas, test result, blockers.
4. CHECKPOINT YOUR WORK. If this is a git repo, commit after EVERY green test
   with a "wip(<goal-id>): <behavior>" message. Stage ONLY the files YOU
   created or modified for this goal — git add <explicit paths>; NEVER
   'git add -A', 'git add .', or 'git commit -a'. The Architect may have
   unrelated work-in-progress in this SHARED working tree. Progress is
   durable: if you are cut off (quota / crash) only the in-flight cycle
   is lost and the next run resumes from the last commit. This harness
   makes the repo's .git writable inside workspace-write so git add /
   commit should succeed without require_escalated. If a commit still
   fails with index.lock "Operation not permitted", retry once with
   escalation; do not declare a sandbox blocker on the first failure.
5. THE ACCEPTANCE GATE IS A CONTRACT. The handoff names it as one of:
     (a) ACCEPTANCE TESTS at a named path — READ-ONLY. Make them pass.
         Do NOT modify, weaken, or delete them.
     (b) A CASE-TABLE in the goal body. Implement exactly those cases
         (encode them as tests via TDD); do not reinterpret or narrow them.
   A contract test that looks wrong is a blocker to bounce (step 8), not
   something to edit. Your own finer unit tests sit on top via TDD.
6. STRICT TDD — red → green, ONE test at a time, behavior not
   implementation, never all tests first. Test ONLY at the seams named
   in the handoff. You are headless: do not wait to confirm seams with
   the user. REFACTORING IS NOT IN YOUR LOOP — stop at green, don't
   polish. Least code that passes: reuse → stdlib → native → already-
   installed dep → one-liner → minimal new code. Never skimp on input
   validation at trust boundaries, error handling that prevents data
   loss, security, or accessibility. Scope is fixed by the plan/goal.
   MARK KNOWN CEILINGS in this exact form:
     # ponytail: <limitation>; upgrade = <path>
   Only load-bearing ceilings. Re-read out-of-scope before finishing.
7. SCOPE is the goal and the plan. Two kinds of change fall outside it:
   - A DEVIATION: a minimal change outside the handoff's stated scope
     that meeting the contract exactly requires — wiring an existing call
     site so passing tests stay green, correcting a comment this goal
     makes false, pinning a dev tool so the suite runs. Make it, and
     record each one (file, change, why the contract required it) under
     "Deviations" in the journal END entry and the return handoff.
   - A BLOCKER (step 8): changing a contract (an acceptance test, a case
     table, or a PLAN decision, interface or signature); building
     behaviour another goal owns; adding a runtime dependency the plan
     does not name; choosing between readings of the spec.
8. NEVER fake success. Do not weaken, skip, comment out, or delete a
   test to make it pass, and do not mark work done with failing tests.
   If you are BLOCKED — a step 7 blocker, a test you cannot make pass,
   or an unknown you cannot resolve from the codebase/plan/docs — STOP.
   Do not guess or research the web. Record the blocker (what you tried,
   hypotheses, the exact question for the Architect) in the journal +
   return handoff, leave tests honestly red, and exit. A bounced blocker
   is a success; a gamed test is a failure.
9. Run the goal's PROOF command and then the full test suite if one
   exists. Report the real result.
10. RESUMABILITY: maintain the return handoff at ${RETURN_DOC} as you
    go — update it after each commit with Status (done / in-progress /
    remaining + last commit sha). Write it EARLY and keep it current.
11. When finished, finalize ${RETURN_DOC} (changes, decisions,
    deviations, test summary, open questions/blockers; secrets redacted)
    and print its path as your LAST line.
EOF

MAX_RETRIES="${DEEPSEEK_MAX_RETRIES:-3}"
attempt=1
LAST_RC=0
LAST_KIND=""
while :; do
  codex_once "$PROMPT"
  case "$LAST_KIND" in
    ok) emit_and_exit ok ;;
    rate_limited)
      if (( attempt >= MAX_RETRIES )); then
        echo "RECOVER: inspect git status and git log --oneline, wait for the" >&2
        echo "  quota window, then re-dispatch with a RESUME handoff." >&2
        emit_and_exit rate_limited
      fi
      if [[ -n "$THREAD_ID" ]]; then
        RESUME_ID="$THREAD_ID"
      fi
      echo "DEEPSEEK_RESULT: rate_limited — attempt ${attempt}/${MAX_RETRIES}" >&2
      sleep $((10 * attempt))
      attempt=$((attempt + 1))
      ;;
    *)
      tail -n 40 "${LAST_JSONL}.err" >&2 || true
      emit_and_exit error
      ;;
  esac
done
