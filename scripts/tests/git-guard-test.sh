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
# No background auto-maintenance: a detached repack still writing .git/objects
# races the next scenario's rm -rf of the repo.
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
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
  fails=0  # counted here, added to the parent's total below
  # shellcheck disable=SC1091
  source "$HERE/lib/git-guard.sh"
  mkdir -p "$TMP/lib" && cd "$TMP/lib" && command git init -q
  git_meta_init
  S="$TMP/lib-saved.txt"

  git_meta_verify "$S"
  git_meta_verify "$S" && r=0 || r=1
  check "unchanged gitdir verifies" "0" "$r"

  echo x >a && git add a && git commit -qm legit
  git_meta_verify "$S" && r=0 || r=1
  check "an ordinary commit is not tampering" "0" "$r"

  # Background auto-maintenance repacks after commits and rewrites
  # info/refs (a generated ref list for dumb HTTP; nothing executes it).
  command git repack -q -d
  printf 'deadbeef\trefs/heads/x\n' >>.git/info/refs
  git_meta_verify "$S" && r=0 || r=1
  check "git-generated info/refs is not tampering" "0" "$r"

  plant_hook .git
  git_meta_verify "$S" && r=0 || r=1
  check "planted hook detected" "1" "$r"
  check "changed path named" "yes" \
    "$([[ "$GIT_META_CHANGED" == *hooks/pre-commit* ]] && echo yes || echo no)"
  check "taint set" "1" "$GIT_META_TAINTED"
  git status >/dev/null 2>&1 && r=0 || r=1
  check "tainted git refuses to run" "1" "$r"
  check "hook never fired" "0" "$(fired)"

  GIT_META_TAINTED=0 && rm -f "$S" && git_meta_verify "$S"
  chmod -x .git/hooks/pre-commit
  git_meta_verify "$S" && r=0 || r=1
  check "mode change detected" "1" "$r"

  GIT_META_TAINTED=0 && rm -f "$S" && git_meta_verify "$S"
  echo 'secret/' >>.git/info/exclude
  git_meta_verify "$S" && r=0 || r=1
  check "info/exclude change detected" "1" "$r"

  GIT_META_TAINTED=0 && rm -f "$S" && git_meta_verify "$S"
  plant_fsmonitor
  git_meta_verify "$S" && r=0 || r=1
  check "config change detected" "1" "$r"

  # Wrapper alone, taint off: armed hook + fsmonitor stay inert.
  GIT_META_TAINTED=0
  chmod +x .git/hooks/pre-commit
  echo y >b && git add b && git status --porcelain >/dev/null && git commit -qm t
  check "wrapper runs no hook or fsmonitor" "0" "$(fired)"
  echo "$fails" >"$TMP/lib-fails"
) || echo 1 >"$TMP/lib-fails"
# The subshell's own count; a crash before the end counts as one failure.
fails=$((fails + $(cat "$TMP/lib-fails" 2>/dev/null || echo 1)))
rm -f "$MARK"

(
  fails=0  # counted here, added to the parent's total below
  # shellcheck disable=SC1091
  source "$HERE/lib/git-guard.sh"
  mkdir -p "$TMP/wt-main" && cd "$TMP/wt-main" && command git init -q
  git commit -q --allow-empty -m root
  git worktree add -q "$TMP/wt-linked"
  cd "$TMP/wt-linked"
  git_meta_init
  check "linked worktree tracks both gitdirs" "2" "${#GIT_META_DIRS[@]}"
  S="$TMP/wt-saved.txt"
  git_meta_verify "$S"
  plant_hook "$TMP/wt-main/.git"
  git_meta_verify "$S" && r=0 || r=1
  check "hook in common gitdir detected" "1" "$r"
  echo "$fails" >"$TMP/wt-fails"
) || echo 1 >"$TMP/wt-fails"
fails=$((fails + $(cat "$TMP/wt-fails" 2>/dev/null || echo 1)))

# --- special and unreadable files (F2-05) --------------------------------
# A FIFO in hooks/ once blocked the read forever, outside every step timeout.
# Each case runs under a timeout and must fail closed: verify returns 1,
# taints, and host git refuses. rc 124 = hung; 0 = passed as unchanged.
special() {
  local name="$1" setup="$2" repo="$TMP/special" rc=0
  chmod -R u+rwx "$repo" 2>/dev/null || true
  rm -rf "$repo" "$TMP/special-saved.txt"
  mkdir -p "$repo" && (cd "$repo" && command git init -q)
  python3 "$HERE/lib/run-timeout.py" 10 bash -c '
    cd "$1" && source "$2/lib/git-guard.sh" && git_meta_init || exit 9
    git_meta_verify "$3" || exit 8
    eval "$4"
    git_meta_verify "$3" && exit 0
    git status >/dev/null 2>&1 && exit 7
    exit 1' _ "$repo" "$HERE" "$TMP/special-saved.txt" "$setup" \
    >"$TMP/special.out" 2>&1 || rc=$?
  check "$name: fails closed promptly" "1" "$rc"
}
special "FIFO in hooks" 'mkfifo .git/hooks/review-fifo'
special "socket in hooks" 'python3 -c "import os, socket; os.chdir(\".git/hooks\"); socket.socket(socket.AF_UNIX).bind(\"s\")"'
special "unreadable hook" 'echo x >.git/hooks/locked && chmod 000 .git/hooks/locked'
special "unreadable hooks dir" 'mkdir .git/hooks/d && chmod 000 .git/hooks/d'
chmod -R u+rwx "$TMP/special" 2>/dev/null || true

# A file removed between listing and reading is a failure, not a traceback.
check "removed mid-walk: fails closed" "failed" "$(python3 - "$HERE/lib/git-meta.py" "$TMP/special/.git" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("gm", sys.argv[1])
gm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gm)
real = os.lstat
def vanished(p, *a, **k):
    if p.endswith("pre-commit.sample"):
        raise FileNotFoundError(2, "No such file or directory")
    return real(p, *a, **k)
os.lstat = vanished
_, problems = gm.manifest([sys.argv[2]])
print("failed" if any("pre-commit.sample" in x for x in problems) else "passed")
PY
)"

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
# Stubs print the full result block, as the real launchers do.
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
