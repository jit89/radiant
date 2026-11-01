#!/usr/bin/env bash
# Self-test: the host proof runs implementer-controlled code, so it is bounded
# (timeout), kept away from credentials in the environment, and checked
# afterwards for changes to HEAD, tracked files, or the contract (F-02).
# Proof bodies here only sleep or write files; launchers are stubs.
set -euo pipefail
# Mutation checks off here (docs/features/mutation-checks; mutation-test.sh turns them on).
export CW_MUTATIONS=0

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
  [[ -z "${PRE:-}" ]] || eval "$PRE"
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
# The whole run, not the proof alone (gates, the sandbox self-test, commits):
# 16 s was seen under run-all -j 8. Under the 41 s nap, so still the timeout's.
check "hang: stops near the limit" "yes" "$([[ $secs -le 30 ]] && echo yes || echo "no (${secs}s)")"
check "hang: proof process killed" "0" "$(pgrep -f "sleep $NAP" | wc -l | tr -d ' ')"
check "hang: no review" "no" "$reviewed"

# 1b. A hung proof whose child ignores TERM: the whole session is killed, and
#     the sandboxed proof never uses GNU timeout (it reaches only its own
#     process group), even when one is on PATH.
mkdir -p "$TMP/fakebin"
printf '#!/bin/sh\necho "$*" >>"%s/gtimeout-called"\nshift 2; exec "$@"\n' "$TMP" >"$TMP/fakebin/gtimeout"
chmod +x "$TMP/fakebin/gtimeout"
rm -f "$TMP/gtimeout-called"
PATH="$TMP/fakebin:$PATH" PROOF_TIMEOUT=2 proof '(trap "" TERM; sleep "$NAP") & wait'
check "hang with a TERM-proof child: proof-timeout" "proof-timeout" "$reason"
check "hang with a TERM-proof child: the child is gone too" "0" "$(pgrep -f "sleep $NAP" | wc -l | tr -d ' ')"
# The stub is live (the launchers' own steps use it) but never wraps a proof.
check "gtimeout on PATH is used by the launchers' steps" yes "$([[ -s "$TMP/gtimeout-called" ]] && echo yes || echo no)"
check "the sandboxed proof never used gtimeout" 0 "$(grep -c sandbox-exec "$TMP/gtimeout-called" 2>/dev/null || true)"

# 1c. A proof that exits 0 and leaves a child behind: the child is killed.
proof 'sleep "$NAP" & exit 0'
check "a child left after exit 0 is gone" "0" "$(pgrep -f "sleep $NAP" | wc -l | tr -d ' ')"

# 2. Credentials in the host environment are not handed to proof code.
export SSH_AUTH_SOCK=/nonexistent/agent ANTHROPIC_API_KEY=stub-anthropic MY_SERVICE_TOKEN=stub-token \
  DB_PASSWORD=stub-pw PLAIN_SETTING=visible KEYBOARD_LAYOUT=us CW_SOME_WALK_SETTING=1
# The proof sandbox lets a proof write only its checkout and TMPDIR, so the
# environment goes to an ignored file in the repo.
IGNORE=$'env.out\n' PROOF_ENV_KEEP="MY_SERVICE_TOKEN CW_KEPT_SETTING" CW_KEPT_SETTING=1 proof 'env >env.out'
check "env: green proof reaches review" "yes" "$reviewed"
seen() { grep -q "^$1=" "$TMP/repo/env.out" && echo present || echo absent; }
check "env: DEEPSEEK_API_KEY hidden" "absent" "$(seen DEEPSEEK_API_KEY)"
check "env: ANTHROPIC_API_KEY hidden" "absent" "$(seen ANTHROPIC_API_KEY)"
check "env: *_PASSWORD hidden" "absent" "$(seen DB_PASSWORD)"
check "env: PROOF_ENV_KEEP passes a named one" "present" "$(seen MY_SERVICE_TOKEN)"
check "env: ordinary variables kept" "present" "$(seen PLAIN_SETTING)"
check "env: PATH kept" "present" "$(seen PATH)"
check "env: KEY inside a word is not a credential" "present" "$(seen KEYBOARD_LAYOUT)"
check "env: git's GIT_CONFIG_KEY_n kept" "present" "$(seen GIT_CONFIG_KEY_0)"
# The one CW_ line left is CW_KEPT_SETTING, named in PROOF_ENV_KEEP.
check "env: CW_* settings hidden, as from the implementer" "absent 1" \
  "$(seen CW_SOME_WALK_SETTING) $(grep -c '^CW_' "$TMP/repo/env.out")"
