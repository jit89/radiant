#!/usr/bin/env bash
# Self-test: run-goal.sh reads `git status` paths verbatim (item 16). The line
# form C-quotes a name with `"`, `\` or a control character, even with
# core.quotePath=false, and joins a rename as `old -> new`; -z does neither.
# Covers the fresh-start gate and the dirty-tree check after a pass, in serial
# mode. Launchers are stubs; nothing calls a model.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-porcelain-XXXXXX")"
export TMPDIR="$TMP"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" EVENTS_CACHE="$TMP/cache"
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
export CLAUDE_REVIEW_TIMEOUT=2
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
lacks() { [[ "$2" != *"$1"* ]] && echo yes || echo "present: $1"; }

HOUSE="$TMP/house"
mkdir -p "$HOUSE/scripts"
cp -R "$HERE/." "$HOUSE/scripts/"
stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$HOUSE/scripts/$1"
  chmod +x "$HOUSE/scripts/$1"
}
stub claude-goal-review.sh 'printf "%s\n" "CLAUDE_REVIEW_RESULT: error (exit 1)" \
  "SESSION_ID: s1" "VERDICT: MISSING" "VERDICT_FILE: /dev/null"; exit 1'
OK_RESULT='printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: haiku:u1" "IMPLEMENTER_STATUS: DONE"'
COMMIT='echo "$RANDOM" >>impl.txt && git add impl.txt && git commit -qm "wip(g1-store): impl"'

# make_repo [journal path]
make_repo() {
  local journal="${1:-docs/journal/example.md}"
  rm -rf "$TMP/repo"
  mkdir -p "$TMP/repo/docs/journal" && cd "$TMP/repo"
  git init -q
  sed "s|^journal: .*|journal: $journal|" "$HERE/../GOALS.example.md" >GOALS.md
  printf '# Plan\n' >PLAN.md
  printf '# Journal: example\n' >"$journal"
  git add -- GOALS.md PLAN.md "$journal"
  git commit -q -m base
}

# Sets reason and detail from the stop file.
run_goal() {
  "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 || true
  local stop
  stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)"
  reason="$(sed -n 's/^- reason: //p' "$stop" 2>/dev/null || true)"
  detail="$(sed -n 's/^- detail: //p' "$stop" 2>/dev/null || true)"
}

TAB=$'\t'
echo "== fresh start: awkward names and a staged rename are named verbatim"
stub claude-implement.sh "$COMMIT; $OK_RESULT"
make_repo
touch 'q"uote.txt' 'back\slash.txt' "tab${TAB}name.txt" 'sp ace.txt' 'é.txt'
git mv PLAN.md PLAN2.md
run_goal
check "gate" "gate" "$reason"
for n in 'q"uote.txt' 'back\slash.txt' "tab${TAB}name.txt" 'sp ace.txt' 'é.txt' PLAN2.md; do
  check "names $n" yes "$(has " $n" "$detail")"
done
check "the rename's source is named" yes "$(has ' PLAN.md' "${detail//PLAN2.md/}")"
check "no 'old -> new' entry" yes "$(lacks ' -> ' "$detail")"
check "no C-quoting" yes "$(lacks '\"' "$detail")"

echo "== after a pass: a journal whose name needs quoting is still the journal"
make_repo 'docs/journal/ex"ample.md'
run_goal
check "reaches review, not dirty-tree" "reviewer-error" "$reason"

echo "== after a pass: an unexpected rename names both paths"
stub claude-implement.sh "$COMMIT; git mv impl.txt 'im\"pl.txt'; $OK_RESULT"
make_repo
run_goal
check "dirty-tree" "dirty-tree" "$reason"
check "names the new path verbatim" yes "$(has 'im"pl.txt' "$detail")"
check "names the old path" yes "$(has ' impl.txt' "$detail")"
check "no 'old -> new' entry" yes "$(lacks ' -> ' "$detail")"

echo "== after a pass: a worktree rename (intent-to-add) names both paths"
stub claude-implement.sh "$COMMIT; mv impl.txt 'w\"t.txt' && git add -N 'w\"t.txt'; $OK_RESULT"
make_repo
run_goal
check "dirty-tree" "dirty-tree" "$reason"
check "names the new path verbatim" yes "$(has 'w"t.txt' "$detail")"
check "names the old path" yes "$(has ' impl.txt' "$detail")"
check "no 'old -> new' entry" yes "$(lacks ' -> ' "$detail")"

if [[ "$fails" -eq 0 ]]; then
  echo "porcelain-test: all passed"
else
  echo "porcelain-test: $fails failed" >&2
  exit 1
fi
