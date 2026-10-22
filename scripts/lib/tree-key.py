#!/usr/bin/env python3
"""tree-key.py ROOT — one sha256 for what a full test run of the house tested.

Covers every file git would show in ROOT (tracked, and untracked but not
ignored) except documentation no test reads (excluded() below): its path,
whether it is executable or a link, and its content (a link's target). Plus
the git and python versions the tests ran under. ROOT must be the top of its
git work tree. Exits 1, printing nothing, otherwise or when git fails: no key
means no reuse.

  tree-key.py --excluded PATH...   prints each PATH the key leaves out

A doc-only change (a journal entry, a plan, FUTURE-WORK, README) then keeps
the key, so install.sh --check reuses the run instead of rerunning the suite
(FUTURE-WORK item 20). scripts/tests/check-reuse-test.sh fails if a test script
names a left-out path through $HERE/../ (the house's idiom for reading the house
top), so a test that starts reading a doc that way stays red until this file
keeps it (KEPT_TOP_MD for a top-level file, excluded() for one under docs/).
"""
import hashlib
import os
import stat
import subprocess
import sys


# Top-level Markdown files a test reads stay in the key; every other top-level
# *.md, and everything under docs/, is documentation the suite never runs.
KEPT_TOP_MD = {"GOALS.example.md"}


def excluded(rel: str) -> bool:
    if rel.startswith("docs/"):
        return True
    return "/" not in rel and rel.endswith(".md") and rel not in KEPT_TOP_MD


def git(*args: str) -> bytes:
    return subprocess.run(["git", "-C", root, *args], check=True,
                          capture_output=True).stdout


if len(sys.argv) > 1 and sys.argv[1] == "--excluded":
    # A folder named without a trailing slash (docs) counts as what it holds; a
    # top-level file named docs is still keyed (the hash below never asks).
    for rel in sys.argv[2:]:
        if excluded(rel) or excluded(rel.rstrip("/") + "/"):
            print(rel)
    sys.exit(0)

root = os.path.realpath(sys.argv[1])
try:
    top = git("rev-parse", "--show-toplevel").decode().strip()
    if os.path.realpath(top) != root:
        sys.exit(1)
    paths = sorted(set(git("ls-files", "-z", "--cached", "--others",
                           "--exclude-standard").split(b"\0")) - {b""})
    gitv = git("--version")
except (subprocess.CalledProcessError, OSError):
    sys.exit(1)

h = hashlib.sha256()
h.update(gitv + sys.version.encode() + b"\0")
for rel in paths:
    if excluded(rel.decode("utf-8", "surrogateescape")):
        continue
    p = os.path.join(root.encode(), rel)
    try:
        st = os.lstat(p)
    except FileNotFoundError:
        continue  # deleted, not yet staged: nothing of it is tested
    if stat.S_ISLNK(st.st_mode):
        kind, body = b"l", os.readlink(p)
    elif stat.S_ISREG(st.st_mode):
        kind = b"x" if st.st_mode & 0o111 else b"f"
        with open(p, "rb") as f:
            body = hashlib.sha256(f.read()).digest()
    else:
        continue  # a submodule or other non-file entry
    h.update(rel + b"\0" + kind + body + b"\0")
print(h.hexdigest())
