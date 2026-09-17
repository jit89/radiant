#!/usr/bin/env python3
"""Compare a journal's committed text to its working copy.

  orch-files.py journal HEAD_COPY WORKTREE_FILE MODE [GOAL_ID]

MODE:
  --none      the working copy must equal HEAD
  --records   HEAD, then only whole journal records: a heading line
              "## <utc> — <ROLE> ..." and the lines under it, for ROLE in
              ORCHESTRATOR, IMPLEMENTER or REVIEWER. An ORCHESTRATOR record
              is that heading alone — the host writes one line — so text
              under it belongs to nobody and is refused, as is loose text
              before any record, and a record naming a goal other than
              GOAL_ID (empty GOAL_ID accepts any goal).

Exit 0 when the mode holds; otherwise print why and exit 1.

The journal is a shared file: the host appends to it, the implementer appends
to it, and the host commits the result under its own name. Byte ownership
cannot be proved after the fact, so what is committed must at least be
records, of this goal, in the documented shape — a note dropped in by anyone
else is not committed silently.
"""

import re
import sys

HEADING = re.compile(
    r"^## (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) — (ORCHESTRATOR|IMPLEMENTER|REVIEWER)(?:\s(.*))?$"
)
LOOSE_HEADING = re.compile(r"^##\s")
# A role the run itself never writes — ARCHITECT notes, say — is the
# author's to commit, not the orchestrator's.
OTHER_ROLE = re.compile(r"^## \S+ — ([A-Z]{3,}) ")
GOAL_ID = re.compile(r"\bg\d+-[a-z0-9-]+\b")


def check_records(extra, goal_id):
    """Return a problem string, or None when every appended line belongs to a
    record of this goal."""
    role = None
    for n, line in enumerate(extra.splitlines(), 1):
        m = HEADING.match(line)
        if m:
            role = m.group(2)
            named = set(GOAL_ID.findall(m.group(3) or ""))
            if goal_id and named - {goal_id}:
                other = ", ".join(sorted(named - {goal_id}))
                return f"appended line {n} is a record for {other}, not {goal_id}"
            continue
        if LOOSE_HEADING.match(line):
            other = OTHER_ROLE.match(line)
            if other:
                return (f"appended line {n} is a {other.group(1)} record, which this run "
                        f"does not commit: {line[:60]!r}")
            return f"appended line {n} is a heading in no known shape: {line[:60]!r}"
        if not line.strip():
            continue
        if role is None:
            return f"appended line {n} is outside any record: {line[:60]!r}"
        if role == "ORCHESTRATOR":
            return f"appended line {n} follows a one-line ORCHESTRATOR record: {line[:60]!r}"
    return None


def main(argv):
    if len(argv) not in (4, 5) or argv[0] != "journal" or argv[3] not in (
        "--none", "--records"
    ):
        sys.exit(__doc__)
    _, head_path, work_path, mode = argv[:4]
    goal_id = argv[4] if len(argv) == 5 else ""
    with open(head_path, "rb") as f:
        head = f.read()
    try:
        with open(work_path, "rb") as f:
            work = f.read()
    except OSError as e:
        print(f"unreadable ({e.strerror})")
        return 1
    if work == head:
        return 0
    if not work.startswith(head):
        print("committed text was edited, not appended to")
        return 1
    if mode == "--none":
        print("has uncommitted additions")
        return 1
    problem = check_records(work[len(head):].decode("utf-8", "replace"), goal_id)
    if problem:
        print(problem)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
