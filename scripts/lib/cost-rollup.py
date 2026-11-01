#!/usr/bin/env python3
"""cost-rollup.py JOURNAL [GOAL_ID...] — each goal's implementer cost, by thread.

Prints one tab-separated line per goal, `GOAL  USD  THREADS`, then
`TOTAL  USD  -`. With no GOAL_ID, every goal that has an `implemented` line.

The rule (docs/features/deepseek-primary step 7):
- An `ORCHESTRATOR implemented <id> rN` line belongs to the THREAD_ID on the
  latest `dispatch` or `ids` line of that goal above it (the rule of
  lib/resume-state.py: a fix round that resumes a thread journals its id on the
  dispatch line only).
- Its `FROM=<thread> FROM_COST_USD=<x> FROM_COST_BASIS=<b>` fields, written when
  the launcher fell back, are a line of the primary's thread.
- A thread whose lines say `COST_BASIS=thread` (or none, as on journals before
  the basis existed: Haiku's cost was always the thread's running total) costs
  the LARGEST of its lines: a running total only grows, but a refused or 402
  pass may report only its failed request. `COST_BASIS=pass` lines are summed.
- A goal's cost is the sum over its threads. `COST_USD=-` counts as nothing.
"""
import re
import sys

ROW = re.compile(r"— ORCHESTRATOR (dispatch|ids|implemented) (\S+) r\d+(?=\s|$)")


def field(line: str, key: str) -> str:
    m = re.search(rf"(?<![A-Z_]){key}=(\S+)", line)
    return m.group(1) if m and m.group(1) != "-" else ""


def money(s: str):
    try:
        return float(s)
    except ValueError:
        return None


def main() -> int:
    if len(sys.argv) < 2:
        sys.exit("usage: cost-rollup.py JOURNAL [GOAL_ID...]")
    want = set(sys.argv[2:])
    thread_of = {}   # goal -> current THREAD_ID
    lines = {}       # goal -> thread -> [(usd, basis)]
    order = []
    with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
        for line in f:
            m = ROW.search(line)
            if not m:
                continue
            kind, gid = m.groups()
            if want and gid not in want:
                continue
            if kind in ("dispatch", "ids"):
                t = field(line, "THREAD_ID")
                if t:
                    thread_of[gid] = t
                elif kind == "dispatch" and re.search(r" r0(?=\s|$)", line):
                    thread_of.pop(gid, None)   # a new attempt: no thread yet
                continue
            if gid not in lines:
                lines[gid] = {}
                order.append(gid)
            entries = [(thread_of.get(gid, "?"), field(line, "COST_USD"), field(line, "COST_BASIS"))]
            if field(line, "FROM"):
                entries.append((field(line, "FROM"), field(line, "FROM_COST_USD"),
                                field(line, "FROM_COST_BASIS")))
            for thread, usd, basis in entries:
                v = money(usd)
                if v is not None:
                    lines[gid].setdefault(thread, []).append((v, basis or "thread"))
    total = 0.0
    for gid in order:
        cost = 0.0
        for rows in lines[gid].values():
            cost += max((v for v, b in rows if b != "pass"), default=0.0)
            cost += sum(v for v, b in rows if b == "pass")
        total += cost
        print(f"{gid}\t{cost:.6f}\t{len(lines[gid])}")
    print(f"TOTAL\t{total:.6f}\t-")
    return 0


if __name__ == "__main__":
    sys.exit(main())
