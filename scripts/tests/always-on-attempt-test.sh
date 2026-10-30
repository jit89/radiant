#!/usr/bin/env bash
# Self-test: one always-on walk attempt (docs/features/always-on step 5; slice
# 3a): lib/always-on-attempt.py's wrapper (the lock, the gated walker, the
# result written once, the complete copy of the stop with its paths rewritten)
# and the run state read from the world (running / finished / interrupted),
# with a fake walker named run-goals.sh. No model, no repo.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-ao-attempt-XXXXXX")"
export TMPDIR="$TMP"
# A HOME of its own: nothing this test runs writes into the caller's.
export HOME="$TMP/home"
mkdir -p "$HOME"
cleanup() {
  # Any fake walker or wrapper a failed check left running.
  pkill -f "$TMP/" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
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

ATT="$HERE/lib/always-on-attempt.py"
CL="$HERE/lib/always-on-classify.py"
FIX="$HERE/tests/fixtures/always-on"
mkdir -p "$TMP/bin"
WALKER="$TMP/bin/run-goals.sh"
# The fake walker: FAKE_MODE done | stop | wave | wait | flood.
cat >"$WALKER" <<'SH'
#!/usr/bin/env bash
run="$FAKE_RUN"
mkdir -p "$run"
echo "walker $$ started" >>"$FAKE_RUN/started"
case "$FAKE_MODE" in
  done) echo "OK all goals done"; exit 0 ;;
  stop)
    printf '# Stop: g1-a\n\n- reason: implementer-error\n- detail: rc=1\n- LOG: %s\n- stderr: %s\n' "$FAKE_LOG" "$FAKE_LOG.err" >"$run/stop.md"
    echo "STOP_FILE: $run/stop.md"; exit 1 ;;
  wave)
    printf '# Stop: g1-a\n\n- reason: implementer-error\n- detail: rc=1\n- LOG: %s\n- stderr: %s\n' "$FAKE_LOG" "$FAKE_LOG.err" >"$run/g1-a-stop.md"
    printf '# Stop: g2-b\n\n- reason: bounced\n- detail: x\n- LOG: \n- stderr: \n' >"$run/g2-b-stop.md"
    { printf '# Stop: walk (wave 1)\n\n- reason: wave-stop\n- utc: now\n- detail: 3 stop(s); each has its own stop file below. A goal listed finished-not-integrated passed review and is recorded as finished: a rerun integrates it without dispatch.\n\n## Stopped\n'
      printf -- '- g1-a: implementer-error — %s\n- g2-b: bounced — %s\n- g3-c: finished-not-integrated — \n- g4-d: interrupted — (no stop file)\n' "$run/g1-a-stop.md" "$run/g2-b-stop.md"
      printf '\n## graph\ng1-a in_progress\n'; } >"$run/stop.md"
    echo "STOP_FILE: $run/stop.md"; exit 1 ;;
  wait)
    # As the walker's own handlers: the trap reset first, then a cleanup that
    # takes a while (a second TERM would cut it short, and no stop is written).
    trap 'trap - TERM; sleep 1; printf "# Stop: g1-a\n\n- reason: interrupted\n- detail: TERM\n" >"$run/stop.md"; echo "STOP_FILE: $run/stop.md"; exit 143' TERM
    touch "$run/waiting"
    # A line on every loop: a walker that outlives its wrapper keeps writing.
    while :; do echo "tick $(date +%s)"; echo "tock" >&2; sleep 0.2; done ;;
  fifo)
    mkfifo "$run/stop.md"; echo "STOP_FILE: $run/stop.md"; exit 1 ;;
  member)
    # A member's stop line on the walker's output, then the walk ends without its own.
    echo "STOP_FILE: /nowhere/member-stop.md"; echo "the walk failed before its own stop"; exit 1 ;;
  relative)
    printf 'x\n' >"$run/env"
    printf '# Stop: g1-a\n\n- reason: implementer-error\n- detail: rc=1\n- LOG: env\n- stderr: \n' >"$run/stop.md"
    echo "STOP_FILE: $run/stop.md"; exit 1 ;;
