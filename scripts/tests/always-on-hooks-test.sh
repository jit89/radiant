#!/usr/bin/env bash
# Self-test: the walker hooks the always-on supervisor relies on
# (docs/features/always-on, slice 1): the spend ledger (lib/always-on-spend.py),
# the reviewer launcher's CLAUDE_REVIEW_COST / CLAUDE_REVIEW_RAW lines,
# run-goal.sh's cost observations and stand-ins, a reviewer stop naming the
# reviewer's raw output, the serial walker's spend and kill-file gate, and
# DECIDER records walker-only in journal-merge.py. Launchers are stubs; nothing
# calls a model.
set -euo pipefail
# Mutation checks off here (docs/features/mutation-checks; mutation-test.sh turns them on).
export CW_MUTATIONS=0

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-ao-hooks-XXXXXX")"
export TMPDIR="$TMP"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" EVENTS_CACHE="$TMP/cache"
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
export DEEPSEEK_API_KEY=stub-not-a-key DEEPSEEK_TIMEOUT=2 CLAUDE_REVIEW_TIMEOUT=2
unset ANTHROPIC_API_KEY CW_ALWAYS_ON_LEDGER CW_ALWAYS_ON_ENTRY CW_ALWAYS_ON_STOP
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

SPEND="$HERE/lib/always-on-spend.py"
total() { python3 "$SPEND" sum "$1" "$2" | python3 -c "import json,sys; d=json.load(sys.stdin); print(round(d[sys.argv[1]], 4))" "$3"; }

echo "== 1. the spend ledger (observations, amounts derived at read time) =="
L="$TMP/ledger1/spend.jsonl"
python3 "$SPEND" observe "$L" e1 reviewer s1 1.0
python3 "$SPEND" observe "$L" e1 reviewer s1 3.0
python3 "$SPEND" observe "$L" e1 reviewer s1 3.0
check "a resumed session observed at 1, 3, 3 adds 3" 3.0 "$(total "$L" e1 entry_usd)"
python3 "$SPEND" bump "$L" e1 stand-in s1 1.0
python3 "$SPEND" observe "$L" e1 reviewer s1 4.5
check "a stand-in, then the resumed session's own total, counts once" 4.5 "$(total "$L" e1 entry_usd)"
python3 "$SPEND" observe "$L" e2 decider d1 0.25
check "entries are summed apart" "4.5 0.25" "$(total "$L" e1 entry_usd) $(total "$L" e2 entry_usd)"
check "the day sums every entry" 4.75 "$(total "$L" e2 day_usd)"
python3 -c "import json,time; print(json.dumps({'ts': time.time()-2*86400, 'entry': 'e9', 'kind': 'x', 'id': 'old', 'cumulative_usd': 7.0}))" >>"$L"
check "a cost two days old is in the week, not the day" "4.75 11.75" "$(total "$L" e2 day_usd) $(total "$L" e2 week_usd)"
rc=0; python3 "$SPEND" check "$L" e1 --walk 4 >/dev/null || rc=$?
check "over a ceiling: exit 3, a halt file" "3 yes" "$rc $([[ -f "$TMP/ledger1/halt" ]] && echo yes || echo no)"
rc=0; python3 "$SPEND" check "$L" e1 --week 100 >/dev/null || rc=$?
check "back under: exit 0, the halt removed" "0 no" "$rc $([[ -f "$TMP/ledger1/halt" ]] && echo yes || echo no)"
touch "$TMP/STOP"
rc=0; python3 "$SPEND" check "$L" e1 --stop "$TMP/STOP" >/dev/null || rc=$?
check "the kill file: exit 4" 4 "$rc"
rm -f "$TMP/STOP"
rc=0; python3 "$SPEND" observe "$L" e1 x y abc 2>/dev/null || rc=$?
check "a cost that is not a number is refused" 2 "$rc"
L2="$TMP/ledger2/spend.jsonl"
python3 "$SPEND" observe "$L2" e1 x a 1
echo '{"ts": 1}' >>"$L2"
rc=0; python3 "$SPEND" check "$L2" e1 >/dev/null 2>&1 || rc=$?
check "a line that does not parse fails the check (no undefined sum passes)" 5 "$rc"
L2b="$TMP/ledger2b/spend.jsonl"
python3 "$SPEND" observe "$L2b" e1 x a 1
echo '{"ts": 1, "entry": "e1", "kind": "x", "id": "b", "cumulative_usd": NaN}' >>"$L2b"
rc=0; python3 "$SPEND" check "$L2b" e1 >/dev/null 2>&1 || rc=$?
check "a NaN or negative cost fails the check" 5 "$rc"
L3="$TMP/ledger3/spend.jsonl"
for i in $(seq 1 40); do python3 "$SPEND" observe "$L3" e1 x "id$i" 0.01 & done
wait
check "40 concurrent appends: 40 whole lines" "40 40" \
  "$(wc -l <"$L3" | tr -d ' ') $(python3 -c 'import json,sys; print(sum(1 for l in open(sys.argv[1]) if json.loads(l)))' "$L3")"

