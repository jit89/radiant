#!/usr/bin/env bash
# Self-test: mutation checks on the implementer's code after a DONE review
# (docs/features/mutation-checks/PLAN.md). The reviewer is a stub that writes
# mutation blocks; each runs on a clone of the checkout under the proof
# sandbox and is scored by the host's own rule. Nothing calls a model.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-mutation-XXXXXX")"
export TMPDIR="$TMP"
TMP="$(cd "$TMP" && pwd -P)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export HOME="$TMP/home" EVENTS_CACHE="$TMP/cache" CALLS="$TMP/calls"
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
export DEEPSEEK_API_KEY=stub-deepseek-key
unset MAX_FIX_ROUNDS PROOF_TIMEOUT CW_MUTATIONS CW_MUTATION_GAPS
mkdir -p "$HOME" "$CALLS"
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

# --- the grammar (lib/mutations.py) -----------------------------------------
G="$TMP/grammar"
mkdir -p "$G"
printf 'src/a.sh\nsrc/run.sh\ndocs/journal/j.md\nGOALS.md\ntests/acceptance/t.sh\nREADME.md\n' >"$G/allowed"
printf 'tests/acceptance/\nGOALS.md\ndocs/journal/j.md\n' >"$G/contract"
gram() {  # gram <diff body> -> "accepted" or the skip reason
  { printf 'MUTATION: a rule\n```diff\n'; printf '%s\n' "$1"; printf '```\n'; } >"$G/reply"
  rm -rf "$G/out"
  python3 "$HERE/lib/mutations.py" "$G/reply" 3 "$G/allowed" "$G/contract" "$G/out" | head -n1 |
    awk -F'\t' '{ print ($2 == "accepted") ? "accepted" : $3 }'
}
EDIT='--- a/src/a.sh
+++ b/src/a.sh
@@ -1,1 +1,1 @@
-x
+y'
check "grammar: a plain edit" accepted "$(gram "$EDIT")"
check "grammar: git diff's own header, 100644" accepted "$(gram "diff --git a/src/a.sh b/src/a.sh
index 1234567..89abcde 100644
$EDIT")"
check "grammar: an executable, 100755" accepted "$(gram "diff --git a/src/run.sh b/src/run.sh
index 1234567..89abcde 100755
--- a/src/run.sh
+++ b/src/run.sh
@@ -1,1 +1,1 @@
-x
+y")"
check "grammar: a symlink mode refused" "mode 120000 (not a regular file)" "$(gram "diff --git a/src/a.sh b/src/a.sh
index 1234567..89abcde 120000
$EDIT")"
check "grammar: a rename refused" yes "$(has rename "$(gram 'diff --git a/src/a.sh b/src/b.sh
rename from src/a.sh
rename to src/b.sh')")"
check "grammar: a mode line refused" yes "$(has "not a plain file edit" "$(gram "diff --git a/src/a.sh b/src/a.sh
old mode 100644
new mode 100755")")"
check "grammar: .. refused" yes "$(has "an unsafe path" "$(gram '--- a/src/../x
+++ b/src/../x
@@ -1,1 +1,1 @@
-x
+y')")"
for ws in ' ' $'\t'; do
  check "grammar: whitespace in a path refused ($(printf %q "$ws"))" yes "$(has "an unsafe path" "$(gram "--- a/src/a${ws}b.sh
+++ b/src/a${ws}b.sh
@@ -1,1 +1,1 @@
-x
+y")")"
done
check "grammar: an absolute path refused" yes "$(has "not a plain file edit" "$(gram '--- /etc/hosts
+++ /etc/hosts')")"
check "grammar: --- and +++ differ" yes "$(has "different paths" "$(gram '--- a/src/a.sh
+++ b/src/run.sh
@@ -1,1 +1,1 @@
-x
+y')")"
check "grammar: a file the implementer did not change" yes "$(has "not a file the implementer changed" "$(gram '--- a/src/other.sh
+++ b/src/other.sh
@@ -1,1 +1,1 @@
-x
+y')")"
for p in docs/journal/j.md GOALS.md tests/acceptance/t.sh; do
  check "grammar: a contract path refused ($p)" yes "$(has "a contract path" "$(gram "--- a/$p
+++ b/$p
@@ -1,1 +1,1 @@
-x
+y")")"
done
check "grammar: a Markdown hunk whose lines hold fences" accepted "$(gram '--- a/README.md
+++ b/README.md
@@ -1,3 +1,3 @@
 ```
-old
+new
 ```')"
check "  ...the whole hunk kept, not cut at its first fence" yes "$(grep -q '^+new$' "$G/out/1.diff" 2>/dev/null && echo yes || echo no)"
check "grammar: no closed fence" "no closed \`\`\`diff fence" \
  "$(printf 'MUTATION: r\n```diff\n%s\n' "$EDIT" >"$G/reply"; python3 "$HERE/lib/mutations.py" "$G/reply" 3 "$G/allowed" "$G/contract" "$G/out" | cut -f3)"
check "grammar: at most N blocks read" 2 \
  "$({ for i in 1 2 3; do printf 'MUTATION: r%s\n```diff\n%s\n```\n' "$i" "$EDIT"; done; } >"$G/reply"
     python3 "$HERE/lib/mutations.py" "$G/reply" 2 "$G/allowed" "$G/contract" "$G/out" | wc -l | tr -d ' ')"

# --- the launcher's --mutations mode (claude-goal-review.sh) ----------------
L="$TMP/launcher"
mkdir -p "$L"
cat >"$L/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$(dirname "$0")/args"
python3 -c 'import json; print(json.dumps({"type":"result","subtype":"success","is_error":False,"session_id":"s-1","result":"MUTATION: r\n```diff\n--- a/f\n+++ b/f\n@@ -1,1 +1,1 @@\n-\tx\n+\ty\n```\nVERDICT: FIX"}))'
SH
chmod +x "$L/claude"
printf 'GOAL: g1\n' >"$L/brief.md"
lout="$(cd "$L" && CW_OUT_DIR="$L" CLAUDE_REAL_BIN="$L/claude" "$HERE/claude-goal-review.sh" --mutations 3 --resume s-1 "$L/brief.md" 2>&1 || true)"
mf="$(sed -n 's/^MUTATIONS_FILE: //p' <<<"$lout")"
check "launcher: --mutations prints MUTATIONS_FILE, no verdict" "yes no" \
  "$([[ -s "$mf" ]] && echo yes || echo no) $(grep -q '^VERDICT:' <<<"$lout" && echo yes || echo no)"
check "launcher: the reply kept whole, tabs and all" yes "$(grep -q "$(printf '^-\tx$')" "$mf" 2>/dev/null && echo yes || echo no)"
check "launcher: it resumes the session" yes "$(grep -q -- '--resume s-1' "$L/args" && echo yes || echo no)"
check "launcher: --mutations needs --resume" 2 \
  "$(cd "$L" && CLAUDE_REAL_BIN="$L/claude" "$HERE/claude-goal-review.sh" --mutations 3 "$L/brief.md" >/dev/null 2>&1; echo $?)"

# --- run-goal.sh ------------------------------------------------------------
HOUSE="$TMP/house"
mkdir -p "$HOUSE/scripts"
cp -R "$HERE/." "$HOUSE/scripts/"
# The implementer writes src/calc.sh (a usage line the oracle never checks,
# and the sum it does).
cat >"$HOUSE/scripts/claude-implement.sh" <<'SH'
#!/usr/bin/env bash
echo implement >>"$CALLS/log"
mkdir -p src
n="$(grep -c implement "$CALLS/log")"
printf '#!/usr/bin/env bash\n# calc: add two numbers (pass %s)\nusage="usage: calc.sh A B"\necho $(( $1 + $2 ))\n' "$n" >src/calc.sh
# $CALLS/tabbed: a tab-indented body instead.
[[ ! -f "$CALLS/tabbed" ]] || printf '#!/usr/bin/env bash\nif true; then\n\techo $(( $1 + $2 ))\nfi\n' >src/calc.sh
git add src/calc.sh
# $CALLS/symlink: also a symlink the implementer changed.
[[ ! -f "$CALLS/symlink" ]] || { ln -sf calc.sh src/link.sh; git add src/link.sh; }
# $CALLS/nested: also vendor/x, committed, then a nested repository planted
# under it whose config would run a clean filter.
if [[ -f "$CALLS/nested" ]]; then
  mkdir -p vendor/x && echo v >vendor/x/a.txt && git add vendor/x/a.txt
fi
if [[ -f "$CALLS/nested-case" ]]; then
  mkdir -p vendor/y && for i in $(seq 1 1600); do echo "$i" >"vendor/y/f$i.txt"; done && git add vendor/y
fi
git -c commit.gpgSign=false commit -qm "feat(g1-store): calc"
if [[ -f "$CALLS/nested" ]]; then
  git -C vendor/x init -q
  git -C vendor/x -c commit.gpgSign=false add a.txt && git -C vendor/x -c commit.gpgSign=false commit -qm v
  printf '[filter "x"]\n\tclean = touch %s/filter-ran; cat\n' "$CALLS" >>vendor/x/.git/config
  printf '* filter=x\n' >vendor/x/.git/info/attributes
  # $CALLS/nested-case: the same repository as .GIT (it opens as .git on a
  # case-insensitive disk), with tracked files sorting after it, so a check
  # piped to grep -q would see ls-files die of SIGPIPE.
  [[ ! -f "$CALLS/nested-case" ]] || mv vendor/x/.git vendor/x/.GIT
fi
printf '%s\n' "IMPLEMENTER_RESULT: ok" "THREAD_ID: haiku:t1" "IMPLEMENTER_STATUS: DONE" "IMPLEMENTER_MODEL: stub"
SH
# The reviewer: a verdict from $CALLS/verdicts (one a call, DONE when none
# left); with --mutations, $CALLS/mutations as its reply.
cat >"$HOUSE/scripts/claude-goal-review.sh" <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *" --mutations "* ]]; then
  echo mutations >>"$CALLS/log"
  if [[ -f "$CALLS/turn-fails" ]]; then
    printf '%s\n' "CLAUDE_REVIEW_RESULT: rate_limited (exit 1)" "SESSION_ID: s1" "VERDICT: MISSING"
    exit 75
  fi
  f="$CW_OUT_DIR/mutations-stub-$RANDOM.txt"
  cp "$CALLS/mutations" "$f" 2>/dev/null || : >"$f"
  printf '%s\n' "CLAUDE_REVIEW_RESULT: ok" "SESSION_ID: s1" "MUTATIONS_FILE: $f" "CLAUDE_REVIEW_MODEL: stub"
  exit 0
fi
echo review >>"$CALLS/log"
v=DONE
if [[ -s "$CALLS/verdicts" ]]; then v="$(head -n1 "$CALLS/verdicts")"; sed -i '' 1d "$CALLS/verdicts"; fi
vf="$CW_OUT_DIR/verdict-$RANDOM.md"
if [[ "$v" == FIX ]]; then printf 'FIX: src/calc.sh:4 — a nit — change it\nVERDICT: FIX\n' >"$vf"; else printf 'VERDICT: %s\n' "$v" >"$vf"; fi
printf '%s\n' "CLAUDE_REVIEW_RESULT: ok" "SESSION_ID: s1" "VERDICT: $v" "VERDICT_FILE: $vf" "CLAUDE_REVIEW_MODEL: stub"
SH
chmod +x "$HOUSE/scripts/"*.sh

ORACLE_OK='out="$(bash src/calc.sh 2 3)"; [ "$out" = 5 ] || { echo "want 5, got $out"; exit 1; }
[ "$(bash src/calc.sh 10 0)" = 10 ] || exit 1
echo ok'
# mut <rule> <diff body> — one block of the reviewer's reply.
mut() { printf 'MUTATION: %s\n```diff\n%s\n```\n\n' "$1" "$2"; }
SUM_TO_MINUS='--- a/src/calc.sh
+++ b/src/calc.sh
@@ -3,2 +3,2 @@
 usage="usage: calc.sh A B"
-echo $(( $1 + $2 ))
+echo $(( $1 - $2 ))'
USAGE_TEXT='--- a/src/calc.sh
+++ b/src/calc.sh
@@ -3,1 +3,1 @@
-usage="usage: calc.sh A B"
+usage="usage: calc A B"'
ORACLE_EDIT='--- a/tests/acceptance/g1-store.sh
+++ b/tests/acceptance/g1-store.sh
@@ -1,1 +1,1 @@
-x
+y'
LOOP='--- a/src/calc.sh
+++ b/src/calc.sh
@@ -4,1 +4,1 @@
-echo $(( $1 + $2 ))
+while :; do :; done'
NOTESTS='--- a/src/calc.sh
+++ b/src/calc.sh
@@ -4,1 +4,1 @@
-echo $(( $1 + $2 ))
+echo $(( $1 + $2 )); echo "Ran 0 tests" >&2'
NO_APPLY='--- a/src/calc.sh
+++ b/src/calc.sh
@@ -4,1 +4,1 @@
-echo not this line
+echo nor this'

make_repo() {
  rm -rf "$TMP/repo" "$CALLS"/* "$HOME/.cache/claude-coding-workflow/run-goal-g1-store"
  mkdir -p "$TMP/repo/docs/journal" "$TMP/repo/tests/acceptance" && cd "$TMP/repo"
  git init -q
  sed -e '/id: g1-store/,/status:/{
s|proof: true|proof: bash tests/acceptance/g1-store.sh|
s|oracle: inline|oracle: tests/acceptance/g1-store.sh|
}' "$HERE/../GOALS.example.md" >GOALS.md
  printf '# Plan\n' >PLAN.md
  printf '%s\n' "$1" >tests/acceptance/g1-store.sh
  printf '.gitignore\n' >.gitignore
  printf '# Journal: example\n' >docs/journal/example.md
  git add -A && git commit -q -m base
}
run() {
  "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 && rc=0 || rc=$?
  local stop
  stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)"
  reason="$(sed -n 's/^- reason: //p' "$stop" 2>/dev/null || true)"
}
status_of() { "$HERE/goals.py" GOALS.md show g1-store | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])'; }
record() { git show HEAD:docs/journal/example.md | sed -n 's/^## .* — ORCHESTRATOR mutations g1-store r[0-9]* //p' | tail -n1; }
event() {  # the newest mutations event, as "<severity> <rules of survivors>"
  python3 - "$(find "$EVENTS_CACHE" -name '*.jsonl' | head -n1)" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
m = [r for r in rows if r.get("event") == "mutations"]
if not m:
    print("none")
else:
    r = m[-1]
    s = [x["rule"] for x in r["payload"]["mutations"] if x["outcome"] == "survived"]
    print(r["severity"], ";".join(s))
PY
}
ART="$HOME/.cache/claude-coding-workflow/run-goal-g1-store"

echo "== a caught mutation, a survivor, a contract edit"
make_repo "$ORACLE_OK"
{ mut 'the sum is a sum' "$SUM_TO_MINUS"; mut 'the usage text' "$USAGE_TEXT"; mut 'the oracle itself' "$ORACLE_EDIT"; } >"$CALLS/mutations"
calc_before=""
run
check "the goal is done" "0 done" "$rc $(status_of)"
check "the record" "caught=1 survived=1 timeout=0 skipped=1" "$(record)"
check "a warning event naming the survivor's rule" "warning the usage text" "$(event)"
check "the survivor's diff and rule kept" yes \
  "$([[ -s "$ART/mutation-r0-2.diff" && "$(cat "$ART/mutation-r0-2.rule")" == "the usage text" ]] && echo yes || echo no)"
check "the checkout untouched: calc.sh as the implementer wrote it" yes \
  "$(grep -q '^echo \$(( \$1 + \$2 ))$' src/calc.sh && grep -q 'usage: calc.sh A B' src/calc.sh && echo yes || echo no)"
check "the checkout untouched: clean, no stash" "" "$(git status --porcelain; git stash list)"
check "no clone left in the temp area" "" "$(ls -d "$TMP"/cw-mut-* 2>/dev/null)"
check "the mutations turn ran once, after the DONE" "implement review mutations" "$(paste -sd ' ' - <"$CALLS/log")"

echo "== a timeout, Ran 0 tests, a diff that does not apply"
make_repo "$ORACLE_OK"
{ mut 'loops' "$LOOP"; mut 'no tests' "$NOTESTS"; mut 'stale context' "$NO_APPLY"; } >"$CALLS/mutations"
PROOF_TIMEOUT=4 run
check "a timeout is timeout; Ran 0 tests is caught; no apply is a skip" \
  "caught=1 survived=0 timeout=1 skipped=1" "$(record)"
check "  ...the goal still done" "0 done" "$rc $(status_of)"

echo "== a baseline red in a copy: every mutation skipped"
make_repo '[ "$(basename "$PWD")" = repo ] || { echo "not the checkout"; exit 1; }'
{ mut 'the sum' "$SUM_TO_MINUS"; mut 'the usage' "$USAGE_TEXT"; } >"$CALLS/mutations"
run
check "baseline red: both skipped, the goal done" "caught=0 survived=0 timeout=0 skipped=2 0 done" "$(record) $rc $(status_of)"
check "  ...the reason names the baseline's outcome" yes "$(python3 -c 'import json,sys; rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]; m=[r for r in rows if r.get("event")=="mutations"][-1]; print("yes" if "the baseline in a copy: red" in json.dumps(m["payload"]) else "no")' "$(find "$EVENTS_CACHE" -name '*.jsonl' | head -n1)")"

check "  ...the baseline's output kept for the Architect" yes \
  "$(grep -q 'not the checkout' "$ART/mutation-r0-baseline.out" 2>/dev/null && echo yes || echo no)"

# ignore <paths...> — ignored folders in the checkout (.gitignore ignores itself).
ignore() { printf '%s/\n' "$@" >>.gitignore; }

echo "== the copy keeps a directory's mtime"
make_repo '[ "$(stat -f %Sm -t %Y cache)" = 2000 ] || { echo "cache mtime $(stat -f %Sm cache)"; exit 1; }
'"$ORACLE_OK"
ignore cache
mkdir cache && echo c >cache/c && touch -t 200001010000 cache
mut 'the sum' "$SUM_TO_MINUS" >"$CALLS/mutations"
run
check "a directory's mtime kept: the baseline green, the mutation caught" "caught=1 survived=0 timeout=0 skipped=0" "$(record)"

echo "== one copy for every mutation: the baseline's build output reused"
# The proof goes red in a copy it has run in before: the usage mutation, a
# survivor in a fresh copy, is caught only in the baseline's copy.
make_repo 'mkdir -p build; case "$PWD" in */cw-mut-*) if grep -qxF "$PWD" build/runs 2>/dev/null; then echo "a copy run before"; exit 1; fi; echo "$PWD" >>build/runs ;; esac
'"$ORACLE_OK"
ignore build
mut 'the usage text' "$USAGE_TEXT" >"$CALLS/mutations"
run
check "the mutation runs in the baseline's copy" "caught=1 survived=0 timeout=0 skipped=0" "$(record)"

echo "== one copy: each mutation starts from the baseline (tracked and untracked files reset)"
make_repo '[ ! -e src/stray.txt ] || { echo "a stray file"; exit 1; }
'"$ORACLE_OK"
{ mut 'the sum, with a stray file' '--- a/src/calc.sh
+++ b/src/calc.sh
@@ -4,1 +4,1 @@
-echo $(( $1 + $2 ))
+touch src/stray.txt; echo $(( $1 - $2 ))'; mut 'the sum' "$SUM_TO_MINUS"; mut 'the usage text' "$USAGE_TEXT"; } >"$CALLS/mutations"
run
check "reset between mutations: caught, caught, survived" "caught=2 survived=1 timeout=0 skipped=0" "$(record)"
check "  ...the survivor is the usage text" "warning the usage text" "$(event)"
check "no copy left in the temp area" "" "$(ls -d "$TMP"/cw-mut-* 2>/dev/null)"

echo "== mutation_proof: the mutations run it, not the proof"
make_repo "$ORACLE_OK"
python3 - <<'PYX'
import re
t = open("GOALS.md").read()
t, n = re.subn(r"(id: g1-store[\s\S]*?\n(\s+)proof: [^\n]*\n)", r"\1\2mutation_proof: true\n", t, count=1)
assert n == 1
open("GOALS.md", "w").write(t)
PYX
git commit -qam "g1-store: a mutation proof"
check "mutation_proof: validate accepts it" 0 "$("$HERE/goals.py" GOALS.md validate >/dev/null 2>&1; echo $?)"
mut 'the sum' "$SUM_TO_MINUS" >"$CALLS/mutations"
run
check "mutation_proof true: the sum mutation survives, the goal done" "caught=0 survived=1 timeout=0 skipped=0 0 done" "$(record) $rc $(status_of)"
sed -i '' 's/mutation_proof: true/mutation_proof: [a, b]/' GOALS.md
v="$("$HERE/goals.py" GOALS.md validate 2>&1 || true)"
check "mutation_proof: a list is refused" yes "$(has 'mutation_proof must be one shell command' "$v$(grep -n mutation_proof GOALS.md)")"
git checkout -q GOALS.md

echo "== the mutations turn returns nothing"
make_repo "$ORACLE_OK"
: >"$CALLS/mutations"
run
check "nothing usable: all skipped, recorded, the goal done" "caught=0 survived=0 timeout=0 skipped=3 0 done" "$(record) $rc $(status_of)"

echo "== CW_MUTATIONS=0: no turn, no record"
make_repo "$ORACLE_OK"
mut 'the sum' "$SUM_TO_MINUS" >"$CALLS/mutations"
CW_MUTATIONS=0 run
check "off: no mutations turn, no record" "implement review|" "$(paste -sd ' ' - <"$CALLS/log")|$(record)"

echo "== a FIX round first: one mutations turn, after the final DONE"
make_repo "$ORACLE_OK"
printf 'FIX\n' >"$CALLS/verdicts"
: >"$CALLS/mutations"
run
check "FIX then DONE: one mutations turn, last" "implement review implement review mutations" "$(paste -sd ' ' - <"$CALLS/log")"

echo "== an invalid CW_MUTATIONS is refused at start"
make_repo "$ORACLE_OK"
CW_MUTATIONS=9 run
check "CW_MUTATIONS=9: exit 2, nothing dispatched" "2 " "$rc $(cat "$CALLS/log" 2>/dev/null)"

echo "== a user config that signs commits, no terminal"
make_repo "$ORACLE_OK"
# In the user's own config ($HOME/.gitconfig): the clone's git clears every
# GIT_* variable and reads no user config, so it must not sign.
printf '[commit]\n\tgpgSign = true\n[gpg]\n\tprogram = /usr/bin/false\n' >"$HOME/.gitconfig"
mut 'the sum' "$SUM_TO_MINUS" >"$CALLS/mutations"
run </dev/null
rm -f "$HOME/.gitconfig"
check "signing on: the clone's baseline commit still made, the mutation caught" "caught=1 survived=0 timeout=0 skipped=0" "$(record)"

echo "== a nested repository in the checkout: not run, its filter never runs"
make_repo "$ORACLE_OK"
touch "$CALLS/nested"
mut 'the sum' "$SUM_TO_MINUS" >"$CALLS/mutations"
run
check "nested .git: skipped, the goal done, no filter ran" "caught=0 survived=0 timeout=0 skipped=1 0 done no" \
  "$(record) $rc $(status_of) $([[ -e "$CALLS/filter-ran" ]] && echo yes || echo no)"
check "  ...the reason names it" yes "$(python3 -c 'import json,sys; rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]; m=[r for r in rows if r.get("event")=="mutations"][-1]; print("yes" if "nested .git" in json.dumps(m["payload"]) else "no")' "$(find "$EVENTS_CACHE" -name '*.jsonl' | head -n1)")"

echo "== a nested repository spelled .GIT, ~100 KB of index after it: not run, its filter never runs"
make_repo "$ORACLE_OK"
touch "$CALLS/nested" "$CALLS/nested-case"
mut 'the sum' "$SUM_TO_MINUS" >"$CALLS/mutations"
run
check ".GIT: skipped, the goal done, no filter ran" "caught=0 survived=0 timeout=0 skipped=1 0 done no" \
  "$(record) $rc $(status_of) $([[ -e "$CALLS/filter-ran" ]] && echo yes || echo no)"

echo "== a symlink the implementer changed: a mutation of it is refused"
make_repo "$ORACLE_OK"
touch "$CALLS/symlink"
mut 'through a link' '--- a/src/link.sh
+++ b/src/link.sh
@@ -4,1 +4,1 @@
-echo $(( $1 + $2 ))
+echo 0' >"$CALLS/mutations"
run
check "symlink destination: skipped" "caught=0 survived=0 timeout=0 skipped=1" "$(record)"

echo "== a tab-indented file, end to end"
make_repo "$ORACLE_OK"
touch "$CALLS/tabbed"
mut 'the sum' "$(printf -- '--- a/src/calc.sh\n+++ b/src/calc.sh\n@@ -2,3 +2,3 @@\n if true; then\n-\techo $(( $1 + $2 ))\n+\techo $(( $1 * $2 ))\n fi')" >"$CALLS/mutations"
run
check "tabs: the mutation applies and is caught" "caught=1 survived=0 timeout=0 skipped=0" "$(record)"

echo "== a rule with quotes reaches the event intact"
make_repo "$ORACLE_OK"
mut 'say "usage" right' "$USAGE_TEXT" >"$CALLS/mutations"
run
check "a quoted rule in the payload" 'warning say "usage" right' "$(event)"

echo "== a failed mutations turn, and an oversized reply"
make_repo "$ORACLE_OK"
touch "$CALLS/turn-fails"
run
check "a failed turn: all skipped, the goal done" "caught=0 survived=0 timeout=0 skipped=3 0 done" "$(record) $rc $(status_of)"
make_repo "$ORACLE_OK"
{ mut 'the sum' "$SUM_TO_MINUS"; head -c 70000 /dev/zero | tr '\0' 'x'; } >"$CALLS/mutations"
run
check "over 64 KB: all skipped" "caught=0 survived=0 timeout=0 skipped=3" "$(record)"

echo "== a BLOCKED verdict runs no mutations turn"
make_repo "$ORACLE_OK"
printf 'BLOCKED\n' >"$CALLS/verdicts"
mut 'the sum' "$SUM_TO_MINUS" >"$CALLS/mutations"
run
check "BLOCKED: no mutations turn" "implement review" "$(paste -sd ' ' - <"$CALLS/log")"

echo "== the serial checkout's .git untouched"
make_repo "$ORACLE_OK"
mut 'the sum' "$SUM_TO_MINUS" >"$CALLS/mutations"
cfg="$(shasum .git/config | cut -c1-40)"
run
check "serial: .git/config unchanged, the mutation caught" "$cfg caught=1" "$(shasum .git/config | cut -c1-40) $(record | cut -d' ' -f1)"

echo "== CW_MUTATION_GAPS=stop: the walk stops after the goal lands"
make_repo "$ORACLE_OK"
mut 'the usage text' "$USAGE_TEXT" >"$CALLS/mutations"
CW_MUTATION_GAPS=stop "$HOUSE/scripts/run-goals.sh" >"$TMP/walk.out" 2>&1 && wrc=0 || wrc=$?
check "strict: the goal is done, the walk stopped oracle-gap" "done yes" \
  "$(status_of) $([[ "$wrc" -ne 0 ]] && grep -q 'oracle-gap' "$TMP/walk.out" && echo yes || echo no)"
# The rerun lands the next goal (a real proof, no survivors of its own): the
# earlier survivor must not stop it.
python3 - <<'PY'
import re
t = open("GOALS.md").read()
t = re.sub(r"(id: g2-ack[\s\S]*?proof: )true", r"\1bash tests/acceptance/g1-store.sh", t, count=1)
open("GOALS.md", "w").write(t)
PY
"$HERE/goals.py" GOALS.md set g3-other done >/dev/null
git commit -qam "g2-ack proves; g3-other done"
: >"$CALLS/mutations"
CW_MUTATION_GAPS=stop "$HOUSE/scripts/run-goals.sh" >"$TMP/walk2.out" 2>&1 || true
check "strict: a rerun lands the next goal (no oracle-gap for the earlier survivor)" "no done" \
  "$(grep -q 'oracle-gap' "$TMP/walk2.out" && echo yes || echo no) $("$HERE/goals.py" GOALS.md show g2-ack | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
check "strict: the stop names the goal and its survivors" yes \
  "$(grep -q 'g1-store survived=1' "$(sed -n 's/^STOP_FILE: //p' "$TMP/walk.out" | tail -n1)" 2>/dev/null && echo yes || echo no)"

echo "== the walk end names each goal of the walk with survivors"
make_repo "$ORACLE_OK"
"$HERE/goals.py" GOALS.md set g2-ack done >/dev/null && "$HERE/goals.py" GOALS.md set g3-other done >/dev/null
git commit -qam "only g1-store left"
mut 'the usage text' "$USAGE_TEXT" >"$CALLS/mutations"
"$HOUSE/scripts/run-goals.sh" >"$TMP/walk3.out" 2>&1 && wrc=0 || wrc=$?
check "a walk with a survivor ends 0 and names it" "0 yes" \
  "$wrc $(grep -q '^mutations survived the oracle: g1-store survived=1 ' "$TMP/walk3.out" && echo yes || echo no)"

echo "== --jobs: the member's worktree and the shared .git untouched"
# A member's .git is a gitfile naming its admin folder in the shared gitdir:
# a clone that reinitialized it would taint host git (git-metadata-tamper).
make_repo "$ORACLE_OK"
"$HERE/goals.py" GOALS.md set g2-ack done >/dev/null && "$HERE/goals.py" GOALS.md set g3-other done >/dev/null
git commit -qam "only g1-store left"
{ mut 'the sum' "$SUM_TO_MINUS"; mut 'the usage text' "$USAGE_TEXT"; } >"$CALLS/mutations"
cfg_before="$(shasum .git/config | cut -c1-40)"
"$HOUSE/scripts/run-goals.sh" --jobs 2 >"$TMP/jobs.out" 2>&1 && jrc=0 || jrc=$?
check "--jobs: the walk ends 0, the goal done" "0 done" "$jrc $(status_of)"
[[ "$jrc" -eq 0 ]] || tail -15 "$TMP/jobs.out" | sed 's/^/    | /'
check "--jobs: the record committed on the walk branch" "caught=1 survived=1 timeout=0 skipped=0" "$(record)"
check "--jobs: the shared .git/config unchanged" "$cfg_before" "$(shasum .git/config | cut -c1-40)"
check "--jobs: the walk end names the survivor" yes \
  "$(grep -q '^mutations survived the oracle: g1-store survived=1 ' "$TMP/jobs.out" && echo yes || echo no)"

echo "== --jobs and CW_MUTATION_GAPS=stop: the walk stops after the wave"
make_repo "$ORACLE_OK"
"$HERE/goals.py" GOALS.md set g2-ack done >/dev/null && "$HERE/goals.py" GOALS.md set g3-other done >/dev/null
git commit -qam "only g1-store left"
mut 'the usage text' "$USAGE_TEXT" >"$CALLS/mutations"
CW_MUTATION_GAPS=stop "$HOUSE/scripts/run-goals.sh" --jobs 2 >"$TMP/jobs2.out" 2>&1 && jrc=0 || jrc=$?
check "--jobs strict: the goal done, the walk stopped oracle-gap" "done yes" \
  "$(status_of) $([[ "$jrc" -ne 0 ]] && grep -q 'oracle-gap' "$TMP/jobs2.out" && echo yes || echo no)"

if [[ "$fails" -eq 0 ]]; then
  echo "mutation-test: all passed"
else
  echo "mutation-test: $fails failed" >&2
  exit 1
fi
