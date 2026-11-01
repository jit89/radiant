#!/usr/bin/env bash
# Self-test: a red host proof becomes a proof fix round (docs/features/proof-fix
# PLAN): a redacted, bounded excerpt goes back to the implementer inside the
# shared MAX_FIX_ROUNDS; a round that changes nothing outside the journal wakes
# proof-red; a resume after that stop proves before it dispatches; the
# implementer's folder holds no raw proof output. Launchers are stubs driven
# by a per-call plan; nothing calls a model.
set -euo pipefail
# Mutation checks off here (docs/features/mutation-checks; mutation-test.sh turns them on).
export CW_MUTATIONS=0

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-prooffix-XXXXXX")"
export TMPDIR="$TMP"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" EVENTS_CACHE="$TMP/cache" CALLS="$TMP/calls"
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
export DEEPSEEK_API_KEY=stub-not-a-key
unset ANTHROPIC_API_KEY MAX_FIX_ROUNDS PROOF_TIMEOUT
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

# Call N of the implementer does line N of $CALLS/ds.plan and keeps its
# handoff as $CALLS/handoff-<N>.md and the handoff's path as $CALLS/path-<N>.
#   ok       a code change (a line appended to impl.txt), committed; DONE
#   fix      FIXED appended to impl.txt, committed (turns the proof green)
#   break    impl.txt rewritten without FIXED, committed (turns it red)
#   same     no change; DONE
#   journal  one IMPLEMENTER record committed to the journal only; DONE
#   blocked  an uncommitted red test left behind; BLOCKED
#   rate       rate limited before any work
#   dirtyrate  an uncommitted edit left, then rate limited (a pass cut off)
cat >"$HOUSE/scripts/claude-implement.sh" <<'SH'
#!/usr/bin/env bash
n=$(( $(grep -c '^ds ' "$CALLS/log" 2>/dev/null || true) + 1 ))
echo "ds $*" >>"$CALLS/log"
cp "${!#}" "$CALLS/handoff-$n.md"
echo "${!#}" >"$CALLS/path-$n"
status=DONE
case "$(sed -n "${n}p" "$CALLS/ds.plan")" in
  ok) echo "pass $n" >>impl.txt && git add impl.txt && git commit -qm "wip(g1-store): pass $n" ;;
  fix) rm -f red.txt wip.txt; echo FIXED >>impl.txt && git add impl.txt && git commit -qm "wip(g1-store): fix" ;;
  break) echo "pass $n" >impl.txt && git add impl.txt && git commit -qm "wip(g1-store): break" ;;
  same) ;;
  journal)
    printf '\n## %s — IMPLEMENTER start g1-store\nnothing to change\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>docs/journal/example.md
    git add docs/journal/example.md && git commit -qm "wip(g1-store): journal" ;;
  blocked) echo red >red.txt; status=BLOCKED ;;
  rate) printf '%s\n' "IMPLEMENTER_RESULT: rate_limited (exit 75)" "THREAD_ID: t1"; exit 75 ;;
  dirtyrate) echo wip >wip.txt; printf '%s\n' "IMPLEMENTER_RESULT: rate_limited (exit 75)" "THREAD_ID: t1"; exit 75 ;;
  *) echo "IMPLEMENTER_RESULT: error (no plan for call $n)"; exit 1 ;;
esac
printf '%s\n' "IMPLEMENTER_RESULT: ok" "THREAD_ID: t1" "IMPLEMENTER_STATUS: $status" \
  "RETURN_HANDOFF: $(dirname "${!#}")/return-$(basename "${!#}")"
SH
cat >"$HOUSE/scripts/claude-goal-review.sh" <<'SH'
#!/usr/bin/env bash
n=$(( $(grep -c '^rv ' "$CALLS/log" 2>/dev/null || true) + 1 ))
echo "rv $*" >>"$CALLS/log"
step="$(sed -n "${n}p" "$CALLS/rv.plan")"
case "$step" in
  done)
    printf 'Reviewed.\nVERDICT: DONE\n' >"$CALLS/verdict-$n.md"
    printf '%s\n' "CLAUDE_REVIEW_RESULT: ok" "SESSION_ID: s1" "VERDICT: DONE" \
      "VERDICT_FILE: $CALLS/verdict-$n.md" ;;
  fix-*)
    printf 'FIX: impl.txt:1 — wrong — apply %s\nVERDICT: FIX\n' "$step" >"$CALLS/verdict-$n.md"
    printf '%s\n' "CLAUDE_REVIEW_RESULT: ok" "SESSION_ID: s1" "VERDICT: FIX" \
      "VERDICT_FILE: $CALLS/verdict-$n.md" ;;
  *) echo "CLAUDE_REVIEW_RESULT: error (no plan)"; exit 1 ;;
