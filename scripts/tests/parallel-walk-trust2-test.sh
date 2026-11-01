#!/usr/bin/env bash
# Self-test: the parallel walker (docs/features/parallel-walker/PLAN.md).
# Launchers are stubs; no model is called.
# Section 7 part 2: worktree_setup failures and
# timeouts, scratch-tree setup, integration-dirty, stray locks, a vanished worktree.
# The trust checks are split in four files (parallel-walk-trust*-test.sh), so
# run-all runs them side by side; each scenario starts from a fresh repo.
set -euo pipefail
# Mutation checks off here (docs/features/mutation-checks; mutation-test.sh turns them on).
export CW_MUTATIONS=0
PW_NAME=pwtrust2
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/parallel-walk-lib.sh"

# --- 7. trust checks and the rest of PLAN step 11 (continued) ---------------
echo "7. trust checks, part 2: setup and integration"
# The second of three members fails setup; the other two run; the rerun recuts
# it (its worktree, junk and all, is replaced).
pwalk_repo
noconflict
sed -i '' 's|^journal: docs/journal/p.md$|journal: docs/journal/p.md\nworktree_setup: test ! -e "$CALLS/fail-$(basename "$PWD")"|' GOALS.md
git commit -qam "setup key"
touch "$CALLS/fail-g2-b"
prun --jobs 3
check "second of three fails setup: it stops" worktree-setup-failed "$(reason_in g2-b)"
check "second of three fails setup: the others integrated" "done done" "$(status_of g1-a) $(status_of g3-c)"
echo junk >"$(wt_of g2-b)/junk.txt"
echo keep >untracked-in-main.txt
rm -f "$CALLS/fail-g2-b"
prun --jobs 3
check "after a setup failure: the rerun integrates nothing while the main checkout is dirty" integration-dirty "$(reason_in g2-b)"
check "the main checkout's own file untouched" keep "$(cat untracked-in-main.txt 2>/dev/null)"
check "integration-dirty: the stop says not to move HEAD" yes \
  "$(grep -q 'Do not move HEAD' "$(stopfile_of g2-b)" && echo yes || echo no)"
rm -f untracked-in-main.txt
prun --jobs 3
check "after cleaning the main checkout: the walk completes" 0 "$prc"
[[ "$prc" -eq 0 ]] || tail -20 "$TMP/pout" | sed 's/^/    | /'
check "the recut goal's old worktree junk is gone" no "$(ls "$WTROOT"/*/g2-b/junk.txt >/dev/null 2>&1 && echo yes || echo no)"

# Setup timeout.
pwalk_repo
sed -i '' 's|^journal: docs/journal/p.md$|journal: docs/journal/p.md\nworktree_setup: if test -e "$CALLS/slow-$(basename "$PWD")"; then sleep 8; fi|' GOALS.md
git commit -qam "setup key"
touch "$CALLS/slow-g2-b"
PROOF_TIMEOUT=2 prun --jobs 3
check "setup timeout: worktree-setup-failed" worktree-setup-failed "$(reason_in g2-b)"

# Setup in the scratch tree after a merge: failing, then dirty. The walk
# branch never moves.
pwalk_repo
sed -i '' 's|^journal: docs/journal/p.md$|journal: docs/journal/p.md\nworktree_setup: case "$PWD" in */.integrate/*) test ! -e "$CALLS/fail-int" \&\& { test ! -e "$CALLS/dirty-int" \|\| touch dirt.txt; } ;; esac|' GOALS.md
git commit -qam "setup key"
touch "$CALLS/fail-int"
prun --jobs 3
check "scratch setup fails: worktree-setup-failed" worktree-setup-failed "$(reason_in g1-a)"
check "scratch setup fails: nothing merged" "" "$(git log --merges --format=%s | grep 'g1-a' || true)"
check "scratch setup fails: main tree clean" "" "$(git status --porcelain)"
rm -f "$CALLS/fail-int"
touch "$CALLS/dirty-int"
prun --jobs 3
check "scratch setup dirty: worktree-setup-dirty" worktree-setup-dirty "$(reason_in g1-a)"
check "scratch setup dirty: nothing merged" "" "$(git log --merges --format=%s | grep 'g1-a' || true)"
rm -f "$CALLS/dirty-int"
before="$(impl_calls)"
prun --jobs 3
check "after setup is fixed: the walk completes" 0 "$prc"
check "after setup is fixed: g1-a not dispatched again" 0 \
  "$(tail -n +$((before + 1)) "$CALLS/implement" | grep -c '^g1-a$' || true)"
