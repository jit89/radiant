#!/usr/bin/env bash
# Self-test: GOALS.md is frozen except the current goal's status — markdown
# bodies included (F-15). Launchers are stubs; nothing calls a model.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
GOALS_PY="$HERE/goals.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-contract-XXXXXX")"
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
OK_LINES='printf "%s\n" "DEEPSEEK_RESULT: ok" "THREAD_ID: t1"'
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

stub deepseek-code.sh "$COMMIT
$OK_LINES"
run_goal
check "honest implementer reaches review" "reviewer-error" "$reason"

# Uncommitted edit to a later goal's case table.
stub deepseek-code.sh "$COMMIT
sed -i.bak 's/stored | acked/stored | nothing/' GOALS.md && rm GOALS.md.bak
$OK_LINES"
run_goal
check "later goal body, uncommitted: tamper wake" "contract-tamper-worktree" "$reason"

# Committed edit to this goal's own case table (reviewer would read it).
stub deepseek-code.sh "$COMMIT
sed -i.bak 's/| mail  | stored   |/| mail  | ignored  |/' GOALS.md && rm GOALS.md.bak
git add GOALS.md && git commit -qm 'wip(g1-store): tidy'
$OK_LINES"
run_goal
check "own goal body, committed: tamper wake" "contract-tamper-committed" "$reason"
check "committed tamper names GOALS.md" "yes" \
  "$([[ "$detail" == *GOALS.md* ]] && echo yes || echo "no: $detail")"

# Fresh start with a body already edited in the worktree: refuse at the gate.
stub deepseek-code.sh "$OK_LINES"
run_goal "sed -i.bak 's/retries/everything/' GOALS.md && rm GOALS.md.bak"
check "dirty body at fresh start: gate" "gate" "$reason"
check "gate names GOALS.md" "yes" \
  "$([[ "$detail" == *"GOALS.md: markdown"* ]] && echo yes || echo "no: $detail")"

if [[ "$fails" -eq 0 ]]; then
  echo "goals-contract: OK"
else
  echo "goals-contract: $fails FAILURE(S)" >&2
  exit 1
fi
