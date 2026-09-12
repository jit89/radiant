#!/usr/bin/env python3
"""Host event index — JSONL in cache. Not source of truth.

docs/journal/<slug>.md remains load-bearing (resume, DeepSeek).
This file is derived. Append is best-effort and must not fail a walk.
Journal git commits stay fail-closed in the host scripts.

walk_id lives in cache until walk-end. A later /run-goals in the same
repo+slug reuses it (quota / bounce restart = same job). walk-end
clears it. If the journal no longer mentions the cached id (wipe /
new journal), remint.

Usage (from the target repo):
  events.py ensure-walk <journal>
  events.py end-walk <journal>
  events.py path <journal>
  events.py append <journal> --event E --severity S --summary TEXT [flags]
  events.py query  <journal> [--errors|--warnings] [--last N] [--since SPEC]
                   [--goal ID] [--walk ID|current] [--json]
  events.py --self-test
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

EVENTS = (
    "walk_start",
    "walk",
    "walk_end",
    "dispatch",
    "review",
    "done",
    "fix",
    "bounced",
    "wake",
)
SEVERITIES = ("info", "warning", "error")
SUMMARY_MAX = 200


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def cache_root() -> Path:
    raw = os.environ.get("EVENTS_CACHE")
    if raw:
        return Path(raw)
    return Path.home() / ".cache" / "claude-coding-workflow" / "logs"


def git_root() -> Path:
    return Path.cwd().resolve()


def repo_id(root: Path) -> str:
    return hashlib.sha256(str(root.resolve()).encode()).hexdigest()[:16]


def resolve_journal(p: str) -> Path:
    path = Path(p)
    if not path.is_absolute():
        path = Path.cwd() / path
    return path


def slug_of(journal: Path) -> str:
    return journal.stem or "journal"


def paths_for(journal: Path) -> tuple[Path, Path]:
    d = cache_root() / repo_id(git_root())
    stem = slug_of(journal)
    return d / f"{stem}.jsonl", d / f"{stem}.walk"


def read_walk_file(walk_path: Path) -> str | None:
    if not walk_path.is_file():
        return None
    try:
        data = json.loads(walk_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    wid = data.get("walk_id")
    return wid if isinstance(wid, str) and wid else None


def write_walk_file(walk_path: Path, walk_id: str, journal: Path) -> None:
    walk_path.parent.mkdir(parents=True, exist_ok=True)
    walk_path.write_text(
        json.dumps(
            {"walk_id": walk_id, "journal": str(journal)},
            separators=(",", ":"),
        )
        + "\n",
        encoding="utf-8",
    )


def journal_mentions_walk(journal: Path, walk_id: str) -> bool:
    if not journal.is_file() or not walk_id:
        return False
    try:
        text = journal.read_text(encoding="utf-8")
    except OSError:
        return False
    return f"walk_id={walk_id}" in text


def ensure_walk(journal: Path) -> tuple[str, bool]:
    _, walk_path = paths_for(journal)
    existing = read_walk_file(walk_path)
    if existing and journal_mentions_walk(journal, existing):
        return existing, False
    wid = str(uuid.uuid4())
    write_walk_file(walk_path, wid, journal)
    return wid, True


def end_walk(journal: Path) -> None:
    _, walk_path = paths_for(journal)
    try:
        walk_path.unlink()
    except FileNotFoundError:
        pass


def current_walk_id(journal: Path) -> str | None:
    jsonl, walk_path = paths_for(journal)
    existing = read_walk_file(walk_path)
    if existing:
        return existing
    last = None
    if jsonl.is_file():
        try:
            with jsonl.open(encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        row = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if row.get("walk_id"):
                        last = row["walk_id"]
        except OSError:
            return None
    return last


def clip_summary(text: str) -> str:
    one = " ".join(text.split())
    if len(one) > SUMMARY_MAX:
        return one[: SUMMARY_MAX - 1] + "…"
    return one


def append_event(
    journal: Path,
    *,
    event: str,
    severity: str,
    summary: str,
    goal_id: str | None = None,
    round: int | None = None,
    reason: str | None = None,
    verdict: str | None = None,
    base_sha: str | None = None,
    head_sha: str | None = None,
    payload: dict | None = None,
) -> None:
    if event not in EVENTS:
        raise ValueError(f"unknown event {event}")
    if severity not in SEVERITIES:
        raise ValueError(f"unknown severity {severity}")
    jsonl, walk_path = paths_for(journal)
    walk_id = read_walk_file(walk_path) or ""
    if not head_sha:
        head = Path.cwd() / ".git"
        if head.exists():
            try:
                import subprocess

                head_sha = subprocess.check_output(
                    ["git", "rev-parse", "HEAD"],
                    stderr=subprocess.DEVNULL,
                    text=True,
                ).strip()
            except (OSError, subprocess.CalledProcessError):
                head_sha = None
    row = {
        "ts": utc_now(),
        "ts_mono": int(time.time() * 1000),
        "walk_id": walk_id or None,
        "goal_id": goal_id or None,
        "round": round,
        "role": "orchestrator",
        "event": event,
        "severity": severity,
        "reason": reason or None,
        "verdict": verdict or None,
        "base_sha": base_sha or None,
        "head_sha": head_sha or None,
        "summary": clip_summary(summary),
        "payload": payload or {},
    }
    jsonl.parent.mkdir(parents=True, exist_ok=True)
    with jsonl.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, separators=(",", ":"), ensure_ascii=False) + "\n")


def parse_since(spec: str) -> tuple[bool, datetime | None]:
    """Return (current_walk_only, cutoff_utc)."""
    if spec == "walk":
        return True, None
    m = re.fullmatch(r"(\d+)([smhd])", spec)
    if m:
        n = int(m.group(1))
        sec = {"s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]
        return False, datetime.now(timezone.utc) - timedelta(seconds=n * sec)
    iso = spec.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(iso)
    except ValueError as e:
        raise SystemExit(f"bad --since {spec!r}") from e
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return False, dt.astimezone(timezone.utc)


def parse_ts(ts: str) -> datetime | None:
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def load_rows(jsonl: Path) -> list[dict]:
    if not jsonl.is_file():
        return []
    rows = []
    with jsonl.open(encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


def cmd_ensure_walk(journal: Path) -> int:
    wid, minted = ensure_walk(journal)
    print(f"{'minted' if minted else 'reused'}\t{wid}")
    return 0


def cmd_end_walk(journal: Path) -> int:
    end_walk(journal)
    return 0


def cmd_path(journal: Path) -> int:
    jsonl, _ = paths_for(journal)
    print(jsonl)
    return 0


def cmd_append(journal: Path, args: argparse.Namespace) -> int:
    payload = {}
    if args.payload:
        try:
            payload = json.loads(args.payload)
        except json.JSONDecodeError as e:
            print(f"events: bad --payload ({e}); dropping payload", file=sys.stderr)
            payload = {}
        if not isinstance(payload, dict):
            print("events: --payload must be a JSON object; dropping", file=sys.stderr)
            payload = {}
    try:
        append_event(
            journal,
            event=args.event,
            severity=args.severity,
            summary=args.summary,
            goal_id=args.goal,
            round=args.round,
            reason=args.reason,
            verdict=args.verdict,
            base_sha=args.base_sha,
            head_sha=args.head_sha,
            payload=payload,
        )
    except Exception as e:  # noqa: BLE001 — best-effort; never fail the walk
        print(f"events: append failed ({e})", file=sys.stderr)
    return 0


def cmd_query(journal: Path, args: argparse.Namespace) -> int:
    jsonl, _ = paths_for(journal)
    rows = load_rows(jsonl)
    walk_filter = args.walk
    since_walk = False
    cutoff = None
    if args.since:
        since_walk, cutoff = parse_since(args.since)
    if since_walk:
        walk_filter = walk_filter or "current"
    if walk_filter == "current":
        walk_filter = current_walk_id(journal)
        if not walk_filter:
            return 0
    want_sev = set()
    if args.errors:
        want_sev.add("error")
    if args.warnings:
        want_sev.add("warning")
    out = []
    for row in rows:
        if walk_filter and row.get("walk_id") != walk_filter:
            continue
        if args.goal and row.get("goal_id") != args.goal:
            continue
        if want_sev and row.get("severity") not in want_sev:
            continue
        if cutoff is not None:
            ts = parse_ts(str(row.get("ts") or ""))
            if ts is None or ts < cutoff:
                continue
        out.append(row)
    n = args.last
    if n is not None and n >= 0:
        out = out[-n:]
    if args.json:
        for row in out:
            print(json.dumps(row, separators=(",", ":"), ensure_ascii=False))
        return 0
    for row in out:
        goal = row.get("goal_id") or "-"
        rnd = row.get("round")
        r = f"r{rnd}" if rnd is not None else "-"
        extra = row.get("reason") or row.get("verdict") or ""
        extra_s = f"  {extra}" if extra else ""
        print(
            f"{row.get('ts', '?')}  {row.get('severity', '?'):<7}  "
            f"{row.get('event', '?'):<11}  {goal}  {r}  "
            f"{row.get('summary', '')}{extra_s}"
        )
    return 0


def cmd_self_test() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="events-self-"))
    os.environ["EVENTS_CACHE"] = str(tmp / "cache")
    journal = tmp / "docs" / "journal" / "t.md"
    journal.parent.mkdir(parents=True)
    journal.write_text("# Journal: t\n", encoding="utf-8")
    old = Path.cwd()
    os.chdir(tmp)
    try:
        wid1, minted = ensure_walk(journal)
        assert minted, "first ensure must mint"
        assert wid1
        # no journal mention yet → remint
        wid2, minted2 = ensure_walk(journal)
        assert minted2 and wid2 != wid1, "unmentioned walk_id must remint"
        journal.write_text(
            f"# Journal: t\n\n## 2026-08-15T00:00:00Z — ORCHESTRATOR walk-start walk_id={wid2}\n",
            encoding="utf-8",
        )
        wid3, minted3 = ensure_walk(journal)
        assert not minted3 and wid3 == wid2, "journal mention must reuse"
        append_event(
            journal,
            event="wake",
            severity="error",
            summary="wake g1 r0 reason=proof-red",
            goal_id="g1",
            round=0,
            reason="proof-red",
        )
        append_event(
            journal,
            event="dispatch",
            severity="info",
            summary="dispatch g1 r0",
            goal_id="g1",
            round=0,
        )
        jsonl, _ = paths_for(journal)
        rows = load_rows(jsonl)
        assert len(rows) == 2
        assert rows[0]["event"] == "wake" and rows[0]["severity"] == "error"
        assert rows[0]["walk_id"] == wid2
        assert rows[0]["reason"] == "proof-red"
        errors = [r for r in rows if r["severity"] == "error"]
        assert len(errors) == 1
        end_walk(journal)
        _, walk_path = paths_for(journal)
        assert not walk_path.exists(), "end-walk must clear walk file"
        # history stays
        assert jsonl.is_file() and load_rows(jsonl)
    finally:
        os.chdir(old)
    return 0


def main(argv: list[str]) -> int:
    if argv and argv[0] == "--self-test":
        return cmd_self_test()
    p = argparse.ArgumentParser(prog="events.py")
    sub = p.add_subparsers(dest="cmd", required=True)

    e = sub.add_parser("ensure-walk")
    e.add_argument("journal")

    n = sub.add_parser("end-walk")
    n.add_argument("journal")

    t = sub.add_parser("path")
    t.add_argument("journal")

    a = sub.add_parser("append")
    a.add_argument("journal")
    a.add_argument("--event", required=True, choices=EVENTS)
    a.add_argument("--severity", required=True, choices=SEVERITIES)
    a.add_argument("--summary", required=True)
    a.add_argument("--goal", default="")
    a.add_argument("--round", type=int, default=None)
    a.add_argument("--reason", default="")
    a.add_argument("--verdict", default="")
    a.add_argument("--base-sha", default="")
    a.add_argument("--head-sha", default="")
    a.add_argument("--payload", default="")

    q = sub.add_parser("query")
    q.add_argument("journal")
    q.add_argument("--errors", action="store_true")
    q.add_argument("--warnings", action="store_true")
    q.add_argument("--last", type=int, default=None)
    q.add_argument("--since", default="")
    q.add_argument("--goal", default="")
    q.add_argument("--walk", default="")
    q.add_argument("--json", action="store_true")

    args = p.parse_args(argv)
    if args.cmd == "ensure-walk":
        return cmd_ensure_walk(resolve_journal(args.journal))
    if args.cmd == "end-walk":
        return cmd_end_walk(resolve_journal(args.journal))
    if args.cmd == "path":
        return cmd_path(resolve_journal(args.journal))
    if args.cmd == "append":
        return cmd_append(resolve_journal(args.journal), args)
    if args.cmd == "query":
        return cmd_query(resolve_journal(args.journal), args)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
