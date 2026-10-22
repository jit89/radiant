#!/usr/bin/env bash
# Self-test: the parallel walker (docs/features/parallel-walker/PLAN.md).
# Launchers are stubs; no model is called.
# The rest of Amendment 5 and after: Ctrl-C in wave
# 2, pinning, a non-ASCII journal path, a linked main checkout, the pane, and
# --jobs 1 equivalence with the walker before item 6.
# The trust checks are split in four files (parallel-walk-trust*-test.sh), so
# run-all runs them side by side; each scenario starts from a fresh repo.
set -euo pipefail
PW_NAME=pwtrust4
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/parallel-walk-lib.sh"

echo "7. trust checks, part 4: pinning and equivalence"
# Ctrl-C in wave 2: a goal that already exited there is kept, not recut.
pwalk_repo
echo 30 >"$CALLS/sleep-g4-d"
touch "$TMP/started"
sleep 1
"$HOUSE/scripts/run-goals.sh" --jobs 3 >"$TMP/pout" 2>&1 &
wpid=$!
for _ in $(seq 600); do
  [[ -z "$(wave_result_after "$TMP/started" g3-c)" ]] || break
  sleep 0.25
done
sleep 2
kill -TERM "$wpid"
wait "$wpid" && prc=0 || prc=$?
pstop="$(sed -n 's/^STOP_FILE: //p' <<<"$(tail -n1 "$TMP/pout")")"
check "Ctrl-C in wave 2: g3-c listed finished-not-integrated" finished-not-integrated "$(reason_in g3-c)"
check "Ctrl-C in wave 2: g4-d listed interrupted" interrupted "$(reason_in g4-d)"
rm -f "$CALLS/sleep-g4-d"
before="$(grep -c '^g3-c$' "$CALLS/implement" || true)"
prun --jobs 3
check "Ctrl-C in wave 2: the rerun completes" 0 "$prc"
check "Ctrl-C in wave 2: g3-c not dispatched again" "$before" "$(grep -c '^g3-c$' "$CALLS/implement" || true)"

# Pinning (Amendment 5): after the cut, something rewrites g1-a's commondir to
# a fake common dir whose config defines a filter driver. Host git, pinned to
# the recorded dirs, never reads it, so the filter never runs. (g1-a's stub
# makes no change of its own, so no git of the stub's touches the fake dir.)
pwalk_repo
FAKE="$TMP/fakecommon"
rm -rf "$FAKE" "$CALLS/pwned"
git init -q --bare "$FAKE"
git -C "$FAKE" config filter.pw.clean "touch '$CALLS/pwned'; cat"
git -C "$FAKE" config filter.pw.smudge cat
mkdir -p "$FAKE/info" && printf '* filter=pw\n' >"$FAKE/info/attributes"
sed -i '' 's|^journal: docs/journal/p.md$|journal: docs/journal/p.md\nworktree_setup: case "$PWD" in */g1-a) printf "%s\\n" "'"$FAKE"'" >"$(git rev-parse --absolute-git-dir)/commondir"; touch -t 202001010000 PLAN.md ;; esac|' GOALS.md
git commit -qam "setup key"
printf ':\n' >"$CALLS/action-g1-a"
prun --jobs 3
# The touched PLAN.md makes any status re-hash it, so an unpinned host git
# would have to run the fake dir's clean filter (not left to racy timing).
check "rewritten commondir: the filter in the fake common dir never ran" no "$([[ -e "$CALLS/pwned" ]] && echo yes || echo no)"
check "rewritten commondir: g1-a stopped (it made no change)" yes "$([[ -n "$(reason_in g1-a)" ]] && echo yes || echo no)"
check "rewritten commondir: g2-b still integrated" done "$(status_of g2-b)"
# The same setup under the proof sandbox: the write to the admin folder (in
# the common gitdir, outside the worktree) is refused, so setup fails first.
pwalk_repo
rm -rf "$CALLS/pwned"
sed -i '' 's|^journal: docs/journal/p.md$|journal: docs/journal/p.md\nworktree_setup: case "$PWD" in */g1-a) printf "%s\\n" "'"$FAKE"'" >"$(git rev-parse --absolute-git-dir)/commondir" ;; esac|' GOALS.md
git commit -qam "setup key"
CW_PROOF_SANDBOX= prun --jobs 3
check "rewritten commondir under the sandbox: g1-a's setup fails" worktree-setup-failed "$(reason_in g1-a)"
check "rewritten commondir under the sandbox: the filter never ran" no "$([[ -e "$CALLS/pwned" ]] && echo yes || echo no)"

