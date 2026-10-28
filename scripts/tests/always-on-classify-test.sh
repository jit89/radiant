#!/usr/bin/env bash
# Self-test: the always-on stop classification (docs/features/always-on, steps
# 7 and 7a; slice 2): lib/always-on-classes.tsv against the reasons the walker
# really writes, and lib/always-on-classify.py on real stop files — the
# step-0d 401 stops captured from run-goal.sh with an invalid key
# (fixtures/always-on/), and wave-stops the real walker writes here with stub
# launchers. No model is called.
set -euo pipefail
PW_NAME=aoclassify
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/parallel-walk-lib.sh"

CL="$HERE/lib/always-on-classify.py"
TSV="$HERE/lib/always-on-classes.tsv"
FIX="$HERE/tests/fixtures/always-on"
has() { [[ "$2" == *"$1"* ]] && echo yes || echo "no: $2"; }
# cls STOP [FIELD...] — the classification's fields, space-joined.
cls() {
  local f="$1"
  shift
  python3 "$CL" "$f" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(str(d[k]) for k in sys.argv[1:]))' "$@"
}
# A fixture's stop with its @DIR@ paths pointing at a copy: fixture NAME OUTDIR.
fixture() {
  mkdir -p "$2"
  cp "$FIX/$1/raw" "$FIX/$1/raw.err" "$2/"
  sed "s|@DIR@|$2|g" "$FIX/$1/stop.md" >"$2/stop.md"
}
# A single stop of REASON whose LOG is FILE (and stderr FILE.err): stop OUT REASON DETAIL LOGFILE.
stop() {
  printf '# Stop: g1-a\n\n- reason: %s\n- detail: %s\n- LOG: %s\n- stderr: %s\n' "$2" "$3" "$4" "${4:+$4.err}" >"$1"
}

