#!/usr/bin/env bash
# Self-test: launcher results that are missing, partial, or timed out are
# classified by run-goal.sh, not lost to set -e as reason=trap (F-07).
# Launchers are stubs; nothing calls a model.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-result-XXXXXX")"
export TMPDIR="$TMP"
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
stub claude-implement.sh 'echo "could not find the codex binary" >&2; exit 1'
run_goal
check "silent crash: implementer-error" "implementer-error" "$reason"
check "silent crash: detail says no result, with rc" "yes" \
  "$(has 'no IMPLEMENTER_RESULT line (rc=1)' "$detail")"

# Implementer exits 0 but prints no result: not a success.
stub claude-implement.sh "$COMMIT"
run_goal
check "rc 0 without result: implementer-error" "implementer-error" "$reason"

# Implementer runs past DEEPSEEK_TIMEOUT.
stub claude-implement.sh 'sleep 30'
run_goal
check "slow implementer: implementer-timeout" "implementer-timeout" "$reason"
check "timeout detail names the limit" "yes" "$(has '2s' "$detail")"

# Only the required line: optional fields missing must not stop the run.
stub claude-implement.sh "$COMMIT"'
echo "IMPLEMENTER_RESULT: ok"'
rm -rf "$EVENTS_CACHE"
run_goal
check "minimal ok result reaches review" "reviewer-error" "$reason"
# The footer's source: the dispatch and each phase carry the pid and its start.
# (This fixture's proof is `true`, no command, so there is no proof phase.)
rows="$(cat "$EVENTS_CACHE"/*/*.jsonl 2>/dev/null || true)"
check "events: review phase recorded" yes "$(has '"phase": "review"' "$(python3 -c 'import json,sys; [print(json.dumps(json.loads(l).get("payload"))) for l in sys.stdin if l.strip()]' <<<"$rows")")"
check "events: every dispatch and phase names its process and start" yes "$(python3 -c '
import json,sys
rows=[json.loads(l) for l in sys.stdin if l.strip()]
own=[r for r in rows if r["event"] in ("dispatch","phase")]
ok=own and all(isinstance(r["payload"].get("pid"),int) and r["payload"].get("pid_start") for r in own)
print("yes" if ok else own)' <<<"$rows")"

# Reviewer crashes silently / runs past its timeout.
stub claude-implement.sh "$COMMIT"'
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: t1"'
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
stub claude-implement.sh 'if [[ " $* " == *" --resume "* ]]; then echo "IMPLEMENTER_RESULT: error (exit 1)"; exit 1; fi
'"$COMMIT"'
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: t1"'
run_goal
check "fix round crash: implementer-error" "implementer-error" "$reason"
check "fix round crash: thread kept" "t1" "$thread"
# FUTURE-WORK item 24: each pass's records are committed before it runs, the
# review, fix and r1 dispatch records included.
c="$(git log -1 --format=%H --grep=': orchestrator dispatch r1$')"
check "fix round: the r1 dispatch commit holds the review, fix and dispatch records" "1 1 1" \
  "$(for r in 'review g1-store r0' 'fix g1-store r0' 'dispatch g1-store r1 '; do git show "$c:docs/journal/example.md" 2>/dev/null | grep -c "ORCHESTRATOR $r" || true; done | paste -sd ' ' -)"
# A reviewer that changes .git stops the goal on that, right after the review
# (FUTURE-WORK item 26), not later as commit-failed.
stub claude-goal-review.sh "printf '#!/bin/sh\nexit 0\n' >.git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
printf '%s\n' 'CLAUDE_REVIEW_RESULT: ok' 'SESSION_ID: s1' 'VERDICT: FIX' 'VERDICT_FILE: $TMP/fix-verdict.md'"
run_goal
check "reviewer changed .git: git-metadata-tamper" "git-metadata-tamper" "$reason"
check "reviewer changed .git: named during review r0" "yes" "$(has 'during review r0' "$detail")"
# FUTURE-WORK item 26: on a DONE verdict too, before the route marks the goal
# done; and Claude Code's own config, the same way.
printf 'VERDICT: DONE\n' >"$TMP/done-verdict.md"
stub claude-goal-review.sh "printf '#!/bin/sh\nexit 0\n' >.git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
printf '%s\n' 'CLAUDE_REVIEW_RESULT: ok' 'SESSION_ID: s1' 'VERDICT: DONE' 'VERDICT_FILE: $TMP/done-verdict.md'"
run_goal
check "reviewer changed .git, DONE: git-metadata-tamper" "git-metadata-tamper" "$reason"
check "reviewer changed .git, DONE: named during review r0" "yes" "$(has 'during review r0' "$detail")"
check "reviewer changed .git, DONE: the goal is not marked done" in_progress \
  "$("$HERE/goals.py" GOALS.md show g1-store | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
