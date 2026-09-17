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

A config file is followed: `include.path` and `includeIf.*.path` name more
config, anywhere on disk, and a filter or textconv driver defined there runs
as the host user just the same. Every include is fingerprinted, whatever its
condition — conditions are not evaluated here, so the set is a superset of
what git will read. A symlink is fingerprinted by its link text *and* by what
it resolves to, so retargeting it, or editing the target, is a change.
"""

import hashlib
import os
import re
import stat
import sys

NAMES = ("config", "config.worktree", "hooks", "info")
# Written by git itself: repack (run by background auto-maintenance after
# commits) regenerates info/refs, a ref list for dumb HTTP that nothing runs.
GENERATED = ("info/refs",)
CONFIG_NAMES = ("config", "config.worktree")
MAX_INCLUDE_DEPTH = 16
# A hook or config file is small. Anything larger is not something to hash on
# every host git call, and nothing git needs there is that big.
MAX_HASH_BYTES = 16 << 20

SECTION_RE = re.compile(r"^\s*\[\s*([A-Za-z0-9.-]+)")
KEY_RE = re.compile(r"^\s*([A-Za-z][A-Za-z0-9-]*)\s*=\s*(.*)$")


def hash_regular(path, size):
    if size > MAX_HASH_BYTES:
        raise OSError(f"{size} bytes, over the {MAX_HASH_BYTES} byte limit")
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0))
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError("replaced while reading")
        h = hashlib.sha256()
        while True:
            chunk = os.read(fd, 1 << 16)
            if not chunk:
                return h.hexdigest()
            h.update(chunk)
    finally:
        os.close(fd)


def unquote(value):
    """A git config value: strip a trailing comment, quotes and escapes."""
    out, quoted, i = [], False, 0
    while i < len(value):
        c = value[i]
        if c == "\\" and i + 1 < len(value):
            nxt = value[i + 1]
            out.append({"n": "\n", "t": "\t", "b": "\b"}.get(nxt, nxt))
            i += 2
            continue
        if c == '"':
            quoted = not quoted
        elif c in "#;" and not quoted:
            break
        else:
            out.append(c)
        i += 1
    return "".join(out).strip()


def include_paths(text, config_path):
    """Every path an [include] / [includeIf] section names, plus unresolvable
    ones as (None, raw). Relative paths resolve against the config's dir."""
    found, section = [], ""
    base = os.path.dirname(config_path)
    for line in text.splitlines():
        m = SECTION_RE.match(line)
        if m:
            section = m.group(1).lower()
            line = line[m.end():].lstrip()
            # "[include] path = x" on one line: drop the rest of the header.
            if line.startswith('"'):
                end = line.find('"', 1)
                line = line[end + 1:] if end != -1 else ""
            line = line.lstrip("] \t")
        if section not in ("include", "includeif"):
            continue
        k = KEY_RE.match(line)
        if not k or k.group(1).lower() != "path":
            continue
        raw = unquote(k.group(2))
        if not raw:
            continue
        if raw.startswith("~/"):
            home = os.environ.get("HOME")
            if not home:
                found.append((None, raw))
                continue
            found.append((os.path.join(home, raw[2:]), raw))
        elif raw.startswith("~") or raw.startswith("%(prefix)"):
            # ~user and %(prefix) need git's own expansion: fail closed.
            found.append((None, raw))
        elif os.path.isabs(raw):
            found.append((raw, raw))
        else:
            found.append((os.path.join(base, raw), raw))
    return found


def manifest(dirs):
    """Return (rows, problems): sorted manifest rows, and paths that fail."""
    rows, problems, seen, followed = [], [], set(), set()

    def add(path, rel, depth=0, config=False):
        if rel in GENERATED:
            return
        # Lexical, not resolved: a symlink and its target are both recorded.
        key = (os.path.abspath(path), rel)
        if key in seen:
            return
        seen.add(key)
        try:
            st = os.lstat(path)
            mode = st.st_mode
            perm = oct(mode & 0o7777)
            if stat.S_ISLNK(mode):
                target = os.readlink(path)
                rows.append(f"{path}\tlink\t-\t{target}")
                # ...and what it resolves to: retargeting or editing the
                # target changes the manifest too.
                resolved = os.path.realpath(path)
                if os.path.lexists(resolved):
                    add(resolved, rel, depth, config)
                else:
                    rows.append(f"{path}\tdangling\t-\t{resolved}")
            elif stat.S_ISDIR(mode):
                rows.append(f"{path}\tdir\t{perm}\t-")
                for name in sorted(os.listdir(path)):
                    add(os.path.join(path, name), f"{rel}/{name}", depth)
            elif stat.S_ISREG(mode):
                rows.append(f"{path}\tfile\t{perm}\t{hash_regular(path, st.st_size)}")
                if config:
                    follow_includes(path, rel, depth)
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

    def follow_includes(path, rel, depth):
        # Two configs including each other must not loop.
        real = os.path.realpath(path)
        if real in followed:
            return
        followed.add(real)
        if depth >= MAX_INCLUDE_DEPTH:
            problems.append(f"{path} (include chain deeper than {MAX_INCLUDE_DEPTH})")
            return
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError as e:
            problems.append(f"{path} (unreadable: {e.strerror or e})")
            return
        for target, raw in include_paths(text, path):
            if target is None:
                problems.append(f"{path} (include path {raw!r} cannot be resolved here)")
                continue
            if os.path.lexists(target):
                add(target, f"{rel}->include", depth + 1, config=True)
            else:
                # git ignores a missing include; record it so creating the
                # file later is a change, not a silent new filter.
                rows.append(f"{target}\tmissing-include\t-\t{path}")

    for d in dirs:
        for name in NAMES:
            p = os.path.join(d, name)
            if os.path.lexists(p):
                add(p, name, 0, config=name in CONFIG_NAMES)
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
        # Atomic: every host git call verifies, and a $(git ...) subshell can
        # race the caller's own first check to write the baseline.
        tmp = f"{target}.{os.getpid()}.tmp"
        with open(tmp, "w") as f:
            f.write("".join(r + "\n" for r in rows))
        os.replace(tmp, target)
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
