#!/usr/bin/env bash
# Self-test: Orchestrator commits are narrow. A path the user staged before
# the walk must never ride along in a GOALS.md / journal commit (F-11), and
# neither may an edit someone else left in GOALS.md or the journal (F2-04).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-orch-commit-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export EVENTS_CACHE="$TMP/cache" HOME="$TMP/home"
mkdir -p "$HOME"
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
# No background auto-maintenance: a detached repack still writing .git/objects
# races the next scenario's rm -rf of the repo.
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
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

# Repo with GOALS.md (g1 done, g2 blocked on it), a journal, and a source file
# the user has modified and staged.
make_repo() {
  local dir="$1"
  mkdir -p "$dir/docs/journal"
  cd "$dir"
  git init -q
  sed -e '/id: g1-store/,/status:/s/status: ready/status: done/' \
    "$HERE/../GOALS.example.md" >GOALS.md
  printf '# Plan\n' >PLAN.md
  printf '# Journal: example\n' >docs/journal/example.md
  printf 'original\n' >source.py
  git add -- GOALS.md PLAN.md docs/journal/example.md source.py
  git commit -q -m base
  printf 'user work\n' >source.py
  git add -- source.py
}

# source.py in any commit after base = absorbed.
absorbed() {
  git log --format= --name-only HEAD~"$(($(git rev-list --count HEAD) - 1))"..HEAD \
    | grep -c '^source.py$' || true
}

# House copy with every live launcher stubbed. If a bug lets a run past the
# gates, it must hit a stub — never a real model — and there is no .env to
# load a key from.
unset DEEPSEEK_API_KEY ANTHROPIC_API_KEY
HOUSE="$TMP/house"
mkdir -p "$HOUSE/scripts"
cp -R "$HERE/." "$HOUSE/scripts/"
stub() {
  printf '#!/usr/bin/env bash\necho "%s: stub reached" >&2\n%s\n' "$1" "$2" \
    >"$HOUSE/scripts/$1"
  chmod +x "$HOUSE/scripts/$1"
}
stub claude-implement.sh 'exit 1'
stub claude-goal-review.sh 'exit 1'
stub grok-review.sh 'exit 1'

# run-goals.sh: refresh + walk-start + walk commits. Child stops at once.
make_repo "$TMP/walk"
stub run-goal.sh 'echo "STOP_FILE: /dev/null"; exit 1'
"$HOUSE/scripts/run-goals.sh" >"$TMP/walk.out" 2>&1 || true
check "run-goals made orchestrator commits" "yes" \
  "$([[ "$(git rev-list --count HEAD)" -gt 1 ]] && echo yes || echo no)"
check "run-goals commits exclude staged user file" "0" "$(absorbed)"
check "user file still staged after walk" "source.py" \
  "$(git diff --cached --name-only)"

# run-goal.sh: blocked id → refresh → orch_commit, then the dirty gate wakes.
cp "$HERE/run-goal.sh" "$HOUSE/scripts/run-goal.sh"
make_repo "$TMP/goal"
"$HOUSE/scripts/run-goal.sh" g2-ack >"$TMP/goal.out" 2>&1 || true
subjects="$(git log --format=%s)"
check "run-goal refresh committed GOALS.md" "yes" \
  "$([[ "$subjects" == *"orchestrator refresh"* ]] && echo yes || echo no)"
check "run-goal commits exclude staged user file" "0" "$(absorbed)"
check "user file still staged after wake" "source.py" \
  "$(git diff --cached --name-only)"
check "run-goal stopped at the dirty gate" "1" \
  "$(grep -c 'GATE: working tree is not clean.*source.py' "$TMP/goal.out" || true)"
check "run-goal reached no model launcher" "0" \
  "$(grep -c 'stub reached' "$TMP/goal.out" || true)"

# --- edits to the orchestration files themselves (F2-04) ------------------
J=docs/journal/example.md
# Everything a refusal must leave as it was: commits, index, both files' bytes.
state() {
  printf '%s\n' "$(git rev-parse HEAD)" "$(git diff --cached | shasum)" \
    "$(shasum GOALS.md "$J")"
}
# refused NAME SCRIPT ARGS... — run it, expect a nonzero stop that names the
# orchestration files, no child dispatched, and state unchanged.
refused() {
  local name="$1" before out rc=0
  shift
  before="$(state)"
  rm -f "$TMP/dispatched"
  "$@" >"$TMP/refused.out" 2>&1 || rc=$?
  check "$name: stops nonzero" "yes" "$([[ $rc -ne 0 ]] && echo yes || echo no)"
  check "$name: says why" "yes" \
    "$(grep -q 'did not make' "$TMP/refused.out" "$(sed -n 's/^STOP_FILE: //p' "$TMP/refused.out" | tail -n1)" 2>/dev/null && echo yes || echo no)"
  check "$name: nothing committed, bytes and index kept" "$before" "$(state)"
  check "$name: nothing dispatched" "no" "$([[ -f "$TMP/dispatched" ]] && echo yes || echo no)"
}
stub run-goal.sh 'touch "'"$TMP"'/dispatched"; echo "STOP_FILE: /dev/null"; exit 1'
walker="$HOUSE/scripts/run-goals.sh"