esac
SH
chmod +x "$HOUSE/scripts/"*.sh

# The proof: green once impl.txt says FIXED or the "host" is fixed
# (.hostfixed, an ignored file in the repo: the proof sandbox lets a proof
# read its checkout, not the test's other folders). It prints a recognised secret (an AWS key id) first, so
# the raw log holds a secret the excerpt must not carry.
ORACLE_BODY='echo "proof: checking impl.txt"
echo "aws AKIAABCDEFGHIJKLMNOP"
if [ -n "${ZERO_FLAG:-}" ]; then echo "Ran 0 tests"; exit 0; fi
if [ -n "${NUL_FLAG:-}" ]; then printf "raw\\0byte\\n"; fi
[ -f .hostfixed ] && exit 0
grep -q FIXED impl.txt || { echo "FAIL: impl.txt is not FIXED"; exit 3; }'

# fresh <ds plan> <rv plan>: new repo, new cache, run once.
fresh() {
  rm -rf "$TMP/repo" "$CALLS" "$HOME/.cache"
  mkdir -p "$TMP/repo/docs/journal" "$TMP/repo/tests/acceptance" "$CALLS" && cd "$TMP/repo"
  git init -q
  sed -e '/id: g1-store/,/status:/{
s|proof: true|proof: bash tests/acceptance/g1-store.sh|
s|oracle: inline|oracle: tests/acceptance/g1-store.sh|
}' "$HERE/../GOALS.example.md" >GOALS.md
  printf '# Plan\n' >PLAN.md
  printf '%s\n' "$ORACLE_BODY" >tests/acceptance/g1-store.sh
  printf 'start\n' >impl.txt
  printf '# Journal: example\n' >docs/journal/example.md
  printf '.hostfixed\n' >.gitignore
  git add -A && git commit -q -m base
  printf '%s\n' $1 >"$CALLS/ds.plan"
  printf '%s\n' $2 >"$CALLS/rv.plan"
  run
}
run() {
  "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 || true
  local stop
  stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)"
  reason="$(sed -n 's/^- reason: //p' "$stop" 2>/dev/null || true)"
  detail="$(sed -n 's/^- detail: //p' "$stop" 2>/dev/null || true)"
  done_="$(grep -q '^GOAL g1-store DONE' "$TMP/out" && echo yes || echo no)"
}
calls() { grep -c "^$1 " "$CALLS/log" 2>/dev/null || true; }
has() { grep -q -- "$1" "$2" 2>/dev/null && echo yes || echo no; }
has_detail() { [[ "$detail" == *"$1"* ]] && echo yes || echo "no: $detail"; }
fix_lines() { grep -c "ORCHESTRATOR fix g1-store" docs/journal/example.md || true; }
fix_line() { grep "ORCHESTRATOR fix g1-store r$1 " docs/journal/example.md | tail -n1; }
findings_hash() { awk 'f { print } /^## Findings$/ { f = 1 }' "$1" | shasum -a 256 | awk '{print $1}'; }
art() { echo "$HOME/.cache/claude-coding-workflow/run-goal-g1-store"; }

echo "== 1. red, then a proof fix that turns it green, then review =="
fresh "ok fix" "done"
check "done" yes "$done_"
check "two implementer passes" 2 "$(calls ds)"
check "one review" 1 "$(calls rv)"
check "the fix line is a proof fix" yes "$([[ "$(fix_line 0)" == *"count=1 "*"source=proof head="* ]] && echo yes || echo "no: $(fix_line 0)")"
check "the journaled hash is the handoff's findings" \
  "$(findings_hash "$CALLS/handoff-2.md")" "$(fix_line 0 | sed -n 's/.*hash=\([0-9a-f]*\).*/\1/p')"
