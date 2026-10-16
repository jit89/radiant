#!/usr/bin/env bash
# run-all.sh — run every scripts/tests/*-test.sh, each under a fresh TMPDIR
# parent and a private HOME, and fail if a test fails or leaves anything in
# either. A test must export its own TMPDIR and HOME (folders it removes on
# exit), so the real scripts it drives never write to the real $TMPDIR or
# ~/.cache/claude-coding-workflow; one that forgets shows up here as a leak.
# That isolation is also what lets tests run side by side (-j).
# Not named *-test.sh, so a loop over the tests does not run it.
#
# Usage: scripts/tests/run-all.sh [-j N] [--results DIR] [name-test.sh ...]
#   -j N           tests at a time (default CW_TEST_JOBS, else 4); the report
#                  is printed in name order either way
#   --results DIR  also write DIR/<name>.rc (0 pass, 1 fail or leak) and
#                  DIR/<name>.out (the test's output, then any leak) for each
#                  test; install.sh --check reads these
#
# A full run (no names) of a house checkout also leaves its results in
# ~/.cache/claude-coding-workflow/tests/last/ (the same files, plus summary,
# key and when; key holds the tree's key and the fail count on one line, so
# they always come from one run), keyed by lib/tree-key.py over the tree it tested; kept
# only when the key is the same at the start and the end. install.sh --check
# reuses them while the key still matches. A failed publish changes nothing.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
JOBS="${CW_TEST_JOBS:-4}"
RESULTS=""
names=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -j) [[ $# -ge 2 ]] || { echo "-j needs a number" >&2; exit 2; }
        JOBS="$2"; shift 2 ;;
    -j*) JOBS="${1#-j}"; shift ;;
    --results) [[ $# -ge 2 ]] || { echo "--results needs a directory" >&2; exit 2; }
        RESULTS="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    -*) echo "usage: run-all.sh [-j N] [--results DIR] [name-test.sh ...]" >&2; exit 2 ;;
    *) names+=("$1"); shift ;;
  esac
done
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "-j needs a positive number: $JOBS" >&2; exit 2; }

G=""

# drain PGID — return once no process is left in the group, KILLing it after
# 10 seconds. The group's leader must already be reaped (or not our child).
drain() {
  local i
  for ((i = 0; i < 100; i++)); do
    kill -0 -- "-$1" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -KILL -- "-$1" 2>/dev/null || true
}

# Each test runs in a process group of its own (see START_TEST), so stopping
# one stops everything it started; the terminal's Ctrl-C reaches only this
# script, which passes it on as TERM. Each run_one stops its own test and waits
# until the test's group is empty (its exit traps, run-goal.sh's stop handler
# and run-timeout.py's grace still write under $G); only then is $G removed. A
# test whose run_one died is stopped and drained here. A leaked read-only
# folder must not stop the removal, and a second signal must not cut it short.
cleanup() {
  trap '' INT TERM
  [[ -n "$G" ]] || return 0
  local f p
  for p in $(jobs -p); do kill -TERM "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  for f in "$G"/*/pid; do
    [[ -f "$f" ]] || continue
    p="$(cat "$f" 2>/dev/null || true)"
    [[ -n "$p" ]] || continue
    kill -TERM -- "-$p" "$p" 2>/dev/null || true
    kill -CONT -- "-$p" 2>/dev/null || true
    drain "$p"
  done
  chmod -R u+w "$G" 2>/dev/null || true
  rm -rf "$G" || true
}
# On INT/TERM: clean up, then die of the same signal, so the caller sees a
# death by that signal rather than a plain exit status.
on_signal() {
  cleanup
  trap - "$1" EXIT
  kill -"$1" $$
}
trap cleanup EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
G="$(mktemp -d "${TMPDIR:-/tmp}/cw-run-all-XXXXXX")"

