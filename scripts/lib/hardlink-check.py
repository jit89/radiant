#!/usr/bin/env python3
"""hardlink-check.py [--gitdir DIR]... DIR... — files with a name outside the trees a proof sees.

Seatbelt checks the path a proof opens, not the file behind it, so a hard link
left in a proof's trees before it runs could reach a file the profile denies
(docs/features/proof-sandbox/PLAN.md step 3). For each regular file under the
given trees, the names it has there are counted; a file whose link count is
greater has a name elsewhere, and is printed. Exit 1 if any, else 0.

Links wholly inside the trees (a package manager's own) are fine. Read-only
files in a real gitdir's object store are skipped: `git clone` of a local path
hard-links them to the source repo's objects, which are git data readable
there anyway. "A real gitdir" is a walked tree's own `.git/objects/`, or a
tree named with --gitdir (a worktree's common gitdir, outside the checkout),
whose `objects/` a proof cannot write; never any other folder named `objects`,
and never a checkout made to look like a gitdir.
Symlinks are not followed (the profile checks their target).
"""
import os
import stat
import sys
from collections import Counter


def object_stores(top, is_gitdir):
    stores = [os.path.join(top, ".git", "objects") + os.sep]
    if is_gitdir:
        stores.append(os.path.join(top, "objects") + os.sep)
    return stores


def git_object(path, mode, stores):
    return not (mode & 0o222) and any(path.startswith(s) for s in stores)


def main():
    names, first = Counter(), {}
    trees, args = [], sys.argv[1:]
    while args:
        if args[0] == "--gitdir" and len(args) > 1:
            trees.append((args[1], True))
            args = args[2:]
        else:
            trees.append((args[0], False))
            args = args[1:]
    for top, is_gitdir in trees:
        if not os.path.isdir(top):
            continue
        stores = object_stores(top, is_gitdir)
        for dp, _dns, fns in os.walk(top):
            for n in fns:
                p = os.path.join(dp, n)
                try:
                    st = os.lstat(p)
                except OSError:
                    continue
                # Files, and sockets and FIFOs: a proof may use unix sockets in
                # its TMPDIR, so a link to an outside socket matters too.
                if not (stat.S_ISREG(st.st_mode) or stat.S_ISSOCK(st.st_mode)
                        or stat.S_ISFIFO(st.st_mode)) or st.st_nlink < 2:
                    continue
                if stat.S_ISREG(st.st_mode) and git_object(p, st.st_mode, stores):
                    continue
                k = (st.st_dev, st.st_ino)
                names[k] += 1
                first.setdefault(k, (p, st.st_nlink))
    bad = sorted(p for k, (p, nl) in first.items() if nl > names[k])
    for p in bad:
        print(p)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
