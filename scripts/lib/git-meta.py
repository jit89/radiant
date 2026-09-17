#!/usr/bin/env python3
"""Fingerprint the parts of a gitdir that can make git run or hide something.

  git-meta.py manifest OUT GITDIR...   write the manifest to OUT
  git-meta.py verify SAVED GITDIR...   compare to SAVED (write it if absent)

Exit 0: unchanged, or manifest/baseline written. Exit 1: prints one line per
changed path, or per path that could not be fingerprinted. Never runs git.

Only regular files are opened, non-blocking and without following links: a
FIFO in hooks/ would otherwise block the read forever, outside every step
timeout. A FIFO, socket, device, or a path that cannot be read (permissions,
removed mid-walk) fails verification: nothing git needs there is like that.
"""

import hashlib
import os
import stat
import sys

NAMES = ("config", "config.worktree", "hooks", "info")
# Written by git itself: repack (run by background auto-maintenance after
# commits) regenerates info/refs, a ref list for dumb HTTP that nothing runs.
GENERATED = ("info/refs",)


def hash_regular(path):
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0))
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError(f"{path}: replaced while reading")
        h = hashlib.sha256()
        while True:
            chunk = os.read(fd, 1 << 16)
            if not chunk:
                return h.hexdigest()
            h.update(chunk)
    finally:
        os.close(fd)


def manifest(dirs):
    """Return (rows, problems): sorted manifest rows, and paths that fail."""
    rows, problems = [], []

    def add(path, rel):
        if rel in GENERATED:
            return
        try:
            st = os.lstat(path)
            mode = st.st_mode
            perm = oct(mode & 0o7777)
            if stat.S_ISLNK(mode):
                rows.append(f"{path}\tlink\t-\t{os.readlink(path)}")
            elif stat.S_ISDIR(mode):
                rows.append(f"{path}\tdir\t{perm}\t-")
                for name in sorted(os.listdir(path)):
                    add(os.path.join(path, name), f"{rel}/{name}")
            elif stat.S_ISREG(mode):
                rows.append(f"{path}\tfile\t{perm}\t{hash_regular(path)}")
            else:
                kind = (
                    "fifo" if stat.S_ISFIFO(mode)
                    else "socket" if stat.S_ISSOCK(mode)
                    else "device" if stat.S_ISCHR(mode) or stat.S_ISBLK(mode)
                    else "unknown"
                )
                rows.append(f"{path}\t{kind}\t{perm}\t-")
                problems.append(f"{path} ({kind}; special files are not allowed)")
        except OSError as e:
            problems.append(f"{path} (unreadable: {e.strerror or e})")

    for d in dirs:
        for name in NAMES:
            p = os.path.join(d, name)
            if os.path.lexists(p):
                add(p, name)
    return sorted(rows), problems


def read_rows(path):
    with open(path) as f:
        return {line.split("\t", 1)[0]: line.rstrip("\n") for line in f if line.strip()}


def main(argv):
    mode, target, dirs = argv[0], argv[1], argv[2:]
    rows, problems = manifest(dirs)
    for p in problems:
        print(p)
    if problems:
        return 1
    if mode == "manifest" or not os.path.exists(target):
        with open(target, "w") as f:
            f.write("".join(r + "\n" for r in rows))
        return 0
    saved = read_rows(target)
    now = {r.split("\t", 1)[0]: r for r in rows}
    changed = [p for p in sorted(set(saved) | set(now)) if saved.get(p) != now.get(p)]
    for p in changed:
        print(p)
    return 1 if changed else 0


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("manifest", "verify"):
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1:]))
