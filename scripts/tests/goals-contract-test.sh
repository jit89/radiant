#!/usr/bin/env bash
# Self-test: GOALS.md is frozen except the current goal's status — markdown
# bodies included (F-15). Launchers are stubs; nothing calls a model.
set -euo pipefail
# Mutation checks off here (docs/features/mutation-checks; mutation-test.sh turns them on).
export CW_MUTATIONS=0

HERE="$(cd "$(dirname "$0")/.." && pwd)"
GOALS_PY="$HERE/goals.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-contract-XXXXXX")"
export TMPDIR="$TMP"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" EVENTS_CACHE="$TMP/cache"
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
# No background auto-maintenance: a detached repack still writing .git/objects
# races the next scenario's rm -rf of the repo.
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
export DEEPSEEK_API_KEY=stub-not-a-key
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

# GOALS.example.md carries a body per goal; the seds below edit those.
BASE="$TMP/base.md"
cp "$HERE/../GOALS.example.md" "$BASE"

# Prints OK or DRIFT (first line of status-only-id output).
compare() { "$GOALS_PY" "$1" status-only-id g1-store "$BASE" 2>&1 | head -n1 || true; }
variant() { sed "$1" "$BASE" >"$TMP/v.md"; compare "$TMP/v.md"; }

# --- goals.py status-only-id ------------------------------------------------
cp "$BASE" "$TMP/same.md"
check "identical file" "OK" "$(compare "$TMP/same.md")"

cp "$BASE" "$TMP/set.md"
"$GOALS_PY" "$TMP/set.md" set g1-store in_progress >/dev/null
check "this goal's status via goals.py set" "OK" "$(compare "$TMP/set.md")"

cp "$BASE" "$TMP/other.md"
"$GOALS_PY" "$TMP/other.md" set g3-other done >/dev/null
check "another goal's status" "DRIFT" "$(compare "$TMP/other.md")"

check "fence field" "DRIFT" "$(variant 's/area: mailer\/outbound/area: x/')"
check "this goal's body" "DRIFT" "$(variant 's/| mail  | stored   |/| mail  | ignored  |/')"
check "another goal's body" "DRIFT" "$(variant 's/stored | acked/stored | nothing/')"
check "text before the fence" "DRIFT" "$(variant 's/Not a real/Not a fake/')"
check "trailing text" "DRIFT" "$(sed '$ a\
extra' "$BASE" >"$TMP/v.md"; compare "$TMP/v.md")"

sed 's/Out of scope: retries./Out of scope: everything./' "$BASE" >"$TMP/v.md"
where="$("$GOALS_PY" "$TMP/v.md" status-only-id g1-store "$BASE" 2>&1 || true)"
check "drift names the goal section" "yes" \
  "$([[ "$where" == *"## g3-other"* ]] && echo yes || echo "no: $where")"

# --- run-goal.sh ------------------------------------------------------------
HOUSE="$TMP/house"
mkdir -p "$HOUSE/scripts"
cp -R "$HERE/." "$HOUSE/scripts/"
stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$HOUSE/scripts/$1"
  chmod +x "$HOUSE/scripts/$1"
}
stub claude-goal-review.sh 'printf "%s\n" "CLAUDE_REVIEW_RESULT: error (exit 1)" \
  "SESSION_ID: s1" "VERDICT: MISSING" "VERDICT_FILE: /dev/null"; exit 1'
OK_LINES='printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: t1"'
COMMIT='echo impl >impl.txt && git add impl.txt && git commit -qm "wip(g1-store): impl"'

run_goal() {
  rm -rf "$TMP/repo"
  mkdir -p "$TMP/repo/docs/journal" && cd "$TMP/repo"
  git init -q
  cp "$BASE" GOALS.md
  printf '# Journal: example\n' >docs/journal/example.md
  printf "# Plan\n" >PLAN.md
  git add -- GOALS.md PLAN.md docs/journal/example.md
  git commit -q -m base
  if [[ -n "${1:-}" ]]; then eval "$1"; fi
  "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 || true
  local stop
  stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)"
  reason="$(sed -n 's/^- reason: //p' "$stop" 2>/dev/null || true)"
  detail="$(sed -n 's/^- detail: //p' "$stop" 2>/dev/null || true)"
}

stub claude-implement.sh "$COMMIT
$OK_LINES"
run_goal
check "honest implementer reaches review" "reviewer-error" "$reason"

# Uncommitted edit to a later goal's case table.
stub claude-implement.sh "$COMMIT
sed -i.bak 's/stored | acked/stored | nothing/' GOALS.md && rm GOALS.md.bak
$OK_LINES"
run_goal
check "later goal body, uncommitted: tamper wake" "contract-tamper-worktree" "$reason"