echo "== 2. the reviewer launcher's cost and raw lines =="
FAKE_DIR="$TMP/fake"
FAKE="$TMP/claude"
cat >"$FAKE" <<'STUB'
#!/usr/bin/env bash
d="$FAKE_DIR"
n=$(( $(cat "$d/n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$d/n"
cat "$d/resp.$n"
[[ -f "$d/rc.$n" ]] && exit "$(cat "$d/rc.$n")"
exit 0
STUB
chmod +x "$FAKE"
reset() {
  rm -rf "$FAKE_DIR"; mkdir -p "$FAKE_DIR"
  local i=1
  for body in "$@"; do printf '%s\n' "$body" >"$FAKE_DIR/resp.$i"; i=$((i + 1)); done
}
printf 'GOAL: g1\n' >"$TMP/brief.md"
review() {
  env CLAUDE_REAL_BIN="$FAKE" CW_OUT_DIR="$TMP/rv" CLAUDE_REVIEW_OUT="$TMP/verdict.md" FAKE_DIR="$FAKE_DIR" \
    "$HERE/claude-goal-review.sh" "$@" "$TMP/brief.md" 2>/dev/null || true
}
mkdir -p "$TMP/rv"
reset '{"type":"result","is_error":false,"result":"Reviewed.\nVERDICT: DONE","session_id":"s-ok","total_cost_usd":0.42}'
out="$(review)"
check "an ok review prints its session's cost" yes "$(has 'CLAUDE_REVIEW_COST: s-ok 0.42' "$out")"
raw="$(sed -n 's/^CLAUDE_REVIEW_RAW: //p' <<<"$out")"
check "  ...and names its raw envelope, which exists" yes "$([[ -f "$raw" ]] && echo yes || echo "no: $raw")"
FLAG='{"type":"result","is_error":true,"result":"claude-opus-5-5'"'"'s safeguards flagged this message.","session_id":"s-flag","total_cost_usd":0.05}'
reset "$FLAG" '{"type":"result","is_error":false,"result":"VERDICT: DONE","session_id":"s-fb","total_cost_usd":0.4}'
out="$(review)"
check "a safety-flag retry: one cost line per call" "yes yes" \
  "$(has 'CLAUDE_REVIEW_COST: s-flag 0.05' "$out") $(has 'CLAUDE_REVIEW_COST: s-fb 0.4' "$out")"
reset '{"type":"result","is_error":true,"api_error_status":401,"result":"Invalid API key","session_id":"s-err","total_cost_usd":0}'
echo 1 >"$FAKE_DIR/rc.1"
out="$(review)"
check "an error review still prints its cost and raw lines" "yes yes yes" \
  "$(has 'CLAUDE_REVIEW_RESULT: error' "$out") $(has 'CLAUDE_REVIEW_COST: s-err 0' "$out") $(has 'CLAUDE_REVIEW_RAW: ' "$out")"

echo "== 3. run-goal.sh records costs only under the supervisor =="
HOUSE="$TMP/house"
mkdir -p "$HOUSE/scripts"
cp -R "$HERE/." "$HOUSE/scripts/"
stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$HOUSE/scripts/$1"
  chmod +x "$HOUSE/scripts/$1"
}
COMMIT='echo "$RANDOM" >>impl.txt && git add impl.txt && git commit -qm "wip(g1-store): impl"'
make_repo() {
  rm -rf "$TMP/repo"
  mkdir -p "$TMP/repo/docs/journal" && cd "$TMP/repo"
  git init -q
  cp "$HERE/../GOALS.example.md" GOALS.md
  printf '# Plan\n' >PLAN.md
  printf '# Journal: example\n' >docs/journal/example.md
  git add -- GOALS.md PLAN.md docs/journal/example.md
  git commit -q -m base
}
run_goal() {
  make_repo
  env "$@" "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 && rc=0 || rc=$?
  stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)"
  reason="$(sed -n 's/^- reason: //p' "$stop" 2>/dev/null || true)"
}
kinds() { python3 -c 'import json,sys; print(" ".join(sorted(json.loads(l)["kind"]+":"+json.loads(l)["id"]+"="+str(json.loads(l)["cumulative_usd"]) for l in open(sys.argv[1]))))' "$1" 2>/dev/null || echo none; }
IMPL_OK="$COMMIT"'
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: haiku:t1" "IMPLEMENTER_STATUS: DONE" "IMPLEMENTER_MODEL: stub" "IMPLEMENTER_COST_USD: 0.3" "IMPLEMENTER_COST_BASIS: thread"'
REVIEW_DONE='v="$(mktemp)"; printf "VERDICT: DONE\n" >"$v"
printf "%s\n" "CLAUDE_REVIEW_RESULT: ok" "SESSION_ID: s1" "VERDICT: DONE" "VERDICT_FILE: $v" "CLAUDE_REVIEW_MODEL: stub" "CLAUDE_REVIEW_COST: s1 0.7" "CLAUDE_REVIEW_RAW: $v"'
stub claude-implement.sh "$IMPL_OK"
stub claude-goal-review.sh "$REVIEW_DONE"
AO="$TMP/ao"
run_goal CW_ALWAYS_ON_LEDGER="$AO/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1
# The example goals' proof is `true`, not an executable proof: a DONE review
# ends done-refused by design; the costs are what this checks.
check "a reviewed goal: the implementer's thread and the review's session observed" \
  "done-refused implementer:haiku:t1=0.3 reviewer:s1=0.7" "$reason $(kinds "$AO/spend.jsonl")"
check "  ...under the entry" 1.0 "$(total "$AO/spend.jsonl" e1 entry_usd)"
rm -rf "$AO"
run_goal
check "no ledger without the supervisor" "done-refused no" "$reason $([[ -e "$AO" ]] && echo yes || echo no)"
stub claude-implement.sh "$COMMIT"'
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: haiku:t2" "IMPLEMENTER_STATUS: DONE" "IMPLEMENTER_MODEL: stub" "IMPLEMENTER_COST_USD: 0.2" "IMPLEMENTER_FALLBACK: deepseek -> haiku (refusal)" "IMPLEMENTER_FALLBACK_FROM: deepseek:t0 COST_USD=0.1 COST_BASIS=thread"'
run_goal CW_ALWAYS_ON_LEDGER="$AO/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1
check "a fallback pass: the primary's thread observed too" yes \
  "$(has 'implementer:deepseek:t0=0.1 implementer:haiku:t2=0.2' "$(kinds "$AO/spend.jsonl")")"
rm -rf "$AO"
stub claude-implement.sh "$IMPL_OK"
stub claude-goal-review.sh 'sleep 10'
run_goal CW_ALWAYS_ON_LEDGER="$AO/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1
check "a review killed by its timeout: a stand-in" "reviewer-timeout yes" \
  "$reason $(has 'stand-in:killed:g1-store:r0:reviewer' "$(kinds "$AO/spend.jsonl")")"
check "  ...of 1.00 beside the implementer's 0.3" 1.3 "$(total "$AO/spend.jsonl" e1 entry_usd)"
rm -rf "$AO"
stub claude-implement.sh 'sleep 10'
run_goal CW_ALWAYS_ON_LEDGER="$AO/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1 IMPLEMENTER_TIMEOUT=2
check "an implementer pass killed by its timeout: a stand-in of 0.50" "implementer-timeout 0.5" \
  "$reason $(total "$AO/spend.jsonl" e1 entry_usd)"
rm -rf "$AO"
stub claude-implement.sh "$IMPL_OK"
stub claude-goal-review.sh 'printf "%s\n" "CLAUDE_REVIEW_RESULT: error (exit 1)" "SESSION_ID: s9" "VERDICT: MISSING" "VERDICT_FILE: /x/raw-env" "CLAUDE_REVIEW_COST: s9 0" "CLAUDE_REVIEW_RAW: /x/raw-env"; exit 1'
run_goal CW_ALWAYS_ON_LEDGER="$AO/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1
check "a reviewer stop names the reviewer's raw envelope and its stderr" "reviewer-error yes yes" \
  "$reason $(has '- LOG: /x/raw-env' "$(cat "$stop")") $(has '- stderr: /x/raw-env.err' "$(cat "$stop")")"
stub claude-goal-review.sh "$REVIEW_DONE"
mkdir -p "$TMP/notafile"
run_goal CW_ALWAYS_ON_LEDGER="$TMP/notafile" CW_ALWAYS_ON_ENTRY=e1
check "an observation the ledger refuses stops the goal: budget" budget "$reason"

echo "== 3b. ordering, signals, resumed and limited calls, mutations =="
# A counter per stub: stub_seq NAME BODY1 BODY2 ... runs the Nth body on call N
# (the last body for later calls).
stub_seq() {
  local name="$1" i=1
  shift
  mkdir -p "$TMP/seq"
  rm -f "$TMP/seq/$name".*
  for body in "$@"; do printf '%s\n' "$body" >"$TMP/seq/$name.$i"; i=$((i + 1)); done
  stub "$name" 'n=$(( $(cat "'"$TMP"'/seq/'"$name"'.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"'"$TMP"'/seq/'"$name"'.n"
f="'"$TMP"'/seq/'"$name"'.$n"; [[ -f "$f" ]] || f="$(ls "'"$TMP"'/seq/'"$name"'".[0-9]* | sort -t. -k2 -n | tail -n1)"
source "$f"'
}
REVIEW_FIX='v="$(mktemp)"; printf "FIX: impl.txt:1 — wrong — change it\nVERDICT: FIX\n" >"$v"
printf "%s\n" "CLAUDE_REVIEW_RESULT: ok" "SESSION_ID: s1" "VERDICT: FIX" "VERDICT_FILE: $v" "CLAUDE_REVIEW_MODEL: stub" "CLAUDE_REVIEW_COST: s1 0.7" "CLAUDE_REVIEW_RAW: $v"'
# A tamper stop after the pass still records its cost: the .git check comes
# first, then the .claude one; the cost is read before both.
rm -rf "$AO"
stub claude-implement.sh 'git config cw.planted 1
'"$IMPL_OK"
stub claude-goal-review.sh "$REVIEW_DONE"
run_goal CW_ALWAYS_ON_LEDGER="$AO/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1
check "a .git tamper stop after the pass: the pass's cost still recorded" "git-metadata-tamper yes" \
  "$reason $(has 'implementer:haiku:t1=0.3' "$(kinds "$AO/spend.jsonl")")"
rm -rf "$AO"
stub claude-implement.sh 'mkdir -p .claude && echo "{}" >.claude/settings.json
'"$IMPL_OK"
run_goal CW_ALWAYS_ON_LEDGER="$AO/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1
check "  ...and a .claude tamper stop" "claude-config-tamper yes" \
  "$reason $(has 'implementer:haiku:t1=0.3' "$(kinds "$AO/spend.jsonl")")"
rm -rf "$AO"
# The reviewer's turn the same: a .git tamper after the review keeps its cost.
stub claude-implement.sh "$IMPL_OK"
stub claude-goal-review.sh 'git config cw.planted 1
'"$REVIEW_DONE"
run_goal CW_ALWAYS_ON_LEDGER="$AO/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1
check "a .git tamper stop after the review: the review's cost still recorded" "git-metadata-tamper yes" \
  "$reason $(has 'reviewer:s1=0.7' "$(kinds "$AO/spend.jsonl")")"
rm -rf "$AO"
# A refused observation is acted on only after both checks: a tamper wins,
# no wake is committed over the unverified .git, and the stop names the refusal.
stub claude-implement.sh 'git config cw.planted 1
'"$IMPL_OK"
stub claude-goal-review.sh "$REVIEW_DONE"
run_goal CW_ALWAYS_ON_LEDGER="$TMP/notafile" CW_ALWAYS_ON_ENTRY=e1
check "a refused observation and a .git tamper: the tamper's reason, no wake commit, the refusal named" \
  "git-metadata-tamper no yes" \
  "$reason $(git -C "$TMP/repo" log -1 --format=%s | grep -q 'orchestrator wake' && echo yes || echo no) $(has 'also: the always-on spend ledger refused' "$(cat "$stop")")"
# A TERM during the implementer's call: a stand-in.
stub claude-implement.sh 'touch "'"$TMP"'/impl-started"; sleep 30'
rm -f "$TMP/impl-started"
make_repo
env CW_ALWAYS_ON_LEDGER="$AO/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1 "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 &
rgpid=$!
for _ in $(seq 600); do [[ -f "$TMP/impl-started" ]] && break; sleep 0.1; done
kill -TERM "$rgpid"
wait "$rgpid" 2>/dev/null || true
check "a TERM during the implementer's call: a stand-in of 0.50" "yes 0.5" \
  "$(has 'stand-in:killed:g1-store:r0:implementer' "$(kinds "$AO/spend.jsonl")") $(total "$AO/spend.jsonl" e1 entry_usd)"
rm -rf "$AO"
# A killed resumed review: the stand-in goes on its session.
stub claude-implement.sh "$IMPL_OK"
stub_seq claude-goal-review.sh "$REVIEW_FIX" 'sleep 10'
run_goal CW_ALWAYS_ON_LEDGER="$AO/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1
check "a killed resumed review: the stand-in on its session (0.7 + 1.00)" "reviewer-timeout yes" \
  "$reason $(has 'stand-in:s1=1.7' "$(kinds "$AO/spend.jsonl")")"
check "  ...the timed-out review's stop names its own output" yes "$(has 'reviewer-r1.out' "$(sed -n 's/^- LOG: //p' "$stop")")"
rm -rf "$AO"
# Rate limits: no stand-in (no model ran); a limited review names its raw .err.
stub claude-implement.sh 'printf "%s\n" "IMPLEMENTER_RESULT: rate_limited (exit 75)"; exit 75'
run_goal CW_ALWAYS_ON_LEDGER="$AO/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1
check "an implementer rate limit: no stand-in" "rate_limited none" "$reason $(kinds "$AO/spend.jsonl")"
stub claude-implement.sh "$IMPL_OK"
stub claude-goal-review.sh 'printf "%s\n" "CLAUDE_REVIEW_RESULT: rate_limited (exit 75)" "SESSION_ID: s1" "VERDICT: MISSING" "VERDICT_FILE: /x/raw2" "CLAUDE_REVIEW_RAW: /x/raw2"; exit 75'
rm -rf "$AO"
run_goal CW_ALWAYS_ON_LEDGER="$AO/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1
check "a reviewer rate limit: no stand-in; the stop names the raw envelope's .err" "reviewer-rate-limited implementer:haiku:t1=0.3 yes" \
  "$reason $(kinds "$AO/spend.jsonl") $(has '- stderr: /x/raw2.err' "$(cat "$stop")")"
rm -rf "$AO"
# After a FIX round, an implementer stop names the implementer's log again.
stub_seq claude-implement.sh "$IMPL_OK" 'printf "%s\n" "IMPLEMENTER_RESULT: error (exit 1)" "THREAD_ID: haiku:t1" "LOG: /x/impl-log" "stderr: /x/impl-err"; exit 1'
stub_seq claude-goal-review.sh "$REVIEW_FIX"
run_goal CW_ALWAYS_ON_LEDGER="$AO/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1
check "after a FIX review, an implementer stop names the implementer's log" "implementer-error yes yes" \
  "$reason $(has '- LOG: /x/impl-log' "$(cat "$stop")") $(has '- stderr: /x/impl-err' "$(cat "$stop")")"
rm -rf "$AO"
# An executable proof makes the mutations turn run.
mutations_repo() {
  make_repo
  mkdir -p tests/acceptance && printf 'test -f impl.txt\n' >tests/acceptance/g1-store.sh
  sed -i '' '/id: g1-store/,/status:/{
s|proof: true|proof: bash tests/acceptance/g1-store.sh|
s|oracle: inline|oracle: tests/acceptance/g1-store.sh|
}' GOALS.md
  git add -A && git commit -qm "an executable proof"
}
# The mutations turn's cost is observed (an executable proof makes it run).
stub claude-implement.sh "$IMPL_OK"
stub claude-goal-review.sh 'if [[ " $* " == *" --mutations "* ]]; then m="$(mktemp)"; : >"$m"
printf "%s\n" "CLAUDE_REVIEW_RESULT: ok" "SESSION_ID: s1" "MUTATIONS_FILE: $m" "CLAUDE_REVIEW_MODEL: stub" "CLAUDE_REVIEW_COST: s1 0.9"; exit 0; fi
'"$REVIEW_DONE"
mutations_repo
env CW_MUTATIONS=1 CW_ALWAYS_ON_LEDGER="$AO/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1 "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 && rc=0 || rc=$?
check "the mutations turn's session cost observed (0.7, then 0.9: 0.2 more)" "0 yes 1.2" \
  "$rc $(has 'mutations:s1=0.9' "$(kinds "$AO/spend.jsonl")") $(total "$AO/spend.jsonl" e1 entry_usd)"