check "env: PROOF_ENV_KEEP passes a named CW_* one" present "$(seen CW_KEPT_SETTING)"
check "env: bytecode writes off (D-09)" "yes" \
  "$(grep -qx 'PYTHONDONTWRITEBYTECODE=1' "$TMP/repo/env.out" && echo yes || echo no)"
check "env: no ssh agent socket (proof sandbox)" "absent" "$(seen SSH_AUTH_SOCK)"
check "env: no global git config (proof sandbox)" "yes" \
  "$(grep -qx 'GIT_CONFIG_GLOBAL=/dev/null' "$TMP/repo/env.out" && echo yes || echo no)"
unset SSH_AUTH_SOCK ANTHROPIC_API_KEY MY_SERVICE_TOKEN DB_PASSWORD PLAIN_SETTING KEYBOARD_LAYOUT

# 2b. A hard link left in the checkout (an ignored folder) to a file outside
#     it: the proof sandbox checks paths, not files, so the goal stops before
#     the proof runs (docs/features/proof-sandbox step 3).
IGNORE=$'build/\n' PRE='echo outside-secret >"$OUTSIDE/secret.txt" && mkdir -p build && ln "$OUTSIDE/secret.txt" build/leak' proof 'cat build/leak >ran.txt'
check "hard link: proof-hardlink" "proof-hardlink" "$reason"
check "hard link: the proof never ran" "no" "$([[ -f "$TMP/repo/ran.txt" ]] && echo yes || echo no)"
check "hard link: no review" "no" "$reviewed"

# 2c. A hard link to an outside unix socket, left in the checkout: a proof
#     may use sockets in its TMPDIR, so linked sockets are checked too.
IGNORE=$'build/\n' PRE='/usr/bin/python3 -c "import socket,time,os; s=socket.socket(socket.AF_UNIX); os.chdir(\"$OUTSIDE\"); s.bind(\"o.sock\"); s.listen(1); time.sleep(60)" & sleep 1; mkdir -p build && ln "$OUTSIDE/o.sock" build/s.sock' \
  proof 'true'
check "socket link: proof-hardlink" "proof-hardlink" "$reason"
pkill -f 'o.sock' 2>/dev/null || true

# 3. Proof code that commits. The proof sandbox refuses writes to .git, so the
#    commit fails; the file it made is still caught as tampering.
proof 'echo x >sneak.txt && git add sneak.txt && git commit -qm sneak'
check "commit: proof-tamper" "proof-tamper" "$reason"
check "commit: the commit never happened" "no" "$(has 'HEAD moved' | cut -c1-3 | sed 's/yes/yes/;s/no:/no/')"
check "commit: the new file is reported" "yes" "$(has 'sneak.txt')"
check "commit: no review" "no" "$reviewed"

# 3b. The same with the sandbox off (the user's opt-out): the tamper rule
#     itself still catches a commit, and the override is journaled.
CW_PROOF_SANDBOX=off proof 'echo x >sneak.txt && git add sneak.txt && git commit -qm sneak'
check "sandbox off, commit: proof-tamper" "proof-tamper" "$reason"
check "sandbox off, commit: says HEAD moved" "yes" "$(has 'HEAD moved')"
check "sandbox off: the override is journaled" yes \
  "$(git -C "$TMP/repo" log -p --all -- docs/journal/example.md 2>/dev/null | grep -q 'proof-sandbox=off' || grep -q 'proof-sandbox=off' "$TMP/repo/docs/journal/example.md"; [[ $? -eq 0 ]] && echo yes || echo no)"

