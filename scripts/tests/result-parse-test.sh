#!/usr/bin/env bash
# Self-test: launcher results that are missing, partial, or timed out are
# classified by run-goal.sh, not lost to set -e as reason=trap (F-07).
# Launchers are stubs; nothing calls a model.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-result-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" EVENTS_CACHE="$TMP/cache"
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
# No background auto-maintenance: a detached repack still writing .git/objects
# races the next scenario's rm -rf of the repo.
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
export DEEPSEEK_API_KEY=stub-not-a-key DEEPSEEK_TIMEOUT=2 CLAUDE_REVIEW_TIMEOUT=2
unset ANTHROPIC_API_KEY
mkdir -p "$HOME"
fails=0

check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name: want [$want] got [$got]"
    fails=$((fails + 1))
  fi
}
has() { [[ "$2" == *"$1"* ]] && echo yes || echo "no: $2"; }

HOUSE="$TMP/house"
mkdir -p "$HOUSE/scripts"
cp -R "$HERE/." "$HOUSE/scripts/"
stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$HOUSE/scripts/$1"
  chmod +x "$HOUSE/scripts/$1"
}
COMMIT='echo "$RANDOM" >>impl.txt && git add impl.txt && git commit -qm "wip(g1-store): impl"'

make_repo() {
  rm -rf "$TMP/repo"
  mkdir -p "$TMP/repo/docs/journal" && cd "$TMP/repo"
  git init -q
  cp "$HERE/../GOALS.example.md" GOALS.md
  printf '# Plan\n' >PLAN.md
  printf '# Journal: example\n' >docs/journal/example.md
  git add -- GOALS.md PLAN.md docs/journal/example.md
  git commit -q -m base
}

# Sets rc, reason, detail, thread from the stop file.
run_goal() {
  make_repo
  "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 && rc=0 || rc=$?
  local stop
  stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)"
  reason="$(sed -n 's/^- reason: //p' "$stop" 2>/dev/null || true)"
  detail="$(sed -n 's/^- detail: //p' "$stop" 2>/dev/null || true)"
  thread="$(sed -n 's/^- THREAD_ID: //p' "$stop" 2>/dev/null || true)"
}

stub claude-goal-review.sh 'printf "%s\n" "CLAUDE_REVIEW_RESULT: error (exit 1)" \
  "SESSION_ID: s1" "VERDICT: MISSING" "VERDICT_FILE: /dev/null"; exit 1'

# Implementer crashes before printing anything (missing binary, key, lock).
stub deepseek-code.sh 'echo "could not find the codex binary" >&2; exit 1'
run_goal
check "silent crash: implementer-error" "implementer-error" "$reason"
check "silent crash: detail says no result, with rc" "yes" \
  "$(has 'no DEEPSEEK_RESULT line (rc=1)' "$detail")"

# Implementer exits 0 but prints no result: not a success.
stub deepseek-code.sh "$COMMIT"
run_goal
check "rc 0 without result: implementer-error" "implementer-error" "$reason"

# Implementer runs past DEEPSEEK_TIMEOUT.
stub deepseek-code.sh 'sleep 30'
run_goal
check "slow implementer: implementer-timeout" "implementer-timeout" "$reason"
check "timeout detail names the limit" "yes" "$(has '2s' "$detail")"

# Only the required line: optional fields missing must not stop the run.
stub deepseek-code.sh "$COMMIT"'
echo "DEEPSEEK_RESULT: ok"'
run_goal
check "minimal ok result reaches review" "reviewer-error" "$reason"

# Reviewer crashes silently / runs past its timeout.
stub deepseek-code.sh "$COMMIT"'
printf "%s\n" "DEEPSEEK_RESULT: ok" "THREAD_ID: t1"'
stub claude-goal-review.sh 'exit 1'
run_goal
check "silent reviewer: reviewer-error" "reviewer-error" "$reason"
check "silent reviewer: detail says no result, with rc" "yes" \
  "$(has 'no CLAUDE_REVIEW_RESULT line (rc=1)' "$detail")"
