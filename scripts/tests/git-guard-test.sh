#!/usr/bin/env bash
# Self-test for lib/git-guard.sh and its use in run-goal.sh (F-01).
# The implementer can write .git; nothing it plants there may run on the host.
# Every "payload" here only appends to a marker file. Launchers are stubs.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-git-guard-XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" EVENTS_CACHE="$TMP/cache"
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
unset ANTHROPIC_API_KEY
mkdir -p "$HOME"
MARK="$TMP/fired"
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

fired() { [[ -f "$MARK" ]] && wc -l <"$MARK" | tr -d ' ' || echo 0; }

# Payload writers — run with the real git, as the implementer would.
plant_hook() {
  printf '#!/bin/sh\necho hook >>%s\n' "$MARK" >"$1/hooks/pre-commit"
  chmod +x "$1/hooks/pre-commit"
}
plant_fsmonitor() {
  printf '#!/bin/sh\necho fsmonitor >>%s\nexit 1\n' "$MARK" >"$TMP/fsm.sh"
  chmod +x "$TMP/fsm.sh"
  command git config core.fsmonitor "$TMP/fsm.sh"
}

# --- lib -------------------------------------------------------------------
(
  # shellcheck disable=SC1091
  source "$HERE/lib/git-guard.sh"
  mkdir -p "$TMP/lib" && cd "$TMP/lib" && command git init -q
  git_meta_init
  S="$TMP/lib-saved.txt"

  git_meta_verify "$S" "$TMP/m0.txt"
  git_meta_verify "$S" "$TMP/m1.txt" && r=0 || r=1
  check "unchanged gitdir verifies" "0" "$r"

  echo x >a && git add a && git commit -qm legit
  git_meta_verify "$S" "$TMP/m2.txt" && r=0 || r=1
  check "an ordinary commit is not tampering" "0" "$r"

  plant_hook .git
  git_meta_verify "$S" "$TMP/m3.txt" && r=0 || r=1
  check "planted hook detected" "1" "$r"
  check "changed path named" "yes" \
    "$([[ "$GIT_META_CHANGED" == *hooks/pre-commit* ]] && echo yes || echo no)"
  check "taint set" "1" "$GIT_META_TAINTED"
  git status >/dev/null 2>&1 && r=0 || r=1
  check "tainted git refuses to run" "1" "$r"
  check "hook never fired" "0" "$(fired)"

  GIT_META_TAINTED=0 && rm -f "$S" && git_meta_verify "$S" "$TMP/m4.txt"
  chmod -x .git/hooks/pre-commit
  git_meta_verify "$S" "$TMP/m5.txt" && r=0 || r=1
  check "mode change detected" "1" "$r"

  GIT_META_TAINTED=0 && rm -f "$S" && git_meta_verify "$S" "$TMP/m6.txt"
  echo 'secret/' >>.git/info/exclude
  git_meta_verify "$S" "$TMP/m7.txt" && r=0 || r=1
  check "info/exclude change detected" "1" "$r"

  GIT_META_TAINTED=0 && rm -f "$S" && git_meta_verify "$S" "$TMP/m8.txt"
  plant_fsmonitor
  git_meta_verify "$S" "$TMP/m9.txt" && r=0 || r=1
  check "config change detected" "1" "$r"

  # Wrapper alone, taint off: armed hook + fsmonitor stay inert.
  GIT_META_TAINTED=0
  chmod +x .git/hooks/pre-commit
  echo y >b && git add b && git status --porcelain >/dev/null && git commit -qm t
  check "wrapper runs no hook or fsmonitor" "0" "$(fired)"
  echo 0 >"$TMP/lib-fails"
) || echo 1 >"$TMP/lib-fails"
[[ "$(cat "$TMP/lib-fails" 2>/dev/null)" == 0 ]] || fails=$((fails + 1))
rm -f "$MARK"

