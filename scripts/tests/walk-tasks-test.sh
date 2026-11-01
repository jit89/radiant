#!/usr/bin/env bash
# Self-test for the walk mod's task list (docs/features/walk-tasks): the walk
# file records its launcher and root atomically, `events.py walks` lists the
# walks a session launched with `live` and `started` read from the walker's
# own rows, and `graph` names why a goal stopped. Real events.py, a throwaway
# cache (EVENTS_CACHE), live and dead pids.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
EV="$HERE/events.py"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cw-walk-tasks-XXXXXX")" && pwd)"
export TMPDIR="$TMP" HOME="$TMP/home"; mkdir -p "$HOME"
trap 'rm -rf "$TMP"' EXIT
export EVENTS_CACHE="$TMP/cache"
unset CLAUDE_CODE_SESSION_ID
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

LIVE=$$
LIVE_START="$(ps -o lstart= -p "$LIVE" | tr -s ' ' | sed 's/^ //; s/ $//')"
DEAD="$(sh -c 'echo $$')"
OLD_START="Thu Jan  1 00:00:00 2015"

rid() { python3 -c 'import hashlib,sys,pathlib; print(hashlib.sha256(str(pathlib.Path(sys.argv[1]).resolve()).encode()).hexdigest()[:16])' "$1"; }
mkrepo() { # name -> path, a git repo with GOALS.md and a journal
  local r="$TMP/$1"
  mkdir -p "$r/docs/journal"
  (cd "$r" && git init -q && cp "$HERE/../GOALS.example.md" GOALS.md && printf '# Journal\n' >docs/journal/example.md)
  echo "$r"
}
walkfile() { echo "$EVENTS_CACHE/$(rid "$1")/example.walk"; }
jsonl() { echo "$EVENTS_CACHE/$(rid "$1")/example.jsonl"; }
mtime() { python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$1"; }
ensure() { # repo [session] -> stdout of ensure-walk
  (cd "$1" && CLAUDE_CODE_SESSION_ID="${2:-}" python3 "$EV" ensure-walk docs/journal/example.md)
}
row() { # repo walk_id event goal mono pid pid_start [reason]
  python3 -c 'import json,sys
f,w,e,g,mono,pid,st,reason=(sys.argv[1:9]+[""]*8)[:8]
p={}
if pid: p["pid"]=int(pid)
if st: p["pid_start"]=st
print(json.dumps({"ts":"2026-10-14T00:00:00Z","ts_mono":int(mono),"walk_id":w,"goal_id":g or None,
  "event":e,"reason":reason or None,"payload":p}))' "$(jsonl "$1")" "${@:2}" >>"$(jsonl "$1")"
}
walks() { python3 "$EV" walks "$@" --json; }
get() { # walks-json walk_id field
  python3 -c 'import json,sys
ws=json.loads(sys.argv[1]); w=[x for x in ws if x["walk_id"]==sys.argv[2]]
print(w[0].get(sys.argv[3]) if w else "absent")' "$1" "$2" "$3"
}
journal_mentions() { printf '## x — ORCHESTRATOR walk-start walk_id=%s\n' "$2" >>"$1/docs/journal/example.md"; }

echo "== walk file: launcher, root, atomic writes"
A="$(mkrepo a)"
out="$(ensure "$A" sess-1)"
WA="${out##*$'\t'}"
check "mint prints minted<TAB>id" "minted" "${out%%$'\t'*}"
check "walk file session" "sess-1" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("session"))' "$(walkfile "$A")")"
check "walk file root" "$(cd "$A" && pwd -P)" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("root"))' "$(walkfile "$A")")"
check "no temp file left beside it" "0" "$(find "$(dirname "$(walkfile "$A")")" -name '.*.tmp' | wc -l | tr -d ' ')"
journal_mentions "$A" "$WA"
m1="$(mtime "$(walkfile "$A")")"; sleep 1.1
out="$(ensure "$A" sess-1)"
check "reuse, same session: stdout unchanged" "reused	$WA" "$out"
check "reuse, same session: file untouched (mtime)" "$m1" "$(mtime "$(walkfile "$A")")"
out="$(ensure "$A")"
check "reuse, no session var: file untouched" "$m1" "$(mtime "$(walkfile "$A")")"
check "reuse, no session var: session kept" "sess-1" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("session"))' "$(walkfile "$A")")"
out="$(ensure "$A" sess-2)"
check "reuse, other session: same id" "reused	$WA" "$out"
check "reuse, other session: session moves" "sess-2" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("session"))' "$(walkfile "$A")")"

