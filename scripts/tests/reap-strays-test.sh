#!/usr/bin/env bash
# Self-test: lib/reap-strays.py ends what an agent step left running in the
# checkout, and nothing else. Each process is started detached (a session of
# its own, no terminal, its parent gone), the way a harness leaves one.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-reap-XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
PIDS=()
cleanup() { for p in ${PIDS[@]+"${PIDS[@]}"}; do kill -9 "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT
fails=0
check() {
  if [[ "$2" == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1: want [$2] got [$3]"; fails=$((fails + 1)); fi
}
alive() { kill -0 "$1" 2>/dev/null && echo alive || echo gone; }
# detached DIR SECS — a `sleep` in DIR, in a new session, its parent exited; prints its pid.
detached() {
  python3 -c 'import subprocess,sys; p=subprocess.Popen(["sleep", sys.argv[2]], cwd=sys.argv[1], start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); print(p.pid)' "$1" "$2"
}
mkdir -p "$TMP/repo/sub" "$TMP/elsewhere" "$TMP/repo-sibling"

echo "== reap-strays"
before="$(detached "$TMP/repo" 301)"; PIDS+=("$before")
sleep 0.3
t0="$(python3 -c 'import time; print(f"{time.time():.6f}")')"
in_root="$(detached "$TMP/repo" 302)"; PIDS+=("$in_root")
in_sub="$(detached "$TMP/repo/sub" 303)"; PIDS+=("$in_sub")
outside="$(detached "$TMP/elsewhere" 304)"; PIDS+=("$outside")
sibling="$(detached "$TMP/repo-sibling" 305)"; PIDS+=("$sibling")
# A descendant of the kept script: spared even with its cwd in the checkout.
( cd "$TMP/repo" && exec sleep 306 ) </dev/null >/dev/null 2>&1 & kept_child=$!; disown "$kept_child"; PIDS+=("$kept_child")
sleep 0.5
out="$(python3 "$HERE/lib/reap-strays.py" "$TMP/repo" "$t0" "$$")"
sleep 0.3
check "a stray in the checkout: ended" gone "$(alive "$in_root")"
check "a stray in a subfolder: ended" gone "$(alive "$in_sub")"
check "  ...each one printed" 2 "$(grep -cE '^[0-9]+ sleep 30[23]$' <<<"$out")"
check "started before the step: spared" alive "$(alive "$before")"
check "cwd outside the checkout: spared" alive "$(alive "$outside")"
check "cwd in a sibling with the same prefix: spared" alive "$(alive "$sibling")"
check "a descendant of the kept script: spared" alive "$(alive "$kept_child")"
check "nothing left: no output" "" "$(python3 "$HERE/lib/reap-strays.py" "$TMP/repo" "$t0" "$$" | grep -v "^$before " || true)"
check "a bad call: usage, exit 2" 2 "$(python3 "$HERE/lib/reap-strays.py" 2>/dev/null; echo $?)"

if [[ "$fails" -eq 0 ]]; then
  echo "reap-strays-test: all passed"
else
  echo "reap-strays-test: $fails failed" >&2
  exit 1
fi