(
  # shellcheck disable=SC1091
  source "$HERE/lib/git-guard.sh"
  mkdir -p "$TMP/wt-main" && cd "$TMP/wt-main" && command git init -q
  git commit -q --allow-empty -m root
  git worktree add -q "$TMP/wt-linked"
  cd "$TMP/wt-linked"
  git_meta_init
  check "linked worktree tracks both gitdirs" "2" "${#GIT_META_DIRS[@]}"
  S="$TMP/wt-saved.txt"
  git_meta_verify "$S" "$TMP/w0.txt"
  plant_hook "$TMP/wt-main/.git"
  git_meta_verify "$S" "$TMP/w1.txt" && r=0 || r=1
  check "hook in common gitdir detected" "1" "$r"
  echo 0 >"$TMP/wt-fails"
) || echo 1 >"$TMP/wt-fails"
[[ "$(cat "$TMP/wt-fails" 2>/dev/null)" == 0 ]] || fails=$((fails + 1))

# --- run-goal.sh -----------------------------------------------------------
HOUSE="$TMP/house"
mkdir -p "$HOUSE/scripts"
cp -R "$HERE/." "$HOUSE/scripts/"
export DEEPSEEK_API_KEY=stub-not-a-key

stub() {
  printf '#!/usr/bin/env bash\necho "%s reached" >>%s\n%s\n' \
    "$1" "$TMP/stubs" "$2" >"$HOUSE/scripts/$1"
  chmod +x "$HOUSE/scripts/$1"
}
# Stubs print every result field: a missing one trips kv under pipefail.
stub claude-goal-review.sh 'printf "%s\n" "CLAUDE_REVIEW_RESULT: error" \
  "SESSION_ID: s1" "VERDICT: MISSING" "VERDICT_FILE: /dev/null"; exit 1'
DS_OK="printf '%s\\n' 'DEEPSEEK_RESULT: ok' 'THREAD_ID: t1' 'RETURN_HANDOFF: -' \
  'LOG: -' 'stderr: -'"

make_repo() {
  rm -rf "$TMP/repo" "$TMP/stubs" "$MARK"
  mkdir -p "$TMP/repo/docs/journal" && cd "$TMP/repo"
  command git init -q
  cp "$HERE/../GOALS.example.md" GOALS.md
  printf '# Journal: example\n' >docs/journal/example.md
  git add -- GOALS.md docs/journal/example.md
  command git commit -q -m base
}

run_goal() {
  "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 && rc=0 || rc=$?
  reason="$(sed -n 's/^- reason: //p' \
    "$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)" 2>/dev/null || true)"
}

# Implementer commits work, then plants a hook and an fsmonitor (last, so the
# marker counts only host-side firings), reports ok.
stub deepseek-code.sh "
echo impl >impl.txt && command git add impl.txt
command git commit -qm 'wip(g1-store): impl'
printf '#!/bin/sh\necho hook >>$MARK\n' >.git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
printf '#!/bin/sh\necho fsmonitor >>$MARK\nexit 1\n' >$TMP/fsm.sh
chmod +x $TMP/fsm.sh
command git config core.fsmonitor $TMP/fsm.sh
$DS_OK"
make_repo
run_goal
check "tampering implementer wakes" "git-metadata-tamper" "$reason"
check "tamper wake exits nonzero" "yes" "$([[ $rc -ne 0 ]] && echo yes || echo no)"
check "no planted program ran on the host" "0" "$(fired)"
check "reviewer not reached after tamper" "0" \
  "$(grep -c claude-goal-review "$TMP/stubs" || true)"
check "wake journaled (uncommitted)" "1" \
  "$(grep -c 'wake g1-store r0 reason=git-metadata-tamper' docs/journal/example.md || true)"

# Resume with the tampered .git still in place: refuse before any dispatch.
: >"$TMP/stubs"
run_goal
check "resume on tampered gitdir wakes" "git-metadata-tamper" "$reason"
check "resume dispatched nothing" "0" "$(grep -c reached "$TMP/stubs" || true)"
check "still no planted program ran" "0" "$(fired)"

# Honest implementer: commits only. Must reach review (no false positive).
stub deepseek-code.sh "
echo impl >impl.txt && command git add impl.txt
command git commit -qm 'wip(g1-store): impl'
$DS_OK"
make_repo
run_goal
check "honest implementer is not flagged" "reviewer-error" "$reason"
check "reviewer reached" "1" "$(grep -c claude-goal-review "$TMP/stubs" || true)"

if [[ "$fails" -eq 0 ]]; then
  echo "git-guard: OK"
else
  echo "git-guard: $fails FAILURE(S)" >&2
  exit 1
fi