check "after setup is fixed: the merged commit is the recorded one" \
  "$(grep 'ORCHESTRATOR finished g1-a head=' docs/journal/p.md | head -n1 | sed 's/.*head=//')" \
  "$(git log --merges --format='%P %s' | grep 'chore(g1-a): orchestrator integrate' | awk '{print $2}')"

# integration-dirty before the fast-forward names the restore, not a reset.
pwalk_repo
printf 'echo dirt >"$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/dirt.txt"; echo $gid >$letter.txt; git add $letter.txt; git commit -qm "feat($gid)"\n' >"$CALLS/action-g1-a"
prun --jobs 3
check "integration-dirty: stop" integration-dirty "$(reason_in g1-a)"
check "integration-dirty: the stop restores to HEAD, does not move it" yes \
  "$(grep -q 'git restore --staged --worktree' "$(stopfile_of g1-a)" && grep -q 'Do not move HEAD' "$(stopfile_of g1-a)" && echo yes || echo no)"
check "integration-dirty: nothing merged" 0 "$(git log --merges --oneline | wc -l | tr -d ' ')"
check "integration-dirty: the sibling is finished-not-integrated" finished-not-integrated "$(reason_in g2-b)"
rm -f dirt.txt "$CALLS/action-g1-a"
before="$(impl_calls)"
prun --jobs 3
check "after integration-dirty: the walk completes" 0 "$prc"
check "after integration-dirty: no new dispatch for the finished goals" 0 \
  "$(tail -n +$((before + 1)) "$CALLS/implement" | grep -c '^g[12]-[ab]$' || true)"

# A finished commit that cannot land (a stray lock): the result copies let the
# next start record and integrate both goals without dispatch.
pwalk_repo
printf ': >"$(git rev-parse --path-format=absolute --git-common-dir)/refs/heads/walk.lock"; echo $gid >$letter.txt; git add $letter.txt; git commit -qm "feat($gid)"\n' >"$CALLS/action-g1-a"
prun --jobs 3
check "walk ref lock: git-lock-stray" git-lock-stray "$(reason_in '(walk)')"
check "walk ref lock: the finished commit did not land" 0 "$(jcount 'ORCHESTRATOR finished ')"
rm -f "$(common)/refs/heads/walk.lock" "$CALLS/action-g1-a"
before="$(impl_calls)"
prun --jobs 3
check "result copies: the walk completes" 0 "$prc"
[[ "$prc" -eq 0 ]] || tail -20 "$TMP/pout" | sed 's/^/    | /'
check "result copies: g1-a and g2-b not dispatched again" 0 \
  "$(tail -n +$((before + 1)) "$CALLS/implement" | grep -c '^g[12]-[ab]$' || true)"
check "result copies: removed once integrated" 0 "$(ls "$WTROOT"/*/.results 2>/dev/null | wc -l | tr -d ' ')"

# A stopped goal whose worktree folder vanished is simply recut.
pwalk_repo
printf 'printf "%%s\\n" "IMPLEMENTER_RESULT: error (exit 1)"; exit 1\n' >"$CALLS/action-g2-b"
prun --jobs 3
rm -rf "$(wt_of g2-b)" "$CALLS/action-g2-b"
prun --jobs 3
check "missing worktree: the rerun recuts and completes" 0 "$prc"

echo
if [[ "$fails" -eq 0 ]]; then
  echo "parallel-walk-trust2-test: all passed"
else
  echo "parallel-walk-trust2-test: $fails failed"
  exit 1
fi
