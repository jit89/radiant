#!/usr/bin/env python3
"""tree-key.py ROOT — one sha256 for what a full test run of the house tested.

Covers every file git would show in ROOT (tracked, and untracked but not
ignored): its path, whether it is executable or a link, and its content (a
link's target). Plus the git and python versions the tests ran under. ROOT
must be the top of its git work tree. Exits 1, printing nothing, otherwise or
when git fails: no key means no reuse.
"""
import hashlib
import os
import stat
import subprocess
import sys


def git(*args: str) -> bytes:
    return subprocess.run(["git", "-C", root, *args], check=True,
                          capture_output=True).stdout


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