rm -rf "$AO"
# A refusal of the mutations turn's observation stops the goal budget, from
# inside run_mutations (the turn turns the ledger into a directory).
stub claude-goal-review.sh 'if [[ " $* " == *" --mutations "* ]]; then m="$(mktemp)"; : >"$m"; rm -f "'"$AO"'/spend.jsonl"; mkdir "'"$AO"'/spend.jsonl"
printf "%s\n" "CLAUDE_REVIEW_RESULT: ok" "SESSION_ID: s1" "MUTATIONS_FILE: $m" "CLAUDE_REVIEW_MODEL: stub" "CLAUDE_REVIEW_COST: s1 0.9"; exit 0; fi
'"$REVIEW_DONE"
mutations_repo
env CW_MUTATIONS=1 CW_ALWAYS_ON_LEDGER="$AO/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1 "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 && rc=0 || rc=$?
stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)"
check "a refused mutations-turn observation: the goal stops budget" "nonzero budget" \
  "$([[ "$rc" -ne 0 ]] && echo nonzero || echo 0) $(sed -n 's/^- reason: //p' "$stop" 2>/dev/null)"
rm -rf "$AO"
# The same with a .git tamper in that turn: the tamper wins, the refusal named.
stub claude-goal-review.sh 'if [[ " $* " == *" --mutations "* ]]; then m="$(mktemp)"; : >"$m"; git config cw.planted 1; mkdir -p "'"$AO"'"; rm -f "'"$AO"'/spend.jsonl"; mkdir "'"$AO"'/spend.jsonl"
printf "%s\n" "CLAUDE_REVIEW_RESULT: ok" "SESSION_ID: s1" "MUTATIONS_FILE: $m" "CLAUDE_REVIEW_MODEL: stub" "CLAUDE_REVIEW_COST: s1 0.9"; exit 0; fi
'"$REVIEW_DONE"
mutations_repo
env CW_MUTATIONS=1 CW_ALWAYS_ON_LEDGER="$AO/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1 "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 && rc=0 || rc=$?
stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)"
check "  ...and with a .git tamper in that turn: the tamper's reason, the refusal named" "git-metadata-tamper yes" \
  "$(sed -n 's/^- reason: //p' "$stop" 2>/dev/null) $(has 'also: the always-on spend ledger refused' "$(cat "$stop" 2>/dev/null)")"
