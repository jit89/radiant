#!/usr/bin/env bash
# Self-test: grok-review.sh reports a review only when Grok's turn ended
# normally. A fake `grok` (GROK_BIN) prints a canned JSON envelope; nothing
# calls the API.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cw-grok-review-XXXXXX")" && pwd)"
export TMPDIR="$TMP" HOME="$TMP/home"; mkdir -p "$HOME"
trap 'rm -rf "$TMP"' EXIT
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

REPO="$TMP/repo"
mkdir -p "$REPO" && printf '# Plan\n' >"$REPO/PLAN.md"

# fake_grok <stopReason> <text>: a grok that ignores its arguments and prints
# one JSON envelope, as `grok -p --output-format json` does.
fake_grok() {
  python3 - "$1" "$2" >"$TMP/envelope.json" <<'PY'
import json, sys
print(json.dumps({"text": sys.argv[2], "stopReason": sys.argv[1],
                  "sessionId": "11111111-2222-3333-4444-555555555555"}))
PY
  printf '#!/usr/bin/env bash\ncat %q\n' "$TMP/envelope.json" >"$TMP/grok"
  chmod +x "$TMP/grok"
}

review() { (cd "$REPO" && GROK_BIN="$TMP/grok" GROK_REVIEW_OUT="$TMP/verdict.md" "$HERE/grok-review.sh" PLAN.md); }
line() { sed -n "s/^$1: //p" "$TMP/out"; }

# A normal turn: the review and its verdict.
fake_grok end_turn $'Two findings.\nVERDICT: REVISE'
review >"$TMP/out" 2>&1 && rc=0 || rc=$?
check "end_turn: exit 0" 0 "$rc"
check "end_turn: result ok" ok "$(line GROK_REVIEW_RESULT)"
check "end_turn: verdict read" REVISE "$(line VERDICT)"
check "end_turn: session from the envelope" 11111111-2222-3333-4444-555555555555 "$(line SESSION_ID)"

# A cancelled turn (a refused tool call ended it): an error, never `ok`, even
# when the partial text happens to end in a verdict line.
fake_grok cancelled $'I will read the plan first.\nVERDICT: APPROVED'
review >"$TMP/out" 2>&1 && rc=0 || rc=$?
check "cancelled: nonzero exit" 1 "$rc"
check "cancelled: reported as an error" "error (turn stopped: cancelled)" "$(line GROK_REVIEW_RESULT)"
check "cancelled: no verdict taken from a partial turn" MISSING "$(line VERDICT)"
check "cancelled: partial text kept for the Architect" "yes" \
  "$(grep -q 'I will read the plan first.' "$TMP/verdict.md" && echo yes || echo no)"

# Any other abnormal stop is an error too.
fake_grok max_tokens $'Finding 1...'
review >"$TMP/out" 2>&1 && rc=0 || rc=$?
check "max_tokens: reported as an error" "error (turn stopped: max_tokens)" "$(line GROK_REVIEW_RESULT)"

# An NDJSON stream: the stop reason is read from its last object, as the
# text is.
python3 - >"$TMP/envelope.json" <<'PY'
import json
print(json.dumps({"type": "progress", "note": "reading"}))
print(json.dumps({"text": "partial\nVERDICT: APPROVED", "stopReason": "cancelled",
                  "sessionId": "11111111-2222-3333-4444-555555555555"}))
PY
printf '#!/usr/bin/env bash\ncat %q\n' "$TMP/envelope.json" >"$TMP/grok"
chmod +x "$TMP/grok"
review >"$TMP/out" 2>&1 && rc=0 || rc=$?
check "ndjson cancelled: reported as an error" "error (turn stopped: cancelled)" "$(line GROK_REVIEW_RESULT)"

# The prompt tells Grok its only tools, in both the first and later rounds,
# and the read-only flags are passed. The fake records the argv it was really
# given (one argument per line), so this checks what Grok receives, not how a
# dry run displays it.
recording_grok() {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >%q\ncat %q\n' "$TMP/argv" "$TMP/envelope.json" >"$TMP/grok"
  chmod +x "$TMP/grok"
}
fake_grok end_turn $'ok\nVERDICT: APPROVED'
recording_grok
review >"$TMP/out" 2>&1
check "round 1 prompt names the only tools" yes \
  "$(LC_ALL=C grep -q 'Your only tools are read_file, grep_search and list_dir' "$TMP/argv" && echo yes || echo no)"
