#!/usr/bin/env python3
"""Join a goal branch's journal onto the walk branch's (parallel walker).

  journal-merge.py BASE OURS THEIRS GOAL_ID OUT

BASE is the journal at the merge base, OURS the walk branch's, THEIRS the
goal branch's. The journal is append-only, so a merge of it is determined:
BASE, then what the walk branch appended, then what the goal appended. Both
sides must be BASE plus a byte-for-byte suffix; the goal's suffix must also be
whole records of GOAL_ID (orch-files.py's rule). The walk side's suffix is not
held to that rule: after the first integration of a walk it carries other
goals' records by design, and the walker's own expected copy vouches for it.

Writes the joined journal to OUT and exits 0, or prints why to stdout and
exits 1, writing nothing. Used for an integration (merge) and for a bounce
(the goal's suffix onto the walk journal, no code merged): the same bytes.
"""

import importlib.util
import os
import re
import sys

# Records only the walker writes (PLAN Amendment 3). A goal's journal may hold
# what run-goal.sh and its implementer write, never these: a planted
# `finished` line copied onto the walk journal would read as the walker's.
WALKER_ONLY = re.compile(
    r"^## \S+ — ORCHESTRATOR (finished|recut|integrated|wave|wave-stop|walk|walk-start|walk-end|walk-stuck)(\s|$)",
    re.M,
)


def _check_records():
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("orch_files", os.path.join(here, "orch-files.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.check_records


def read(path):
    with open(path, "rb") as f:
        return f.read()


def join(base, ours, theirs, goal_id):
    """The joined bytes, or (None, why)."""
    if not ours.startswith(base):
        return None, "walk branch journal: committed text was edited, not appended to"
    if not theirs.startswith(base):
        return None, f"{goal_id} journal: committed text was edited, not appended to"
    walk_add, goal_add = ours[len(base):], theirs[len(base):]
    # Already joined (a bounce appended these records, then the goal was
    # recut): the walk side holds them byte for byte; nothing to add.
    if goal_add and goal_add in walk_add:
        return ours, None
    m = WALKER_ONLY.search(goal_add.decode("utf-8", "replace"))
    if m:
        return None, f"{goal_id} journal: holds a walker-only record ({m.group(1)})"
    problem = _check_records()(goal_add.decode("utf-8", "replace"), goal_id)
    if problem:
        return None, f"{goal_id} journal: {problem}"
    sep = b"\n" if walk_add and goal_add and not walk_add.endswith(b"\n") else b""
    return base + walk_add + sep + goal_add, None


def main(argv):
    if len(argv) != 5:
        sys.exit(__doc__)
    base_p, ours_p, theirs_p, goal_id, out_p = argv
    try:
        base, ours, theirs = read(base_p), read(ours_p), read(theirs_p)
    except OSError as e:
        print(f"unreadable: {e.filename} ({e.strerror})")
        return 1
    joined, why = join(base, ours, theirs, goal_id)
    if joined is None:
        print(why)
        return 1
    with open(out_p, "wb") as f:
        f.write(joined)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
