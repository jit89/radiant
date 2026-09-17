#!/usr/bin/env bash
# Self-test: on resume, a contract changed since BASE_SHA — committed, staged,
# unstaged, or untracked — is refused before anything is dispatched (F-13).
# Run 1 is a stub implementer that tampers and then dies before assess, which
# is how such a change survives to a resume. Launchers are stubs.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
GOALS_PY="$HERE/goals.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-resume-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" EVENTS_CACHE="$TMP/cache" STUBS="$TMP/stubs"
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

HOUSE="$TMP/house"
mkdir -p "$HOUSE/scripts"
cp -R "$HERE/." "$HOUSE/scripts/"
cat >"$HOUSE/scripts/claude-goal-review.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "CLAUDE_REVIEW_RESULT: error (exit 1)" "SESSION_ID: s1" \
  "VERDICT: MISSING" "VERDICT_FILE: /dev/null"
exit 1
SH
chmod +x "$HOUSE/scripts/claude-goal-review.sh"

# The implementer stub runs $TAMPER (if set) on its first call, commits some
# work, then crashes. Every later call just succeeds. Each call is counted.
cat >"$HOUSE/scripts/deepseek-code.sh" <<'SH'
#!/usr/bin/env bash
echo call >>"$STUBS"
echo "$RANDOM" >>impl.txt && git add impl.txt && git commit -qm "wip(g1-store): impl"
if [[ "$(wc -l <"$STUBS")" -eq 1 ]]; then
  eval "${TAMPER:-}"
  echo "DEEPSEEK_RESULT: error (exit 1)"
  exit 1
fi
printf '%s\n' "DEEPSEEK_RESULT: ok" "THREAD_ID: t1"
SH
chmod +x "$HOUSE/scripts/deepseek-code.sh"

# scenario <tamper run inside implementer run 1> <tamper run between runs>
# Sets reason1, reason, detail, calls.
scenario() {
  rm -rf "$TMP/repo" "$STUBS"
  mkdir -p "$TMP/repo/docs/journal" "$TMP/repo/tests/acceptance" && cd "$TMP/repo"
  git init -q
  sed -e '/id: g1-store/,/status:/{
s|proof: true|proof: bash tests/acceptance/g1-store.sh|
s|oracle: inline|oracle: tests/acceptance/g1-store.sh|
}' "$HERE/../GOALS.example.md" >GOALS.md
  printf 'test "$(head -c1 impl.txt)" != ""\n' >tests/acceptance/g1-store.sh
  printf 'true\n' >tests/acceptance/g2-ack.sh
  printf '# Journal: example\n' >docs/journal/example.md
  git add -A && git commit -q -m base

  TAMPER="$1" "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out1" 2>&1 || true
  reason1="$(stop_field reason "$TMP/out1")"
  eval "$2"
  "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 || true
  reason="$(stop_field reason "$TMP/out")"
  detail="$(stop_field detail "$TMP/out")"
  calls="$(cat "$STUBS" 2>/dev/null | wc -l | tr -d ' ')"
}
stop_field() {
  local stop
  stop="$(sed -n 's/^STOP_FILE: //p' "$2" | tail -n1)"
  sed -n "s/^- $1: //p" "$stop" 2>/dev/null || true
}
has() { [[ "$detail" == *"$1"* ]] && echo yes || echo "no: $detail"; }
WEAKEN='printf "true\n" >tests/acceptance/g1-store.sh'

# Control: crash with no contract change resumes and dispatches again.
scenario '' ''
check "run 1 crashed before assess" "implementer-error" "$reason1"
check "clean resume dispatches" "2" "$calls"
check "clean resume reaches review" "reviewer-error" "$reason"

scenario "$WEAKEN; git add tests/acceptance/g1-store.sh" ''
check "staged oracle edit: gate" "gate" "$reason"
check "staged oracle edit: nothing dispatched" "1" "$calls"
check "staged edit listed as uncommitted" "yes" "$(has '; uncommitted: tests/acceptance/g1-store.sh')"

scenario "$WEAKEN; git add tests/acceptance/g1-store.sh; git commit -qm 'wip: tidy test'" ''
check "committed oracle edit: gate" "gate" "$reason"
check "committed oracle edit: nothing dispatched" "1" "$calls"
check "committed edit listed as committed" "yes" "$(has '— committed: tests/acceptance/g1-store.sh')"
check "gate offers bounce" "yes" "$(has "set g1-store bounced")"
check "names the commit that edited the oracle" "yes" \
  "$(has "$(git log --format=%h -1 --grep='wip: tidy test')")"

scenario "$WEAKEN" ''
check "unstaged oracle edit: gate" "gate" "$reason"
check "unstaged oracle edit: nothing dispatched" "1" "$calls"

scenario '' 'printf "true\n# edited\n" >tests/acceptance/g2-ack.sh; git add -A; git commit -qm "architect: fix g2 test"'
check "another acceptance file committed between runs: gate" "gate" "$reason"
check "names that file" "yes" "$(has 'tests/acceptance/g2-ack.sh')"

scenario 'printf "true\n" >tests/acceptance/g1-store-extra.sh' ''
check "untracked acceptance file: gate" "gate" "$reason"
check "names the untracked file" "yes" "$(has 'tests/acceptance/g1-store-extra.sh')"

scenario '' "sed -i.bak 's/retries/everything/' GOALS.md && rm GOALS.md.bak && git commit -qam 'edit goals'"
check "GOALS.md body committed between runs: gate" "gate" "$reason"
check "names GOALS.md" "yes" "$(has 'GOALS.md')"
check "GOALS.md drift: nothing dispatched" "1" "$calls"

if [[ "$fails" -eq 0 ]]; then
  echo "resume-contract: OK"
else
  echo "resume-contract: $fails FAILURE(S)" >&2
  exit 1
fi