check "read-only flags passed" yes "$(LC_ALL=C tr '\n' ' ' <"$TMP/argv" |
  LC_ALL=C grep -q -- '--permission-mode plan --tools read_file,grep_search,list_dir --no-subagents --disable-web-search' && echo yes || echo no)"
(cd "$REPO" && GROK_BIN="$TMP/grok" GROK_REVIEW_OUT="$TMP/verdict.md" "$HERE/grok-review.sh" \
  --resume 11111111-2222-3333-4444-555555555555 PLAN.md) >"$TMP/out" 2>&1
check "later rounds name the only tools too" yes \
  "$(LC_ALL=C grep -q 'Your only tools are' "$TMP/argv" && echo yes || echo no)"
check "later rounds resume the session" yes \
  "$(LC_ALL=C tr '\n' ' ' <"$TMP/argv" | LC_ALL=C grep -q -- '--resume 11111111-2222-3333-4444-555555555555' && echo yes || echo no)"

# --oracle (Phase 3): the oracles of this DAG, a fresh session, its own
# prompts. Fixture: g1 has a file oracle and a swept edit on an older file;
# g2 is inline with a swept edit written `file:line`, which also re-names
# g1's oracle (deduplicated); an Edits-owned path and an older oracle out of
# scope sit on disk too.
O="$TMP/oracle-repo"
mkdir -p "$O/docs/feat" "$O/tests/acceptance"
printf '# Plan\n' >"$O/docs/feat/PLAN.md"
printf '# Plan Review Log\n## Round 1 — Grok\nok\n' >"$O/docs/feat/PLAN-REVIEW-LOG.md"
for f in g1_new.c g0_old_swept.c g0_other.py only_g2.c owned_by_g2.c unlisted_old.c; do printf 'x\n' >"$O/tests/acceptance/$f"; done

