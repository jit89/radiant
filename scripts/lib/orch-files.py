#!/usr/bin/env python3
"""Compare a journal's committed text to its working copy.

  orch-files.py journal HEAD_COPY WORKTREE_FILE MODE

MODE:
  --none                the working copy must equal HEAD
  --orchestrator-lines  HEAD, then only blank lines and one-line
                        "## <utc> — ORCHESTRATOR ..." records (a stopped run's own)
  --append              HEAD, then anything (a run in progress: the implementer
                        journals too)

Exit 0 when the mode holds; otherwise print why and exit 1.
"""

import re
import sys

ORCH_LINE = re.compile(r"^## \S+ — ORCHESTRATOR \S")


def main(argv):
    if len(argv) != 4 or argv[0] != "journal" or argv[3] not in (
        "--none", "--orchestrator-lines", "--append"
    ):
        sys.exit(__doc__)
    _, head_path, work_path, mode = argv
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
    if mode == "--orchestrator-lines":
        extra = work[len(head):].decode("utf-8", "replace").splitlines()
        other = [line for line in extra if line.strip() and not ORCH_LINE.match(line)]
        if other:
            print(f"has uncommitted additions that are not ORCHESTRATOR records ({len(other)} line(s))")
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