# Committed edit to this goal's own case table (reviewer would read it).
stub claude-implement.sh "$COMMIT
sed -i.bak 's/| mail  | stored   |/| mail  | ignored  |/' GOALS.md && rm GOALS.md.bak
git add GOALS.md && git commit -qm 'wip(g1-store): tidy'
$OK_LINES"
run_goal
check "own goal body, committed: tamper wake" "contract-tamper-committed" "$reason"
check "committed tamper names GOALS.md" "yes" \
  "$([[ "$detail" == *GOALS.md* ]] && echo yes || echo "no: $detail")"

# Fresh start with a body already edited in the worktree: refuse at the gate.
stub claude-implement.sh "$OK_LINES"
run_goal "sed -i.bak 's/retries/everything/' GOALS.md && rm GOALS.md.bak"
check "dirty body at fresh start: gate" "gate" "$reason"
check "gate names GOALS.md" "yes" \
  "$([[ "$detail" == *"GOALS.md: markdown"* ]] && echo yes || echo "no: $detail")"

# --- tool_path (docs/features/rust-toolchain-gates) ------------------------
# Its folders live in the house checkout: goals.py rejects a temp-area path,
# which the proof sandbox cannot read.
TROOT="${CW_TEST_TOOLS_ROOT:-$HERE/../.test-tools}"; mkdir -p "$TROOT" && TOOLS="$(mktemp -d "$TROOT/toolpath-XXXXXX")"
trap 'rm -rf "$TMP" "$TOOLS"' EXIT
mkdir -p "$TOOLS/bin" "$TOOLS/gitbin"
printf '#!/bin/sh\n' >"$TOOLS/gitbin/git" && chmod +x "$TOOLS/gitbin/git"
# vcheck LINE — GOALS.example.md with LINE after `journal:`; the first
# tool_path error, OK, or the parse error.
vcheck() {
  LINE="$1" awk '{ print } /^journal: docs\/journal\/example.md$/ { print ENVIRON["LINE"] }' \
    "$HERE/../GOALS.example.md" >"$TMP/tp.md"
  "$GOALS_PY" "$TMP/tp.md" validate 2>&1 | grep '^tool_path\|^OK\|unexpected\|bad list' | head -1 || true
}
has() { [[ "$1" == *"$2"* ]] && echo yes || echo "no: $1"; }
LISTMSG="tool_path: must be a non-empty one-line list, e.g. tool_path: [/abs/bin]"
check "tool_path: a real absolute dir" "OK" "$(vcheck "tool_path: [$TOOLS/bin]" | cut -c1-2)"
check "tool_path: two dirs" "OK" "$(vcheck "tool_path: [$TOOLS/bin, $TOOLS/bin]" | cut -c1-2)"
check "tool_path: relative" "tool_path: bin is not absolute" "$(vcheck 'tool_path: [bin]')"
check "tool_path: missing" "tool_path: $TOOLS/nope is not an existing directory" "$(vcheck "tool_path: [$TOOLS/nope]")"
check "tool_path: a colon" yes "$(has "$(vcheck "tool_path: [$TOOLS/bin:x]")" "outside [A-Za-z0-9._/@+-]")"
check "tool_path: empty list" "$LISTMSG" "$(vcheck 'tool_path: []')"
check "tool_path: a scalar" "$LISTMSG" "$(vcheck "tool_path: $TOOLS/bin")"
check "tool_path: holds git" yes "$(has "$(vcheck "tool_path: [$TOOLS/gitbin]")" "holds an executable git")"
mkdir -p "$TMP/inrepo" "$TMP/other-repo" "$HOME/.cache/claude-coding-workflow/runs"
check "tool_path: inside the target repo" yes "$(has "$(vcheck "tool_path: [$TMP/inrepo]")" "inside the target repo, which the implementer can write")"
# Not inside the target repo (GOALS.md moved out), so the sandbox denials decide.
vtemp() { vcheck "$1" >/dev/null; mv "$TMP/tp.md" "$TOOLS/tp.md"; "$GOALS_PY" "$TOOLS/tp.md" validate 2>&1 | grep "^tool_path" | head -1 || true; }
check "tool_path: a temp area" yes "$(has "$(vtemp "tool_path: [$TMP/other-repo]")" "which the proof sandbox cannot read")"
check "tool_path: the house cache" yes "$(has "$(vtemp "tool_path: [$HOME/.cache/claude-coding-workflow/runs]")" ".cache/claude-coding-workflow, which the proof sandbox cannot read")"
check "tool_path: a block list" yes "$([[ "$(vcheck $'tool_path:\n  - /usr/bin')" =~ (bad list|unexpected) ]] && echo yes || echo no)"
vcheck "tool_path: [$TOOLS/bin]" >/dev/null
check "tool_path: meta prints it" "[\"$TOOLS/bin\"]" "$("$GOALS_PY" "$TMP/tp.md" meta | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["tool_path"]))')"
check "tool_path: meta null when absent" "null" "$("$GOALS_PY" "$HERE/../GOALS.example.md" meta | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["tool_path"]))')"

if [[ "$fails" -eq 0 ]]; then
  echo "goals-contract: OK"
else
  echo "goals-contract: $fails FAILURE(S)" >&2
  exit 1
fi
