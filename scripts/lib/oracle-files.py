#!/usr/bin/env python3
"""oracle-files.py — the files an oracle review covers, read from GOALS.md.

Usage: oracle-files.py <GOALS.md>    (run from the repo root)

Prints one repo-relative path per line, in goal order, each once:
  - every `oracle:` value in the YAML fence other than `inline`;
  - every `tests/acceptance/` path named in a goal body's **Acceptance edits**
    section (written `file:line, old → new`; a trailing `:line`, `:line:col`,
    `:line-line` or pytest `::node` is dropped, as is a sentence's full stop). **Edits owned** is not read: its
    `tests/acceptance/` paths are the ones `goals.py validate` rejects.

Earlier weeks' oracles elsewhere under `tests/acceptance/` are out of scope.
Exit 2 with a message on stderr when GOALS.md is missing or does not parse, a
listed path is missing on disk, or an Acceptance-edits section that is not
`None` (an empty one included) names no path. A DAG whose oracles are all `inline` prints nothing:
the case tables in GOALS.md are the oracles then.
"""
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import goals  # noqa: E402 - the DAG reader beside this directory

# The bold heading, with its colon inside the bold or just after it.
EDITS_RE = re.compile(r"^\*\*Acceptance edits[^*\n]*(?::\*\*|\*\*:)", re.M)
# Any bold section heading, colon inside the bold or just after it: the end of
# the Acceptance-edits section (goals.SECTION_RE knows only the first form).
ANY_SECTION_RE = re.compile(r"^\*\*[^*\n]+(?::\*\*|\*\*:)", re.M)
# What may follow the file in an entry: `::node`, `:40`, `:40:7`, `:40-42`.
SUFFIX_RE = re.compile(r"(?:::.*|(?::\d+(?:-\d+)?){1,2})$")


def fail(msg: str) -> None:
    sys.stderr.write(f"oracle-files.py: {msg}\n")
    sys.exit(2)


def edits_paths(body: str, gid: str) -> list[str]:
    m = EDITS_RE.search(body)
    if not m:
        return []
    nxt = ANY_SECTION_RE.search(body, m.end())
    section = body[m.end() : nxt.start() if nxt else len(body)].strip()
    if section.lower().startswith("none"):
        return []
    found = [SUFFIX_RE.sub("", p.rstrip(".")) for p in goals.ACCEPTANCE_PATH_RE.findall(section)]
    found = [p for p in found if p.rstrip("/") != "tests/acceptance"]
    if not found:
        fail(f"{gid}: the Acceptance edits section names no tests/acceptance/ path")
    return found


def main(argv: list[str]) -> None:
    if len(argv) != 1:
        fail("usage: oracle-files.py <GOALS.md>")
    path = argv[0]
    if not os.path.isfile(path):
        fail(f"no {path}")
    try:
        text, data, _, _ = goals.load(Path(path))
    except SystemExit as exc:
        fail(f"{path} does not parse: {exc}")
    out: list[str] = []
    for g in data.get("goals") or []:
        gid = g.get("id", "?")
        oracle = str(g.get("oracle") or "").strip()
        if oracle and oracle != "inline":
            out.append(oracle)
        try:
            body = goals.goal_body(text, gid)
        except SystemExit:
            fail(f"{gid}: no ## {gid} section in {path}")
        out.extend(edits_paths(body, gid))
    seen = set()
    for p in out:
        if p in seen:
            continue
        seen.add(p)
        if not os.path.isfile(p):
            fail(f"listed for review but missing: {p}")
        print(p)


if __name__ == "__main__":
    main(sys.argv[1:])
