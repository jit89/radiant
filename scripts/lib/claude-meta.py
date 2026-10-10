#!/usr/bin/env python3
"""claude-meta.py — fingerprint the repo's Claude Code configuration.

Prints one line per file, link or special entry under `.claude/` and for
`.mcp.json`: path, type, then a content hash or link target. Never follows a
link. Run from the repo root; prints nothing when there is nothing.

Directories are not listed: an empty directory configures nothing, and a
directory's contents are listed one by one. Left out: `.claude/worktrees/`, and
`.claude/.cc-writes/`, which Claude Code's own sandbox creates (empty, 0700) in
every repo an implementer session runs in -- measured on the uregex dogfood,
where listing it woke g1 as tampering.

`.claude/settings*.json` can define hooks and MCP servers that Claude Code runs
as the host user in the next session opened here, and Claude Code keeps
`settings.local.json` out of git, so neither the review diff nor the dirty-tree
gate sees it. The implementer's sandbox already denies these writes; this is the
host's own check that nothing got through.
"""
import hashlib
import os
import stat

SKIP = {os.path.join(".claude", "worktrees"), os.path.join(".claude", ".cc-writes")}


def entry(path):
    try:
        st = os.lstat(path)
    except OSError:
        return None
    if stat.S_ISLNK(st.st_mode):
        return f"{path}\tlink\t{os.readlink(path)}"
    if stat.S_ISDIR(st.st_mode):
        return f"{path}\tdir\t-"
    if stat.S_ISREG(st.st_mode):
        h = hashlib.sha256()
        try:
            with open(path, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 16), b""):
                    h.update(chunk)
        except OSError as exc:
            return f"{path}\tunreadable\t{exc.errno}"
        return f"{path}\tfile\t{h.hexdigest()}"
    return f"{path}\tspecial\t{stat.S_IFMT(st.st_mode)}"


lines = []
for top in (".mcp.json",):
    e = entry(top)
    if e:
        lines.append(e)
if os.path.lexists(".claude"):
    if os.path.isdir(".claude") and not os.path.islink(".claude"):
        for root, dirs, files in os.walk(".claude"):
            keep = []
            for d in sorted(dirs):
                p = os.path.join(root, d)
                if p in SKIP:
                    continue
                if os.path.islink(p):  # os.walk lists a link to a dir as a dir
                    lines.append(entry(p))
                else:
                    keep.append(d)
            dirs[:] = keep
            for name in sorted(files):
                e = entry(os.path.join(root, name))
                if e:
                    lines.append(e)
    else:  # .claude itself a link or a file
        e = entry(".claude")
        if e:
            lines.append(e)
lines = sorted(set(x for x in lines if x))
if lines:
    print("\n".join(lines))