stub claude-goal-review.sh "mkdir -p .claude && printf '{}\n' >.claude/settings.json
printf '%s\n' 'CLAUDE_REVIEW_RESULT: ok' 'SESSION_ID: s1' 'VERDICT: DONE' 'VERDICT_FILE: $TMP/done-verdict.md'"
run_goal
check "reviewer changed .claude/: claude-config-tamper" "claude-config-tamper" "$reason"
check "reviewer changed .claude/: named during review r0" "yes" "$(has 'during review r0' "$detail")"
stub claude-goal-review.sh "printf '%s\n' 'CLAUDE_REVIEW_RESULT: ok' 'SESSION_ID: s1' \
  'VERDICT: FIX' 'VERDICT_FILE: $TMP/fix-verdict.md'"

# A goal whose attempt fell back resumes with the fallback off, so it stays on
# the model it fell back to (docs/features/deepseek-primary Q2), even if the
# primary changed meanwhile. Without a fallback the resume leaves it alone.
export FB_SEEN="$TMP/fb-seen"
for fb in yes no; do
  rm -f "$FB_SEEN"
  line=""
  [[ "$fb" == no ]] || line='"IMPLEMENTER_FALLBACK: haiku -> deepseek (refusal)"'
  stub claude-implement.sh 'if [[ " $* " == *" --resume "* ]]; then echo "${IMPLEMENTER_FALLBACK-unset}" >"$FB_SEEN"; echo "IMPLEMENTER_RESULT: error (exit 1)"; exit 1; fi
'"$COMMIT"'
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: deepseek:t2" "IMPLEMENTER_STATUS: DONE" '"$line"
  run_goal
  if [[ "$fb" == yes ]]; then
    check "fell back: the resume runs with the fallback off" "none" "$(cat "$FB_SEEN" 2>/dev/null)"
  else
    check "no fallback: the resume leaves the setting alone" "unset" "$(cat "$FB_SEEN" 2>/dev/null)"
  fi
done
# An earlier attempt's fallback (before a recut: an older `dispatch r0`) does
# not carry into a new attempt.
rm -f "$FB_SEEN"
stub claude-implement.sh 'if [[ " $* " == *" --resume "* ]]; then echo "${IMPLEMENTER_FALLBACK-unset}" >"$FB_SEEN"; echo "IMPLEMENTER_RESULT: error (exit 1)"; exit 1; fi
'"$COMMIT"'
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: deepseek:t3" "IMPLEMENTER_STATUS: DONE"'
make_repo
printf '\n## 2026-01-01T00:00:00Z — ORCHESTRATOR dispatch g1-store r0 BASE_SHA=0000000 THREAD_ID=- SESSION_ID=-\n\n## 2026-01-01T00:00:01Z — ORCHESTRATOR implemented g1-store r0 STATUS=DONE MODEL=m FALLBACK=(haiku -> deepseek (refusal)) COST_USD=-\n' >>docs/journal/example.md
git add docs/journal/example.md && git commit -qm "an earlier attempt that fell back"
"$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 || true
check "an earlier attempt's fallback does not carry into a new one" "unset" "$(cat "$FB_SEEN" 2>/dev/null || tail -n 5 "$TMP/out")"

