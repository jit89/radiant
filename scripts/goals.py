#!/usr/bin/env python3
"""Read and update the YAML fence in GOALS.md.

Phase 5's source of truth. The markdown bodies are for humans; this
tool only touches the ```yaml block. Status writes edit that block
in place and leave the rest of the file alone.

Usage (from the target repo):
  goals.py [GOALS.md] validate
  goals.py [GOALS.md] graph
  goals.py [GOALS.md] frontier
  goals.py [GOALS.md] refresh
  goals.py [GOALS.md] set <id> <status>
  goals.py [GOALS.md] show <id>
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

STATUSES = ("ready", "blocked", "in_progress", "done", "bounced")
ID_RE = re.compile(r"^g\d+-[a-z0-9-]+$")


def extract_fence(text: str) -> tuple[str, int, int]:
    m = re.search(r"```yaml\n(.*?)```", text, re.S)
    if not m:
        raise SystemExit("GOALS.md: no ```yaml fence")
    return m.group(1), m.start(1), m.end(1)


def _parse_scalar(raw: str):
    raw = raw.strip()
    if raw in ("[]",):
        return []
    if raw.startswith("[") and raw.endswith("]"):
        inner = raw[1:-1].strip()
        if not inner:
            return []
        return [p.strip().strip("'\"") for p in inner.split(",") if p.strip()]
    if (raw.startswith('"') and raw.endswith('"')) or (
        raw.startswith("'") and raw.endswith("'")
    ):
        return raw[1:-1]
    return raw


def parse_yaml_subset(blob: str) -> dict:
    """Parse the GOAL-FORMAT.yaml subset. Not a general YAML parser."""
    data: dict = {"goals": []}
    current: dict | None = None
    for raw in blob.splitlines():
        if not raw.strip() or raw.strip().startswith("#"):
            continue
        if raw.startswith("  - "):
            rest = raw[4:]
            if ":" not in rest:
                raise SystemExit(f"bad list item: {raw}")
            k, v = rest.split(":", 1)
            current = {k.strip(): _parse_scalar(v)}
            data["goals"].append(current)
            continue
        if raw.startswith("    ") and current is not None:
            if ":" not in raw:
                raise SystemExit(f"bad field: {raw}")
            k, v = raw.split(":", 1)
            current[k.strip()] = _parse_scalar(v)
            continue
        if raw.startswith(" ") and not raw.startswith("  -"):
            raise SystemExit(f"unexpected indent: {raw!r}")
        if ":" not in raw:
            raise SystemExit(f"bad top-level line: {raw}")
        k, v = raw.split(":", 1)
        key = k.strip()
        if key == "goals":
            continue
        data[key] = _parse_scalar(v)
    return data


def load(path: Path) -> tuple[str, dict, int, int]:
    text = path.read_text()
    blob, start, end = extract_fence(text)
    return text, parse_yaml_subset(blob), start, end


def _render_val(val) -> str:
    if isinstance(val, list):
        return "[" + ", ".join(str(x) for x in val) + "]" if val else "[]"
    return str(val)


def dump_yaml(data: dict) -> str:
    top_known = ("plan", "log", "journal")
    goal_known = (
        "id",
        "title",
        "blocked_by",
        "conflicts_with",
        "area",
        "proof",
        "oracle",
        "status",
    )
    lines = []
    for key in top_known:
        if key in data:
            lines.append(f"{key}: {_render_val(data[key])}")
    for key, val in data.items():
        if key in top_known or key == "goals":
            continue
        lines.append(f"{key}: {_render_val(val)}")
    lines.append("goals:")
    for g in data["goals"]:
        first = True
        keys = [k for k in goal_known if k in g]
        keys += [k for k in g if k not in goal_known]
        for k in keys:
            rendered = _render_val(g[k])
            if first:
                lines.append(f"  - {k}: {rendered}")
                first = False
            else:
                lines.append(f"    {k}: {rendered}")
    return "\n".join(lines) + "\n"


def write_fence(path: Path, text: str, start: int, end: int, data: dict) -> None:
    path.write_text(text[:start] + dump_yaml(data) + text[end:])


def by_id(data: dict) -> dict[str, dict]:
    return {g["id"]: g for g in data["goals"]}


def validate(data: dict) -> list[str]:
    errors: list[str] = []
    if not data.get("goals"):
        errors.append("zero goals — empty fence is not a valid DAG")
    ids = [g.get("id") for g in data["goals"]]
    if len(ids) != len(set(ids)):
        errors.append("duplicate goal ids")
    known = set(ids)
    for g in data["goals"]:
        gid = g.get("id", "")
        if not ID_RE.match(str(gid)):
            errors.append(f"{gid}: id must match g<n>-<slug>")
        st = g.get("status", "")
        if st not in STATUSES:
            errors.append(f"{gid}: bad status {st!r}")
        for field in ("blocked_by", "conflicts_with"):
            refs = g.get(field) or []
            if not isinstance(refs, list):
                errors.append(f"{gid}: {field} must be a list")
                continue
            for r in refs:
                if r not in known:
                    errors.append(f"{gid}: {field} references unknown {r}")
                if r == gid:
                    errors.append(f"{gid}: {field} includes itself")
    # cycles on blocked_by
    visiting, seen = set(), set()

    def walk(n: str) -> None:
        if n in seen:
            return
        if n in visiting:
            errors.append(f"cycle involving {n}")
            return
        visiting.add(n)
        node = by_id(data).get(n)
        if node:
            for b in node.get("blocked_by") or []:
                walk(b)
        visiting.remove(n)
        seen.add(n)

    for gid in known:
        walk(gid)
    return errors


def unfinished(status: str) -> bool:
    return status not in ("done",)


def frontier(data: dict) -> list[str]:
    """in_progress first (resume), then ready, file order within each."""
    idx = by_id(data)
    progress, ready = [], []
    for g in data["goals"]:
        if g.get("status") not in ("ready", "in_progress"):
            continue
        blockers = g.get("blocked_by") or []
        if any(unfinished(idx[b]["status"]) for b in blockers if b in idx):
            continue
        if g.get("status") == "in_progress":
            progress.append(g["id"])
        else:
            ready.append(g["id"])
    return progress + ready


def refresh(data: dict) -> list[str]:
    """Flip blocked↔ready from edges. Do not touch in_progress/done/bounced."""
    idx = by_id(data)
    notes = []
    for g in data["goals"]:
        st = g.get("status")
        if st in ("in_progress", "done", "bounced"):
            continue
        blockers = g.get("blocked_by") or []
        open_blockers = [
            b for b in blockers if b in idx and unfinished(idx[b]["status"])
        ]
        if open_blockers and st == "ready":
            g["status"] = "blocked"
            notes.append(f"{g['id']}: ready → blocked ({', '.join(open_blockers)})")
        elif not open_blockers and st == "blocked":
            g["status"] = "ready"
            notes.append(f"{g['id']}: blocked → ready")
    return notes


def cmd_validate(path, data, **_):
    errs = validate(data)
    if errs:
        print("INVALID")
        for e in errs:
            print(e)
        return 1
    print("OK", len(data["goals"]), "goals")
    return 0


def cmd_graph(path, data, **_):
    for g in data["goals"]:
        blocks = ",".join(g.get("blocked_by") or []) or "-"
        conf = ",".join(g.get("conflicts_with") or []) or "-"
        print(f"{g['id']}  {g.get('status')}  blocked_by={blocks}  conflicts={conf}")
    return 0


def cmd_frontier(path, data, **_):
    ids = frontier(data)
    if not ids:
        print("(empty)")
        return 0
    for i in ids:
        print(i)
    return 0


def cmd_refresh(path, data, text, start, end, **_):
    notes = refresh(data)
    write_fence(path, text, start, end, data)
    if notes:
        for n in notes:
            print(n)
    else:
        print("(no status changes)")
    return 0


def cmd_set(path, data, text, start, end, extra, **_):
    if len(extra) != 2:
        raise SystemExit("set <id> <status>")
    gid, status = extra
    if status not in STATUSES:
        raise SystemExit(f"status must be one of {', '.join(STATUSES)}")
    g = by_id(data).get(gid)
    if not g:
        raise SystemExit(f"unknown goal {gid}")
    old = g.get("status")
    g["status"] = status
    write_fence(path, text, start, end, data)
    print(f"{gid}: {old} → {status}")
    return 0


def cmd_show(path, data, extra, **_):
    if len(extra) != 1:
        raise SystemExit("show <id>")
    g = by_id(data).get(extra[0])
    if not g:
        raise SystemExit(f"unknown goal {extra[0]}")
    print(json.dumps(g, indent=2))
    return 0


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="goals.py")
    p.add_argument("path", nargs="?", default="GOALS.md")
    p.add_argument(
        "cmd",
        choices=("validate", "graph", "frontier", "refresh", "set", "show"),
    )
    p.add_argument("extra", nargs="*")
    args = p.parse_args(argv)
    path = Path(args.path)
    if not path.is_file():
        raise SystemExit(f"not found: {path}")
    text, data, start, end = load(path)
    fn = {
        "validate": cmd_validate,
        "graph": cmd_graph,
        "frontier": cmd_frontier,
        "refresh": cmd_refresh,
        "set": cmd_set,
        "show": cmd_show,
    }[args.cmd]
    return fn(path=path, data=data, text=text, start=start, end=end, extra=args.extra)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