make_repo "$TMP/j1" && printf '\nUSER PRIVATE NOTE\n' >>"$J"
refused "walk, unstaged journal note" "$walker"

make_repo "$TMP/j2" && printf '\nUSER PRIVATE NOTE\n' >>"$J" && git add "$J"
refused "walk, staged journal note" "$walker"

make_repo "$TMP/g1" && sed -i.bak 's/Label-ack after enqueue/Label-ack, renamed/' GOALS.md && rm GOALS.md.bak
refused "walk, GOALS title edit" "$walker"

make_repo "$TMP/g2" && sed -i.bak 's/Label-ack after enqueue/Label-ack, renamed/' GOALS.md && rm GOALS.md.bak && git add GOALS.md
refused "walk, staged GOALS edit" "$walker"

make_repo "$TMP/g3" && "$HERE/goals.py" GOALS.md set g2-ack bounced >/dev/null
refused "walk, GOALS status no step makes" "$walker"

# A stopped goal's own leftovers are not user edits: in_progress, and its
# ORCHESTRATOR lines. The walker takes them and dispatches.
make_repo "$TMP/r1" && "$HERE/goals.py" GOALS.md set g2-ack in_progress >/dev/null
printf '\n## 2026-09-17T00:00:00Z — ORCHESTRATOR wake g2-ack r0 reason=interrupted\n' >>"$J"
"$walker" >"$TMP/r1.out" 2>&1 || true
check "walk, in-flight state: goal dispatched" "yes" "$([[ -f "$TMP/dispatched" ]] && echo yes || echo no)"
check "walk, in-flight state: user file still staged" "source.py" "$(git diff --cached --name-only)"
rm -f "$TMP/dispatched"

make_repo "$TMP/r2" && "$HERE/goals.py" GOALS.md set g2-ack in_progress >/dev/null
printf '\n## 2026-09-17T00:00:00Z — ORCHESTRATOR wake g2-ack r0 reason=interrupted\n\nUSER NOTE\n' >>"$J"
refused "walk, in-flight state plus a user line" "$walker"

# Checked again after each goal, not only at the start: a goal that returns
# success with an edit left in the journal stops the walk uncommitted.
stub run-goal.sh 'printf "\\nSOMEONE ELSE\\n" >>'"$J"'; exit 0'
make_repo "$TMP/mid"
rc=0
"$walker" >"$TMP/mid.out" 2>&1 || rc=$?
check "walk, edit left during a goal: stops nonzero" "yes" "$([[ $rc -ne 0 ]] && echo yes || echo no)"
check "walk, edit left during a goal: not committed" "0" "$(git log --format= -p | grep -c 'SOMEONE ELSE' || true)"
check "walk, edit left during a goal: still in the file" "1" "$(grep -c 'SOMEONE ELSE' "$J" || true)"
stub run-goal.sh 'touch "'"$TMP"'/dispatched"; echo "STOP_FILE: /dev/null"; exit 1'

# run-goal.sh on its own: the same refusals, before its walk-start commit.
cp "$HERE/run-goal.sh" "$HOUSE/scripts/run-goal.sh"
make_repo "$TMP/rg1" && printf '\nUSER PRIVATE NOTE\n' >>"$J"
refused "goal, unstaged journal note" "$HOUSE/scripts/run-goal.sh" g3-other

make_repo "$TMP/rg2" && sed -i.bak 's/Label-ack after enqueue/Label-ack, renamed/' GOALS.md && rm GOALS.md.bak && git add GOALS.md
refused "goal, staged GOALS edit" "$HOUSE/scripts/run-goal.sh" g2-ack

make_repo "$TMP/rg3" && "$HERE/goals.py" GOALS.md set g3-other done >/dev/null
refused "goal, GOALS status no step makes" "$HOUSE/scripts/run-goal.sh" g3-other

if [[ "$fails" -eq 0 ]]; then
  echo "orch-commit: OK"
else
  echo "orch-commit: $fails FAILURE(S)" >&2
  exit 1
fi
