#!/usr/bin/env bash
# Self-test: INT/TERM stop run-goal.sh / run-goals.sh promptly, nonzero, with a
# stop record, and take the running step's whole process tree down with them
# (F-06). Launchers and proof are stubs that sleep; nothing calls a model.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-signal-XXXXXX")"
export TMPDIR="$TMP"
TMP="$(cd "$TMP" && pwd -P)"
# A unique sleep length marks every process a stub starts.
NAP="37.$$"
cleanup() {
  pkill -f "sleep $NAP" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
export HOME="$TMP/home" EVENTS_CACHE="$TMP/cache" STUBS="$TMP/stubs" NAP
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

stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$HOUSE/scripts/$1"
  chmod +x "$HOUSE/scripts/$1"
}
NAPPER='echo "$0 started" >>"$STUBS"; sleep "$NAP"; echo "$0 finished" >>"$STUBS"'
DS_OK='echo impl >impl.txt && git add impl.txt && git commit -qm "wip(g1-store): impl"
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: t1" "RETURN_HANDOFF: -" "LOG: -" "stderr: -"'

# Start CMD in its own session, wait for READY in $STUBS, deliver SIG to the
# process (pid) or its group (group), print "<exit code> <seconds to exit>".
cat >"$TMP/drive.py" <<'PY'
import os, signal, subprocess, sys, time
mode, sig, ready, out = sys.argv[1:5]
cmd = sys.argv[5:]
p = subprocess.Popen(cmd, start_new_session=True,
                     stdout=open(out, "w"), stderr=subprocess.STDOUT)
# The goal runs in a session of its own, out of reach of a signal to this
# test's group: stopping this driver must stop it too (run-all.sh TERMs the
# group on an interrupt).
def stop(signum, frame):
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    sys.exit(128 + signum)
signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
end = time.time() + 30
while time.time() < end:
    try:
        if ready in open(os.environ["STUBS"]).read():
            break
    except FileNotFoundError:
        pass
    if p.poll() is not None:
        print(f"early:{p.returncode} 0")
        sys.exit(0)
    time.sleep(0.1)
else:
    p.kill()
    print("never-ready 0")
    sys.exit(0)
time.sleep(0.5)
t0 = time.time()
s = getattr(signal, sig)
os.killpg(p.pid, s) if mode == "group" else os.kill(p.pid, s)
try:
    rc = p.wait(timeout=60)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    rc = "hung"
print(rc, round(time.time() - t0))
PY

make_repo() {
  rm -rf "$TMP/repo" "$STUBS"
  mkdir -p "$TMP/repo/docs/journal" "$TMP/repo/tests/acceptance" && cd "$TMP/repo"
  git init -q
  cp "$HERE/../GOALS.example.md" GOALS.md
  printf '# Plan\n' >PLAN.md
  printf '# Journal: example\n' >docs/journal/example.md
  git add -- GOALS.md PLAN.md docs/journal/example.md
  git commit -q -m base
}

# drive <pid|group> <SIG> <ready-text> <command...>; sets rc, secs, reason, detail.
drive() {
  local res stop
  res="$(python3 "$TMP/drive.py" "$1" "$2" "$3" "$TMP/out" "${@:4}")"
  rc="${res% *}"
  secs="${res#* }"
  sleep 1
  stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)"
  reason="$(sed -n 's/^- reason: //p' "$stop" 2>/dev/null || true)"
  detail="$(sed -n 's/^- detail: //p' "$stop" 2>/dev/null || true)"
}

survivors() { pgrep -f "sleep $NAP" | wc -l | tr -d ' '; }
fast() { [[ "$secs" =~ ^[0-9]+$ && "$secs" -le 12 ]] && echo yes || echo "no (${secs}s)"; }
journaled() {
  grep -c 'wake g1-store r0 reason=interrupted' docs/journal/example.md || true
}