echo "== 1. the table =="
cls_of() { python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("c", sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
t=m.load_table(sys.argv[2]); print(" ".join(m.class_of(r, t) for r in sys.argv[3:]))' "$CL" "$TSV" "$@"; }
check "one reason per class, a pattern, unknown and empty" "A A B C D wait F A A" \
  "$(cls_of budget contract-tamper-staged bounced implementer-error max-fix-rounds rate_limited finished-not-integrated no-such-reason '')"
# Every reason the walker writes is in the table, so none falls to A unread;
# every table entry is a reason the walker (or the supervisor) writes, so a
# typo cannot silently send a C reason to A.
emitted="$(cd "$HERE" && {
  grep -hoE '(wake|walk_stop|stop_unplanned) "?[a-z][a-z_-]+"?' run-goal.sh run-goals.sh lib/*.sh
  grep -hoE '(goal_stop|integration_stop|add_stop) "\$g" "?[a-z][a-z_-]+"?' lib/wave-walk.sh
  grep -hoE '(SETUP_REASON|PROOF_SANDBOX_REASON)="?[a-z][a-z_-]+' lib/*.sh
} | sed -E 's/.* "?([a-z][a-z_-]+)"?$/\1/; s/.*=//' | sort -u)"
# Prose the patterns also catch (a wake/walk_stop word in a comment).
prose=" could writes we this there stops still path leaves journal commits "
missing="$(python3 -c 'import importlib.util,sys
from fnmatch import fnmatchcase
s=importlib.util.spec_from_file_location("c", sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
exact, pats = m.load_table(sys.argv[2]); prose = set(sys.argv[3].split())
print(" ".join(r for r in sys.argv[4:] if r not in prose and r not in exact and not any(fnmatchcase(r, p) for p, _ in pats)))' "$CL" "$TSV" "$prose" $emitted)"
check "every reason the walker writes is in the table" "" "$missing"
extra=""
for r in $(grep -vE '^#|\*' "$TSV" | cut -f1); do
  case "$r" in claude-version-changed | contract-drift) continue ;; esac # the supervisor's / the plan's name for contract-tamper-*
  grep -rqE "[\"' =|]$r([\"' |);}]|$)" "$HERE/run-goal.sh" "$HERE/run-goals.sh" "$HERE/lib" --include='*.sh' || extra="$extra $r"
done
check "every table entry is a reason the walker writes" "" "$extra"

echo "== 2. the step-0d 401 stops (real, from run-goal.sh) =="
fixture reviewer-401 "$TMP/r401"
check "a reviewer-error whose envelope says 401: A budget, held" "A budget True reviewer-error" \
  "$(cls "$TMP/r401/stop.md" class reason hold) $(python3 "$CL" "$TMP/r401/stop.md" | python3 -c 'import json,sys; print(json.load(sys.stdin)["goals"][0]["reason"])')"
check "  ...the 401 named" yes "$(has 'api_error_status 401' "$(python3 "$CL" "$TMP/r401/stop.md")")"
fixture implementer-401 "$TMP/i401"
check "an implementer-error whose envelope says 401: A budget" "A budget" "$(cls "$TMP/i401/stop.md" class reason)"
# The same stop with the envelope gone (pruned): the class from the table alone.
rm "$TMP/i401/raw"
check "  ...its envelope gone: C implementer-error" "C implementer-error False" "$(cls "$TMP/i401/stop.md" class reason hold)"

echo "== 3. markers =="
D="$TMP/m"
mkdir -p "$D"
printf '%s\n' '{"type":"result","is_error":true,"api_error_status":402,"terminal_reason":"api_error","result":"API Error: 402 {\"error\":{\"message\":\"Insufficient Balance\",\"type\":\"insufficient_quota\"}}","session_id":"SID"}' >"$D/bal-num"
printf '%s\n' '{"type":"result","is_error":true,"api_error_status":"402","terminal_reason":"api_error","result":"API Error: 402 Insufficient Balance","session_id":"SID"}' >"$D/bal-str"
printf '%s\n' '{"type":"result","is_error":true,"api_error_status":429,"result":"API Error: 429 {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"spend limit reached\",\"details\":{\"error_code\":\"enforced_spend_limit_reached\"}}}","session_id":"SID"}' >"$D/spend-429"
printf '%s\n' '{"type":"result","is_error":false,"result":"The proof timed out. Note the billing_error case in the docs.","session_id":"SID"}' >"$D/ok-quotes"
printf '%s\n' '{"type":"result","is_error":true,"api_error_status":403,"result":"Forbidden","session_id":"SID"}' >"$D/forbidden"
printf '%s\n' '{"type":"result","is_error":true,"api_error_status":500,"result":"Internal server error","session_id":"SID"}' >"$D/e500"
printf 'garbage\n{"type":"system"}\n{"type":"result","is_error":true,"api_error_status":402,"result":"x"}\n' >"$D/stream"
for f in bal-num bal-str spend-429 ok-quotes forbidden e500 stream; do : >"$D/$f.err"; done
stop "$D/s1" implementer-declined "IMPLEMENTER_RESULT=balance (deepseek) — out of balance (DeepSeek 402)" "$D/bal-num"
check "a DeepSeek 402 (a number) on an implementer-declined: A budget" "A budget" "$(cls "$D/s1" class reason)"
stop "$D/s2" implementer-error "rc=1" "$D/bal-str"
check "  ...402 as a string" "A budget" "$(cls "$D/s2" class reason)"
stop "$D/s3" reviewer-rate-limited "" "$D/spend-429"
check "a 429 spend limit (the documented shape) is held, never waited on" "A budget" "$(cls "$D/s3" class reason)"
check "  ...found in the LOG envelope's text" "LOG: spend limit" \
  "$(python3 "$CL" "$D/s3" | python3 -c 'import json,sys; print(json.load(sys.stdin)["goals"][0]["billing"])')"
# Only the error envelopes are read: a successful one beside a 500 in the same
# stream, and the tool inputs in permission_denials, may quote anything.
printf '%s\n' '{"type":"result","is_error":false,"result":"Quoting: billing_error, spend limit."}' \
  '{"type":"result","is_error":true,"api_error_status":500,"result":"Internal server error"}' >"$D/mixed"
: >"$D/mixed.err"
stop "$D/s3b" reviewer-error "" "$D/mixed"
check "a stream: a successful envelope quoting markers beside a 500: stays C" "C reviewer-error" "$(cls "$D/s3b" class reason)"
printf '%s\n' '{"type":"result","subtype":"error_max_turns","is_error":true,"result":"","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"grep -rn \"spend limit\" ."}}]}' >"$D/denied"
: >"$D/denied.err"
stop "$D/s3c" reviewer-error "" "$D/denied"
check "an error envelope whose permission_denials quote a marker: stays C" "C reviewer-error" "$(cls "$D/s3c" class reason)"
printf '%s\n' '[{"type":"system"},{"type":"result","is_error":true,"api_error_status":402,"result":"x"}]' >"$D/array"
: >"$D/array.err"
stop "$D/s3d" implementer-error "" "$D/array"
check "a LOG that is a JSON array (json --verbose) with a 402: A budget" "A budget" "$(cls "$D/s3d" class reason)"
mkfifo "$D/fifo"
stop "$D/s3e" implementer-error "" "$D/fifo"
check "a LOG that is a FIFO: not read, no hang" "C implementer-error" \
  "$(python3 -c 'import subprocess,sys; print(subprocess.run(sys.argv[1:], capture_output=True, text=True, timeout=10).stdout)' python3 "$CL" "$D/s3e" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["class"], d["reason"])')"
stop "$D/s4" proof-timeout "" "$D/ok-quotes"
check "a successful envelope quoting billing_error: stays C" "C proof-timeout" "$(cls "$D/s4" class reason)"
printf '%s\n' '{"type":"result","is_error":true,"api_error_status":"401","result":"Unauthorized","session_id":"SID"}' >"$D/unauth-str"
: >"$D/unauth-str.err"
stop "$D/s4b" reviewer-error "" "$D/unauth-str"
check "a 401 as a string with no marker text: A budget" "A budget" "$(cls "$D/s4b" class reason)"
stop "$D/s5" reviewer-error "" "$D/forbidden"
check "a 403: A budget" "A budget" "$(cls "$D/s5" class reason)"
stop "$D/s6" reviewer-error "" "$D/e500"
check "a 500: stays C" "C reviewer-error" "$(cls "$D/s6" class reason)"
stop "$D/s7" implementer-error "" "$D/stream"
check "a stream with a 402 envelope among other lines: A budget" "A budget" "$(cls "$D/s7" class reason)"
stop "$D/s8" implementer-error "HEAD 4029abc1 moved; rc=1" ""
check "a hex sha containing 402 in the detail: not billing" "C implementer-error" "$(cls "$D/s8" class reason)"
stop "$D/s9" implementer-error "rc=1 API Error: Requires usage credits" ""
check "a marker on the detail line: A budget" "A budget" "$(cls "$D/s9" class reason)"
: >"$D/plain"
printf 'Error: Invalid API key\n' >"$D/plain.err"
stop "$D/s10" reviewer-error "" "$D/plain"
check "a marker in the stderr file: A budget" "A budget" "$(cls "$D/s10" class reason)"
printf '# Stop: g1-a\n\n- reason: reviewer-error\n- detail: x\n- utc: now\n- note: spend limit\n' >"$D/s11"
check "a marker elsewhere in the stop file is not read" "C reviewer-error" "$(cls "$D/s11" class reason)"

echo "== 4. single stops: walk stops, empty, unknown, unreadable =="
printf '# Stop: walk\n\n- reason: always-on-config\n- detail: IMPLEMENTER=codex\n' >"$D/w1"
check "a walk stop always-on-config: A" "A always-on-config True" "$(cls "$D/w1" class reason hold)"
printf '# Stop: g1-a\n\n- reason: \n- detail: x\n' >"$D/w2"
check "an empty reason: A" "A True" "$(cls "$D/w2" class hold)"
printf '# Stop: g1-a\n\n- reason: something-new\n' >"$D/w3"
check "an unknown reason: A" "A something-new" "$(cls "$D/w3" class reason)"
check "a stop file that cannot be read: A" "A stop-unreadable" "$(cls "$D/nope" class reason)"
rc=0; out="$(python3 "$CL" --table "$D/no-table" "$D/w4")" || rc=$?
check "a table that cannot be read: A classify-error, JSON, exit 0" "0 A classify-error True" \
  "$rc $(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["class"], d["reason"], d["hold"])' "$out")"
{ cat "$TSV"; printf 'rate_limited\tC\n'; } >"$D/dup.tsv"
out="$(python3 "$CL" --table "$D/dup.tsv" "$D/w4")"
check "a reason listed twice in the table: A classify-error" "A classify-error" \
  "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["class"], d["reason"])' "$out")"
printf '# Stop: g1-a\n\n- reason: rate_limited\n- detail: x\n' >"$D/w4"
check "rate_limited: wait, not held" "wait False" "$(cls "$D/w4" class hold)"

echo "== 5. wave-stops (the real walker) =="
# Wave 1 is g1-a and g2-b. g2-b's implementer fails, naming an envelope.
wave() { # wave LOGFILE: g1-a finishes, g2-b stops implementer-error with LOG
  pwalk_repo
  printf 'printf "%%s\\n" "IMPLEMENTER_RESULT: error (exit 1)" "THREAD_ID: haiku:t-g2-b" "LOG: %s" "stderr: %s"; exit 1\n' "$1" "${1:+$1.err}" >"$CALLS/action-g2-b"
  prun --jobs 2
}
wave "$D/e500"
check "the walker wrote a wave-stop with g2-b implementer-error" "wave-stop implementer-error" \
  "$(sed -n 's/^- reason: //p' "$pstop" | head -n1) $(reason_in g2-b)"
check "a wave-stop with one implementer-error: C, not held" "wave C implementer-error False" "$(cls "$pstop" kind class reason hold)"
cp "$pstop" "$TMP/wave-c.md"
wave "$D/spend-429"
check "  ...the member's own stop naming a spend-limit envelope: A budget" "A budget" "$(cls "$pstop" class reason)"
# The real file's bullets, rewritten: the format is the walker's own.
W="$TMP/wave-c.md"
sed 's/^\(- g2-b: \)implementer-error\( — \)/\1bounced\2/' "$W" >"$TMP/wave-b.md"
check "a bounced member: B, held" "B bounced True" "$(cls "$TMP/wave-b.md" class reason hold)"
awk '/^## Stopped/{print; print "- g9-z: finished-not-integrated — "; next} {print}' "$W" >"$TMP/wave-f.md"
check "finished-not-integrated beside implementer-error: C" "C implementer-error" "$(cls "$TMP/wave-f.md" class reason)"
awk '/^## Stopped/{print; print "- g9-z: finished-not-integrated — "; f=1; next} f && /^- /{next} {print}' "$W" >"$TMP/wave-fo.md"
check "finished-not-integrated alone: F, not held" "F finished-not-integrated False" "$(cls "$TMP/wave-fo.md" class reason hold)"
awk '/^## Stopped/{print; print "- g9-z: finished-not-integrated — "; f=1; next} f && /^- /{next} {print}' "$W" |
  awk '/^## Stopped/{print; print "- a bullet the walker cannot write"; next} {print}' >"$TMP/wave-u.md"
check "an unparsed bullet beside finished-not-integrated: A, never F" "A unparsed-bullet True" "$(cls "$TMP/wave-u.md" class reason hold)"
awk '/^## Stopped/{print; print "- g9-z:  — (no stop file)"; next} {print}' "$W" >"$TMP/wave-e.md"
check "a member with an empty reason and no stop file: A, read as that goal with no reason" "A True [g9-z||None]" \
  "$(cls "$TMP/wave-e.md" class hold) $(python3 "$CL" "$TMP/wave-e.md" | python3 -c 'import json,sys; print([g["goal"]+"|"+g["reason"]+"|"+str(g["file"]) for g in json.load(sys.stdin)["goals"] if g["goal"]=="g9-z"][0].join("[]"))')"
sed 's/^- detail: .*/- detail: spend limit; invalid api key/' "$W" >"$TMP/wave-d.md"
check "a marker on the wave-stop's own detail line is not read" "C implementer-error" "$(cls "$TMP/wave-d.md" class reason)"
awk '/^## Stopped/{f=1; print; next} f && /^- /{next} {print}' "$W" >"$TMP/wave-0.md"
check "a wave-stop with no bullets: A" "A True" "$(cls "$TMP/wave-0.md" class hold)"

echo
if [[ "$fails" -eq 0 ]]; then
  echo "always-on-classify-test: all passed"
else
  echo "always-on-classify-test: $fails failed"
  exit 1
fi