check "handoff titled as a red proof" yes "$(has '(after round 0: red host proof)' "$CALLS/handoff-2.md")"
check "handoff names the blocker rule by its step" yes "$(has 'report BLOCKED with the exact question (step 8)' "$CALLS/handoff-2.md")"
check "handoff names the contract by its step" yes "$(has '(step 5 of your instructions)' "$CALLS/handoff-2.md")"
check "handoff says the host ran it outside the sandbox" yes "$(has 'outside your sandbox, and it failed' "$CALLS/handoff-2.md")"
check "handoff names what differs on the host" yes "$(has 'environment variables, $TMPDIR, network access, and the proof sandbox' "$CALLS/handoff-2.md")"
check "handoff points at the denial listing" yes "$(has 'its denials, if any, are listed' "$CALLS/handoff-2.md")"
check "handoff's DONE keeps the journal records" yes "$(has 'DONE without changing any file but the journal' "$CALLS/handoff-2.md")"
check "handoff carries the failure" yes "$(has 'FAIL: impl.txt is not FIXED' "$CALLS/handoff-2.md")"
check "handoff carries the exit code" yes "$(has 'exited 3' "$CALLS/handoff-2.md")"
check "a nonzero exit gets no Ran-0-tests line" no "$(has 'which the host counts as a' "$CALLS/handoff-2.md")"
check "the secret is redacted" no "$(has 'AKIAABCDEFGHIJKLMNOP' "$CALLS/handoff-2.md")"
# At least one: the denial listing appended to a red proof is system-wide (other
# tests' sandboxed proofs under run-all -j N land in it, and a long random
# token there is redacted too). Exact counts are pinned on proof-excerpt.py
# alone in section 12.
check "the redaction is counted" yes "$(grep -Eq '^([1-9][0-9]* values|1 value) redacted\.' "$CALLS/handoff-2.md" && echo yes || echo no)"
check "the fix is saved for a resume" yes "$([[ -f "$(art)/fix-r0.md" ]] && echo yes || echo no)"

echo "== 2. a proof fix round that changes nothing: proof-red, no more rounds =="
fresh "ok same" ""
check "proof-red" proof-red "$reason"
check "names the no-progress rule" yes "$(has_detail 'no change since the red proof at r0')"
check "two passes, no third" 2 "$(calls ds)"
check "no review" 0 "$(calls rv)"
# A stop keeps the run folder: what the implementer was given is still there.
IMPL="$(dirname "$(cat "$CALLS/path-1")")"
check "the implementer folder is kept" yes "$([[ -d "$IMPL" ]] && echo yes || echo no)"
check "first handoff in a handoffs/ folder, outside the run folder" handoffs "$(basename "$(dirname "$IMPL")")"
check "fix handoff in the same folder" "$IMPL" "$(dirname "$(cat "$CALLS/path-2")")"
check "no raw proof log there" 0 "$(find "$IMPL" -name 'proof-*' | wc -l | tr -d ' ')"
check "the secret appears nowhere there" no "$(grep -rq AKIAABCDEFGHIJKLMNOP "$IMPL" && echo yes || echo no)"
check "it is in the raw log, in the run folder" yes "$(grep -q AKIAABCDEFGHIJKLMNOP "$HOME/.cache/claude-coding-workflow/runs"/run-goal-g1-store-*/proof-* && echo yes || echo no)"

echo "== 3. a journal-only commit is not progress =="
fresh "ok journal" ""
check "proof-red" proof-red "$reason"
check "names the no-progress rule" yes "$(has_detail 'the host and the sandbox may disagree')"

echo "== 4. progress resets the rule: another proof fix =="
fresh "ok ok fix" "done"
check "done" yes "$done_"
check "two proof fixes" 2 "$(fix_lines)"
check "the second is r1" yes "$([[ "$(fix_line 1)" == *"source=proof"* ]] && echo yes || echo no)"

echo "== 5. the shared budget =="
export MAX_FIX_ROUNDS=1
fresh "ok ok ok" ""
check "cap 1: max-fix-rounds" max-fix-rounds "$reason"
check "cap 1: after a red proof" yes "$(has_detail 'after a red proof')"
check "cap 1: one repair" 2 "$(calls ds)"
export MAX_FIX_ROUNDS=0
fresh "ok" ""
check "cap 0: max-fix-rounds on the first red" max-fix-rounds "$reason"
check "cap 0: no repair" 1 "$(calls ds)"
unset MAX_FIX_ROUNDS

