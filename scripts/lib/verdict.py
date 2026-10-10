#!/usr/bin/env python3
"""verdict.py [--key KEY] FILE TOKEN... — print the verdict a model reply ends with, or MISSING.

The one grammar both reviewers' launchers parse, and the implementer's final
status line (`--key IMPLEMENTER_STATUS`); KEY defaults to VERDICT. The last
non-empty line must be `KEY: <TOKEN>`, optionally followed by a comment
(` — why`, `: why`, `.`). Markdown emphasis or backticks and a leading list
marker are tolerated.

MISSING when: the last line is anything else (a bare `DONE ...`, a verdict
quoted mid-sentence, a verdict followed by more text), the token is not one of
TOKEN..., or another standalone verdict line elsewhere names a different token
(a contradictory reply, or the verdict menu echoed back).
"""
import re
import sys

args = sys.argv[1:]
key = "VERDICT"
if args[:1] == ["--key"]:
    key, args = args[1], args[2:]
path, tokens = args[0], args[1:]
alt = "|".join(re.escape(t) for t in tokens)
LINE = re.compile(
    rf"^{re.escape(key)}:\s*({alt})"
    r"(?:\s*$|\s+[-—–]\s.*$|\s*[—–].*$|[.:](?:\s.*)?$)"
)


def verdict_of_line(line: str):
    s = re.sub(r"[*`]", "", line).strip()
    s = re.sub(r"^[-*+]\s+", "", s)
    m = LINE.match(s)
    return m.group(1) if m else None


try:
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = [line for line in f.read().splitlines() if line.strip()]
except OSError:
    lines = []

final = verdict_of_line(lines[-1]) if lines else None
if final is None or any(
    (v := verdict_of_line(line)) is not None and v != final for line in lines[:-1]
):
    print("MISSING")
else:
    print(final)