# goals_md <g1 oracle> <g1 Acceptance-edits text> <g2 Acceptance-edits text> [plan path]
goals_md() {
  cat >"$O/GOALS.md" <<GOALS
# Goals: fixture

\`\`\`yaml
plan: ${4:-docs/feat/PLAN.md}
log: docs/feat/PLAN-REVIEW-LOG.md
journal: docs/journal/feat.md
goals:
  - id: g1-new
    title: New behaviour
    blocked_by: []
    conflicts_with: []
    area: core
    proof: make test
    oracle: $1
    status: ready
  - id: g2-inline
    title: Inline goal
    blocked_by: [g1-new]
    conflicts_with: []
    area: core
    proof: (case table)
    oracle: inline
    status: blocked
\`\`\`

## g1-new — New behaviour

**Acceptance edits (applied, read-only):** $2

**Edits owned:** None.

## g2-inline — Inline goal

**Acceptance edits (applied, read-only):** $3

**Edits owned:** \`tests/acceptance/owned_by_g2.c\` (listed here only to be ignored by the review).
GOALS
}
good_goals() {
  goals_md tests/acceptance/g1_new.c \
    '`tests/acceptance/g0_old_swept.c:40:7`, `1 → 2`; `tests/acceptance/g0_other.py::test_ack`, `a → b`.' \
    '`tests/acceptance/g1_new.c:12-14`, `x → y`, `tests/acceptance/only_g2.c:3`, and tests/acceptance/g0_old_swept.c:41.'
}

oracle_review() { (cd "$O" && GROK_BIN="$TMP/grok" GROK_REVIEW_OUT="$TMP/verdict.md" "$HERE/grok-review.sh" --oracle "$@"); }
argv_has() { LC_ALL=C grep -q -F -- "$1" "$TMP/argv" && echo yes || echo no; }
argv_line() { LC_ALL=C tr '\n' ' ' <"$TMP/argv"; }
FLAGS='--permission-mode plan --tools read_file,grep_search,list_dir --no-subagents --disable-web-search'
flags_ok() { argv_line | LC_ALL=C grep -q -F -- "$FLAGS" && echo yes || echo no; }

fake_grok end_turn $'Oracles look fine.\nVERDICT: APPROVED'
recording_grok
good_goals
rm -f "$TMP/argv"
oracle_review docs/feat/PLAN.md >"$TMP/out" 2>&1 && rc=0 || rc=$?
check "oracle r1: exit 0" 0 "$rc"
check "oracle r1: a fresh session" yes "$(argv_line | LC_ALL=C grep -q -- '--session-id ' && echo yes || echo no)"
check "oracle r1: never resumes" no "$(argv_has '--resume')"
check "oracle r1: the oracle prompt, not the plan's" yes "$(argv_has 'adversarial reviewer of acceptance oracles')"
check "oracle r1: names the plan" yes "$(argv_has "$O/docs/feat/PLAN.md")"
check "oracle r1: names the log beside the plan" yes "$(argv_has "$O/docs/feat/PLAN-REVIEW-LOG.md")"
check "oracle r1: names GOALS.md" yes "$(argv_has "$O/GOALS.md")"
check "oracle r1: the exact list, suffixes dropped, each once, in order" yes \
  "$(argv_has 'tests/acceptance/: tests/acceptance/g1_new.c, tests/acceptance/g0_old_swept.c, tests/acceptance/g0_other.py, tests/acceptance/only_g2.c. You')"
check "oracle r1: no :line, :line:col, ::node or range left" no \
  "$(LC_ALL=C grep -q -E 'g0_old_swept\.c:|g0_other\.py::|g1_new\.c:' "$TMP/argv" && echo yes || echo no)"
check "oracle r1: not the Edits-owned path" no "$(argv_has 'owned_by_g2.c')"
check "oracle r1: not an older oracle out of scope" no "$(argv_has 'unlisted_old.c')"
check "oracle r1: names the only tools" yes "$(argv_has 'Your only tools are read_file, grep_search and list_dir')"
check "oracle r1: asks for the PLAN: prefix" yes "$(argv_has 'Start a finding with PLAN:')"
check "oracle r1: requires the closing verdict line" yes "$(argv_has 'End your reply with EXACTLY one line: VERDICT: APPROVED')"
check "oracle r1: the full read-only flag set" yes "$(flags_ok)"
check "oracle r1: verdict read" APPROVED "$(line VERDICT)"

rm -f "$TMP/argv"
oracle_review --resume 11111111-2222-3333-4444-555555555555 docs/feat/PLAN.md >"$TMP/out" 2>&1 && rc=0 || rc=$?
check "oracle r2: exit 0" 0 "$rc"
check "oracle r2: resumes the oracle session" yes "$(argv_line | LC_ALL=C grep -q -- '--resume 11111111-2222-3333-4444-555555555555' && echo yes || echo no)"
check "oracle r2: no --session-id" no "$(argv_has '--session-id')"
check "oracle r2: the oracle re-review prompt" yes "$(argv_has 'I revised the oracles.')"
check "oracle r2: never the plan re-review prompt" no "$(argv_has 'I revised the plan.')"
check "oracle r2: repeats the file list" yes "$(argv_has 'tests/acceptance/g1_new.c, tests/acceptance/g0_old_swept.c, tests/acceptance/g0_other.py, tests/acceptance/only_g2.c.')"
check "oracle r2: names the only tools" yes "$(argv_has 'Your only tools are read_file')"
check "oracle r2: requires the closing verdict line" yes "$(argv_has 'End your reply with EXACTLY one line: VERDICT: APPROVED or VERDICT: REVISE.')"
check "oracle r2: the full read-only flag set" yes "$(flags_ok)"

# Headings written with the colon outside the bold: g2's Acceptance edits
# (the only section naming only_g2.c) is still read, and g2's Edits owned in
# the same form still ends it (owned_by_g2.c stays out).
good_goals
python3 - "$O/GOALS.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
g2 = s.index("## g2-inline")
head, tail = s[:g2], s[g2:]
tail = tail.replace("**Acceptance edits (applied, read-only):**", "**Acceptance edits (applied, read-only)**:", 1)
tail = tail.replace("**Edits owned:**", "**Edits owned**:", 1)
open(p, "w").write(head + tail)
PY
check "colon outside: the fixture was rewritten" yes \
  "$(grep -q '^\*\*Acceptance edits (applied, read-only)\*\*: `tests/acceptance/g1_new.c:12-14`' "$O/GOALS.md" &&
     grep -q '^\*\*Edits owned\*\*: ' "$O/GOALS.md" && echo yes || echo no)"
rm -f "$TMP/argv"
oracle_review docs/feat/PLAN.md >"$TMP/out" 2>&1
check "colon outside: the section is still read" yes "$(argv_has 'tests/acceptance/only_g2.c')"
check "colon outside: Edits owned still ends it" no "$(argv_has 'owned_by_g2.c')"
good_goals

# Plan mode is today's command exactly: every argument, prompt included,
# against a golden copy (the session id normalised).
TOOLS='Your only tools are read_file, grep_search and list_dir: there is no shell, and calling any other tool ends the review with nothing recorded.'
golden() { # golden <prompt> <session flag> <session value>
  printf '%s\n' -p "$1" --model grok-4.7 --reasoning-effort high --output-format json \
    --permission-mode plan --tools read_file,grep_search,list_dir --no-subagents --disable-web-search "$2" "$3"
}
normalised() { LC_ALL=C sed -E 's/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/<uuid>/' "$TMP/argv"; }
P="$REPO/PLAN.md"
rm -f "$TMP/argv"
(cd "$REPO" && GROK_BIN="$TMP/grok" GROK_REVIEW_OUT="$TMP/verdict.md" "$HERE/grok-review.sh" PLAN.md) >"$TMP/out" 2>&1
check "plan mode r1: argv identical to the golden copy" yes "$([[ "$(normalised)" == "$(golden "You are an adversarial reviewer for an implementation plan written by a different model. Be skeptical and specific — your job is to find what breaks, not to be agreeable. Do not defer to the plan's confidence. Read the plan at ${P} (and GLOSSARY.md or CONTEXT.md / ADRs for domain language, if present) and any repo files you need (you are read-only). ${TOOLS} Identify concrete flaws: security holes, race conditions, missing edge cases, schema conflicts, wrong assumptions, observability gaps, simpler alternatives. For each, give a one-line fix. Do NOT modify any files. End your reply with EXACTLY one line: VERDICT: APPROVED if the plan is sound enough to implement, or VERDICT: REVISE if it still has material problems." --session-id '<uuid>')" ]] && echo yes || echo no)"
rm -f "$TMP/argv"
(cd "$REPO" && GROK_BIN="$TMP/grok" GROK_REVIEW_OUT="$TMP/verdict.md" "$HERE/grok-review.sh" --resume 11111111-2222-3333-4444-555555555555 PLAN.md) >"$TMP/out" 2>&1
check "plan mode r2: argv identical to the golden copy" yes "$([[ "$(normalised)" == "$(golden "I revised the plan. Re-review the file at ${P} (and GLOSSARY.md or CONTEXT.md / docs/adr / any repo files you need; you are read-only). ${TOOLS} Check whether your prior findings are addressed and flag anything new. Same rules as before. Do NOT modify any files. End your reply with EXACTLY one line: VERDICT: APPROVED or VERDICT: REVISE." --resume '<uuid>')" ]] && echo yes || echo no)"

# --smoke is untouched by --oracle: its own short prompt, a fresh session.
rm -f "$TMP/argv"
(cd "$REPO" && GROK_BIN="$TMP/grok" GROK_REVIEW_OUT="$TMP/verdict.md" "$HERE/grok-review.sh" --smoke) >"$TMP/out" 2>&1
check "smoke: its own prompt" yes "$(argv_has 'PONG grok-4.7')"
check "smoke: low effort" yes "$(argv_line | LC_ALL=C grep -q -- '--reasoning-effort low' && echo yes || echo no)"
check "smoke: the full read-only flag set" yes "$(flags_ok)"

# Usage errors: each exits 2 with its own reason, before any call to Grok.
# usage_case <name> <stderr reason> <args...>, run in $O.
usage_case() {
  local name="$1" reason="$2"
  shift 2
  rm -f "$TMP/argv"
  (cd "$O" && GROK_BIN="$TMP/grok" "$HERE/grok-review.sh" "$@") >"$TMP/out" 2>&1 && rc=0 || rc=$?
  check "usage: $name: exit 2" 2 "$rc"
  check "usage: $name: says why" yes "$(LC_ALL=C grep -q -F -- "$reason" "$TMP/out" && echo yes || echo no)"
  check "usage: $name: Grok never called" no "$([[ -f "$TMP/argv" ]] && echo yes || echo no)"
}
good_goals
usage_case "--oracle without a plan" "--oracle needs the plan path" --oracle
usage_case "--fork" "--fork is not supported" --oracle --fork 11111111-2222-3333-4444-555555555555 docs/feat/PLAN.md
usage_case "--smoke with --oracle" "--smoke and --oracle do not combine" --smoke --oracle docs/feat/PLAN.md
usage_case "--oracle on a missing plan" "plan not found: docs/feat/NOPE.md" --oracle docs/feat/NOPE.md
# Usage is decided before Grok is looked for: the same answer without one.
rm -f "$TMP/argv"
(cd "$O" && HOME="$TMP/nohome" PATH=/usr/bin:/bin GROK_BIN="$TMP/no-such-grok" "$HERE/grok-review.sh" --oracle) >"$TMP/out" 2>&1 && rc=0 || rc=$?
check "usage: no Grok installed, still a usage error" 2 "$rc"
mv "$O/docs/feat/PLAN-REVIEW-LOG.md" "$TMP/log.bak"
usage_case "no review log" "no PLAN-REVIEW-LOG.md beside" --oracle docs/feat/PLAN.md
mv "$TMP/log.bak" "$O/docs/feat/PLAN-REVIEW-LOG.md"
mv "$O/GOALS.md" "$TMP/GOALS.bak"
usage_case "no GOALS.md" "no GOALS.md in" --oracle docs/feat/PLAN.md
mv "$TMP/GOALS.bak" "$O/GOALS.md"
mv "$O/tests/acceptance/g0_other.py" "$TMP/g0_other.py"
usage_case "a listed file missing" "listed for review but missing: tests/acceptance/g0_other.py" --oracle docs/feat/PLAN.md
mv "$TMP/g0_other.py" "$O/tests/acceptance/g0_other.py"
goals_md tests/acceptance/g1_new.c 'applied to the old parser test.' 'None.'
usage_case "an edits section with no path" "g1-new: the Acceptance edits section names no tests/acceptance/ path" --oracle docs/feat/PLAN.md
goals_md tests/acceptance/g1_new.c '' 'None.'
usage_case "an empty edits section" "g1-new: the Acceptance edits section names no tests/acceptance/ path" --oracle docs/feat/PLAN.md
goals_md tests/acceptance/g1_new.c 'None.' 'None.' docs/other/PLAN.md
usage_case "GOALS.md cut from another plan" "GOALS.md names plan: docs/other/PLAN.md" --oracle docs/feat/PLAN.md
printf '# Goals\n\nno fence here\n' >"$O/GOALS.md"
usage_case "GOALS.md that does not parse" "does not parse" --oracle docs/feat/PLAN.md
good_goals
python3 - "$O/GOALS.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s[: s.index("## g2-inline")])
PY
usage_case "a goal with no section" "g2-inline: no ## g2-inline section" --oracle docs/feat/PLAN.md

# A crash in the file lister is not dressed up as a usage error.
good_goals
chmod 000 "$O/GOALS.md"
(cd "$O" && GROK_BIN="$TMP/grok" "$HERE/grok-review.sh" --oracle docs/feat/PLAN.md) >"$TMP/out" 2>&1 && rc=0 || rc=$?
chmod 644 "$O/GOALS.md"
check "crash: an unreadable GOALS.md exits non-zero, not 2" yes "$([[ $rc -ne 0 && $rc -ne 2 ]] && echo yes || echo no)"

# An all-inline DAG reviews the case tables in GOALS.md.
goals_md inline 'None.' 'None.'
rm -f "$TMP/argv"
oracle_review docs/feat/PLAN.md >"$TMP/out" 2>&1 && rc=0 || rc=$?
check "all inline: exit 0" 0 "$rc"
check "all inline: points at the case tables" yes "$(argv_has "none: every goal's oracle is inline")"

# A hung round is void, not waited on for ever (FUTURE-WORK 11.1). The fake
# grok leaves a child behind it, which must die with the round.
hung_grok() {
  # Hung for 20 s, so a missing stop fails the checks instead of hanging them.
  printf '#!/usr/bin/env bash\n%s\n' \
    "echo \$PPID >$(printf %q "$TMP/watcher")" \
    "sleep 20 & echo \$! >$(printf %q "$TMP/child")" \
    'wait' >"$TMP/grok"
  chmod +x "$TMP/grok"
  rm -f "$TMP/child" "$TMP/watcher"
}
child_gone() {
  local pid; pid="$(cat "$TMP/child" 2>/dev/null)"
  [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null && echo yes || echo "no: ${pid:-no pid}"
}

hung_grok
start=$SECONDS
GROK_REVIEW_TIMEOUT=2 review >"$TMP/out" 2>&1 && rc=0 || rc=$?
check "timeout: exit 124" 124 "$rc"
check "timeout: a void round" "error (timed out after 2s)" "$(line GROK_REVIEW_RESULT)"
check "timeout: no verdict" MISSING "$(line VERDICT)"
check "timeout: stopped near the cap" yes "$([[ $((SECONDS - start)) -lt 15 ]] && echo yes || echo no)"
check "timeout: grok's child is gone" yes "$(child_gone)"
helper=yes
for _ in $(seq 25); do
  pgrep -f "^/usr/bin/caffeinate -i $TMP/grok" >/dev/null || { helper=gone; break; }
  sleep 0.2
done
check "timeout: caffeinate's helper is gone" gone "$helper"

# The host slept: the watcher is stopped for longer than the gap, as a sleeping
# Mac stops it, and the round is void when it runs again.
hung_grok
(GROK_REVIEW_TIMEOUT=0 GROK_REVIEW_SLEEP_GAP=2 review >"$TMP/out" 2>&1 && rc=0 || rc=$?; echo "$rc" >"$TMP/rc") &
waiter=$!
# grok's parent is the watcher (caffeinate execs grok).
for _ in $(seq 50); do
  [[ -s "$TMP/child" ]] && break
  sleep 0.2
done
if [[ -x /usr/bin/caffeinate ]]; then
  # caffeinate execs grok; a forked helper with the same arguments holds the
  # assertion. pmset cuts the "on behalf of <path> (pid N)" detail of a long
  # path, so the helper is found by its arguments and the assertion by its pid.
  awake=no
  for _ in $(seq 50); do
    helper="$(pgrep -f "^/usr/bin/caffeinate -i $TMP/grok" | head -n1 || true)"
    # To a file first: under pipefail, grep -q quitting early fails the pipe.
    pmset -g assertions >"$TMP/pmset" 2>/dev/null || true
    if [[ -n "$helper" ]] && grep -q "pid $helper(caffeinate).*PreventUserIdleSystemSleep" "$TMP/pmset"; then
      awake=yes; break
    fi
    sleep 0.2
  done
  check "the round runs under caffeinate -i" yes "$awake"
fi
watcher="$(cat "$TMP/watcher")"
check "slept: the watcher is run-timeout.py" yes "$(ps -o command= -p "$watcher" | grep -q 'run-timeout.py --wall 2 0' && echo yes || echo no)"
kill -STOP "$watcher"; sleep 4; kill -CONT "$watcher"
wait "$waiter"
check "slept: exit 125" 125 "$(cat "$TMP/rc")"
check "slept: a void round" "error (host slept)" "$(line GROK_REVIEW_RESULT)"
check "slept: grok's child is gone" yes "$(child_gone)"

# A hangup (the terminal closed) stops the command's whole session too.
rm -f "$TMP/child"
python3 "$HERE/lib/run-timeout.py" --wall 0 0 sh -c "sleep 20 & echo \$! >$(printf %q "$TMP/child"); wait" &
hup=$!
for _ in $(seq 25); do [[ -s "$TMP/child" ]] && break; sleep 0.2; done
kill -HUP "$hup"
wait "$hup" && rc=0 || rc=$?
check "SIGHUP: exit 129" 129 "$rc"
check "SIGHUP: the command's child is gone" yes "$(child_gone)"

# GAP 0 turns the sleep check off.
python3 "$HERE/lib/run-timeout.py" --wall 0 5 sleep 2 && rc=0 || rc=$?
check "--wall 0: no sleep check, the command's status" 0 "$rc"

# Without --wall, run-timeout.py is unchanged for its other callers.
python3 "$HERE/lib/run-timeout.py" 1 sleep 5 && rc=0 || rc=$?
check "run-timeout without --wall: 124 at the cap" 124 "$rc"
python3 "$HERE/lib/run-timeout.py" 0 sh -c 'exit 3' && rc=0 || rc=$?
check "run-timeout without --wall: the command's status" 3 "$rc"

if [[ "$fails" -eq 0 ]]; then
  echo "grok-review: OK"
else
  echo "grok-review: $fails FAILURE(S)" >&2
  exit 1
fi