# 1. TERM to run-goal.sh alone while the implementer runs.
stub claude-implement.sh "$NAPPER"
stub claude-goal-review.sh 'exit 1'
make_repo
drive pid SIGTERM claude-implement.sh "$HOUSE/scripts/run-goal.sh" g1-store
check "goal TERM: exit 143" "143" "$rc"
check "goal TERM: stops promptly" "yes" "$(fast)"
check "goal TERM: stop reason" "interrupted" "$reason"
check "goal TERM: detail names the phase" "yes" \
  "$([[ "$detail" == *SIGTERM*implementer* ]] && echo yes || echo "no: $detail")"
check "goal TERM: wake journaled" "1" "$(journaled)"
check "goal TERM: implementer killed" "0" "$(survivors)"
check "goal TERM: implementer never finished" "0" \
  "$(grep -c finished "$STUBS" || true)"

# 2. Ctrl-C (INT to the whole group) while the reviewer runs.
stub claude-implement.sh "$DS_OK"
stub claude-goal-review.sh "$NAPPER"
make_repo
drive group SIGINT claude-goal-review.sh "$HOUSE/scripts/run-goal.sh" g1-store
check "goal Ctrl-C: exit 130" "130" "$rc"
check "goal Ctrl-C: stops promptly" "yes" "$(fast)"
check "goal Ctrl-C: detail names review" "yes" \
  "$([[ "$detail" == *SIGINT*review* ]] && echo yes || echo "no: $detail")"
check "goal Ctrl-C: reviewer killed" "0" "$(survivors)"

# 3. TERM while the host proof runs (file oracle, command proof).
stub claude-goal-review.sh 'exit 1'
make_repo
# The proof runs under the proof sandbox, which lets it write only its
# checkout and TMPDIR: its started/finished marker is an ignored file there.
STUBS_OUTSIDE="$STUBS"
export STUBS="$TMP/repo/.stubs"
printf '.stubs\n' >.gitignore
printf '%s\n' "$NAPPER" >tests/acceptance/g1-store.sh
sed -i.bak -e '/id: g1-store/,/status:/{
s|proof: true|proof: bash tests/acceptance/g1-store.sh|
s|oracle: inline|oracle: tests/acceptance/g1-store.sh|
}' GOALS.md && rm -f GOALS.md.bak
git add -A && git commit -q -m "file oracle"
drive pid SIGTERM tests/acceptance/g1-store.sh "$HOUSE/scripts/run-goal.sh" g1-store
check "proof TERM: exit 143" "143" "$rc"
check "proof TERM: stops promptly" "yes" "$(fast)"
check "proof TERM: detail names proof" "yes" \
  "$([[ "$detail" == *SIGTERM*proof* ]] && echo yes || echo "no: $detail")"
check "proof TERM: proof killed" "0" "$(survivors)"
export STUBS="$STUBS_OUTSIDE"

# 4. TERM to the walker alone: child stopped, walk ends, no next dispatch.
stub claude-implement.sh "$NAPPER"
make_repo
drive pid SIGTERM claude-implement.sh "$HOUSE/scripts/run-goals.sh"
check "walk TERM: exit 143" "143" "$rc"
check "walk TERM: stops promptly" "yes" "$(fast)"
check "walk TERM: child stop file reprinted" "interrupted" "$reason"
check "walk TERM: implementer killed" "0" "$(survivors)"
check "walk TERM: no further dispatch" "1" "$(grep -c started "$STUBS" || true)"

# 5. Ctrl-C to the walker's whole group.
make_repo
drive group SIGINT claude-implement.sh "$HOUSE/scripts/run-goals.sh"
check "walk Ctrl-C: exit 130" "130" "$rc"
check "walk Ctrl-C: stops promptly" "yes" "$(fast)"
check "walk Ctrl-C: child stop file reprinted" "interrupted" "$reason"
check "walk Ctrl-C: implementer killed" "0" "$(survivors)"
check "walk Ctrl-C: no further dispatch" "1" "$(grep -c started "$STUBS" || true)"

if [[ "$fails" -eq 0 ]]; then
  echo "signals: OK"
else
  echo "signals: $fails FAILURE(S)" >&2
  exit 1
fi