# 3c. A proof the sandbox refuses: red, and its output ends with the denials
#     the kernel logged (diagnosis only). run-all.sh turns the listing off.
CW_PROOF_DENIALS=on proof 'touch "$HOME/escape-attempt"; exit 1'
pf="$(ls -t "$HOME/.cache/claude-coding-workflow/runs"/run-goal-g1-store-*/proof-g1-store-r0.txt 2>/dev/null | head -n1)"
check "denied proof: the denial listing is appended" yes \
  "$(grep -q -- '--- proof sandbox denials' "$pf" 2>/dev/null && echo yes || echo no)"
check "denied proof: it names the denied path" yes \
  "$(sed -n '/--- proof sandbox denials/,$p' "$pf" 2>/dev/null | grep -q 'escape-attempt' && echo yes || echo no)"
check "denied proof: the escape never happened" no "$([[ -e "$HOME/escape-attempt" ]] && echo yes || echo no)"
CW_PROOF_DENIALS=off proof 'touch "$HOME/escape-attempt"; exit 1'
pf="$(ls -t "$HOME/.cache/claude-coding-workflow/runs"/run-goal-g1-store-*/proof-g1-store-r0.txt 2>/dev/null | head -n1)"
check "CW_PROOF_DENIALS=off: no denial listing" no \
  "$(grep -q -- '--- proof sandbox denials' "$pf" 2>/dev/null && echo yes || echo no)"
check "CW_PROOF_DENIALS=off: still red, as proof-red" proof-red "$reason"

# 3d. Only a --jobs member skips the self-test (the walker ran it): a lone run
#     ignores CW_PROOF_SANDBOX_CHECKED and still refuses a broken sandbox.
mv "$HOUSE/scripts/lib/proof-sandbox.py" "$HOUSE/scripts/lib/proof-sandbox.py.away"
CW_PROOF_SANDBOX_CHECKED=1 proof 'exit 0'
mv "$HOUSE/scripts/lib/proof-sandbox.py.away" "$HOUSE/scripts/lib/proof-sandbox.py"
check "a lone run ignores CW_PROOF_SANDBOX_CHECKED: the self-test still stops it" yes "$(has 'proof-sandbox-unavailable')"

# 3e. A proof that edits Claude Code's config the snapshot cannot see (an
#     existing ignored file): stopped as that, during the proof (item 26).
IGNORE='.claude/' PRE='mkdir -p .claude && echo "{}" >.claude/settings.local.json' \
  proof 'echo "{\"hooks\":1}" >.claude/settings.local.json'
check "proof edits ignored .claude config: claude-config-tamper" "claude-config-tamper" "$reason"
check "  ...named during the proof" yes "$(has 'during proof r0')"

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

# 13. A red proof is a proof fix round (docs/features/proof-fix): the fix is
#     dispatched; this stub changes nothing on it, so the round then stops as
#     proof-red (no progress). With no repair budget the first red stops.
proof 'exit 3'
check "red: a proof fix is issued" "yes" \
  "$(grep -q 'ORCHESTRATOR fix g1-store r0 count=1 .*source=proof' docs/journal/example.md && echo yes || echo no)"
check "red: the fix round is dispatched" "yes" \
  "$(grep -q 'ORCHESTRATOR dispatch g1-store r1 ' docs/journal/example.md && echo yes || echo no)"
check "red: no change, so proof-red" "proof-red" "$reason"
check "red: names the no-progress rule" "yes" "$(has 'no change since the red proof at r0')"
check "red: no review" "no" "$reviewed"
MAX_FIX_ROUNDS=0 proof 'exit 3'
check "red, no budget: max-fix-rounds" "max-fix-rounds" "$reason"
check "red, no budget: after a red proof" "yes" "$(has 'after a red proof')"

if [[ "$fails" -eq 0 ]]; then
  echo "proof: OK"
else
  echo "proof: $fails FAILURE(S)" >&2
  exit 1
fi