# Before the test list, so a test added meanwhile changes the key.
KEY=""
if [[ ${#names[@]} -eq 0 && -f "$HERE/../lib/tree-key.py" ]]; then
  KEY="$(python3 "$HERE/../lib/tree-key.py" "$HERE/../.." 2>/dev/null || true)"
fi
tests=()
seen=" "
if [[ ${#names[@]} -gt 0 ]]; then
  for t in "${names[@]}"; do
    t="$(basename "$t")"
    [[ "$seen" != *" $t "* ]] || continue
    seen="$seen$t "
    tests+=("$HERE/$t")
  done
else
  for t in "$HERE"/*-test.sh; do tests+=("$t"); done
fi

# START_TEST — exec the test the way an interactive shell would start it: in
# a process group of its own, with SIGINT, SIGQUIT, SIGPIPE and SIGXFSZ at
# their defaults. A background job in a non-interactive bash starts with SIGINT
# and SIGQUIT ignored (run-goal.sh would never see a test's Ctrl-C), and
# Python ignores SIGPIPE and SIGXFSZ; exec keeps whatever is ignored.
START_TEST=(python3 -c 'import os, signal, sys
os.setpgid(0, 0)
for s in (signal.SIGINT, signal.SIGQUIT, signal.SIGPIPE, signal.SIGXFSZ):
    signal.signal(s, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])')

# The caller's settings that steer the launchers' output: every CW_* variable,
# the verdict overrides and the events index location.
UNSETS=(-u GROK_REVIEW_OUT -u CLAUDE_REVIEW_OUT -u EVENTS_CACHE)
while IFS= read -r v; do UNSETS+=(-u "$v"); done < <(compgen -e | grep '^CW_' || true)

# run_one TEST — one test in its own TMPDIR and HOME under $G/<name>/; its
# result in $G/<name>/rc, and failed / leak beside it.
# stop_test — run_one's TERM: stop the test and everything in its group, and
# return only once the group is empty. The pid itself too: until START_TEST
# reaches setpgid the group does not exist yet. A test that outlives 10
# seconds of TERM is KILLed; then the leader is reaped and the rest drained.
stop_test() {
  local i
  if [[ -n "$pid" ]]; then
    kill -TERM -- "-$pid" "$pid" 2>/dev/null || true
    kill -CONT -- "-$pid" 2>/dev/null || true
    for ((i = 0; i < 100; i++)); do
      [[ " $(jobs -rp | tr '\n' ' ') " == *" $pid "* ]] || break
      sleep 0.1
    done
    [[ "$i" -lt 100 ]] || kill -KILL -- "-$pid" "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    drain "$pid"
    rm -f "$d/pid"
  fi
  exit 143
}

run_one() {
  local t="$1" name d left rc=0 pid=""
  trap stop_test TERM
  # INT stays ignored (as a background job starts): the runner forwards it.
  trap '' INT
  trap - EXIT
  name="$(basename "$t")"
  d="$G/$name"
  mkdir -p "$d/tmp" "$d/home"
  "${START_TEST[@]}" env "${UNSETS[@]}" TMPDIR="$d/tmp" HOME="$d/home" \
    bash "$t" </dev/null >"$d/out" 2>&1 &
  pid=$!
  echo "$pid" >"$d/pid"
  if ! wait "$pid"; then
    rc=1
    : >"$d/failed"
  fi
  # Gone now: a later cleanup must not signal a pid the system has reused.
  rm -f "$d/pid"
  pid=""
  # || true: a leaked folder find cannot read must still be reported as a leak.
  left="$(find "$d/tmp" "$d/home" -mindepth 1 -maxdepth 3 2>/dev/null | sed -n "s|^$d/||;1,5p" || true)"
  if [[ -n "$left" ]]; then
    rc=1
    printf '%s\n' "$left" >"$d/leak"
  fi
  echo "$rc" >"$d/rc"
}

# Bash 3.2 has no `wait -n`: cap the running tests by polling.
for t in "${tests[@]}"; do
  while [[ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$JOBS" ]]; do sleep 0.2; done
  run_one "$t" &
done
wait

mkdir -p "$G/res"
fails=0
for t in "${tests[@]}"; do
  name="$(basename "$t")"
  d="$G/$name"
  mkdir -p "$d"
  # No rc file: the test's runner itself died, which is a failure too.
  rc="$(cat "$d/rc" 2>/dev/null || echo 1)"
  [[ -f "$d/rc" ]] || : >"$d/failed"
  echo "$rc" >"$G/res/$name.rc"
  { cat "$d/out" 2>/dev/null || true
    if [[ -f "$d/leak" ]]; then echo "LEAK: left in its TMPDIR or HOME:"; cat "$d/leak"; fi
  } >"$G/res/$name.out"
  if [[ "$rc" == 0 ]]; then
    echo "ok    $name"
    continue
  fi
  fails=$((fails + 1))
  if [[ -f "$d/failed" ]]; then
    echo "FAIL  $name"
    { tail -n 20 "$d/out" 2>/dev/null || true; } | sed 's/^/      /'
  fi
  if [[ -f "$d/leak" ]]; then
    echo "LEAK  $name left:"
    sed 's/^/      /' "$d/leak"
  fi
done >"$G/report"
echo "test scripts: ${#tests[@]}, jobs=$JOBS, fails=$fails" >>"$G/report"
cat "$G/report"

if [[ -n "$RESULTS" ]]; then
  mkdir -p "$RESULTS"
  cp "$G"/res/* "$RESULTS"/
fi
# Published only for the tree the whole run saw: an edit during it changes the key.
if [[ -n "$KEY" && "$KEY" == "$(python3 "$HERE/../lib/tree-key.py" "$HERE/../.." 2>/dev/null || true)" ]]; then
  cache="$HOME/.cache/claude-coding-workflow/tests"
  # Chained, so a failure here never changes this run's exit status; another
  # run's half-filled .new-* is left alone unless it is an hour old.
  new=""
  if mkdir -p "$cache" && chmod 700 "$(dirname "$cache")" "$cache" &&
    { find "$cache" -maxdepth 1 -name '.new-*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true; } &&
    new="$(mktemp -d "$cache/.new-XXXXXX")" &&
    cp "$G"/res/* "$new"/ && cp "$G/report" "$new/summary" &&
    echo "$KEY $fails" >"$new/key" &&
    date -u +%Y-%m-%dT%H:%M:%SZ >"$new/when" &&
    rm -rf "$cache/last" && mv "$new" "$cache/last"; then
    :
  else
    [[ -z "$new" ]] || rm -rf "$new" || true
  fi
fi
[[ "$fails" -eq 0 ]]
