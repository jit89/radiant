#!/usr/bin/env python3
"""mutations.py REPLY N ALLOWED CONTRACT OUTDIR — the reviewer's mutation blocks.

docs/features/mutation-checks/PLAN.md step 3. REPLY is the mutations turn's
raw text (claude-goal-review.sh --mutations): blocks of

    MUTATION: <the rule it attacks, one line>
    ```diff
    <a unified diff>
    ```

Reviewer text is untrusted (an implementer can prompt-inject the reviewer), so
a block is accepted only when its diff is nothing but plain edits of existing
regular files, in the shape `git diff` writes, every path a file in ALLOWED
(one a line: the files changed in BASE_SHA..HEAD) and not in CONTRACT (one a
line: a path, or a folder ending in "/"). At most N blocks are read.

For the k-th block (from 1) an accepted one is written to OUTDIR/k.diff and
OUTDIR/k.rule. One line a block on stdout, tab-separated:
    k  accepted|skipped  <reason or ->  <rule>
"""
import os
import re
import sys

FENCE_OPEN = "```diff"
FENCE_CLOSE = "```"
HUNK = re.compile(r"^@@ -\d+(,\d+)? \+\d+(,\d+)? @@")
GITHDR = re.compile(r"^diff --git a/(\S+) b/(\S+)$")
INDEX = re.compile(r"^index [0-9a-f]+\.\.[0-9a-f]+ (\d{6})$")


def blocks(text):
    """(rule, diff lines or None when the block has no closed diff fence)."""
    lines = text.split("\n")
    i, out = 0, []
    while i < len(lines):
        if not lines[i].startswith("MUTATION:"):
            i += 1
            continue
        rule = lines[i][len("MUTATION:"):].strip()
        i += 1
        while i < len(lines) and lines[i].strip() == "":
            i += 1
        if i >= len(lines) or lines[i] != FENCE_OPEN:
            out.append((rule, None))
            continue
        i += 1
        body = []
        # The fence ends only on a line that is exactly ```: a fence inside a
        # hunk always carries its diff marker (space, + or -).
        while i < len(lines) and lines[i] != FENCE_CLOSE:
            body.append(lines[i])
            i += 1
        if i >= len(lines):
            out.append((rule, None))
            break
        i += 1
        out.append((rule, body))
    return out


def safe_path(p):
    # Whitespace too: git apply drops a timestamp-like suffix after a space,
    # so the path it edits could differ from the one checked here.
    if not p or p.startswith('"') or p.startswith("/") or "\\" in p or any(c.isspace() for c in p):
        return False
    if any(seg in ("", ".", "..") for seg in p.split("/")):
        return False
    return os.path.normpath(p) == p


def check(diff, allowed, contract):
    """The paths the diff edits, or a reason it is refused."""
    if not diff or not any(l.strip() for l in diff):
        return None, "empty diff"
    paths, i, n = [], 0, len(diff)
    while i < n:
        line = diff[i]
        if line == "":
            i += 1
            continue
        m = GITHDR.match(line)
        if m:
            if m.group(1) != m.group(2):
                return None, "a rename (diff --git names two paths)"
            i += 1
            line = diff[i] if i < n else ""
        m = INDEX.match(line)
        if m:
            if m.group(1) not in ("100644", "100755"):
                return None, f"mode {m.group(1)} (not a regular file)"
            i += 1
            line = diff[i] if i < n else ""
        elif line.startswith("index "):
            return None, f"an index line it cannot read: {line[:60]!r}"
        if not line.startswith("--- a/"):
            return None, f"not a plain file edit: {line[:60]!r}"
        old = line[len("--- a/"):]
        i += 1
        new_line = diff[i] if i < n else ""
        if not new_line.startswith("+++ b/"):
            return None, f"no +++ line after {line[:60]!r}"
        new = new_line[len("+++ b/"):]
        if old != new:
            return None, f"--- and +++ name different paths ({old!r}, {new!r})"
        if not safe_path(old):
            return None, f"an unsafe path: {old[:80]!r}"
        if old not in allowed:
            return None, f"not a file the implementer changed: {old}"
        if any(old == c or (c.endswith("/") and old.startswith(c)) for c in contract):
            return None, f"a contract path: {old}"
        paths.append(old)
        i += 1
        hunks = 0
        while i < n and not diff[i].startswith(("diff --git ", "--- a/", "index ")):
            line = diff[i]
            if HUNK.match(line):
                hunks += 1
            elif line == "" or line[0] in " +-\\":
                pass
            else:
                return None, f"not part of a hunk: {line[:60]!r}"
            i += 1
        if hunks == 0:
            return None, f"no hunk for {old}"
    if not paths:
        return None, "no file in the diff"
    return paths, None


def main(argv):
    if len(argv) != 5:
        sys.exit(__doc__)
    reply, n, allowed_f, contract_f, outdir = argv
    n = int(n)
    with open(reply, "rb") as f:
        text = f.read().decode("utf-8", "replace")
    allowed = {l for l in open(allowed_f, encoding="utf-8").read().split("\n") if l}
    contract = [l for l in open(contract_f, encoding="utf-8").read().split("\n") if l]
    os.makedirs(outdir, exist_ok=True)
    for k, (rule, diff) in enumerate(blocks(text)[:n], 1):
        rule = rule.replace("\t", " ") or "-"
        if diff is None:
            print(f"{k}\tskipped\tno closed ```diff fence\t{rule}")
            continue
        paths, why = check(diff, allowed, contract)
        if why:
            print(f"{k}\tskipped\t{why}\t{rule}")
            continue
        with open(os.path.join(outdir, f"{k}.diff"), "w", encoding="utf-8") as f:
            f.write("\n".join(diff).rstrip("\n") + "\n")
        with open(os.path.join(outdir, f"{k}.rule"), "w", encoding="utf-8") as f:
            f.write(rule + "\n")
        print(f"{k}\taccepted\t-\t{rule}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