echo "== walks: which files are listed"
check "missing cache root: [] exit 0" "[]" "$(EVENTS_CACHE="$TMP/nope" python3 "$EV" walks --session x --json)"
w="$(walks --session sess-2)"
check "listed for its session" "$WA" "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0]["walk_id"])' "$w")"
check "not listed for another session" "[]" "$(walks --session sess-1)"
check "several ids" "1" "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$(walks --session nope --session sess-2)")"
check "from a cwd unrelated to any root" "$WA" "$(cd "$TMP" && get "$(walks --session sess-2)" "$WA" walk_id)"
B="$(mkrepo b)"; mkdir -p "$(dirname "$(walkfile "$B")")"
printf '{"walk_id":"nosess","journal":"x","root":"%s"}\n' "$B" >"$(walkfile "$B")"
check "no session field: skipped" "absent" "$(get "$(walks --session sess-2)" nosess walk_id)"
printf '{"walk_id":"noroot","journal":"x","session":"sess-2"}\n' >"$(walkfile "$B")"
check "no root field: skipped" "absent" "$(get "$(walks --session sess-2)" noroot walk_id)"
printf 'not json' >"$(walkfile "$B")"
check "unparsable file: skipped" "1" "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$(walks --session sess-2)")"
printf '\xff\xfe{"walk_id":"bin"}' >"$(walkfile "$B")"
check "non-UTF-8 file: skipped" "1" "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$(walks --session sess-2)")"
printf '{"walk_id":"listsess","journal":"x","session":["sess-2"],"root":"%s"}\n' "$B" >"$(walkfile "$B")"
check "session not a string: skipped" "1" "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$(walks --session sess-2)")"
check "mtime is milliseconds" "True" "$(python3 -c 'import json,sys,time; m=json.loads(sys.argv[1])[0]["mtime"]; print(abs(m/1000-time.time())<3600)' "$(walks --session sess-2)")"
if [[ "$(id -u)" != 0 ]]; then
  chmod 000 "$EVENTS_CACHE"
  set +e; python3 "$EV" walks --session x --json >/dev/null 2>&1; rc=$?; set -e
  chmod 755 "$EVENTS_CACHE"
  check "unreadable cache root: nonzero" "1" "$rc"
fi

echo "== walks: live and started"
check "no rows: not live" "False" "$(get "$(walks --session sess-2)" "$WA" live)"
row "$A" "$WA" walk g1-store 1000 "$LIVE" "$LIVE_START"
check "walk row with a live pid: live" "True" "$(get "$(walks --session sess-2)" "$WA" live)"
check "started is that row's ts_mono" "1000" "$(get "$(walks --session sess-2)" "$WA" started)"
row "$A" "$WA" dispatch g1-store 1100 "$DEAD" "$OLD_START"
row "$A" "$WA" done g1-store 1200 "" ""
check "between goals (after done): still live" "True" "$(get "$(walks --session sess-2)" "$WA" live)"
for i in $(seq 1 450); do row "$A" "$WA" phase g1-store $((2000 + i)) "$DEAD" "$OLD_START"; done
row "$A" "$WA" walk g2-ack 3000 "$LIVE" "$LIVE_START"
check "started fixed with the first pid row >400 lines back" "1000" "$(get "$(walks --session sess-2)" "$WA" started)"
row "$A" "$WA" walk_end "" 3100 "" ""
check "walk_end newer than the live row: not live" "False" "$(get "$(walks --session sess-2)" "$WA" live)"
check "not live: started null" "None" "$(get "$(walks --session sess-2)" "$WA" started)"
row "$A" "$WA" walk g3-x 3200 "$LIVE" "$LIVE_START"
check "stale walk_end, then a later live row (reused id): live" "True" "$(get "$(walks --session sess-2)" "$WA" live)"

C="$(mkrepo c)"
out="$(ensure "$C" sess-2)"; WC="${out##*$'\t'}"
row "$C" "$WC" dispatch g1-store 5000 "$LIVE" "$LIVE_START"
check "/run-goal (dispatch, no walk row): live" "True" "$(get "$(walks --session sess-2)" "$WC" live)"
check "/run-goal started" "5000" "$(get "$(walks --session sess-2)" "$WC" started)"