# The case the guard is for: a goal that fell back pauses before any fix round,
# and its resume (which re-dispatches r0 with the thread) must still run with
# the fallback off, on a second pause too.
resume_goal() { "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 || true; }
RESUME_RECORDS='if [[ " $* " == *" --resume "* ]]; then echo "${IMPLEMENTER_FALLBACK-unset}" >>"$FB_SEEN"; echo "IMPLEMENTER_RESULT: error (exit 1)"; exit 1; fi'
rm -f "$FB_SEEN"
stub claude-implement.sh "$RESUME_RECORDS"'
'"$COMMIT"'
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: deepseek:t5" "IMPLEMENTER_STATUS: DONE" "IMPLEMENTER_FALLBACK: haiku -> deepseek (refusal)"'
stub claude-goal-review.sh 'printf "%s\n" "CLAUDE_REVIEW_RESULT: rate_limited (exit 1)" "SESSION_ID: s1" "VERDICT: MISSING" "VERDICT_FILE: /dev/null"; exit 75'
run_goal
check "fell back, then the review paused it" "reviewer-rate-limited" "$reason"
resume_goal
resume_goal
check "resumed after the pause, twice: the fallback stays off" "none none" "$(paste -sd' ' - <"$FB_SEEN" 2>/dev/null)"
# A fallback whose second pass stopped (a rate limit) before any implemented line.
rm -f "$FB_SEEN"
stub claude-implement.sh "$RESUME_RECORDS"'
printf "%s\n" "IMPLEMENTER_RESULT: rate_limited (exit 1)" "THREAD_ID: haiku:t6" "IMPLEMENTER_STATUS: MISSING" "IMPLEMENTER_FALLBACK: deepseek -> haiku (balance)"; exit 75'
run_goal
check "the secondary was rate-limited" "rate_limited" "$reason"
check "the fallback is on the journal's ids line" "1" "$(grep -c 'ORCHESTRATOR ids g1-store r0 THREAD_ID=haiku:t6 SESSION_ID=- FALLBACK=(deepseek -> haiku (balance))' "$TMP/repo/docs/journal/example.md")"
resume_goal
check "resumed: the fallback stays off" "none" "$(cat "$FB_SEEN" 2>/dev/null || tail -n 5 "$TMP/out")"

# Reviewer safeguards flag the review and no fallback cleared it (exit 76): the
# orchestrator stops fail-closed under its own reason, never a guessed verdict.
stub claude-implement.sh "$COMMIT"'
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: t1"'
stub claude-goal-review.sh 'printf "%s\n" "CLAUDE_REVIEW_RESULT: flagged (claude-opus-4-8)" \
  "SESSION_ID: s1" "VERDICT: MISSING" "VERDICT_FILE: /dev/null" \
  "CLAUDE_REVIEW_MODEL: claude-opus-4-8" \
  "CLAUDE_REVIEW_FALLBACK: claude-opus-5-5 -> claude-opus-4-8 (both flagged)"; exit 76'
run_goal
check "flagged reviewer: reviewer-flagged" "reviewer-flagged" "$reason"
check "flagged reviewer: detail says nothing was judged" "yes" "$(has 'Nothing was judged' "$detail")"

# The journal names the model that judged, and marks a fallback so it is never silent.
stub claude-implement.sh 'if [[ " $* " == *" --resume "* ]]; then echo "IMPLEMENTER_RESULT: error (exit 1)"; exit 1; fi
'"$COMMIT"'
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: t1"'
stub claude-goal-review.sh "printf '%s\n' 'CLAUDE_REVIEW_RESULT: ok' 'SESSION_ID: s1' \
  'VERDICT: FIX' 'VERDICT_FILE: $TMP/fix-verdict.md' 'CLAUDE_REVIEW_MODEL: claude-opus-4-8' \
  'CLAUDE_REVIEW_FALLBACK: claude-opus-5-5 -> claude-opus-4-8 (safety flag)'"
run_goal
journal="$(cat "$TMP/repo/docs/journal/example.md")"
check "fallback: the judging model is journaled" "yes" "$(has 'MODEL=claude-opus-4-8' "$journal")"
check "fallback: the switch is journaled" "yes" \
  "$(has 'FALLBACK=(claude-opus-5-5 -> claude-opus-4-8 (safety flag))' "$journal")"
stub claude-goal-review.sh "printf '%s\n' 'CLAUDE_REVIEW_RESULT: ok' 'SESSION_ID: s1' \
  'VERDICT: FIX' 'VERDICT_FILE: $TMP/fix-verdict.md' 'CLAUDE_REVIEW_MODEL: claude-opus-5-5'"
run_goal
journal="$(cat "$TMP/repo/docs/journal/example.md")"
check "no fallback: the primary is journaled" "yes" "$(has 'MODEL=claude-opus-5-5' "$journal")"
check "no fallback: no FALLBACK marker" "yes" \
  "$([[ "$journal" != *FALLBACK=* ]] && echo yes || echo "present")"

# Implementer refused or declined with no fallback left (exit 76): its own stop,
# nothing assessed.
stub claude-goal-review.sh 'printf "%s\n" "CLAUDE_REVIEW_RESULT: error (exit 1)" \
  "SESSION_ID: s1" "VERDICT: MISSING" "VERDICT_FILE: /dev/null"; exit 1'
stub claude-implement.sh 'printf "%s\n" "IMPLEMENTER_RESULT: declined (deepseek)" "THREAD_ID: deepseek:u1" \
  "IMPLEMENTER_STATUS: DECLINED" "IMPLEMENTER_MODEL: deepseek-v4-flash" \
  "IMPLEMENTER_FALLBACK: haiku -> deepseek (declined)"; exit 76'
run_goal
check "declined implementer: implementer-declined" "implementer-declined" "$reason"
check "declined implementer: detail names the result" "yes" "$(has 'IMPLEMENTER_RESULT=declined (deepseek)' "$detail")"
check "declined implementer: thread kept" "deepseek:u1" "$thread"

# Out of balance with no fallback left: the same stop, worded to say so, and a
# `balance` result is enough even without the exit code.
stub claude-implement.sh 'printf "%s\n" "IMPLEMENTER_RESULT: balance (deepseek)" "THREAD_ID: deepseek:u5" \
  "IMPLEMENTER_STATUS: MISSING" "IMPLEMENTER_MODEL: deepseek-flash"; exit 1'
run_goal
check "balance: implementer-declined" "implementer-declined" "$reason"
check "balance: the stop names the balance" "yes" "$(has 'out of balance (DeepSeek 402)' "$detail")"

# BLOCKED with its red test left uncommitted: the blocker is the reason, not the
# dirty tree, and the status reaches the stop file.
stub claude-implement.sh 'echo red >red_test.txt
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: haiku:u1" "IMPLEMENTER_STATUS: BLOCKED" \
  "IMPLEMENTER_MODEL: claude-haiku-5-5" "RETURN_HANDOFF: /tmp/return.md"'
run_goal
check "blocked implementer: implementer-blocked" "implementer-blocked" "$reason"
check "blocked implementer: status in the stop file" "yes" \
  "$(has 'IMPLEMENTER_STATUS: BLOCKED' "$(cat "$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)")")"

# Claude Code's own sandbox creates .claude/.cc-writes in the repo an
# implementer session runs in (seen on the uregex dogfood): not configuration,
# and a new empty .claude/ configures nothing. Neither wakes the goal.
# Claude Code also adds `**/.claude/.cc-writes/` to the user's global git
# ignore. This run gets a global config of its own carrying that line (and an
# identity for the stub's commit), so the dirty-tree gate behaves the same on
# a machine without it.
printf '**/.claude/.cc-writes/\n' >"$TMP/global-ignore"
printf '[core]\n\texcludesFile = %s\n[user]\n\tname = t\n\temail = t@example.invalid\n' \
  "$TMP/global-ignore" >"$TMP/global-gitconfig"
stub claude-implement.sh "$COMMIT"'
mkdir -p .claude/.cc-writes .claude/empty && touch .claude/.cc-writes/w
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: haiku:u1" "IMPLEMENTER_STATUS: DONE"'
GIT_CONFIG_GLOBAL="$TMP/global-gitconfig" run_goal
check "harness .cc-writes and empty dirs: not tamper" "reviewer-error" "$reason"
# The scanner on its own, no git involved: nothing listed for the harness
# directory or empty directories; a file in .claude/ and a link are.
scan="$TMP/scan" && rm -rf "$scan" && mkdir -p "$scan/.claude/.cc-writes" "$scan/.claude/empty/deeper"
touch "$scan/.claude/.cc-writes/w"
check "scanner: harness dir and empty dirs list nothing" "" "$(cd "$scan" && python3 "$HOUSE/scripts/lib/claude-meta.py")"
echo '{}' >"$scan/.claude/empty/deeper/settings.json" && ln -s /tmp "$scan/.claude/linked"
check "scanner: a nested file and a dir link are listed" "2" \
  "$(cd "$scan" && python3 "$HOUSE/scripts/lib/claude-meta.py" | grep -c -E $'^\\.claude/(empty/deeper/settings\\.json\tfile|linked\tlink)\t')"

# A pass that plants Claude Code configuration (a hook in settings.local.json,
# which Claude Code keeps out of git) stops before anything else reads it.
stub claude-implement.sh "$COMMIT"'
mkdir -p .claude && echo "{\"hooks\":{}}" >.claude/settings.local.json
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: haiku:u1" "IMPLEMENTER_STATUS: DONE"'
run_goal
check "planted .claude config: claude-config-tamper" "claude-config-tamper" "$reason"
check "planted .claude config: names the file" "yes" "$(has '.claude/settings.local.json' "$detail")"
check "planted .claude config: only the file, no blank entry" "yes" \
  "$(has 'implementer r0: .claude/settings.local.json —' "$detail")"
check "planted .claude config: thread kept" "haiku:u1" "$thread"

# Each pass journals who implemented it, a fallback included, and what it cost.
stub claude-implement.sh "$COMMIT"'
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: deepseek:u2" "IMPLEMENTER_STATUS: DONE" \
  "IMPLEMENTER_MODEL: deepseek-v4-flash" "IMPLEMENTER_FALLBACK: haiku -> deepseek (refusal)" \
  "IMPLEMENTER_COST_USD: 0.25"'
run_goal
journal="$(cat "$TMP/repo/docs/journal/example.md")"
check "implemented record: model, fallback and cost journaled" "yes" \
  "$(has 'ORCHESTRATOR implemented g1-store r0 STATUS=DONE MODEL=deepseek-v4-flash FALLBACK=(haiku -> deepseek (refusal)) COST_USD=0.25' "$journal")"
check "implemented record: still reaches review" "reviewer-error" "$reason"
check "implemented record: no basis or FROM when the launcher prints none" "0" \
  "$(grep 'COST_USD=0.25' <<<"$journal" | grep -c -E 'COST_BASIS=| FROM=' || true)"

# The cost basis, and a fallback's primary pass with its own thread and cost
# (docs/features/deepseek-primary step 7), reach the journal line.
stub claude-implement.sh "$COMMIT"'
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: haiku:u3" "IMPLEMENTER_STATUS: DONE" \
  "IMPLEMENTER_MODEL: claude-haiku-5-5" "IMPLEMENTER_FALLBACK: deepseek -> haiku (balance)" \
  "IMPLEMENTER_FALLBACK_FROM: deepseek:u9 COST_USD=0.0042 COST_BASIS=thread" \
  "IMPLEMENTER_COST_USD: 0.31" "IMPLEMENTER_COST_BASIS: thread"'
run_goal
journal="$(cat "$TMP/repo/docs/journal/example.md")"
check "implemented record: basis and the primary's thread and cost" "yes" \
  "$(has 'MODEL=claude-haiku-5-5 FALLBACK=(deepseek -> haiku (balance)) COST_USD=0.31 COST_BASIS=thread FROM=deepseek:u9 FROM_COST_USD=0.0042 FROM_COST_BASIS=thread' "$journal")"

# AWAKE_PROBE: which ancestor (run-goals.sh or run-goal.sh) holds a
# `caffeinate -i -w <its pid>` while this stub runs (FUTURE-WORK item 23).
AWAKE_PROBE='p=$$; found=none; for _ in 1 2 3 4 5 6 7 8; do p="$(ps -o ppid= -p "$p" | tr -d " ")"; [[ -n "$p" && "$p" != 1 && "$p" != "$AWAKE_TOP" ]] || break; if pgrep -f "^/usr/bin/caffeinate -i -w $p\$" >/dev/null; then found="$(ps -o command= -p "$p" | grep -oE "run-goals?\.sh" | head -n1)"; break; fi; done; echo "$found" >>"$AWAKE_OUT"'
# The walk stops at this test: run-all.sh above it holds an assertion too.
export AWAKE_OUT="$TMP/awake" AWAKE_TOP=$$
rm -f "$AWAKE_OUT"
stub claude-implement.sh "$AWAKE_PROBE"'
printf "%s\n" "IMPLEMENTER_RESULT: error (exit 1)"; exit 1'
run_goal
check "a lone run-goal.sh keeps the host awake while the implementer runs" "run-goal.sh" "$(cat "$AWAKE_OUT" 2>/dev/null)"

# Resume holds .claude/ to the baseline the stopped run took: a file planted
# while the goal was paused is refused before any dispatch.
"$HOUSE/scripts/goals.py" GOALS.md show g1-store | grep -q '"in_progress"' && paused=yes || paused=no
check "baseline: the goal is paused in_progress" "yes" "$paused"
mkdir -p .claude && echo '{"hooks":{}}' >.claude/settings.json
stub claude-implement.sh 'echo dispatched >>"$TMP_MARK"; printf "%s\n" "IMPLEMENTER_RESULT: ok"'
export TMP_MARK="$TMP/dispatched"
rm -f "$TMP_MARK"
"$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 && rc=0 || rc=$?
stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)"
check "baseline: resume refused" "gate" "$(sed -n 's/^- reason: //p' "$stop" 2>/dev/null)"
check "baseline: names the planted file" "yes" "$(has '.claude/settings.json' "$(sed -n 's/^- detail: //p' "$stop")")"
check "baseline: nothing dispatched" "no" "$([[ -f "$TMP_MARK" ]] && echo yes || echo no)"

# The legacy Codex launcher still runs under IMPLEMENTER=codex.
stub deepseek-code.sh "$COMMIT"'
printf "%s\n" "DEEPSEEK_RESULT: ok" "THREAD_ID: t1"'
IMPLEMENTER=codex run_goal
check "IMPLEMENTER=codex: legacy result line reaches review" "reviewer-error" "$reason"

if [[ "$fails" -eq 0 ]]; then
  echo "result-parse: OK"
else
  echo "result-parse: $fails FAILURE(S)" >&2
  exit 1
fi
