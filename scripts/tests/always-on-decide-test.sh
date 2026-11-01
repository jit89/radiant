#!/usr/bin/env bash
# Self-test: the user's side of the always-on house (docs/features/always-on
# steps 1-3, 13-14; slice 4a): lib/notify.sh with a stub osascript, and
# cw-decide.sh's sign, status, resume, skip, stop, start, doctor and heartbeat
# against real git repos, with stub launchctl, pmset, defaults and notifier.
# Nothing is sent and no model is called.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-ao-decide-XXXXXX")"
export TMPDIR="$TMP"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
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

DEC="$HERE/cw-decide.sh"
S="$TMP/stubs"
CALLS="$TMP/calls"
mkdir -p "$S/bin" "$CALLS"
export CW_AO_HOME="$TMP/aohome" CW_AO_CACHE="$TMP/aocache" CW_AO_LAUNCH_AGENTS="$TMP/agents"
export CW_AO_NOTIFY="$S/notify" CW_AO_KEY_FILE="$S/key" CW_AO_CLAUDE="$S/claude" CW_AO_BALANCE="$S/balance"
export CW_AO_LAUNCHCTL="$S/launchctl"
mkdir -p "$CW_AO_HOME" "$CW_AO_LAUNCH_AGENTS"
printf '#!/usr/bin/env bash\necho "claude 1.0"\n' >"$S/claude"
printf '#!/usr/bin/env bash\necho "BALANCE_USD: 9"\n' >"$S/balance"
printf '#!/usr/bin/env bash\nprintf "%%s|" "$@" >>"%s/notify"; echo >>"%s/notify"\n' "$CALLS" "$CALLS" >"$S/notify"
# launchctl: print fails until bootstrap has run for that label.
cat >"$S/launchctl" <<SH
#!/usr/bin/env bash
echo "\$*" >>"$CALLS/launchctl"
case "\$1" in
  print) grep -qx "\${2##*/}" "$CALLS/loaded" 2>/dev/null ;;
  bootstrap) basename "\$3" .plist >>"$CALLS/loaded" ;;
