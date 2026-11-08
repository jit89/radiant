#!/usr/bin/env python3
"""Compare a journal's committed text to its working copy.

  orch-files.py journal HEAD_COPY WORKTREE_FILE MODE [GOAL_ID] [--host LEDGER]

MODE:
  --none      the working copy must equal HEAD
  --prefix    the working copy must start with HEAD_COPY, whatever follows
              it (HEAD_COPY being the journal from before the implementer ran)
  --records   HEAD, then only whole journal records: a heading line
              "## <utc> — <ROLE> ..." and the lines under it, for ROLE in
              ORCHESTRATOR, IMPLEMENTER or REVIEWER. An ORCHESTRATOR record
              is that heading alone — the host writes one line — so text
              under it belongs to nobody and is refused, as is loose text
              before any record, and a record naming a goal other than
              GOAL_ID, which --records requires: nothing commits records
              it cannot attribute to the goal being run. An IMPLEMENTER or
              REVIEWER record must name GOAL_ID — the prompt tells the
              implementer to — so a record from another run or another goal
              cannot pass as this one's. An ORCHESTRATOR record need not:
              walk-start belongs to the walk, not to a goal.
              With --host, every appended ORCHESTRATOR record must also be a
              line of LEDGER, the records run-goal.sh wrote for this goal
              (a missing LEDGER holds none): only the host writes them, so a
              record forged by anyone else is not committed under its name.
              (A resume reads the ledger, not the journal: FUTURE-WORK item 25.)

  --headings  every heading line ("## ...") appended after HEAD_COPY has a
              full UTC time, "## <YYYY-MM-DDTHH:MM:SSZ> — <ROLE> ...". With
              HEAD_COPY the journal at BASE_SHA this also sees records the
              implementer committed itself, which --records (against HEAD)
              does not: g30's END record went in as "## 2026-11-07T23:5x — …"
              (a typed time). Records are append-only, so the host reports
              this (a warning event), it does not stop: no fix could remove it.

Exit 0 when the mode holds; otherwise print why and exit 1.

  orch-files.py journal-chain LABEL PATH [LABEL PATH ...]

The journal's versions in order, oldest first: its copy at the goal's
BASE_SHA, at each later commit that touched it, then the working copy last. A
version is kept when it starts with the last version kept; the working copy
must be kept. So a record edited and committed is caught however many commits
later, and putting the edited lines back (keeping what follows) clears it
(FUTURE-WORK item 24). An unreadable version is never kept.

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


def check_records(extra, goal_id, host=None):
    """Return a problem string, or None when every appended line belongs to a
    record of this goal (and, with HOST, every ORCHESTRATOR record is one of
    those lines)."""
    role = None
    for n, line in enumerate(extra.splitlines(), 1):
        m = HEADING.match(line)
        if m:
            role = m.group(2)
            if host is not None and role == "ORCHESTRATOR" and line not in host:
                return (f"appended line {n} is an ORCHESTRATOR record the host did not "
                        f"write: {line[:80]!r}")
            named = set(GOAL_ID.findall(m.group(3) or ""))
            if goal_id and named - {goal_id}:
                other = ", ".join(sorted(named - {goal_id}))
                return f"appended line {n} is a record for {other}, not {goal_id}"
            if goal_id and role != "ORCHESTRATOR" and goal_id not in named:
                return f"appended line {n} is a {role} record naming no goal, not {goal_id}"
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


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return None


def check_chain(pairs):
    """Return a problem string, or None when the last version is kept."""
    kept_label, kept = pairs[0][0], read(pairs[0][1])
    if kept is None:
        return f"the journal at {kept_label} is unreadable"
    broke = None
    for label, path in pairs[1:]:
        text = read(path)
        if text is not None and text.startswith(kept):
            kept_label, kept, broke = label, text, None
        elif broke is None:
            broke = label
    if broke is None:
        return None
    return (f"text already in the journal at {kept_label} was edited, not appended "
            f"to (from {broke} on)")


def main(argv):
    if argv[:1] == ["journal-chain"] and len(argv) >= 5 and len(argv) % 2 == 1:
        it = iter(argv[1:])
        problem = check_chain(list(zip(it, it)))
        if problem:
            print(problem)
            return 1
        return 0
    host = None
    if len(argv) >= 2 and argv[-2] == "--host":
        try:
            with open(argv[-1], encoding="utf-8", errors="replace") as f:
                host = set(f.read().splitlines())
        except OSError:
            host = set()
        argv = argv[:-2]
    if len(argv) not in (4, 5) or argv[0] != "journal" or argv[3] not in (
        "--none", "--records", "--prefix", "--headings"
    ):
        sys.exit(__doc__)
    _, head_path, work_path, mode = argv[:4]
    goal_id = argv[4] if len(argv) == 5 else ""
    if mode == "--records" and not goal_id:
        sys.exit("--records needs the goal whose records may appear")
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
        print("earlier text was edited, not appended to" if mode == "--prefix"
              else "committed text was edited, not appended to")
        return 1
    if mode == "--prefix":
        return 0
    if mode == "--none":
        print("has uncommitted additions")
        return 1
    if mode == "--headings":
        bad = [line for line in work[len(head):].decode("utf-8", "replace").splitlines()
               if line.startswith("## ") and OTHER_ROLE.match(line)
               and not re.match(r"^## \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z — ", line)]
        for line in bad:
            print(f"a heading with no UTC time from date -u: {line[:80]!r}")
        return 1 if bad else 0
    problem = check_records(work[len(head):].decode("utf-8", "replace"), goal_id, host)
    if problem:
        print(problem)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