esac
SH
chmod +x "$WALKER"
# A wrapper in a session of its own, as the supervisor starts it: attempt DIR [ENV...]
attempt() {
  local dir="$1"
  shift
  mkdir -p "$dir"
  env "$@" python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
    python3 "$ATT" run "$dir" -- "$WALKER" --jobs 2
}
state() { python3 "$ATT" state "$1"; }
field() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(json.dumps(d.get(k)) for k in sys.argv[2:]))' "$@"; }
# The wrapper's own pid, from its lock record.
wrapper_pid() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$1/lock"; }
# reap PID: wait for a background job at most 30s, then KILL it (a planted
# wrapper that never forwards a signal must not hang the test).
reap() {
  local i
  for i in $(seq 300); do kill -0 "$1" 2>/dev/null || break; sleep 0.1; done
  kill -KILL "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}
wait_for() { for _ in $(seq 300); do [[ -e "$1" ]] && return 0; sleep 0.1; done; return 1; }

echo "== 1. a completed walk =="
A="$TMP/a/e1/1"
attempt "$A" FAKE_MODE=done FAKE_RUN="$TMP/run1"
check "exit 0, no stop: a result, finished" '0 true null null [] finished' "$(field "$A/result.json" exit walked stop_file stop copy_errors) $(state "$A")"
check "  ...the walker's output kept in a file" yes "$(has 'OK all goals done' "$(cat "$A/walker.out")")"
rc=0; attempt "$A" FAKE_MODE=done FAKE_RUN="$TMP/run1" 2>/dev/null || rc=$?
check "the same attempt again: refused, the walker never started twice" "2 1" "$rc $(wc -l <"$TMP/run1/started" | tr -d ' ')"

echo "== 2. a single stop, copied whole =="
mkdir -p "$TMP/raw"
cp "$FIX/reviewer-401/raw" "$TMP/raw/env"
printf 'boom\n' >"$TMP/raw/env.err"
A="$TMP/a/e1/2"
attempt "$A" FAKE_MODE=stop FAKE_RUN="$TMP/run2" FAKE_LOG="$TMP/raw/env"
check "exit 1, the stop file named, its copy" "1 \"$TMP/run2/stop.md\" \"stop/stop.md\" []" "$(field "$A/result.json" exit stop_file stop copy_errors)"
copy="$A/stop/stop.md"
check "  ...LOG and stderr point at copies inside the attempt" "yes yes" \
  "$(grep -q "^- LOG: $A/stop/named-1-env\$" "$copy" && echo yes || echo no) $(grep -q "^- stderr: $A/stop/named-2-env.err\$" "$copy" && echo yes || echo no)"
rm -rf "$TMP/run2" "$TMP/raw"
check "  ...classified from the copy after the originals are gone: A budget" "A budget" \
  "$(python3 "$CL" "$copy" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["class"], d["reason"])')"

echo "== 3. a wave-stop, every member copied =="
mkdir -p "$TMP/raw"
cp "$FIX/implementer-401/raw" "$TMP/raw/env"
: >"$TMP/raw/env.err"
A="$TMP/a/e1/3"
attempt "$A" FAKE_MODE=wave FAKE_RUN="$TMP/run3" FAKE_LOG="$TMP/raw/env"
copy="$A/stop/stop.md"
check "the bullets point at the copied member stops" "yes yes" \
  "$(grep -q "^- g1-a: implementer-error — $A/stop/goals/1-g1-a/stop.md\$" "$copy" && echo yes || echo no) $(grep -q "^- g2-b: bounced — $A/stop/goals/2-g2-b/stop.md\$" "$copy" && echo yes || echo no)"
check "  ...the bullets without a file kept as they were" "yes yes" \
  "$(grep -q '^- g3-c: finished-not-integrated — $' "$copy" && echo yes || echo no) $(grep -q '^- g4-d: interrupted — (no stop file)$' "$copy" && echo yes || echo no)"
check "  ...a member's LOG points at its own copy" yes \
  "$(grep -q "^- LOG: $A/stop/goals/1-g1-a/named-1-env\$" "$A/stop/goals/1-g1-a/stop.md" && echo yes || echo no)"
check "  ...empty LOG lines are no copy errors" "[]" "$(field "$A/result.json" copy_errors)"
rm -rf "$TMP/run3" "$TMP/raw"
check "  ...classified from the copies, originals gone: the member's 401 is A budget" "A budget" \
  "$(python3 "$CL" "$copy" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["class"], d["reason"])')"

echo "== 4. files that cannot be copied are recorded =="
mkdir -p "$TMP/raw"
printf 'x\n' >"$TMP/raw/env"
chmod 000 "$TMP/raw/env"
A="$TMP/a/e1/4"
attempt "$A" FAKE_MODE=stop FAKE_RUN="$TMP/run4" FAKE_LOG="$TMP/raw/env"
chmod 600 "$TMP/raw/env"
check "an unreadable LOG and a missing stderr: both in copy_errors, their lines emptied" \
  "unreadable missing yes yes" \
  "$(python3 -c 'import json,sys; print(" ".join(e["why"] for e in json.load(open(sys.argv[1]))["copy_errors"]))' "$A/result.json") $(grep -q '^- LOG: $' "$A/stop/stop.md" && echo yes || echo no) $(grep -q '^- stderr: $' "$A/stop/stop.md" && echo yes || echo no)"

echo "== 5. the run state from the world =="
A="$TMP/a/e1/5"
attempt "$A" FAKE_MODE=wait FAKE_RUN="$TMP/run5" &
wpid=$!
wait_for "$TMP/run5/waiting"
check "a live attempt: running" running "$(state "$A")"
rc=0; mkdir -p "$A" && python3 "$ATT" run "$A" -- "$WALKER" 2>/dev/null || rc=$?
check "a second wrapper on it: refused by the lock, no second walker" "75 1" "$rc $(wc -l <"$TMP/run5/started" | tr -d ' ')"
kill -KILL "$(wrapper_pid "$A")"
reap "$wpid"
check "the wrapper SIGKILLed, its walker alive: still running" running "$(state "$A")"
n0="$(grep -c tick "$A/walker.out")"
sleep 1
check "  ...the walker still alive and still writing (no broken pipe)" yes \
  "$([[ "$(grep -c tick "$A/walker.out")" -gt "$n0" ]] && echo yes || echo no)"
rc=0; python3 "$ATT" run "$A" -- "$WALKER" 2>/dev/null || rc=$?
check "  ...a second wrapper on its folder: refused on the walker record, no second walker" "2 1" "$rc $(wc -l <"$TMP/run5/started" | tr -d ' ')"
check "  ...STOP still reaches it through the walker's record" signalled "$(python3 "$ATT" stop "$A")"
check "  ...once: a second STOP does not signal it again" already-signalled "$(python3 "$ATT" stop "$A")"
wait_for "$TMP/run5/stop.md"
check "  ...its cleanup ran to the end (its own stop written)" yes "$([[ -s "$TMP/run5/stop.md" ]] && echo yes || echo no)"
for _ in $(seq 100); do [[ "$(state "$A")" == running ]] || break; sleep 0.1; done
check "the walker gone, no result: interrupted" interrupted "$(state "$A")"
check "  ...and nothing left to signal" not-running "$(python3 "$ATT" stop "$A")"

echo "== 6. a recycled pid is not the walker =="
A="$TMP/a/e1/6"
mkdir -p "$A"
# A group leader of its own, as a recycled pid could be.
python3 -c 'import os,sys; os.setsid(); os.execvp("sleep", ["sleep", "30"])' &
spid=$!
sleep 0.3
python3 -c 'import json,subprocess,sys; s=" ".join(subprocess.run(["ps","-o","lstart=","-p",sys.argv[2]],capture_output=True,text=True).stdout.split()); open(sys.argv[1],"w").write(json.dumps({"pid":int(sys.argv[2]),"start":s,"pgid":int(sys.argv[2])}))' "$A/walker.json" "$spid"
check "a live pid whose command is not the walker: interrupted, never signalled" "interrupted not-running" \
  "$(state "$A") $(python3 "$ATT" stop "$A")"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["start"]="Mon Jan  1 00:00:00 2001"; open(sys.argv[1],"w").write(json.dumps(d))' "$A/walker.json"
check "a pid whose start time differs: interrupted" interrupted "$(state "$A")"
check "  ...the recycled group never signalled" yes "$(kill -0 "$spid" 2>/dev/null && echo yes || echo no)"
kill "$spid" 2>/dev/null || true
# The walker's command, but another start time (a pid reused by another walker).
mkdir -p "$TMP/run6"
FAKE_MODE=wait FAKE_RUN="$TMP/run6" python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$WALKER" >/dev/null 2>&1 &
opid=$!
wait_for "$TMP/run6/waiting"
python3 -c 'import json,sys; open(sys.argv[1],"w").write(json.dumps({"pid":int(sys.argv[2]),"start":"Mon Jan  1 00:00:00 2001","pgid":int(sys.argv[2])}))' "$A/walker.json" "$opid"
check "a walker's command under another start time: interrupted, never signalled" "interrupted not-running" \
  "$(state "$A") $(python3 "$ATT" stop "$A")"
kill -KILL "$opid" 2>/dev/null || true

echo "== 7. TERM to the wrapper reaches the walker; its stop is the result =="
A="$TMP/a/e1/7"
attempt "$A" FAKE_MODE=wait FAKE_RUN="$TMP/run7" &
wpid=$!
wait_for "$TMP/run7/waiting"
kill -TERM "$(wrapper_pid "$A")"
reap "$wpid"
check "the walker's own stop recorded, exit 143, the signal noted" '143 "stop/stop.md" ["SIGTERM"] finished' \
  "$(field "$A/result.json" exit stop signals) $(state "$A")"
A="$TMP/a/e1/8"
attempt "$A" FAKE_MODE=wait FAKE_RUN="$TMP/run8" &
wpid=$!
wait_for "$TMP/run8/waiting"
check "STOP on a running attempt: the walker signalled" signalled "$(python3 "$ATT" stop "$A")"
reap "$wpid"
check "  ...one TERM: the walker's cleanup ran, its stop is the result" '143 "stop/stop.md" finished' "$(field "$A/result.json" exit stop) $(state "$A")"
check "  ...the walker's pid alone: the wrapper got no signal (it would forward a second TERM)" null "$(field "$A/result.json" signals)"

A="$TMP/a/e1/8h"
attempt "$A" FAKE_MODE=wait FAKE_RUN="$TMP/run8h" &
wpid=$!
wait_for "$TMP/run8h/waiting"
kill -HUP "$(wrapper_pid "$A")"
reap "$wpid"
check "HUP to the wrapper reaches the walker as TERM (which it traps)" '143 "stop/stop.md"' "$(field "$A/result.json" exit stop)"

echo "== 8. not started; ps failing; the walk's own stop line; relative paths =="
A="$TMP/a/e1/9"
mkdir -p "$A"
check "an empty attempt folder: not-started" not-started "$(state "$A")"
: >"$A/lock"
check "  ...a free lock file and nothing else: not-started" not-started "$(state "$A")"
mkdir -p "$TMP/badps"
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/badps/ps"
chmod +x "$TMP/badps/ps"
A="$TMP/a/e1/10"
rc=0; attempt "$A" FAKE_MODE=done FAKE_RUN="$TMP/run10" PATH="$TMP/badps:$PATH" 2>/dev/null || rc=$?
check "ps fails for the wrapper: refused, no walker, not-started" "2 no not-started" \
  "$rc $([[ -e "$TMP/run10/started" ]] && echo yes || echo no) $(state "$A")"
# ps answers once (the wrapper's own record), then fails (the walker's).
printf '#!/usr/bin/env bash\nc="%s/badps/n"; n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 )); echo $n >"$c"\n[[ $n -le 1 ]] && exec /bin/ps "$@"\nexit 1\n' "$TMP" >"$TMP/badps/ps"
A="$TMP/a/e1/11"
attempt "$A" FAKE_MODE=done FAKE_RUN="$TMP/run11" PATH="$TMP/badps:$PATH"
check "ps fails for the walker: the gate stays shut, the result says so" "false no finished" \
  "$(field "$A/result.json" walked) $([[ -e "$TMP/run11/started" ]] && echo yes || echo no) $(state "$A")"
A="$TMP/a/e1/12"
attempt "$A" FAKE_MODE=member FAKE_RUN="$TMP/run12"
check "a member's STOP_FILE line earlier in the output: not the walk's stop" "1 null null" "$(field "$A/result.json" exit stop_file stop)"
A="$TMP/a/e1/14"
attempt "$A" FAKE_MODE=fifo FAKE_RUN="$TMP/run14" &
wpid=$!
reap "$wpid"
kill -KILL "$(wrapper_pid "$A")" 2>/dev/null || true # a wrapper blocked on the FIFO
check "a STOP_FILE that is a FIFO: not opened, recorded, no hang" '"not-a-file" null finished' \
  "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["copy_errors"][0]["why"]))' "$A/result.json" 2>/dev/null) $(field "$A/result.json" stop) $(state "$A")"
A="$TMP/a/e1/13"
attempt "$A" FAKE_MODE=relative FAKE_RUN="$TMP/run13"
check "a relative LOG path: copied from the stop's folder" "yes []" \
  "$(grep -q "^- LOG: $A/stop/named-1-env\$" "$A/stop/stop.md" && echo yes || echo no) $(field "$A/result.json" copy_errors)"

echo
if [[ "$fails" -eq 0 ]]; then
  echo "always-on-attempt-test: all passed"
else
  echo "always-on-attempt-test: $fails failed"
  exit 1
fi
