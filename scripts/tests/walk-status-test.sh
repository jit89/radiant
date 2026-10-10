#!/usr/bin/env bash
# Self-test: `events.py status` names the goal an orchestrator is running now
# (goal, round, phase, done/total) from the event index, from anywhere in the
# repo, and reads as idle once the goal stopped or its process is gone.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cw-walk-status-XXXXXX")" && pwd)"
trap 'rm -rf "$TMP"' EXIT
export EVENTS_CACHE="$TMP/cache"
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
mkdir -p "$REPO/docs/journal" "$REPO/src/deep" && cd "$REPO"
git init -q
cp "$HERE/../GOALS.example.md" GOALS.md
printf '# Journal\n' >docs/journal/example.md
JSONL="$EVENTS_CACHE/$(python3 -c 'import hashlib,sys,pathlib; print(hashlib.sha256(str(pathlib.Path(sys.argv[1]).resolve()).encode()).hexdigest()[:16])' "$REPO")/example.jsonl"
mkdir -p "$(dirname "$JSONL")"

LIVE=$$
# A pid whose process has exited. (Killing a background job instead races its
# fork: the child can still be this shell, and its EXIT trap removes $TMP.)
DEAD="$(sh -c 'echo $$')"

LIVE_START="$(ps -o lstart= -p "$LIVE" | tr -s ' ' | sed 's/^ //; s/ $//')"

row() { # event goal round pid [verdict] [phase] [pid_start]
  python3 -c 'import json,sys
e,g,r,pid,v,ph,st=(sys.argv[1:8]+[""]*7)[:7]
p={"pid":int(pid)} if pid else {}
if st: p["pid_start"]=st
if ph: p["phase"]=ph
print(json.dumps({"event":e,"goal_id":g or None,"round":int(r) if r else None,"verdict":v or None,"payload":p}))' "$@" >>"$JSONL"
}
status() { (cd "${1:-$REPO}" && python3 "$HERE/events.py" status --json); }
field() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]))' "$1"; }

check "no events: idle" False "$(status | field running)"

row walk g1-store "" "$LIVE" "" ""
check "walk picked a goal: running" True "$(status | field running)"
check "walk picked a goal: phase start" start "$(status | field phase)"

row dispatch g1-store 0 "$LIVE" "" ""
check "dispatch: implement" implement "$(status | field phase)"
check "label" "g1-store r0 · implement · 0/3" "$(status | field label)"
check "from a subdirectory" implement "$(status "$REPO/src/deep" | field phase)"

row implemented g1-store 0 "" "" ""
check "implemented, no pid on the row: pid from the dispatch" proof "$(status | field phase)"
row phase g1-store 0 "$LIVE" "" review
check "phase event: review" review "$(status | field phase)"
row review g1-store 0 "" FIX ""
check "FIX verdict: fix" fix "$(status | field phase)"
row dispatch g1-store 1 "$LIVE" "" ""
check "round moves on" 1 "$(status | field round)"

row wake g1-store 1 "" "" ""
check "wake: idle" False "$(status | field running)"
check "idle still counts done/total" 3 "$(status | field total)"

row dispatch g1-store 2 "$DEAD" "" ""
check "dead process, no wake: idle" False "$(status | field running)"

row dispatch g2-ack 0 "$LIVE" "" ""
python3 - "$REPO/GOALS.md" <<'PY'
import re,sys
p=sys.argv[1]; t=open(p).read()
t=re.sub(r"(id: g1-store[\s\S]*?status: )\w+", r"\1done", t, count=1)
open(p,"w").write(t)
PY
check "done counts from GOALS.md" "g2-ack r0 · implement · 1/3" "$(status | field label)"

# A pid alive now but started at another time is a reused pid, not the walk.
row dispatch g2-ack 1 "$LIVE" "" "" "Thu Jan  1 00:00:00 1970"
check "reused pid (start time differs): idle" False "$(status | field running)"
row dispatch g2-ack 2 "$LIVE" "" "" "$LIVE_START"
check "same pid and start time: running" True "$(status | field running)"
check "start time compared whitespace-blind" True \
  "$(row phase g2-ack 2 "$LIVE" "" review "  $LIVE_START  " && status | field running)"

check "outside a goals repo: idle" False "$(status "$TMP" | field running)"

# Goals run side by side (a parallel walk): each is judged by its own rows.
row dispatch g3-other 0 "$LIVE" "" "" "$LIVE_START"
check "two live goals: the newest leads" g3-other "$(status | field goal)"
check "two live goals: the other is counted" "g3-other r0 · implement +1 · 1/3" "$(status | field label)"

# The /walk pane's model.
graph() { (cd "${1:-$REPO}" && python3 "$HERE/events.py" graph --json); }
gfield() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }
check "graph: both live goals read as running" "done running running" \
  "$(graph | gfield '" ".join(d["goals"][g]["state"] for g in ("g1-store","g2-ack","g3-other"))')"
check "graph: a running goal's phase is its own" "review implement" \
  "$(graph | gfield 'd["goals"]["g2-ack"]["phase"] + " " + d["goals"]["g3-other"]["phase"]')"
check "graph: rows (g2 under g1, g3 a root of its own)" "●|◉|◉" \
  "$(graph | gfield '"|".join(r["graph"] for r in d["rows"])')"
check "graph: --dir reads another repo" True "$(cd "$TMP" && python3 "$HERE/events.py" graph --json --dir "$REPO" | gfield 'd["found"]')"
check "graph: no GOALS.md" False "$(graph "$TMP" | gfield 'd["found"]')"

# The implementer's cost: the last total of each thread, summed.
for c in "0.10 haiku:a" "0.30 haiku:a" "0.05 deepseek:b" "0.20 deepseek:b"; do
  set -- $c
  printf '{"event":"implemented","goal_id":"g3-other","round":0,"payload":{"model":"claude-haiku-5-5","cost_usd":"%s","thread":"%s"}}\n' "$1" "$2" >>"$JSONL"
done
check "graph: cost adds each thread's last total" 0.5 "$(graph | gfield 'd["goals"]["g3-other"]["cost"]')"

# The layout alone: a diamond forks and joins.
check "layout: a diamond" "○|├─╮|○ │|│ ○|○─╯" "$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1]); import events
g = [{"id": "a"}, {"id": "b", "blocked_by": ["a"]}, {"id": "c", "blocked_by": ["a"]}, {"id": "d", "blocked_by": ["b", "c"]}]
print("|".join(r["graph"] for r in events.lay_out(g)))' "$HERE")"
check "layout: an unknown or self edge is dropped" "○|○" "$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1]); import events
print("|".join(r["graph"] for r in events.lay_out([{"id": "a", "blocked_by": ["zz", "a"]}, {"id": "b"}])))' "$HERE")"

# A GOALS.md that does not parse (one mid-write) is a failed poll, not idle,
# so the footer keeps what it showed.
printf 'no fence here\n' >"$REPO/GOALS.md"
(cd "$REPO" && python3 "$HERE/events.py" status --json >/dev/null 2>&1) && rc=0 || rc=$?
check "unparseable GOALS.md: exit 1" 1 "$rc"

if [[ "$fails" -eq 0 ]]; then
  echo "walk-status: OK"
else
  echo "walk-status: $fails FAILURE(S)" >&2
  exit 1
fi
