#!/usr/bin/env bash
# Self-test: the host proof runs implementer-controlled code, so it is bounded
# (timeout), kept away from credentials in the environment, and checked
# afterwards for changes to HEAD, tracked files, or the contract (F-02).
# Proof bodies here only sleep or write files; launchers are stubs.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-proof-XXXXXX")"
export TMPDIR="$TMP"
TMP="$(cd "$TMP" && pwd -P)"
NAP="41.$$"
cleanup() {
  pkill -f "sleep $NAP" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
export HOME="$TMP/home" EVENTS_CACHE="$TMP/cache" NAP OUTSIDE="$TMP/outside"
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
export DEEPSEEK_API_KEY=stub-deepseek-key
unset MAX_FIX_ROUNDS PROOF_TIMEOUT PROOF_ENV_KEEP
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
printf '%s\n' '#!/usr/bin/env bash' \
  'echo impl >impl.txt && git add impl.txt && git commit -qm "wip(g1-store): impl"' \
  'printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: t1"' >"$HOUSE/scripts/claude-implement.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo reached >"$OUTSIDE/reviewer"' \
  'printf "%s\n" "CLAUDE_REVIEW_RESULT: error (exit 1)" "SESSION_ID: s1" "VERDICT: MISSING" "VERDICT_FILE: /dev/null"' \
  'exit 1' >"$HOUSE/scripts/claude-goal-review.sh"
chmod +x "$HOUSE/scripts/"*.sh

# proof '<body of tests/acceptance/g1-store.sh>': file-oracle goal, one run.
proof() {
  rm -rf "$TMP/repo" "$OUTSIDE"/*
  mkdir -p "$TMP/repo/docs/journal" "$TMP/repo/tests/acceptance" && cd "$TMP/repo"
  git init -q
  sed -e '/id: g1-store/,/status:/{
s|proof: true|proof: bash tests/acceptance/g1-store.sh|
s|oracle: inline|oracle: tests/acceptance/g1-store.sh|
}' "$HERE/../GOALS.example.md" >GOALS.md
  printf '# Plan\n' >PLAN.md
  printf '%s\n' "$1" >tests/acceptance/g1-store.sh
  [[ -z "${HELPER:-}" ]] || printf '%s\n' "$HELPER" >tests/acceptance/helper.py
  printf '.gitignore\n%s' "${IGNORE:-}" >.gitignore
  printf '# Journal: example\n' >docs/journal/example.md
  git add -A && git commit -q -m base
  local t0=$SECONDS
  "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 || true
  secs=$((SECONDS - t0))
  local stop
  stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)"
  reason="$(sed -n 's/^- reason: //p' "$stop" 2>/dev/null || true)"
  detail="$(sed -n 's/^- detail: //p' "$stop" 2>/dev/null || true)"
  reviewed="$([[ -f "$OUTSIDE/reviewer" ]] && echo yes || echo no)"
}
has() { [[ "$detail" == *"$1"* ]] && echo yes || echo "no: $detail"; }

# 1. A proof that never ends (watch mode, a server, a wait on input).
PROOF_TIMEOUT=2 proof 'sleep "$NAP"'
check "hang: proof-timeout" "proof-timeout" "$reason"
check "hang: stops near the limit" "yes" "$([[ $secs -le 15 ]] && echo yes || echo "no (${secs}s)")"
check "hang: proof process killed" "0" "$(pgrep -f "sleep $NAP" | wc -l | tr -d ' ')"
check "hang: no review" "no" "$reviewed"

# 2. Credentials in the host environment are not handed to proof code.
export ANTHROPIC_API_KEY=stub-anthropic MY_SERVICE_TOKEN=stub-token \
  DB_PASSWORD=stub-pw PLAIN_SETTING=visible KEYBOARD_LAYOUT=us
PROOF_ENV_KEEP="MY_SERVICE_TOKEN" proof 'env >"$OUTSIDE/env"'
check "env: green proof reaches review" "yes" "$reviewed"
seen() { grep -q "^$1=" "$OUTSIDE/env" && echo present || echo absent; }
check "env: DEEPSEEK_API_KEY hidden" "absent" "$(seen DEEPSEEK_API_KEY)"
check "env: ANTHROPIC_API_KEY hidden" "absent" "$(seen ANTHROPIC_API_KEY)"
check "env: *_PASSWORD hidden" "absent" "$(seen DB_PASSWORD)"
check "env: PROOF_ENV_KEEP passes a named one" "present" "$(seen MY_SERVICE_TOKEN)"
check "env: ordinary variables kept" "present" "$(seen PLAIN_SETTING)"
check "env: PATH kept" "present" "$(seen PATH)"
check "env: KEY inside a word is not a credential" "present" "$(seen KEYBOARD_LAYOUT)"
check "env: git's GIT_CONFIG_KEY_n kept" "present" "$(seen GIT_CONFIG_KEY_0)"
check "env: bytecode writes off (D-09)" "yes" \
  "$(grep -qx 'PYTHONDONTWRITEBYTECODE=1' "$OUTSIDE/env" && echo yes || echo no)"
unset ANTHROPIC_API_KEY MY_SERVICE_TOKEN DB_PASSWORD PLAIN_SETTING KEYBOARD_LAYOUT

# 3. Proof code that commits.
proof 'echo x >sneak.txt && git add sneak.txt && git commit -qm sneak'
check "commit: proof-tamper" "proof-tamper" "$reason"
check "commit: says HEAD moved" "yes" "$(has 'HEAD moved')"
check "commit: no review" "no" "$reviewed"

# 4. Proof code that edits a tracked source file.
proof 'echo changed >impl.txt'
check "tracked edit: proof-tamper" "proof-tamper" "$reason"
check "tracked edit: names the file" "yes" "$(has 'impl.txt')"

# 5. Proof code that rewrites its own oracle, then passes.
proof 'printf "true\n" >tests/acceptance/g1-store.sh'
check "oracle rewrite: proof-tamper" "proof-tamper" "$reason"
check "oracle rewrite: names the oracle" "yes" "$(has 'tests/acceptance/g1-store.sh')"

# 6. New untracked file under tests/acceptance.
proof 'echo x >tests/acceptance/extra.sh'
check "acceptance addition: proof-tamper" "proof-tamper" "$reason"

# 7. Build/test output the project declares in .gitignore is fine, and leaves
#    nothing the next goal's clean-tree gate would refuse.
IGNORE=$'.cache-out/\ncoverage.txt\n' \
  proof 'mkdir -p .cache-out && echo x >.cache-out/result.xml && echo y >coverage.txt'
check "declared artifacts: not tamper" "reviewer-error" "$reason"
check "declared artifacts: review reached" "yes" "$reviewed"
check "declared artifacts: nothing untracked for the next goal" "" \
  "$(git status --porcelain --untracked-files=all | grep '^??' || true)"

# 8. The same output, undeclared: a deterministic stop, not silent acceptance.
proof 'mkdir -p .cache-out && echo x >.cache-out/result.xml && echo y >coverage.txt'
check "undeclared artifacts: proof-tamper" "proof-tamper" "$reason"
check "undeclared artifacts: names them" "yes" "$(has 'coverage.txt')"
check "undeclared artifacts: no review" "no" "$reviewed"

# 9. An untracked source file the proof writes (and could import).
proof 'printf "def helper():\n    return 1\n" >generated.py'
check "untracked source: proof-tamper" "proof-tamper" "$reason"
check "untracked source: names it" "yes" "$(has 'generated.py')"
check "untracked source: no review" "no" "$reviewed"

# 10. An untracked symlink.
proof 'ln -s /etc/hosts hosts-link'
check "untracked symlink: proof-tamper" "proof-tamper" "$reason"
check "untracked symlink: no review" "no" "$reviewed"

# 11. .gitignore makes a file an artifact — but not under tests/acceptance,
#     where an ignored file would be invisible to every check and the reviewer.
IGNORE=$'tests/acceptance/extra.sh\n' \
  proof 'printf "true\n" >tests/acceptance/extra.sh'
check "ignored acceptance addition: proof-tamper" "proof-tamper" "$reason"
check "ignored acceptance addition: names it" "yes" "$(has 'tests/acceptance/extra.sh')"
check "ignored acceptance addition: no review" "no" "$reviewed"

IGNORE=$'tests/acceptance/junk/\n' \
  proof 'mkdir -p tests/acceptance/junk && printf "x\n" >tests/acceptance/junk/x.sh'
check "ignored acceptance directory: proof-tamper" "proof-tamper" "$reason"

# 12. A Python proof that imports a module under tests/acceptance/ must not leave
#     bytecode there: an ignored .pyc under the contract is tamper (case 11), so
#     without PYTHONDONTWRITEBYTECODE every Python target would wake (D-09).
IGNORE=$'__pycache__/\n' HELPER='X = 1' \
  proof 'python3 -c "import sys; sys.path.insert(0, \"tests/acceptance\"); import helper"'
check "python proof: not tamper" "reviewer-error" "$reason"
check "python proof: no bytecode under the contract" "" \
  "$(find tests/acceptance -name '*.pyc' 2>/dev/null)"

# 13. Red proof still red.
proof 'exit 3'
check "red: proof-red" "proof-red" "$reason"

if [[ "$fails" -eq 0 ]]; then
  echo "proof: OK"
else
  echo "proof: $fails FAILURE(S)" >&2
  exit 1
fi