# A non-ASCII journal path: git quotes such names unless told not to.
pwalk_repo
git mv docs/journal/p.md "docs/journal/é.md"
sed -i '' 's|^journal: docs/journal/p.md$|journal: docs/journal/é.md|' GOALS.md
git commit -qam "non-ASCII journal"
prun --jobs 3
check "non-ASCII journal path: the walk completes" 0 "$prc"
[[ "$prc" -eq 0 ]] || tail -20 "$TMP/pout" | sed 's/^/    | /'
check "non-ASCII journal path: every goal done" "done done done done" "$(for g in g1-a g2-b g3-c g4-d; do status_of "$g"; done | paste -sd ' ' -)"

# Deny paths when the main checkout is itself a linked worktree.
pwalk_repo
git worktree add -q -b walk2 "$TMP/linked" HEAD
( cd "$TMP/linked" && "$HOUSE/scripts/run-goals.sh" --jobs 3 >"$TMP/pout" 2>&1 ) || true
check "linked main checkout: HEAD denied under worktrees/linked" yes \
  "$([[ "$(cat "$CALLS/args-g1-a")" == *"/.git/worktrees/linked/HEAD "* ]] && echo yes || echo no)"
check "linked main checkout: its branch denied" yes \
  "$([[ "$(cat "$CALLS/args-g1-a")" == *"/.git/refs/heads/walk2 "* ]] && echo yes || echo no)"
check "the other member's admin folder denied, as git named it" yes \
  "$([[ "$(cat "$CALLS/args-g1-a")" == *"/.git/worktrees/g2-b "* ]] && echo yes || echo no)"
git worktree remove --force "$TMP/linked"

# Three goals live at once read as running in the pane.
check "three live goals" 3 "$(python3 - "$HERE/events.py" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("events", sys.argv[1])
ev = importlib.util.module_from_spec(spec); spec.loader.exec_module(ev)
me = os.getpid()
rows = [{"event": "walk", "goal_id": g, "payload": {"pid": me}} for g in ("g1-a", "g2-b", "g3-c")]
rows += [{"event": "dispatch", "goal_id": g, "payload": {"pid": me}} for g in ("g1-a", "g2-b", "g3-c")]
print(len(ev.live_goals(rows)))
PY
)"

# --jobs 1 makes the same commits and journal records as the walker before the
# parallel walker (pinned: 547d770, item 6's plan amendment, the last commit
# before its build; HEAD would compare the new walker with itself).
PRE_ITEM6=547d770
if ! git -C "$HERE/.." cat-file -e "$PRE_ITEM6^{commit}" 2>/dev/null; then
  # A copy of scripts/ outside the house repo, or a shallow clone.
  check "--jobs 1 equivalence: the pinned walker $PRE_ITEM6 is in the house repo" yes no
else
  OLD="$TMP/oldhouse"
  rm -rf "$OLD" && mkdir -p "$OLD"
  git -C "$HERE/.." archive "$PRE_ITEM6" scripts | tar -x -C "$OLD"
  cp "$HOUSE/scripts/claude-implement.sh" "$HOUSE/scripts/claude-goal-review.sh" "$OLD/scripts/"
  norm() {
    git log --reverse --format=%s
    sed -E 's/^## [0-9TZ:-]+ — /## T — /; s/(BASE_SHA|walk_id|merge)=[0-9a-f-]+/\1=X/g' docs/journal/p.md
  }
  pwalk_repo
  "$OLD/scripts/run-goals.sh" >"$TMP/pout-old" 2>&1 && orc=0 || orc=$?
  old_done="$(for g in g1-a g2-b g3-c g4-d; do status_of "$g"; done | paste -sd ' ' -)"
  norm >"$TMP/norm-old"
  pwalk_repo
  # Sandbox on: the old walker had none, and these proofs need nothing outside
  # the checkout, so the records must match it exactly.
  CW_PROOF_SANDBOX= "$HOUSE/scripts/run-goals.sh" >"$TMP/pout-new" 2>&1 && nrc=0 || nrc=$?
  new_done="$(for g in g1-a g2-b g3-c g4-d; do status_of "$g"; done | paste -sd ' ' -)"
  norm >"$TMP/norm-new"
  check "--jobs 1: both walks succeed and finish every goal" "0 0 done done done done done done done done" \
    "$orc $nrc $old_done $new_done"
  check "--jobs 1: same commits and journal records as the walker at 547d770" "" "$(diff "$TMP/norm-old" "$TMP/norm-new")"
fi

echo
if [[ "$fails" -eq 0 ]]; then
  echo "parallel-walk-trust4-test: all passed"
else
  echo "parallel-walk-trust4-test: $fails failed"
  exit 1
fi