rm -rf "$AO"
stub claude-goal-review.sh "$REVIEW_DONE"
# The legacy launcher prints no cost: refused under the supervisor.
make_repo
env IMPLEMENTER=codex CW_ALWAYS_ON_LEDGER="$AO/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1 "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 && rc=0 || rc=$?
check "IMPLEMENTER=codex under the supervisor: refused" "2 yes" "$rc $(has 'cannot run under the always-on supervisor' "$(cat "$TMP/out")")"

echo "== 4. the serial walker's gate =="
walk() {
  make_repo
  env "$@" "$HOUSE/scripts/run-goals.sh" >"$TMP/wout" 2>&1 && rc=0 || rc=$?
  stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/wout" | tail -n1)"
  reason="$(sed -n 's/^- reason: //p' "$stop" 2>/dev/null || true)"
}
CALLS="$TMP/calls"
stub claude-implement.sh 'echo x >>'"$CALLS"'
'"$IMPL_OK"
rm -f "$CALLS"
L4="$TMP/ao4/spend.jsonl"
python3 "$SPEND" observe "$L4" e1 x big 11
walk CW_ALWAYS_ON_LEDGER="$L4" CW_ALWAYS_ON_ENTRY=e1
check "over the day's ceiling: the walk stops budget, nothing dispatched" "budget no" \
  "$reason $([[ -s "$CALLS" ]] && echo yes || echo no)"