echo "== 6. a review fix, then a red proof: one counter =="
fresh "fix break fix" "fix-A done"
check "done" yes "$done_"
check "r0 is a review fix" yes "$([[ "$(fix_line 0)" == *"source=review"* ]] && echo yes || echo "no: $(fix_line 0)")"
check "r1 is a proof fix" yes "$([[ "$(fix_line 1)" == *"source=proof"* ]] && echo yes || echo "no: $(fix_line 1)")"
check "the review fix handoff is under handoffs/" handoffs "$(basename "$(dirname "$(dirname "$(cat "$CALLS/path-2")")")")"
check "the repair after it is r2" yes "$(grep -q 'ORCHESTRATOR dispatch g1-store r2 ' docs/journal/example.md && echo yes || echo no)"

echo "== 7. BLOCKED in a proof fix round, then a resume =="
fresh "ok blocked fix" "done"
check "implementer-blocked" implementer-blocked "$reason"
run
check "resume: dispatched, not proved first" 3 "$(calls ds)"
check "resume: not a dirty-tree stop" yes "$([[ "$reason" != dirty-tree ]] && echo yes || echo "no: $reason")"
check "resume: done" yes "$done_"
check "resume: the same findings" "$(findings_hash "$CALLS/handoff-2.md")" "$(findings_hash "$CALLS/handoff-3.md")"

echo "== 8. interrupted before the proof fix ran, then a resume =="
fresh "ok rate fix" "done"
check "rate_limited" rate_limited "$reason"
run
check "resume: dispatched" 3 "$(calls ds)"
check "resume: the same findings" "$(findings_hash "$CALLS/handoff-2.md")" "$(findings_hash "$CALLS/handoff-3.md")"
check "resume: done" yes "$done_"

echo "== 9. a resume after the no-progress stop proves first =="
fresh "ok same fix" "done"
check "stuck" proof-red "$reason"
run
check "unchanged: proof-red again" proof-red "$reason"
check "unchanged: nothing dispatched" 2 "$(calls ds)"
touch "$TMP/repo/.hostfixed"
run
check "host fixed: done" yes "$done_"
check "host fixed: nothing dispatched" 2 "$(calls ds)"
check "host fixed: reviewed" 1 "$(calls rv)"
# The same proof-first resume with the sandbox off (the user's opt-out): the
# override is journaled before the proof's snapshot, so it is not tampering.
fresh "ok same fix" "done"
check "stuck (sandbox off case)" proof-red "$reason"
touch "$TMP/repo/.hostfixed"
CW_PROOF_SANDBOX=off run
check "proof-first resume, sandbox off: done" yes "$done_"
check "proof-first resume, sandbox off: the override journaled" yes \
  "$(grep -q 'ORCHESTRATOR overrides g1-store proof-sandbox=off' docs/journal/example.md && echo yes || echo no)"
fresh "ok same fix" "done"
echo "by hand" >>notes.txt && git add notes.txt && git commit -qm "a person's change"
run
check "changed: the pending fix is dispatched" 3 "$(calls ds)"
check "changed: its findings" "$(findings_hash "$CALLS/handoff-2.md")" "$(findings_hash "$CALLS/handoff-3.md")"
check "changed: done" yes "$done_"

echo "== 10. a tampered saved fix stops at the gate =="
fresh "ok rate" ""
printf 'tampered\n' >>"$(art)/fix-r0.md"
run
check "gate" gate "$reason"
check "nothing dispatched" 2 "$(calls ds)"

echo "== 11. Ran 0 tests with exit 0 is red =="
export ZERO_FLAG=1
fresh "ok same" ""
unset ZERO_FLAG
check "a proof fix was issued" yes "$([[ "$(fix_line 0)" == *"source=proof"* ]] && echo yes || echo "no: $(fix_line 0)")"
check "the excerpt shows it" yes "$(has 'Ran 0 tests' "$CALLS/handoff-2.md")"
check "the handoff says why exit 0 is red" yes "$(has 'which the host counts as a' "$CALLS/handoff-2.md")"

echo "== 13. interrupted, resumed, then no change: the saved head still judges =="
fresh "ok rate same" ""
check "rate_limited" rate_limited "$reason"
run
check "resume: proof-red" proof-red "$reason"
check "resume: the no-progress rule" yes "$(has_detail 'no change since the red proof at r0')"

echo "== 14. a pass cut off with edits in the tree, then a resume =="
fresh "ok dirtyrate fix" "done"
check "rate_limited" rate_limited "$reason"
run
check "resume: dispatched" 3 "$(calls ds)"
check "resume: done, not dirty-tree" yes "$done_"