esac
SH
chmod +x "$S"/*
printf 'sk-test\n' >"$S/key"
chmod 600 "$S/key"

echo "== 1. notify.sh =="
printf 'recipient=+15550000000\n' >"$CW_AO_HOME/notify.conf"
cat >"$S/bin/osascript" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$CALLS/osa-args"
cat >"$CALLS/osa-script"
[[ -e "$CALLS/osa-empty" ]] || echo "acct-1"
exit \$(cat "$CALLS/osa-rc" 2>/dev/null || echo 0)
SH
chmod +x "$S/bin/osascript"
NOTIFY="$HERE/lib/notify.sh"
CW_AO_OSASCRIPT="$S/bin/osascript" "$NOTIFY" held my-repo 0123456789abcdef A "budget\"; do shell script \"rm -rf ~\"" 'attempt 2
INJECT'
check "the handle and the text are argv items; the script holds neither" "+15550000000 no no" \
  "$(sed -n 2p "$CALLS/osa-args") $(grep -q 15550000000 "$CALLS/osa-script" && echo yes || echo no) $(grep -q my-repo "$CALLS/osa-script" && echo yes || echo no)"
text="$(sed -n '3,$p' "$CALLS/osa-args")"
check "  ...fields cleaned: no quote, no semicolon, no newline; the commands named" "no no 1 yes yes" \
  "$(has '"' "$text" | cut -c1-2) $(has ';' "$text" | cut -c1-2) $(printf '%s\n' "$text" | wc -l | tr -d ' ') $(has 'resume 0123456789ab' "$text") $(has 'held, class A' "$text")"
CW_AO_OSASCRIPT="$S/bin/osascript" "$NOTIFY" held my-repo 0123456789abcdef A supervisor-error-unsaved "attempt 2"
check "an unsaved hold's message: restart the supervisor, not resume" "yes no" \
  "$(has 'launchctl kickstart -k' "$(sed -n '3,$p' "$CALLS/osa-args")") $(grep -q 'resume 0123' "$CALLS/osa-args" && echo yes || echo no)"
echo 1 >"$CALLS/osa-rc"
rc=0; CW_AO_OSASCRIPT="$S/bin/osascript" "$NOTIFY" done r e "" walk-end x 2>/dev/null || rc=$?
check "osascript failing: exit 1" 1 "$rc"
rm "$CALLS/osa-rc"
mv "$CW_AO_HOME/notify.conf" "$TMP/notify.conf"
rc=0; CW_AO_OSASCRIPT="$S/bin/osascript" "$NOTIFY" done r e "" walk-end x 2>/dev/null || rc=$?
check "no notify.conf: exit 1" 1 "$rc"
printf 'other=1\n' >"$CW_AO_HOME/notify.conf"
rm -f "$CALLS/osa-args"
rc=0; CW_AO_OSASCRIPT="$S/bin/osascript" "$NOTIFY" done r e "" walk-end x 2>/dev/null || rc=$?
check "a notify.conf with no recipient: exit 1, Messages never called" "1 no" "$rc $([[ -e "$CALLS/osa-args" ]] && echo yes || echo no)"
mv "$TMP/notify.conf" "$CW_AO_HOME/notify.conf"

echo "== 2. sign =="
# repo NAME: a repo ready to sign (decompose recorded, the last oracle round APPROVED).
repo() {
  local r="$TMP/$1"
  rm -rf "$r"
  mkdir -p "$r/docs/journal"
  (cd "$r" && git init -q && cp "$HERE/../GOALS.example.md" GOALS.md && printf '# Plan\n' >PLAN.md &&
    printf '# Journal: example\n\n## 2026-10-30T00:00:00Z — ARCHITECT decompose\nIds g1-store...\n' >docs/journal/example.md &&
    printf '# Plan Review Log\n\n## Oracle round 1 — Grok\nVERDICT: REVISE\n\n## Oracle round 2 — Grok\nVERDICT: APPROVED\n\n### Architect'"'"'s response\nNone.\n' >PLAN-REVIEW-LOG.md &&
    git add -A && git commit -qm base)
  (cd "$r" && pwd -P) # sign keeps the real path
}
R="$(repo r1)"
out="$("$DEC" sign "$R")"
check "a ready repo: signed at HEAD, jobs 2, the queue 0600" "yes $(git -C "$R" rev-parse HEAD) 2 600" \
  "$(has 'signed' "$out") $(python3 -c 'import json,sys; d=json.loads(open(sys.argv[1]).readline()); print(d["signed"], d["jobs"])' "$CW_AO_HOME/queue.jsonl") $(stat -f %Lp "$CW_AO_HOME/queue.jsonl")"
rc=0; "$DEC" sign "$R" jobs=3 2>"$TMP/err" || rc=$?
check "a second sign while the entry is queued: refused" "1 yes" "$rc $(has 'already has an entry' "$(cat "$TMP/err")")"
refused() { # refused NAME REPO WHY [ARGS]
  local rc=0
  "$DEC" sign "$2" ${4:-} 2>"$TMP/err" >/dev/null || rc=$?
  check "$1: refused, naming it" "nonzero yes" "$([[ "$rc" -ne 0 ]] && echo nonzero || echo 0) $(has "$3" "$(cat "$TMP/err")")"
}
R2="$(repo r2)"
echo dirt >"$R2/x.txt"
refused "a dirty tree" "$R2" "the tree is not clean"
R2="$(repo r2)"
(cd "$R2" && printf '# Journal: example\n' >docs/journal/example.md && git commit -qam "no decompose")
refused "no decompose record" "$R2" "ARCHITECT decompose"
R2="$(repo r2)"
(cd "$R2" && printf '\n## Oracle round 3 — Grok\nVERDICT: REVISE\n' >>PLAN-REVIEW-LOG.md && git commit -qam "a later round")
refused "the last oracle round not APPROVED (an earlier one was)" "$R2" "VERDICT: APPROVED"
(cd "$R2" && printf '\n## 2026-10-30T01:00:00Z — ARCHITECT oracle-review override\nThe user overrode.\n' >>docs/journal/example.md && git commit -qam "override")
check "  ...with a committed oracle-review override: signed" yes "$(has signed "$("$DEC" sign "$R2")")"
R3="$(repo r3)"
(cd "$R3" && printf '\n## Oracle round 3 — Grok\nVERDICT: REVISE\n' >>PLAN-REVIEW-LOG.md && git add -A && git commit -qm x)
(cd "$R3" && printf '\n## 2026-10-30T01:00:00Z — ARCHITECT oracle-review override\n' >>docs/journal/example.md)
refused "an override record not committed" "$R3" "VERDICT: APPROVED"
R3="$(repo r3)"
(cd "$R3" && sed -i '' 's/id: g2-ack/id: g1-store/' GOALS.md && git commit -qam "a goal id twice")
refused "a GOALS.md that does not validate" "$R3" "does not validate"
R3="$(repo r3)"
(cd "$R3" && mkdir -p scripts && touch scripts/cw-supervisor.sh && git add -A && git commit -qm house)
refused "the house itself" "$R3" "the house itself"
refused "a folder inside a repo" "$R/docs" "not the toplevel"
R3="$(repo r3)"
refused "jobs=5" "$R3" "jobs must be" "jobs=5"
R3="$(repo r3)"
git -C "$R3" worktree add -q "$TMP/r3-linked" -b linked
refused "a linked worktree" "$(cd "$TMP/r3-linked" && pwd -P)" "linked worktree"
R4="$(repo r4)"
(cd "$R4" && git rm -q --cached GOALS.md && echo GOALS.md >.gitignore && git add .gitignore && git commit -qm "GOALS.md ignored")
refused "a GOALS.md not committed (ignored)" "$R4" "not committed at HEAD"

echo "== 3. status, resume, skip =="
EID="$(python3 -c 'import hashlib,json,sys
for l in open(sys.argv[1]):
    if json.loads(l)["repo"] == sys.argv[2]: print(hashlib.sha256(l.rstrip("\n").encode()).hexdigest())' "$CW_AO_HOME/queue.jsonl" "$R")"
out="$("$DEC" status)"
check "status: the entry, its state, the supervisor not running" "yes yes yes" \
  "$(has "${EID:0:12}  r1  queued" "$out") $(has 'supervisor: not running' "$out") $(has 'spend: $0.00 in 24 h' "$out")"
mkdir -p "$CW_AO_HOME/state"
NOCOUNTS='{"C": {}, "D": {}}'
hold_state() { # hold_state REASON [COUNTS-JSON]
  python3 -c 'import json,sys; json.dump({"id":sys.argv[2],"repo":sys.argv[3],"signed":sys.argv[4],"jobs":2,"status":"held","attempt":3,"acted_attempt":3,"counts":json.loads(sys.argv[6]),"f_only":0,"rate_stops":[],"wait_until":None,"hold":{"class":"needs-human","reason":sys.argv[5]}}, open(sys.argv[1],"w"))' \
    "$CW_AO_HOME/state/$EID.json" "$EID" "$R" "$(git -C "$R" rev-parse HEAD)" "$1" "${2:-$NOCOUNTS}"
}
hold_state count-cap '{"C": {"g1-store": 2, "g2-ack": 1}, "D": {"g3-other": 1}}'
out="$("$DEC" resume "${EID:0:8}")"
st() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(json.dumps(eval(k, {}, {"d": d})) for k in sys.argv[2:]))' "$CW_AO_HOME/state/$EID.json" "$@"; }
check "resume at a count cap: no counter changed (the rerun is the one extra), queued, the hold cleared" '"queued" null 2 1 1' \
  "$(st 'd["status"]' 'd["hold"]' 'd["counts"]["C"]["g1-store"]' 'd["counts"]["C"]["g2-ack"]' 'd["counts"]["D"]["g3-other"]')"
check "  ...the fixed record committed in the target journal" "yes chore: always-on resume" \
  "$(tail -n1 "$R/docs/journal/example.md" | grep -qE '^## [0-9TZ:-]+ — ARCHITECT always-on resume$' && echo yes || echo no) $(git -C "$R" log -1 --format=%s)"
rc=0; "$DEC" resume "${EID:0:8}" 2>"$TMP/err" || rc=$?
check "resume of an entry that is not held: refused" "1 yes" "$rc $(has 'is not held' "$(cat "$TMP/err")")"
# Held, yet its attempt still runs (an error hold after its walk started).
hold_state supervisor-error
mkdir -p "$CW_AO_HOME/attempts/$EID/3"
python3 -c 'import fcntl,os,sys,time; fd=os.open(sys.argv[1], os.O_RDWR|os.O_CREAT); fcntl.flock(fd, fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(4)' \
  "$CW_AO_HOME/attempts/$EID/3/lock" "$TMP/att3-locked" &
for _ in $(seq 50); do [[ -e "$TMP/att3-locked" ]] && break; sleep 0.1; done
rc=0; "$DEC" resume "${EID:0:8}" 2>"$TMP/err" || rc=$?
rc2=0; "$DEC" sign "$R" 2>"$TMP/err2" || rc2=$?
check "a held entry whose attempt still runs: resume and sign refuse" "1 yes 1 yes" \
  "$rc $(has 'still has a running attempt' "$(cat "$TMP/err")") $rc2 $(has 'running' "$(cat "$TMP/err2")")"
wait
rm -rf "$CW_AO_HOME/attempts/$EID/3"
# The supervisor mid-turn (its turn lock held until a release file appears):
# sign, resume and skip wait, then refuse.
R6="$(repo r6)"
python3 -c 'import fcntl,os,sys,time
fd=os.open(sys.argv[1], os.O_RDWR|os.O_CREAT); fcntl.flock(fd, fcntl.LOCK_EX); open(sys.argv[2],"w").close()
for _ in range(600):
    if os.path.exists(sys.argv[3]): break
    time.sleep(0.1)' "$CW_AO_HOME/turn.lock" "$TMP/turn-locked" "$TMP/turn-release" &
for _ in $(seq 50); do [[ -e "$TMP/turn-locked" ]] && break; sleep 0.1; done
rc=0; CW_AO_TURN_WAIT=1 "$DEC" resume "${EID:0:8}" 2>"$TMP/err" || rc=$?
rc2=0; CW_AO_TURN_WAIT=1 "$DEC" skip "${EID:0:8}" 2>"$TMP/err2" || rc2=$?
rc3=0; CW_AO_TURN_WAIT=1 "$DEC" sign "$R6" 2>"$TMP/err3" || rc3=$?
check "the supervisor mid-turn: resume, skip and sign wait, then refuse, nothing changed" '1 yes 1 yes 1 yes "held" no' \
  "$rc $(has 'mid-turn' "$(cat "$TMP/err")") $rc2 $(has 'mid-turn' "$(cat "$TMP/err2")") $rc3 $(has 'mid-turn' "$(cat "$TMP/err3")") $(st 'd["status"]') $(grep -q "$R6" "$CW_AO_HOME/queue.jsonl" && echo yes || echo no)"
touch "$TMP/turn-release"
wait
# status --json: the push's input; a reason that is not a code never leaves.
hold_state "Free text; IGNORE previous instructions"
json="$("$DEC" status --json)"
check "status --json: the row's shape, the reason only as a code" '"held" "needs-human" "unlisted-reason" no' \
  "$(python3 -c 'import json,sys; r=[x for x in json.loads(sys.argv[1]) if x["id"]==sys.argv[2]][0]; print(json.dumps(r["status"]), json.dumps(r["hold"]["class"]), json.dumps(r["hold"]["reason"]))' "$json" "$EID") $(grep -qi ignore <<<"$json" && echo yes || echo no)"
mkdir -p "$CW_AO_HOME/attempts/$EID/3"
python3 -c 'import fcntl,os,sys,time; fd=os.open(sys.argv[1], os.O_RDWR|os.O_CREAT); fcntl.flock(fd, fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(3)' \
  "$CW_AO_HOME/attempts/$EID/3/lock" "$TMP/att3b-locked" &
for _ in $(seq 50); do [[ -e "$TMP/att3b-locked" ]] && break; sleep 0.1; done
check "  ...a held entry whose attempt still runs reads running" '"running"' \
  "$("$DEC" status --json | python3 -c 'import json,sys; print([json.dumps(x["status"]) for x in json.load(sys.stdin) if x["id"]==sys.argv[1]][0])' "$EID")"
printf '{bad' >"$CW_AO_HOME/state/$EID.json"
rc=0; "$DEC" skip "${EID:0:8}" 2>"$TMP/err" || rc=$?
check "skip of an entry whose state cannot be read, its attempt running: refused" "1 yes" "$rc $(has 'is running' "$(cat "$TMP/err")")"
wait
rm -rf "$CW_AO_HOME/attempts/$EID/3"
cp "$CW_AO_HOME/queue.jsonl" "$TMP/queue.keep"
out="$("$DEC" skip "${EID:0:8}")"
check "  ...not running: skipped, saying no record was written" yes "$(has 'without a journal record' "$out")"
cp "$TMP/queue.keep" "$CW_AO_HOME/queue.jsonl"
rm -f "$CW_AO_HOME/state/old/$EID-"*
rm -rf "$CW_AO_HOME/attempts/$EID/3"
hold_state budget
hold_state serial-goal-in-progress
rc=0; "$DEC" resume "${EID:0:8}" 2>"$TMP/err" || rc=$?
check "resume on serial-goal-in-progress: refused, the serial command printed" "1 yes" "$rc $(has 'run-goals.sh' "$(cat "$TMP/err")")"
hold_state contract-drift
printf 'more\n' >>"$R/PLAN.md"
git -C "$R" commit -qam "plan edit"
rc=0; "$DEC" resume "${EID:0:8}" 2>"$TMP/err" || rc=$?
check "resume after the signed plan changed: refused, sign the new HEAD" '1 yes "held"' "$rc $(has 'sign the new HEAD' "$(cat "$TMP/err")") $(st 'd["status"]')"
git -C "$R" reset -q --hard HEAD~1
hold_state budget
echo dirt >"$R/untracked.txt"
rc=0; "$DEC" resume "${EID:0:8}" 2>"$TMP/err" || rc=$?
check "resume on a dirty tree: refused, nothing changed" '1 yes "held"' "$rc $(has 'not clean' "$(cat "$TMP/err")") $(st 'd["status"]')"
rm "$R/untracked.txt"
# A running attempt (its lock held): skip refuses.
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.update(status="queued", attempt=4, acted_attempt=3, hold=None); json.dump(d, open(p,"w"))' "$CW_AO_HOME/state/$EID.json"
mkdir -p "$CW_AO_HOME/attempts/$EID/4"
python3 -c 'import fcntl,os,sys,time; fd=os.open(sys.argv[1], os.O_RDWR|os.O_CREAT); fcntl.flock(fd, fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(4)' \
  "$CW_AO_HOME/attempts/$EID/4/lock" "$TMP/att-locked" &
for _ in $(seq 50); do [[ -e "$TMP/att-locked" ]] && break; sleep 0.1; done
rc=0; "$DEC" skip "${EID:0:8}" 2>"$TMP/err" || rc=$?
check "skip of a running entry: refused" "1 yes" "$rc $(has 'is running' "$(cat "$TMP/err")")"
wait
rm -rf "$CW_AO_HOME/attempts/$EID/4"
hold_state budget
printf '{not json' >"$CW_AO_HOME/state/$EID.json"
rc=0; "$DEC" sign "$R" 2>"$TMP/err" || rc=$?
check "sign over an entry whose state cannot be read: refused" "1 yes" "$rc $(has 'cannot be read' "$(cat "$TMP/err")")"
hold_state budget
out="$("$DEC" skip "${EID:0:8}")"
check "skip: dropped from the queue, its state kept under state/old, the record committed" "no 1 yes" \
  "$(grep -q "\"$R\"" "$CW_AO_HOME/queue.jsonl" && echo yes || echo no) $(ls "$CW_AO_HOME/state/old" | grep -c "^$EID-") $(tail -n1 "$R/docs/journal/example.md" | grep -q 'ARCHITECT always-on skip$' && echo yes || echo no)"
"$DEC" sign "$R" >/dev/null
EID="$(python3 -c 'import hashlib,json,sys
for l in open(sys.argv[1]):
    if json.loads(l)["repo"] == sys.argv[2]: print(hashlib.sha256(l.rstrip("\n").encode()).hexdigest())' "$CW_AO_HOME/queue.jsonl" "$R")"
hold_state budget
git -C "$R" commit -q --allow-empty -m later
old="$EID"
out="$("$DEC" sign "$R" jobs=3)"
check "sign over a held entry: replaced, the old state moved to state/old" "yes 1 no" \
  "$(has "replaced ${old:0:12}" "$out") $(ls "$CW_AO_HOME/state/old" | grep -c "^$old-") $([[ -e "$CW_AO_HOME/state/$old.json" ]] && echo yes || echo no)"
EID="$(python3 -c 'import hashlib,json,sys
for l in open(sys.argv[1]):
    if json.loads(l)["repo"] == sys.argv[2]: print(hashlib.sha256(l.rstrip("\n").encode()).hexdigest())' "$CW_AO_HOME/queue.jsonl" "$R")"
python3 -c 'import json,sys; json.dump({"id":sys.argv[2],"repo":sys.argv[3],"signed":"x","jobs":3,"status":"done","attempt":1,"acted_attempt":1,"counts":{"C":{},"D":{}},"f_only":0,"rate_stops":[],"wait_until":None,"hold":None}, open(sys.argv[1],"w"))' \
  "$CW_AO_HOME/state/$EID.json" "$EID" "$R"
git -C "$R" commit -q --allow-empty -m "next walk"
check "sign over a done entry: replaced (a done entry no longer claims its repo)" "yes 1" \
  "$(has replaced "$("$DEC" sign "$R")") $(grep -c "\"$R\"" "$CW_AO_HOME/queue.jsonl")"

R5="$(repo r5)"
"$DEC" sign "$R5" >/dev/null
E5="$(python3 -c 'import hashlib,json,sys
for l in open(sys.argv[1]):
    if json.loads(l)["repo"] == sys.argv[2]: print(hashlib.sha256(l.rstrip("\n").encode()).hexdigest())' "$CW_AO_HOME/queue.jsonl" "$R5")"
rm -rf "$R5"
rc=0; out="$("$DEC" skip "${E5:0:10}" 2>&1)" || rc=$?
check "skip of an entry whose repo is gone: skipped without a record" "0 yes no" \
  "$rc $(has 'without a journal record' "$out") $(grep -q "${E5:0:12}" <<<"$(python3 -c 'import hashlib,sys
for l in open(sys.argv[1]): print(hashlib.sha256(l.rstrip("\n").encode()).hexdigest())' "$CW_AO_HOME/queue.jsonl")" && echo yes || echo no)"

echo "== 4. stop, start =="
"$DEC" stop >/dev/null
check "stop: the kill file written" yes "$([[ -e "$CW_AO_HOME/STOP" ]] && echo yes || echo no)"
rc=0; "$DEC" start >/dev/null 2>"$TMP/err" || rc=$?
check "start without the plists: refused, install named; STOP kept" "1 yes yes" \
  "$rc $(has 'install.sh --always-on' "$(cat "$TMP/err")") $([[ -e "$CW_AO_HOME/STOP" ]] && echo yes || echo no)"
touch "$CW_AO_LAUNCH_AGENTS/com.cw.always-on.plist" "$CW_AO_LAUNCH_AGENTS/com.cw.always-on.heartbeat.plist"
"$DEC" start >/dev/null
check "start: STOP removed" no "$([[ -e "$CW_AO_HOME/STOP" ]] && echo yes || echo no)"
check "start: both LaunchAgents bootstrapped" 2 "$(grep -c '^bootstrap gui/' "$CALLS/launchctl")"
"$DEC" start >/dev/null
check "  ...again: already loaded, not bootstrapped twice" 2 "$(grep -c '^bootstrap gui/' "$CALLS/launchctl")"

echo "== 5. doctor, heartbeat =="
for t in pmset defaults; do printf '#!/usr/bin/env bash\ncat "%s/%s.out" 2>/dev/null\n' "$CALLS" "$t" >"$S/bin/$t"; chmod +x "$S/bin/$t"; done
printf "Now drawing from 'AC Power'\n" >"$CALLS/pmset.out"
echo cobalt >"$CALLS/defaults.out"
: >"$CALLS/osa-args"
rc=0; out="$(PATH="$S/bin:$PATH" "$DEC" doctor)" || rc=$?
check "doctor with everything in place: all OK" "0 yes" "$rc $(has 'doctor: all OK' "$out")"
printf "Now drawing from 'Battery Power'\n" >"$CALLS/pmset.out"
: >"$S/key"
rc=0; out="$(PATH="$S/bin:$PATH" "$DEC" doctor)" || rc=$?
check "doctor on battery with an empty key: those two FAIL, nonzero" "1 yes yes yes" \
  "$rc $(has 'FAIL  on AC power' "$out") $(has 'FAIL  the API key file' "$out") $(has 'doctor: 2 FAIL' "$out")"
printf 'sk-test\n' >"$S/key"
chmod 644 "$S/key"
printf "Now drawing from 'AC Power'\n" >"$CALLS/pmset.out"
rc=0; out="$(PATH="$S/bin:$PATH" "$DEC" doctor)" || rc=$?
check "doctor with a key readable by others (0644): that FAIL alone" "1 yes yes" \
  "$rc $(has 'FAIL  the API key file' "$out") $(has 'doctor: 1 FAIL' "$out")"
chmod 600 "$S/key"
touch "$CALLS/osa-empty"
rc=0; out="$(PATH="$S/bin:$PATH" "$DEC" doctor)" || rc=$?
rm "$CALLS/osa-empty"
check "doctor where Messages answers no iMessage account: that FAIL" "1 yes" "$rc $(has 'FAIL  Messages has an iMessage account' "$out")"
echo 1.5 >"$TMP/bal"
printf '#!/usr/bin/env bash\necho "BALANCE_USD: $(cat %s/bal)"\n' "$TMP" >"$S/balance"
rc=0; out="$(PATH="$S/bin:$PATH" "$DEC" doctor)" || rc=$?
check "doctor with the DeepSeek balance under the floor: that FAIL" "1 yes" "$rc $(has 'FAIL  the DeepSeek balance' "$out")"
echo 9 >"$TMP/bal"
mkdir -p "$CW_AO_HOME/attempts/feedfacecafe0001/1"
python3 -c 'import fcntl,os,sys,time; fd=os.open(sys.argv[1], os.O_RDWR|os.O_CREAT); fcntl.flock(fd, fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(4)' \
  "$CW_AO_HOME/attempts/feedfacecafe0001/1/lock" "$TMP/live-locked" &
for _ in $(seq 50); do [[ -e "$TMP/live-locked" ]] && break; sleep 0.1; done
"$DEC" heartbeat >/dev/null || true
wait
check "heartbeat with no supervisor: says so first, and names the walk still running" "yes yes" \
  "$(has 'heartbeat|||||the supervisor is NOT running: at the Mac, cw-decide.sh doctor' "$(tail -n1 "$CALLS/notify")") $(has 'still running without it: feedfacecafe' "$(tail -n1 "$CALLS/notify")")"
rm -rf "$CW_AO_HOME/attempts/feedfacecafe0001"
python3 -c 'import fcntl,os,sys,time; fd=os.open(sys.argv[1], os.O_RDWR|os.O_CREAT); fcntl.flock(fd, fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(5)' \
  "$CW_AO_HOME/supervisor.lock" "$TMP/locked" &
for _ in $(seq 50); do [[ -e "$TMP/locked" ]] && break; sleep 0.1; done
"$DEC" heartbeat >/dev/null
check "heartbeat with the supervisor's lock held: alive, the entries and the spend" "yes yes" \
  "$(has 'heartbeat|||||alive.' "$(tail -n1 "$CALLS/notify")") $(has 'spend: $0.00 in 24 h' "$(tail -n1 "$CALLS/notify")")"
wait

echo
if [[ "$fails" -eq 0 ]]; then
  echo "always-on-decide-test: all passed"
else
  echo "always-on-decide-test: $fails failed"
  exit 1
fi
