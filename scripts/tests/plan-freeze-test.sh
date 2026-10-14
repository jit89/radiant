#!/usr/bin/env bash
# Self-test: the signed plan is contract (F2-02). Both agents read a copy frozen
# at BASE_SHA, and an implementer edit to the live plan — committed or not, at
# the default or a configured plan: path — stops the goal before review.
# Launchers are stubs; nothing calls a model.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-plan-XXXXXX")"
export TMPDIR="$TMP"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" EVENTS_CACHE="$TMP/cache" OUTSIDE="$TMP/outside"
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
export DEEPSEEK_API_KEY=stub-deepseek-key
unset ANTHROPIC_API_KEY MAX_FIX_ROUNDS
mkdir -p "$HOME" "$OUTSIDE"
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

HOUSE="$TMP/house"
mkdir -p "$HOUSE/scripts"
cp -R "$HERE/." "$HOUSE/scripts/"
# Implementer: save the plan its handoff names, run $OUTSIDE/act, commit work.
cat >"$HOUSE/scripts/claude-implement.sh" <<'SH'
#!/usr/bin/env bash
hand="${!#}"
plan="$(sed -n 's/^- PLAN (signed, frozen at BASE_SHA): `\([^`]*\)`.*/\1/p' "$hand")"
cp "$plan" "$OUTSIDE/impl-plan" 2>/dev/null || echo "(no plan: $plan)" >"$OUTSIDE/impl-plan"
bash "$OUTSIDE/act"
echo impl >impl.txt && git add impl.txt && git commit -qm "wip(g1-store): impl"
printf '%s\n' "IMPLEMENTER_RESULT: ok" "THREAD_ID: t1"
SH
# Reviewer: save the plan its brief names, then fail (the run stops there).
cat >"$HOUSE/scripts/claude-goal-review.sh" <<'SH'
#!/usr/bin/env bash
brief="${!#}"
plan="$(sed -n 's/^PLAN: //p' "$brief")"
echo "$plan" >"$OUTSIDE/review-plan-path"
cp "$plan" "$OUTSIDE/review-plan" 2>/dev/null || true
printf '%s\n' "CLAUDE_REVIEW_RESULT: error (exit 1)" "SESSION_ID: s1" "VERDICT: MISSING" "VERDICT_FILE: /dev/null"
exit 1
SH
chmod +x "$HOUSE/scripts/"*.sh

# run PLANPATH 'implementer action' [commit-plan=1]
run() {
  local plan="$1"
  rm -rf "$TMP/repo" "$OUTSIDE"/*
  printf '%s\n' "$2" >"$OUTSIDE/act"
  mkdir -p "$TMP/repo/docs/journal" && cd "$TMP/repo"
  git init -q
  sed "s|^plan: PLAN.md|plan: $plan|" "$HERE/../GOALS.example.md" >GOALS.md
  mkdir -p "$(dirname "$plan")"
  printf 'ORIGINAL PLAN\n' >"$plan"
  printf '# Journal: example\n' >docs/journal/example.md
  git add GOALS.md docs/journal/example.md
  [[ "${3:-1}" == 0 ]] || git add "$plan"
  git commit -q -m base
  "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 || true
  stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)"
  reason="$(sed -n 's/^- reason: //p' "$stop" 2>/dev/null || true)"
  frozen="$(dirname "$stop")/implementer/plan-at-base-$(basename "$plan")"
}
content() { cat "$1" 2>/dev/null || echo "(missing)"; }
reviewed() { [[ -f "$OUTSIDE/review-plan-path" ]] && echo yes || echo no; }

# 1. Honest implementer: both agents get the frozen copy, not the live path.
run PLAN.md 'true'
check "honest: reaches review" "reviewer-error" "$reason"
check "honest: implementer reads the signed plan" "ORIGINAL PLAN" "$(content "$OUTSIDE/impl-plan")"
check "honest: reviewer reads the signed plan" "ORIGINAL PLAN" "$(content "$OUTSIDE/review-plan")"
check "honest: reviewer's PLAN is the frozen copy" "$frozen" "$(content "$OUTSIDE/review-plan-path")"

# 2. Implementer commits a plan edit.
run PLAN.md 'echo "EDITED PLAN" >PLAN.md && git commit -qam "plan tweak"'
check "committed edit: contract tamper" "contract-tamper-committed" "$reason"
check "committed edit: no review" "no" "$(reviewed)"
check "committed edit: frozen copy keeps the signed text" "ORIGINAL PLAN" "$(content "$frozen")"

# 3. Non-default plan: path, committed edit.
run docs/spec/plan.md 'echo "EDITED" >docs/spec/plan.md && git commit -qam "plan tweak"'
check "custom path, committed: contract tamper" "contract-tamper-committed" "$reason"
check "custom path, committed: no review" "no" "$(reviewed)"
check "custom path: frozen copy keeps the signed text" "ORIGINAL PLAN" "$(content "$frozen")"

# 4. Non-default plan: path, uncommitted edit: stopped and restored.
run docs/spec/plan.md 'echo "EDITED" >docs/spec/plan.md'
check "custom path, uncommitted: contract tamper" "contract-tamper-worktree" "$reason"
check "custom path, uncommitted: no review" "no" "$(reviewed)"
check "custom path, uncommitted: live plan restored" "ORIGINAL PLAN" "$(content docs/spec/plan.md)"

# 5. A plan that was never committed: refused at the gate, nothing dispatched.
run PLAN.md 'true' 0
check "uncommitted plan: gate" "gate" "$reason"
check "uncommitted plan: nothing dispatched" "absent" \
  "$([[ -f "$OUTSIDE/impl-plan" ]] && echo present || echo absent)"

if [[ "$fails" -eq 0 ]]; then
  echo "plan-freeze: OK"
else
  echo "plan-freeze: $fails FAILURE(S)" >&2
  exit 1
fi