echo "== 15. the resume cap names a pending proof fix =="
fresh "ok rate" ""
MAX_FIX_ROUNDS=0 run
check "max-fix-rounds" max-fix-rounds "$reason"
check "after a red proof" yes "$(has_detail 'after a red proof')"
check "cites the saved fix" yes "$(has_detail 'run-goal-g1-store/fix-r0.md')"

echo "== 16. stuck, a person's change, a blocked pass, then a resume dispatches =="
fresh "ok same blocked fix" "done"
check "stuck" proof-red "$reason"
echo "by hand" >>notes.txt && git add notes.txt && git commit -qm "a person's change"
run
check "the pending fix ran and blocked" implementer-blocked "$reason"
run
check "resume: dispatched, not proved first" 4 "$(calls ds)"
check "resume: done" yes "$done_"

echo "== 17. NUL bytes in the proof output survive a resume =="
export NUL_FLAG=1
fresh "ok rate fix" "done"
unset NUL_FLAG
check "rate_limited" rate_limited "$reason"
run
check "resume: the saved fix passes the hash gate" yes "$done_"
check "no NUL in the handoff" no "$(python3 -c 'import sys; print("yes" if b"\0" in open(sys.argv[1],"rb").read() else "no")' "$CALLS/handoff-2.md")"

echo "== 18. an excerpt that cannot be built stops with its own reason =="
cp "$HOUSE/scripts/lib/proof-excerpt.py" "$TMP/proof-excerpt.py.real"
printf '%s\n' '#!/usr/bin/env python3' 'import sys; sys.exit(1)' >"$HOUSE/scripts/lib/proof-excerpt.py"
fresh "ok" ""
check "proof-excerpt-error" proof-excerpt-error "$reason"
check "names the raw output" yes "$(has_detail 'Output: ')"
check "no fix line" 0 "$(fix_lines)"
cp "$TMP/proof-excerpt.py.real" "$HOUSE/scripts/lib/proof-excerpt.py"

echo "== 12. the excerpt: redact whole, then cut =="
EX="$HERE/lib/proof-excerpt.py"
X="$TMP/excerpt"
mkdir -p "$X"
ex() { python3 "$EX" "$1" "bash t.sh" 1; }
bytes() { LC_ALL=C wc -c | tr -d ' '; }
KEY=sk-ant-api03-abcdefghijklmnopqrstuvwx
# A PEM block that starts in the kept head and ends in the dropped middle.
{ for i in $(seq 1 30); do echo "head $i"; done
  echo "-----BEGIN RSA PRIVATE KEY-----"
  for i in $(seq 1 50); do echo "pemline-$i-secretmaterial"; done
  echo "-----END RSA PRIVATE KEY-----"
  for i in $(seq 1 400); do echo "tail $i"; done; } >"$X/pem"
out="$(ex "$X/pem")"
check "PEM: no body line survives" no "$([[ "$out" == *pemline-* ]] && echo yes || echo no)"
check "PEM: the head is kept" yes "$([[ "$out" == *"head 30"* ]] && echo yes || echo no)"
check "PEM: the tail is kept" yes "$([[ "$out" == *"tail 400"* ]] && echo yes || echo no)"
# An unclosed BEGIN does not erase the failure after it.
{ echo "-----BEGIN PRIVATE KEY-----"
  echo "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7"
  echo "FAIL: want 3 got 4"; } >"$X/open"
out="$(ex "$X/open")"
check "unclosed BEGIN: the failure stays" yes "$([[ "$out" == *"FAIL: want 3 got 4"* ]] && echo yes || echo no)"
check "unclosed BEGIN: its body is redacted" no "$([[ "$out" == *MIIEvQIBADAN* ]] && echo yes || echo no)"
check "unclosed BEGIN: counted" yes "$([[ "$out" == *"2 values redacted."* ]] && echo yes || echo "no: $(head -3 <<<"$out")")"
# A key across the 2 KiB line cut, and one across the 16 KiB cut.
{ printf '%*s' 2040 '' | tr ' ' x; echo " $KEY"; } >"$X/longline"
out="$(ex "$X/longline")"
check "key across the line cut: no part of it" no "$([[ "$out" == *sk-ant-* ]] && echo yes || echo no)"
check "the line is truncated" yes "$([[ "$out" == *"[… line truncated …]"* ]] && echo yes || echo no)"
# A PEM block straddling the 16 KiB cut: long head lines, the block in the
# head, a tail that alone fills most of 16 KiB.
{ for i in $(seq 1 4); do printf '%*s\n' 900 "head $i"; done
  echo "-----BEGIN PRIVATE KEY-----"
  for i in $(seq 1 30); do printf 'pemline-%s-%s\n' "$i" "$(printf '%*s' 900 '' | tr ' ' x)"; done
  echo "-----END PRIVATE KEY-----"
  for i in $(seq 1 160); do printf '%*s\n' 95 "tail $i"; done
  echo "FAIL: the final summary"; } >"$X/total"