stub claude-goal-review.sh 'sleep 30'
run_goal
check "slow reviewer: reviewer-timeout" "reviewer-timeout" "$reason"

# Fix round: resumed implementer dies without a THREAD_ID line. The thread
# from round 0 must survive into the stop file so the goal can resume it.
cat >"$TMP/fix-verdict.md" <<'MD'
FIX: impl.txt:1 — wrong — change it
VERDICT: FIX
MD
stub claude-goal-review.sh "printf '%s\n' 'CLAUDE_REVIEW_RESULT: ok' 'SESSION_ID: s1' \
  'VERDICT: FIX' 'VERDICT_FILE: $TMP/fix-verdict.md'"
stub deepseek-code.sh 'if [[ "$1" == --resume ]]; then echo "DEEPSEEK_RESULT: error (exit 1)"; exit 1; fi
'"$COMMIT"'
printf "%s\n" "DEEPSEEK_RESULT: ok" "THREAD_ID: t1"'
run_goal
check "fix round crash: implementer-error" "implementer-error" "$reason"
check "fix round crash: thread kept" "t1" "$thread"

# Reviewer safeguards flag the review and no fallback cleared it (exit 76): the
# orchestrator stops fail-closed under its own reason, never a guessed verdict.
stub deepseek-code.sh "$COMMIT"'
printf "%s\n" "DEEPSEEK_RESULT: ok" "THREAD_ID: t1"'
stub claude-goal-review.sh 'printf "%s\n" "CLAUDE_REVIEW_RESULT: flagged (claude-opus-4-8)" \
  "SESSION_ID: s1" "VERDICT: MISSING" "VERDICT_FILE: /dev/null" \
  "CLAUDE_REVIEW_MODEL: claude-opus-4-8" \
  "CLAUDE_REVIEW_FALLBACK: claude-opus-5 -> claude-opus-4-8 (both flagged)"; exit 76'
run_goal
check "flagged reviewer: reviewer-flagged" "reviewer-flagged" "$reason"
check "flagged reviewer: detail says nothing was judged" "yes" "$(has 'Nothing was judged' "$detail")"

# The journal names the model that judged, and marks a fallback so it is never silent.
stub deepseek-code.sh 'if [[ "$1" == --resume ]]; then echo "DEEPSEEK_RESULT: error (exit 1)"; exit 1; fi
'"$COMMIT"'
printf "%s\n" "DEEPSEEK_RESULT: ok" "THREAD_ID: t1"'
stub claude-goal-review.sh "printf '%s\n' 'CLAUDE_REVIEW_RESULT: ok' 'SESSION_ID: s1' \
  'VERDICT: FIX' 'VERDICT_FILE: $TMP/fix-verdict.md' 'CLAUDE_REVIEW_MODEL: claude-opus-4-8' \
  'CLAUDE_REVIEW_FALLBACK: claude-opus-5 -> claude-opus-4-8 (safety flag)'"
run_goal
journal="$(cat "$TMP/repo/docs/journal/example.md")"
check "fallback: the judging model is journaled" "yes" "$(has 'MODEL=claude-opus-4-8' "$journal")"
check "fallback: the switch is journaled" "yes" \
  "$(has 'FALLBACK=(claude-opus-5 -> claude-opus-4-8 (safety flag))' "$journal")"
stub claude-goal-review.sh "printf '%s\n' 'CLAUDE_REVIEW_RESULT: ok' 'SESSION_ID: s1' \
  'VERDICT: FIX' 'VERDICT_FILE: $TMP/fix-verdict.md' 'CLAUDE_REVIEW_MODEL: claude-opus-5'"
run_goal
journal="$(cat "$TMP/repo/docs/journal/example.md")"
check "no fallback: the primary is journaled" "yes" "$(has 'MODEL=claude-opus-5' "$journal")"
check "no fallback: no FALLBACK marker" "yes" \
  "$([[ "$journal" != *FALLBACK=* ]] && echo yes || echo "present")"

if [[ "$fails" -eq 0 ]]; then
  echo "result-parse: OK"
else
  echo "result-parse: $fails FAILURE(S)" >&2
  exit 1
fi
