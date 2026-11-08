#!/usr/bin/env python3
"""Read and update the YAML fence in GOALS.md.

Phase 5's source of truth. Writes only touch the ```yaml block: status
writes edit it in place and leave the rest of the file alone. The
markdown bodies are still contract (case tables, seams), so
status-only-id compares the whole file.

Usage (from the target repo):
  goals.py [GOALS.md] validate
  goals.py [GOALS.md] graph
  goals.py [GOALS.md] frontier
  goals.py [GOALS.md] refresh
  goals.py [GOALS.md] set <id> <status>
  goals.py [GOALS.md] show <id>
  goals.py [GOALS.md] body <id>
  goals.py [GOALS.md] blockers <id>     # unfinished blocked_by, "id (status)"
  goals.py [GOALS.md] remaining         # every goal not done, and why
  goals.py [GOALS.md] meta
  goals.py [GOALS.md] status-only-id <id> <other.md>   # whole file, not just the fence
  goals.py [GOALS.md] status-transitions <other.md> [<id>=<old>:<new>,...]
                                        # whole file; only listed status moves ("*" = any)
  goals.py [GOALS.md] todos
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

# TodoWrite statuses. House statuses map onto these.
TODO_OF = {
    "done": "completed",
    "bounced": "cancelled",
    "in_progress": "in_progress",
    "ready": "pending",
    "blocked": "pending",
}

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


def atomic_write(path: Path, text: str) -> None:
    """Replace the file whole: a temp file beside it, flushed and fsynced, then
    os.replace. A concurrent reader (the /walk-status pane, a goal starting) sees the
    old file or the new one, never half. Written through a symlink, as
    write_text did, and with the file's mode kept."""
    real = path.resolve()
    mode = stat.S_IMODE(real.stat().st_mode) if real.exists() else 0o644
    fd, tmp = tempfile.mkstemp(dir=real.parent, prefix=f".{real.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, real)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def write_fence(path: Path, text: str, start: int, end: int, data: dict) -> None:
    atomic_write(path, text[:start] + dump_yaml(data) + text[end:])


def by_id(data: dict) -> dict[str, dict]:
    return {g["id"]: g for g in data["goals"]}


# "## <id>" then whitespace or end of line. Not \b: "-" is a word boundary,
# so \b let g1-store match the heading of g1-store-extra.
HEADING_RE = re.compile(r"^## (g\d+-[a-z0-9-]+)(?=\s|$)", re.M)


def goal_body(text: str, gid: str) -> str:
    """Return the ## <id> markdown section (verbatim, including heading)."""
    pat = re.compile(rf"^## {re.escape(gid)}(?=\s|$).*$", re.M)
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


def status_only_drift(text: str, data: dict, other_text: str, gid: str) -> list[str]:
    """Empty if text is other_text with at most gid's status changed.

    The whole file is the contract: fence and markdown bodies (case tables,
    seams, out-of-scope) alike. Fence fields are compared parsed, for precise
    messages. Then gid's status is carried onto other_text with the same
    in-place rewrite `set` uses, and the files must match exactly.
    """
    _, other_start, other_end = extract_fence(other_text)
    other_data = parse_yaml_subset(other_text[other_start:other_end])
    errs = fences_status_only(data, other_data, gid)
    if errs:
        return errs
    status = by_id(data)[gid].get("status")
    blob = rewrite_goal_status(other_text[other_start:other_end], gid, status)
    expected = other_text[:other_start] + blob + other_text[other_end:]
    if expected == text:
        return []
    now, was = text.splitlines(), expected.splitlines()
    i = next(
        (n for n, (x, y) in enumerate(zip(now, was)) if x != y),
        min(len(now), len(was)),
    )
    _, start, end = extract_fence(text)
    fence_first = text.count("\n", 0, start)
    fence_last = text.count("\n", 0, end)
    if fence_first <= i <= fence_last:
        where = "the yaml fence (formatting)"
    else:
        heads = [line for line in now[:i + 1] if line.startswith("## ")]
        where = heads[-1] if heads else "the preamble"
    return [f"markdown differs from line {i + 1}, under {where}"]


def status_transitions_drift(text: str, data: dict, other_text: str, allowed: str) -> list[str]:
    """Empty if text is other_text with only allowed status moves.

    allowed is "<id>=<old>:<new>,..." where any part may be "*". The rest of
    the file — fence fields and markdown bodies — must match exactly.
    """
    _, other_start, other_end = extract_fence(other_text)
    other_data = parse_yaml_subset(other_text[other_start:other_end])
    errs: list[str] = []
    for k in sorted((set(data) | set(other_data)) - {"goals"}):
        if data.get(k) != other_data.get(k):
            errs.append(f"top-level {k} differs")
    now, was = by_id(data), by_id(other_data)
    if set(now) != set(was):
        return errs + ["goal id set differs"]
    rules = [r.strip() for r in allowed.split(",") if r.strip()]

    def permitted(gid: str, old: str, new: str) -> bool:
        for rule in rules:
            rid, _, move = rule.partition("=")
            rold, _, rnew = move.partition(":")
            if rid in ("*", gid) and rold in ("*", old) and rnew in ("*", new):
                return True
        return False

    blob = other_text[other_start:other_end]
    for gid in now:
        a, b = dict(now[gid]), dict(was[gid])
        new, old = a.pop("status", None), b.pop("status", None)
        if a != b:
            errs.append(f"{gid}: fence fields differ beyond status")
        elif new != old:
            if not permitted(gid, old, new):
                errs.append(f"{gid}: status {old} → {new} is not a move this step makes")
            blob = rewrite_goal_status(blob, gid, new)
    if errs:
        return errs
    if other_text[:other_start] + blob + other_text[other_end:] != text:
        errs.append("markdown or fence formatting differs beyond status")
    return errs


def validate_bodies(text: str, data: dict) -> list[str]:
    """Every goal has one body: the handoff's spec, and for oracle: inline the oracle."""
    errors: list[str] = []
    counts: dict[str, int] = {}
    for m in HEADING_RE.finditer(text):
        counts[m.group(1)] = counts.get(m.group(1), 0) + 1
    for g in data["goals"]:
        gid = g.get("id", "")
        n = counts.get(gid, 0)
        if n > 1:
            errors.append(f"{gid}: {n} ## {gid} sections (the handoff would take the first)")
        if n == 0 and g.get("oracle") == "inline":
            errors.append(f"{gid}: oracle: inline but no ## {gid} section — the case table is the oracle")
        elif n == 0:
            errors.append(
                f"{gid}: no ## {gid} section — the handoff carries the body "
                "(deliverable, seams, case table, scope); a file oracle does not replace it"
            )
        if n:
            for path in owned_acceptance_paths(goal_body(text, gid)):
                errors.append(
                    f"{gid}: {path} is under **Edits owned** — the host guards all of "
                    "tests/acceptance/ and tests/e2e/; the Architect applies that edit before "
                    "dispatch and lists it under **Acceptance edits (applied, read-only)**"
                )
            if g.get("status") != "done":
                for name in required_section_names(data):
                    if not section_text(goal_body(text, gid), name):
                        errors.append(
                            f"{gid}: no **{name}:** section with text — required_sections names it, "
                            "so every goal not yet done states it"
                        )
    return errors


# A body section starts with a bold label line, "**Label:**".
SECTION_RE = re.compile(r"^\*\*[^*\n]+:\*\*", re.M)
ACCEPTANCE_PATH_RE = re.compile(r"tests/(?:acceptance|e2e)/[^\s`'\"),;]*")


def required_section_names(data: dict) -> list[str]:
    """The body sections a target requires of every goal not yet done (required_sections:)."""
    names = data.get("required_sections")
    if not isinstance(names, list):
        return []
    return [name for name in names if isinstance(name, str) and name.strip()]


def section_text(body: str, name: str) -> str:
    """The text of the body's **name:** section, stripped; empty when it is missing or blank."""
    m = re.search(rf"^\*\*{re.escape(name)}:\*\*", body, re.M)
    if not m:
        return ""
    nxt = SECTION_RE.search(body, m.end())
    return body[m.end() : nxt.start() if nxt else len(body)].strip()


def owned_acceptance_paths(body: str) -> list[str]:
    """tests/acceptance/ and tests/e2e/ paths listed under the body's **Edits owned:** section."""
    m = re.search(r"^\*\*Edits owned:\*\*", body, re.M)
    if not m:
        return []
    nxt = SECTION_RE.search(body, m.end())
    section = body[m.end() : nxt.start() if nxt else len(body)]
    return ACCEPTANCE_PATH_RE.findall(section)


# tool_path (docs/features/rust-toolchain-gates): directories prepended to PATH
# for a goal's own processes only. Safe characters only (no `:`, which would
# split the list, and no spaces); absolute; existing; and never a directory
# that would shadow a tool the proof or the host relies on.
TOOL_PATH_SAFE = re.compile(r"^[A-Za-z0-9._/@+-]+$")
TOOL_PATH_SHADOWED = ("bash", "sh", "env", "git", "python3", "shasum")


def _read_denied() -> list[str]:
    """lib/proof-sandbox.py's read denials: the one list of folders no proof
    can read (temp areas, secret paths, the house cache)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "proof_sandbox", os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "proof-sandbox.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return [os.path.realpath(d) for d in mod.read_denied()]


def _under(p: str, d: str) -> bool:
    return p == d or p.startswith(d.rstrip("/") + "/")


SANDBOX_SKIP_SAFE = re.compile(r"^[A-Za-z0-9_:./-]+$")


def sandbox_skips_errors(value) -> list[str]:
    """implementer_sandbox_skips: tests only the implementer's sandbox cannot
    run (prompt-audit AUDIT-2026-11-08, F3). The handoff names them; the host's
    proof still runs every one."""
    if value is None:
        return []
    if not isinstance(value, list) or not value:
        return ["implementer_sandbox_skips: must be a non-empty one-line list, "
                "e.g. implementer_sandbox_skips: [test-binary::test_name]"]
    return [f"implementer_sandbox_skips: {e!r} has a character outside [A-Za-z0-9_:./-]"
            for e in value if not isinstance(e, str) or not SANDBOX_SKIP_SAFE.match(e)]


def tool_path_errors(value, root: str | None = None) -> list[str]:
    """ROOT: the target repo (GOALS.md's folder). A tool folder inside it is
    one the implementer can write, and it runs first in every proof."""
    if value is None:
        return []
    if not isinstance(value, list) or not value:
        return ["tool_path: must be a non-empty one-line list, e.g. tool_path: [/abs/bin]"]
    errors = []
    for entry in value:
        if not isinstance(entry, str) or not entry:
            errors.append(f"tool_path: entry {entry!r} is not a path")
            continue
        if not entry.startswith("/"):
            errors.append(f"tool_path: {entry} is not absolute")
            continue
        if not TOOL_PATH_SAFE.match(entry):
            errors.append(f"tool_path: {entry} has a character outside [A-Za-z0-9._/@+-]")
            continue
        if not os.path.isdir(entry):
            errors.append(f"tool_path: {entry} is not an existing directory")
            continue
        real = os.path.realpath(entry)
        if root is not None and _under(real, os.path.realpath(root)):
            errors.append(f"tool_path: {entry} is inside the target repo, which the implementer can write")
            continue
        # A folder the proof sandbox cannot read fails every proof with only
        # "Operation not permitted".
        # The most specific match names the rule (the cache before its temp area).
        denied = max((d for d in _read_denied() if _under(real, d)), key=len, default=None)
        if denied is not None:
            errors.append(f"tool_path: {entry} is under {denied}, which the proof sandbox cannot read")
            continue
        for name in TOOL_PATH_SHADOWED:
            exe = os.path.join(entry, name)
            if os.path.isfile(exe) and os.access(exe, os.X_OK):
                errors.append(f"tool_path: {entry} holds an executable {name}, which would shadow the host's")
    return errors


def validate(data: dict, root: str | None = None) -> list[str]:
    errors: list[str] = []
    if not data.get("plan"):
        errors.append("missing top-level plan:")
    if not data.get("journal"):
        errors.append("missing top-level journal:")
    if not data.get("goals"):
        errors.append("zero goals — empty fence is not a valid DAG")
    setup = data.get("worktree_setup")
    if setup is not None and (not isinstance(setup, str) or not setup.strip()):
        errors.append("worktree_setup: must be one shell command (a non-empty string)")
    # The proof sandbox's network (docs/features/proof-sandbox/PLAN.md,
    # Amendment 1 A): absent means none; only these two strings open it.
    net = data.get("proof_network")
    if net is not None and net not in ("loopback", "true"):
        errors.append("proof_network: must be loopback or true (leave it out for none)")
    required = data.get("required_sections")
    if required is not None and (
        not isinstance(required, list)
        or not required
        or not all(isinstance(name, str) and name.strip() for name in required)
    ):
        errors.append("required_sections: must be a list of section names (leave it out for none)")
    errors.extend(tool_path_errors(data.get("tool_path"), root))
    errors.extend(sandbox_skips_errors(data.get("implementer_sandbox_skips")))
    ids = [g.get("id") for g in data["goals"]]
    if len(ids) != len(set(ids)):
        errors.append("duplicate goal ids")
    known = set(ids)
    for g in data["goals"]:
        gid = g.get("id", "")
        if not ID_RE.match(str(gid)):
            errors.append(f"{gid}: id must match g<n>-<slug>")
        mp = g.get("mutation_proof")
        if mp is not None and (not isinstance(mp, str) or not mp.strip()):
            errors.append(f"{gid}: mutation_proof must be one shell command (a non-empty string)")
        soak = g.get("soak")
        if soak is not None and (not isinstance(soak, str) or not soak.strip()):
            errors.append(f"{gid}: soak must be one shell command (a non-empty string)")
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


def open_blockers(data: dict, gid: str) -> list[str]:
    """blocked_by entries that are not done — the same rule frontier uses."""
    idx = by_id(data)
    return [
        f"{b} ({idx[b].get('status')})"
        for b in by_id(data)[gid].get("blocked_by") or []
        if b in idx and unfinished(idx[b]["status"])
    ]


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


def cmd_validate(path, data, text, **_):
    errs = validate(data, os.path.dirname(os.path.realpath(path))) + validate_bodies(text, data)
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


def cmd_todos(data, **_):
    """JSON for the Architect's TodoWrite. Seed before the walk; refresh on exit."""
    out = []
    for g in data.get("goals") or []:
        st = g.get("status") or "ready"
        title = g.get("title") or g["id"]
        out.append(
            {
                "id": g["id"],
                "content": f"{g['id']} — {title}",
                "status": TODO_OF.get(st, "pending"),
                "goal_status": st,
            }
        )
    print(json.dumps(out, indent=2))
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
    atomic_write(path, text[:start] + blob + text[end:])
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
    atomic_write(path, text[:start] + blob + text[end:])
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


def cmd_blockers(path, data, extra, **_):
    if len(extra) != 1:
        raise SystemExit("blockers <id>")
    if extra[0] not in by_id(data):
        raise SystemExit(f"unknown goal {extra[0]}")
    for b in open_blockers(data, extra[0]):
        print(b)
    return 0


def cmd_remaining(path, data, **_):
    """One line per goal that is not done: its status and open blockers."""
    for g in data["goals"]:
        st = g.get("status")
        if st == "done":
            continue
        open_ = open_blockers(data, g["id"])
        if open_ and st == "blocked":
            print(f"{g['id']}: blocked by {', '.join(open_)}")
        elif open_:
            print(f"{g['id']}: {st}, blocked by {', '.join(open_)}")
        else:
            print(f"{g['id']}: {st}")
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
                "worktree_setup": data.get("worktree_setup"),
                "proof_network": data.get("proof_network") or "none",
                "tool_path": data.get("tool_path"),
                "implementer_sandbox_skips": data.get("implementer_sandbox_skips"),
            },
            indent=2,
        )
    )
    return 0