out="$(ex "$X/total")"
check "PEM across the 16 KiB cut: no body line" no "$([[ "$out" == *pemline-* ]] && echo yes || echo no)"
check "PEM across the 16 KiB cut: the last line survives" yes "$([[ "$out" == *"FAIL: the final summary"* ]] && echo yes || echo no)"
{ for i in $(seq 1 150); do printf '%*s\n' 150 "row $i"; done; echo "FAIL: short but wide"; } >"$X/shortwide"
check "200 lines or fewer: the last line survives the cut" yes "$([[ "$(ex "$X/shortwide")" == *"FAIL: short but wide"* ]] && echo yes || echo no)"
{ for i in $(seq 1 250); do printf '%*s\n' 150 "row $i"; done; echo "FAIL: the final summary"; } >"$X/wide"
out="$(ex "$X/wide")"
check "16 KiB cut noted" yes "$([[ "$out" == *"cut to 16 KiB"* ]] && echo yes || echo no)"
check "the last line survives the cut" yes "$([[ "$out" == *"FAIL: the final summary"* ]] && echo yes || echo no)"
check "the cut keeps it under 16 KiB plus the header" yes "$([[ $(bytes <<<"$out") -le 17000 ]] && echo yes || echo no)"
printf '"api_key": "%s"\n' "$KEY" >"$X/json"
check "one secret counts once" yes "$([[ "$(ex "$X/json")" == *"1 value redacted."* ]] && echo yes || echo no)"
{ echo "-----BEGIN PRIVATE KEY-----"; echo "FAIL: between the blocks"
  echo "-----BEGIN RSA PRIVATE KEY-----"; echo "pemline-inner"; echo "-----END RSA PRIVATE KEY-----"; } >"$X/twoblocks"
out="$(ex "$X/twoblocks")"
check "unclosed then closed: the line between survives" yes "$([[ "$out" == *"FAIL: between the blocks"* ]] && echo yes || echo no)"
check "unclosed then closed: the closed body goes" no "$([[ "$out" == *pemline-inner* ]] && echo yes || echo no)"
printf 'a\0b\x01c\td\n' >"$X/ctl"
check "control bytes replaced, tab kept" yes "$(ex "$X/ctl" | python3 -c 'import sys; b=sys.stdin.buffer.read(); print("yes" if b"\0" not in b and b"\x01" not in b and b"\t" in b else "no")')"
# Sizes.
seq 1 10000 | sed 's/^/line /' >"$X/many"
out="$(ex "$X/many")"
pat=$'line 40\n[… 9800 lines omitted …]\nline 9841'
check "10 000 lines: the first 40 and the last 160" yes "$([[ "$out" == *"$pat"* ]] && echo yes || echo no)"
check "10 000 lines: at most 16 KiB plus the header" yes "$([[ $(bytes <<<"$out") -le 17000 ]] && echo yes || echo no)"
head -c 1048576 /dev/zero | tr '\0' x >"$X/huge"
check "a 1 MiB line: at most 16 KiB plus the header" yes "$([[ $(ex "$X/huge" | bytes) -le 17000 ]] && echo yes || echo no)"
# The fence and bad bytes.
printf 'ok\n``````\nmore\n' >"$X/ticks"
check "backticks cannot close the fence" '```````' "$(ex "$X/ticks" | sed -n 5p)"
printf 'bad \xff\xfe bytes\n' >"$X/bad"
check "invalid UTF-8 does not crash it" yes "$(ex "$X/bad" >/dev/null 2>&1 && echo yes || echo no)"
check "the bare-hex rule stays" yes "$(printf 'sha %s\n' 0123456789abcdef0123456789abcdef01234567 >"$X/hex" && [[ "$(ex "$X/hex")" == *"sha [REDACTED]"* ]] && echo yes || echo no)"

if [[ "$fails" -eq 0 ]]; then
  echo "proof-fix: OK"
else
  echo "proof-fix: $fails FAILURE(S)" >&2
  exit 1
fi
