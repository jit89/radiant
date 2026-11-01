#!/usr/bin/env bash
# Self-test: a parallel walk will not take a goal a serial run is mid-way
# through (FUTURE-WORK item 31): an uncommitted in_progress, or in the goal's
# host ledger in the main checkout a run-goal.sh record of any kind (overrides
# included) after the walker's last mark, stops the walk
# `serial-goal-in-progress` before any goal runs. The committed-code case
# is in parallel-walk-trust4-test.sh. Launchers are stubs; no model is called.
set -euo pipefail
# Mutation checks off here (docs/features/mutation-checks; mutation-test.sh turns them on).
export CW_MUTATIONS=0
PW_NAME=pwserial
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/parallel-walk-lib.sh"

stopped() { grep -q "^- reason: $1\$" "$pstop" 2>/dev/null && echo yes || echo "no: $(sed -n 's/^- reason: //p' "$pstop" 2>/dev/null)"; }
names() { grep -q -- "$1" "$pstop" 2>/dev/null && echo yes || echo no; }
ledger_of() { printf '%s\n' "$HOME/.cache/claude-coding-workflow/run-goal-$1/host-records-$(printf '%s' "$(git rev-parse --absolute-git-dir)" | shasum | cut -c1-12)"; }
calls_now() { wc -l <"$CALLS/implement" | tr -d ' '; }
hand_back() {
  "$GOALS_PY" GOALS.md set "$1" ready >/dev/null
  git diff --quiet -- GOALS.md || git commit -qm "architect: hand $1 back" -- GOALS.md
}

echo "serial goals under a parallel walk"

# A serial stop that committed nothing leaves g2-b's in_progress uncommitted:
# the walk stops serial-goal-in-progress (not the dirty-file refusal, whose
# "restore" would start g2-b over), and a serial rerun finishes the walk.
pwalk_repo
printf 'printf "%%s\\n" "IMPLEMENTER_RESULT: error (exit 1)"; exit 1\n' >"$CALLS/action-g2-b"
prun
rm -f "$CALLS/action-g2-b"
check "serial stop: g2-b in_progress, uncommitted" "in_progress yes" \
  "$(status_of g2-b) $([[ -n "$(git status --porcelain -- GOALS.md)" ]] && echo yes || echo no)"
before="$(calls_now)"
prun --jobs 3
check "--jobs: stops serial-goal-in-progress, nothing dispatched" "yes $before" "$(stopped serial-goal-in-progress) $(calls_now)"
check "  ...with the serial way out, no branch to remove" "yes no" \
  "$(names 'without --jobs resumes it from its own base') $(names 'git branch -D')"
# The same uncommitted in_progress with no ledger at all (another HOME, a moved
# repo): still refused, on the uncommitted status alone.
mv "$(ledger_of g2-b)" "$TMP/ledger-aside"
prun --jobs 3
mv "$TMP/ledger-aside" "$(ledger_of g2-b)"
check "  ...and with no ledger, on the uncommitted in_progress alone" "yes yes" \
  "$(stopped serial-goal-in-progress) $(names 'in_progress uncommitted in GOALS.md')"
prun
check "serial rerun: every goal done" "0 done done done done" \
  "$prc $(for g in g1-a g2-b g3-c g4-d; do status_of "$g"; done | paste -sd ' ' -)"

# A goal a parallel walk bounced keeps its cw/ branch and worktree; handed back
# and run serially, its pass commits code and stops. The guard reads the
# ledger, not the branch or the journal: the walk stops, and the stop says to
# remove the kept branch and worktree first (the serial walker will not run a
# goal that has them). Following it, a serial rerun finishes the walk.
pwalk_repo
echo BLOCKED >"$CALLS/verdict-g2-b"
prun --jobs 3
check "bounced path: g2-b bounced, its branch kept" "bounced yes" \
  "$(status_of g2-b) $(git show-ref --verify --quiet refs/heads/cw/g2-b && echo yes || echo no)"
rm -f "$CALLS/verdict-g2-b"
hand_back g2-b
printf 'echo g2-b >b.txt; git add b.txt; git commit -qm "feat(g2-b): b, half done"; printf "%%s\\n" "IMPLEMENTER_RESULT: error (exit 1)"; exit 1\n' >"$CALLS/action-g2-b"
prun
rm -f "$CALLS/action-g2-b"
check "bounced path: the serial run stopped at g2-b with b.txt committed" "in_progress yes" \
  "$(status_of g2-b) $(log="$(git log --format=%s)"; [[ "$log" == *"feat(g2-b): b, half done"* ]] && echo yes || echo no)"
prun --jobs 3
check "bounced path: the walk stops serial-goal-in-progress" yes "$(stopped serial-goal-in-progress)"
check "  ...saying to remove the kept worktree and branch first" yes "$(names 'git branch -D cw/g2-b')"
git worktree remove -f -f "$(wt_of g2-b)"
git branch -q -D cw/g2-b
prun
check "  ...which done, a serial rerun finishes the walk" "0 done done" "$prc $(status_of g2-b) $(status_of g4-d)"

# A goal the walker took (its mark in the ledger) and that then stopped inside
# the parallel walk is the walker's: the next --jobs run recuts it, though a
# serial run had dispatched it before. A serial record after the mark, any
# round (a serial resume dispatches rK), or a ledger that cannot be read, stops
# the walk instead.
pwalk_repo
printf 'printf "%%s\\n" "IMPLEMENTER_RESULT: error (exit 1)"; exit 1\n' >"$CALLS/action-g2-b"
prun
hand_back g2-b
prun --jobs 3
L="$(ledger_of g2-b)"
check "walker-marked: g2-b stopped inside the parallel walk, marked in the ledger" "in_progress yes" \
  "$(status_of g2-b) $( (( $(grep -c '— ORCHESTRATOR walker wave g2-b$' "$L" || true) >= 1 )) && echo yes || echo no)"
rm -f "$CALLS/action-g2-b"
printf '## 2026-10-26T00:00:00Z — ORCHESTRATOR dispatch g2-b r1 BASE_SHA=x THREAD_ID=- SESSION_ID=-\n' >>"$L"
prun --jobs 3
check "  ...a serial r1 record after the mark: the walk stops" yes "$(stopped serial-goal-in-progress)"
sed -i '' '$d' "$L"
printf '## 2026-10-26T00:00:01Z — ORCHESTRATOR overrides g2-b dotenv=allowed\n' >>"$L"
prun --jobs 3
check "  ...a serial record with no round (overrides) after the mark: the walk stops" yes "$(stopped serial-goal-in-progress)"
sed -i '' '$d' "$L"
chmod 000 "$L"
prun --jobs 3
chmod 600 "$L"
check "  ...a ledger it cannot read: the walk stops, never advising to delete the branch" "yes yes no" \
  "$(stopped serial-goal-in-progress) $(names 'cannot be read') $(names 'git branch -D')"
prun --jobs 3
check "  ...the mark last: recut, and the walk finishes" "0 done done" "$prc $(status_of g2-b) $(status_of g4-d)"

echo
if [[ "$fails" -eq 0 ]]; then
  echo "parallel-walk-serial-test: all passed"
else
  echo "parallel-walk-serial-test: $fails failed"
  exit 1
fi
