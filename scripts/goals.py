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
  goals.py [GOALS.md] body <id>
  goals.py [GOALS.md] meta
  goals.py [GOALS.md] status-only-id <id> <other.md>
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


def goal_body(text: str, gid: str) -> str:
    """Return the ## <id> markdown section (verbatim, including heading)."""
    pat = re.compile(rf"^## {re.escape(gid)}\b.*$", re.M)
    m = pat.search(text)
    if not m:
        raise SystemExit(f"no markdown section for {gid}")
    nxt = re.compile(r"^## g\d+-", re.M)
    m2 = nxt.search(text, m.end())
    end = m2.start() if m2 else len(text)
    return text[m.start() : end].rstrip() + "\n"


def rewrite_goal_status(blob: str, gid: str, new_status: str) -> str:
    """Replace the status: line for gid. Does not re-render the fence."""
    lines = blob.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if line.startswith("  - ")]
    if not starts:
        raise SystemExit("no goals in fence")
    bounds = starts + [len(lines)]
    first_key = re.compile(r"^  - (status):\s*(.*)$")
    nested = re.compile(r"^    (status):\s*(.*)$")
    for a, b in zip(bounds, bounds[1:]):
        block = "".join(lines[a:b])
        parsed = parse_yaml_subset("goals:\n" + block)
        if not parsed["goals"] or parsed["goals"][0].get("id") != gid:
            continue
        found = False
        new_block: list[str] = []
        for line in lines[a:b]:
            nl = "\n" if line.endswith("\n") else ""
            raw = line.rstrip("\n")
            if first_key.match(raw):
                new_block.append(f"  - status: {new_status}{nl}")
                found = True
            elif nested.match(raw):
                new_block.append(f"    status: {new_status}{nl}")
                found = True
            else:
                new_block.append(line)
        if not found:
            raise SystemExit(f"{gid}: no status: line to rewrite")
        return "".join(lines[:a] + new_block + lines[b:])
    raise SystemExit(f"unknown goal {gid}")


def assert_status(path: Path, gid: str, expected: str) -> None:
    _, data, _, _ = load(path)
    got = by_id(data).get(gid, {}).get("status")
    if got != expected:
        raise SystemExit(f"{gid}: status write failed (wanted {expected!r}, got {got!r})")


def fences_status_only(a: dict, b: dict, gid: str) -> list[str]:
    """Empty if fences match except possibly gid's status."""
    errs: list[str] = []
    keys = (set(a) | set(b)) - {"goals"}
    for k in sorted(keys):
        if a.get(k) != b.get(k):
            errs.append(f"top-level {k} differs")
    ga, gb = by_id(a), by_id(b)
    if set(ga) != set(gb):
        errs.append("goal id set differs")
        return errs
    for i in ga:
        da, db = dict(ga[i]), dict(gb[i])
        if i == gid:
            da.pop("status", None)
            db.pop("status", None)
        if da != db:
            errs.append(f"{i}: fence fields differ beyond allowed status")
    return errs


def validate(data: dict) -> list[str]:
    errors: list[str] = []
    if not data.get("plan"):
        errors.append("missing top-level plan:")
    if not data.get("journal"):
        errors.append("missing top-level journal:")
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
    before = {g["id"]: g.get("status") for g in data["goals"]}
    notes = refresh(data)
    blob = text[start:end]
    for g in data["goals"]:
        if g.get("status") != before.get(g["id"]):
            blob = rewrite_goal_status(blob, g["id"], g["status"])
    path.write_text(text[:start] + blob + text[end:])
    for g in data["goals"]:
        if g.get("status") != before.get(g["id"]):
            assert_status(path, g["id"], g["status"])
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
    blob = rewrite_goal_status(text[start:end], gid, status)
    path.write_text(text[:start] + blob + text[end:])
    assert_status(path, gid, status)
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


def cmd_body(path, text, extra, **_):
    if len(extra) != 1:
        raise SystemExit("body <id>")
    sys.stdout.write(goal_body(text, extra[0]))
    return 0


def cmd_meta(data, **_):
    print(
        json.dumps(
            {
                "plan": data.get("plan"),
                "log": data.get("log"),
                "journal": data.get("journal"),
            },
            indent=2,
        )
    )
    return 0


def cmd_status_only_id(path, data, extra, **_):
    if len(extra) != 2:
        raise SystemExit("status-only-id <id> <other.md>")
    gid, other = extra
    if gid not in by_id(data):
        raise SystemExit(f"unknown goal {gid}")
    op = Path(other)
    if not op.is_file():
        raise SystemExit(f"not found: {op}")
    _, other_data, _, _ = load(op)
    errs = fences_status_only(data, other_data, gid)
    if errs:
        print("DRIFT")
        for e in errs:
            print(e)
        return 1
    print("OK")
    return 0


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="goals.py")
    p.add_argument("path", nargs="?", default="GOALS.md")
    p.add_argument(
        "cmd",
        choices=(
            "validate",
            "graph",
            "frontier",
            "refresh",
            "set",
            "show",
            "body",
            "meta",
            "status-only-id",
        ),
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
        "body": cmd_body,
        "meta": cmd_meta,
        "status-only-id": cmd_status_only_id,
    }[args.cmd]
    return fn(path=path, data=data, text=text, start=start, end=end, extra=args.extra)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