def cmd_status_only_id(path, data, text, extra, **_):
    if len(extra) != 2:
        raise SystemExit("status-only-id <id> <other.md>")
    gid, other = extra
    if gid not in by_id(data):
        raise SystemExit(f"unknown goal {gid}")
    op = Path(other)
    if not op.is_file():
        raise SystemExit(f"not found: {op}")
    errs = status_only_drift(text, data, op.read_text(), gid)
    if errs:
        print("DRIFT")
        for e in errs:
            print(e)
        return 1
    print("OK")
    return 0


def cmd_status_transitions(path, data, text, extra, **_):
    if len(extra) not in (1, 2):
        raise SystemExit("status-transitions <other.md> [<id>=<old>:<new>,...]")
    op = Path(extra[0])
    if not op.is_file():
        raise SystemExit(f"not found: {op}")
    errs = status_transitions_drift(text, data, op.read_text(), extra[1] if len(extra) == 2 else "")
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
            "blockers",
            "remaining",
            "meta",
            "status-only-id",
            "status-transitions",
            "todos",
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
        "blockers": cmd_blockers,
        "remaining": cmd_remaining,
        "meta": cmd_meta,
        "status-only-id": cmd_status_only_id,
        "status-transitions": cmd_status_transitions,
        "todos": cmd_todos,
    }[args.cmd]
    return fn(path=path, data=data, text=text, start=start, end=end, extra=args.extra)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