D="$(mkrepo d)"
out="$(ensure "$D" sess-2)"; WD="${out##*$'\t'}"
# An older run that had the same pid number but another process start.
row "$D" "$WD" walk g1-store 100 "$LIVE" "$OLD_START"
row "$D" "$WD" walk g2-ack 900 "$LIVE" "$LIVE_START"
check "reused pid number from an older run: not counted" "900" "$(get "$(walks --session sess-2)" "$WD" started)"

E="$(mkrepo e)"
out="$(ensure "$E" sess-2)"; WE="${out##*$'\t'}"
row "$E" "$WE" walk g1-store 700 "$DEAD" "$OLD_START"
row "$E" "$WE" walk g1-store 700 "$LIVE" "$LIVE_START"
check "dead and live rows in one ms: later line wins" "True" "$(get "$(walks --session sess-2)" "$WE" live)"
F="$(mkrepo f)"
out="$(ensure "$F" sess-2)"; WF="${out##*$'\t'}"
row "$F" "$WF" walk g1-store 700 "$LIVE" "$LIVE_START"
row "$F" "$WF" walk g1-store 700 "$DEAD" "$OLD_START"
check "live then dead row in one ms: dead wins" "False" "$(get "$(walks --session sess-2)" "$WF" live)"

echo "== graph: reason"
G="$(mkrepo g)"
out="$(ensure "$G" sess-3)"; WG="${out##*$'\t'}"
setstatus() { (cd "$G" && python3 "$HERE/goals.py" GOALS.md set "$1" "$2" >/dev/null); }
reason() { (cd "$G" && python3 "$EV" graph --json) | python3 -c 'import json,sys; print(json.load(sys.stdin)["goals"][sys.argv[1]]["reason"])' "$1"; }
setstatus g1-store in_progress
row "$G" "$WG" walk g1-store 100 "$DEAD" "$OLD_START"
row "$G" "$WG" wake g1-store 200 "" "" proof-red
check "paused: the goal's own wake" "proof-red" "$(reason g1-store)"
row "$G" "$WG" dispatch g1-store 300 "$DEAD" "$OLD_START"
check "wake older than the goal's dispatch: stopped" "stopped" "$(reason g1-store)"
row "$G" "$WG" wake "" 400 "" "" walk-stuck
check "goal-less wake newer than the dispatch" "walk-stuck" "$(reason g1-store)"
row "$G" "$WG" wake g1-store 500 "" "" ""
check "a wake with no reason is skipped" "walk-stuck" "$(reason g1-store)"
row "$G" "$WG" dispatch g1-store 600 "$DEAD" "$OLD_START"
row "$G" "$WG" wake g1-store 600 "" "" dirty-tree
check "wake in the same ms as the dispatch, later line: newer" "dirty-tree" "$(reason g1-store)"
setstatus g1-store bounced
row "$G" "$WG" dispatch g1-store 700 "$DEAD" "$OLD_START"
row "$G" "$WG" bounced g1-store 800 "" "" ""
check "bounced, its wake missing: stopped" "stopped" "$(reason g1-store)"
row "$G" "$WG" wake g1-store 900 "" "" max-fix-rounds
check "bounced, then its wake" "max-fix-rounds" "$(reason g1-store)"
check "a ready goal has no reason" "None" "$(reason g2-ack)"
check "never the word null" "0" "$( (cd "$G" && python3 "$EV" graph --json) | grep -c '"reason": "null"' || true)"

echo "== the mod's fixtures are what events.py prints now"
python3 "$HERE/gen-walk-fixtures.py" "$TMP/fixtures.ts" >/dev/null
if diff -u "$HERE/../mods/walk/hooks/fixtures.ts" "$TMP/fixtures.ts" >"$TMP/fixtures.diff"; then
  echo "  ok   mods/walk/hooks/fixtures.ts matches a fresh run"
else
  echo "  FAIL mods/walk/hooks/fixtures.ts is stale (rerun scripts/gen-walk-fixtures.py):"
  head -20 "$TMP/fixtures.diff"
  fails=$((fails + 1))
fi

echo
if [[ "$fails" -eq 0 ]]; then echo "walk-tasks-test: all ok"; else echo "walk-tasks-test: $fails failed"; exit 1; fi