mkdir -p "$TMP/ao5"
touch "$TMP/ao5/STOP"
walk CW_ALWAYS_ON_LEDGER="$TMP/ao5/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1 CW_ALWAYS_ON_STOP="$TMP/ao5/STOP"
check "the kill file: the walk stops always-on-stop" always-on-stop "$reason"
rm -f "$CALLS"
walk CW_ALWAYS_ON_LEDGER="$TMP/ao6/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1
check "under every ceiling: the walk dispatches (and stops on the goal's own done-refused)" "done-refused yes" \
  "$reason $([[ -s "$CALLS" ]] && echo yes || echo no)"

walk IMPLEMENTER=codex CW_ALWAYS_ON_LEDGER="$TMP/ao7/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1
check "IMPLEMENTER=codex: the walk stops always-on-config before any record" "always-on-config base" \
  "$reason $(git -C "$TMP/repo" log -1 --format=%s)"
make_repo
env IMPLEMENTER=codex CW_ALWAYS_ON_LEDGER="$TMP/ao7/spend.jsonl" CW_ALWAYS_ON_ENTRY=e1 "$HOUSE/scripts/run-goals.sh" --jobs 2 >"$TMP/wout" 2>&1 || true
stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/wout" | tail -n1)"
check "  ...and under --jobs 2, before any wave" "always-on-config base" \
  "$(sed -n 's/^- reason: //p' "$stop" 2>/dev/null) $(git -C "$TMP/repo" log -1 --format=%s)"

