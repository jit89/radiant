#!/usr/bin/env python3
"""resume-state.py JOURNAL GOAL_ID — where an in_progress goal stopped.

Prints one tab-separated line (empty fields as "-"):
  BASE_SHA  ROUND  THREAD_ID  SESSION_ID  PENDING_FIX_ROUND  PENDING_FIX_HASH
or nothing when the journal has no dispatch for the goal.

Reads the ORCHESTRATOR dispatch / ids / review / fix lines of the current
attempt only — from the last `dispatch <id> r0` on; an earlier attempt's
rounds belong to an older BASE_SHA.

- BASE_SHA: the attempt's last dispatch line.
- THREAD_ID / SESSION_ID: the latest non-empty value on dispatch or ids lines.
- A FIX is pending when the attempt's latest review-or-fix line is `fix rK`:
  its findings have not been reviewed since. ROUND is then at least K+1.
- ROUND otherwise: the last dispatched round.
"""
import re
import sys

journal, gid = sys.argv[1], sys.argv[2]
EVENT = re.compile(
    r"— ORCHESTRATOR (dispatch|ids|review|fix) " + re.escape(gid) + r" r(\d+)(?=\s|$)"
)


def field(line: str, key: str) -> str:
    m = re.search(rf"\b{key}=(\S+)", line)
    return m.group(1) if m and m.group(1) != "-" else ""


try:
    with open(journal, encoding="utf-8", errors="replace") as f:
        events = [(m.group(1), int(m.group(2)), line)
                  for line in f if (m := EVENT.search(line))]
except OSError:
    events = []

starts = [i for i, (kind, rnd, _) in enumerate(events) if kind == "dispatch" and rnd == 0]
if not starts:
    sys.exit(0)
attempt = events[starts[-1]:]

base = rnd = ""
thread = session = ""
pending_round = pending_hash = ""
for kind, n, line in attempt:
    if kind == "dispatch":
        base, rnd = field(line, "BASE_SHA"), n
    if kind in ("dispatch", "ids"):
        thread = field(line, "THREAD_ID") or thread
        session = field(line, "SESSION_ID") or session
    if kind == "review":
        pending_round = pending_hash = ""
    if kind == "fix":
        pending_round, pending_hash = n, field(line, "hash")
if pending_round != "":
    rnd = max(rnd, pending_round + 1)

print("\t".join(str(v) if v != "" else "-"
                for v in (base, rnd, thread, session, pending_round, pending_hash)))
