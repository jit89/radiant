#!/usr/bin/env bash
# Self-test: Orchestrator commits are narrow. A path the user staged before
# the walk must never ride along in a GOALS.md / journal commit (F-11).
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
  printf '# Journal: example\n' >docs/journal/example.md
  printf 'original\n' >source.py
  git add -- GOALS.md docs/journal/example.md source.py
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
stub deepseek-code.sh 'exit 1'
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

if [[ "$fails" -eq 0 ]]; then
  echo "orch-commit: OK"
else
  echo "orch-commit: $fails FAILURE(S)" >&2
  exit 1
fi