echo "== 5. DECIDER and ARCHITECT always-on records are walker-only =="
J="$TMP/jm"
mkdir -p "$J"
printf '# J\n' >"$J/base"
printf '# J\n' >"$J/ours"
printf '# J\n\n## 2026-10-26T00:00:00Z — DECIDER rerun\n' >"$J/theirs"
rc=0; python3 "$HERE/lib/journal-merge.py" "$J/base" "$J/ours" "$J/theirs" g1-a "$J/merged" >"$J/out" 2>&1 || rc=$?
check "a goal's journal carrying a DECIDER record is refused, naming it" "nonzero yes" \
  "$([[ "$rc" -ne 0 ]] && echo nonzero || echo 0) $(has 'walker-only record (DECIDER)' "$(cat "$J/out")")"
printf '# J\n\n## 2026-10-26T00:00:00Z — ARCHITECT always-on resume\n' >"$J/theirs"
rc=0; python3 "$HERE/lib/journal-merge.py" "$J/base" "$J/ours" "$J/theirs" g1-a "$J/merged" >"$J/out" 2>&1 || rc=$?
check "  ...and an ARCHITECT always-on record" "nonzero yes" \
  "$([[ "$rc" -ne 0 ]] && echo nonzero || echo 0) $(has 'walker-only record (ARCHITECT always-on)' "$(cat "$J/out")")"

echo
if [[ "$fails" -eq 0 ]]; then
  echo "always-on-hooks-test: all passed"
else
  echo "always-on-hooks-test: $fails failed"
  exit 1
fi
