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
  events.py status [--json]      # the goal running now, from anywhere in the repo
  events.py graph [--json] [--dir DIR]   # every goal as a git graph (the /walk-status pane)
  events.py walks --session ID [--session ID ...] [--json]   # walks those sessions launched
  events.py --self-test
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import shutil
import tempfile
import fcntl
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

EVENTS = (
    "walk_start",
    "walk",
    "walk_end",
    "dispatch",
    "implemented",
    "phase",
    "review",
    "done",
    "fix",
    "bounced",
    "wake",
    # Parallel walker: the walker merging a goal (it names the goal and carries
    # the walker's pid), and one walker-owned row per wave with no goal.
    "integrate",
    "join_wait",
    # A goal recut after a merge conflict: it runs fresh in a later wave
    # (docs/features/merge-conflict-recut). Not a stop.
    "recut",
    # The mutation checks after a DONE review (docs/features/mutation-checks).
    "mutations",
    # The always-on decider's choice (docs/features/always-on, step 12).
    "decision",
    # Processes an agent step left running in the checkout, ended (lib/reap-strays.py).
    "strays",
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
    """The repo an event belongs to. A goal of a parallel walk runs in its own
    worktree; the walker sets CW_EVENTS_ROOT to the main checkout so its
    events land in the walk's index, where the pane and the task list read."""
    raw = os.environ.get("CW_EVENTS_ROOT")
    if raw:
        return Path(raw).resolve()
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


def read_walk_data(walk_path: Path) -> dict | None:
    """The whole walk file, or None when it is missing or does not parse."""
    try:
        data = json.loads(walk_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):  # ValueError: bad JSON or bytes that are not UTF-8
        return None
    return data if isinstance(data, dict) else None


def write_walk_file(walk_path: Path, walk_id: str, journal: Path,
                    session: str | None = None, root: Path | None = None) -> None:
    """Write the walk file atomically (a temp file beside it, then a rename), so
    a reader never sees half of it. `session` is the launching Claude session
    (`CLAUDE_CODE_SESSION_ID`) and `root` the repo root: the walk mod finds the
    walks a session launched by them."""
    walk_path.parent.mkdir(parents=True, exist_ok=True)
    data = {"walk_id": walk_id, "journal": str(journal)}
    if session:
        data["session"] = session
    if root is not None:
        data["root"] = str(root)
    fd, tmp = tempfile.mkstemp(dir=walk_path.parent, prefix=f".{walk_path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(data, separators=(",", ":")) + "\n")
        os.replace(tmp, walk_path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


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
    session = os.environ.get("CLAUDE_CODE_SESSION_ID") or None
    root = git_root()
    existing = read_walk_file(walk_path)
    if existing and journal_mentions_walk(journal, existing):
        # A reuse rewrites the file only when its launcher or root changed (a
        # walk resumed from another session moves there); the ensure-walk every
        # goal's run-goal.sh makes leaves the file, and its mtime, alone.
        data = read_walk_data(walk_path) or {}
        if (session and data.get("session") != session) or data.get("root") != str(root):
            write_walk_file(walk_path, existing, journal,
                            session=session or data.get("session"), root=root)
        return existing, False
    wid = str(uuid.uuid4())
    write_walk_file(walk_path, wid, journal, session=session, root=root)
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
    # A goal of a parallel walk (CW_EVENTS_ROOT) makes no git call here: its
    # host git is pinned to recorded paths, and this one would not be.
    if not head_sha and not os.environ.get("CW_EVENTS_ROOT"):
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
    data = (json.dumps(row, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")
    # One locked write per line: in a parallel walk N goals and the walker
    # append at once, and a torn line is dropped by every reader.
    fd = os.open(jsonl, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        view = memoryview(data)
        while view:
            view = view[os.write(fd, view):]
    finally:
        os.close(fd)


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
        shutil.rmtree(tmp, ignore_errors=True)
    return 0


# What a running goal is doing, by the last event naming it.
PHASE_OF = {"walk": "start", "dispatch": "implement", "implemented": "proof", "fix": "fix",
            "integrate": "integrate"}
# Events after which no orchestrator process is working on that goal.
# A conflict recut ends the goal's attempt too: it runs again in a later wave.
TERMINAL = {"done", "bounced", "wake", "walk_end", "recut"}


def find_goals_root(start: Path) -> Path | None:
    """The nearest directory at or above `start` holding GOALS.md and .git."""
    for d in [start, *start.parents]:
        if (d / "GOALS.md").is_file() and (d / ".git").exists():
            return d
    return None


def proc_start(pid) -> str | None:
    """When process `pid` started, as `ps -o lstart=` prints it, or None."""
    import subprocess  # noqa: PLC0415

    try:
        out = subprocess.run(
            ["ps", "-o", "lstart=", "-p", str(int(pid))],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        return None
    out = " ".join(out.split())
    return out or None


def pid_alive(pid, started: str | None = None) -> bool:
    """True while process `pid` lives and, when `started` is given, is the one
    that started then: a pid the OS reused for another process reads as gone."""
    try:
        os.kill(int(pid), 0)
    except (ValueError, TypeError, ProcessLookupError):
        return False
    except PermissionError:
        pass
    if not started:
        return True
    return proc_start(pid) == " ".join(started.split())


def tail_rows(jsonl: Path, limit: int = 400) -> list[dict]:
    try:
        lines = jsonl.read_text(encoding="utf-8").splitlines()[-limit:]
    except OSError:
        return []
    rows = []
    for line in lines:
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def phase_of(row: dict) -> str:
    """What a goal is doing, by the last event naming it."""
    event = row.get("event")
    if event == "phase":
        return (row.get("payload") or {}).get("phase") or "running"
    if event == "review":
        return "fix" if row.get("verdict") == "FIX" else "review"
    return PHASE_OF.get(event, "running")


def live_goals(rows: list[dict]) -> dict[str, dict]:
    """Every goal an orchestrator is running now, newest first: `{round, phase}`.

    A goal runs while the last event naming it is not terminal and the process
    that wrote it (its payload `pid`, started at `pid_start`) is alive: a goal
    killed outright leaves no wake, and a row from before pids were recorded
    never reads as running. Each goal is judged by its own rows, so goals run
    side by side (a parallel walk) each read as running.

    One exception: a goal of a parallel walk that finished writes `phase
    integrate` and exits, then waits for the wave's join. While the walker is
    alive (the newest `walk` row's pid, no `walk_end` after it), such a goal
    still reads as running, in phase `integrate`, not as paused.
    """
    walker_alive = False
    for r in reversed(rows):
        if r.get("event") == "walk_end":
            break
        if r.get("event") == "walk":
            p = r.get("payload") if isinstance(r.get("payload"), dict) else {}
            walker_alive = bool(p.get("pid")) and pid_alive(p["pid"], p.get("pid_start"))
            break
    last: dict[str, dict] = {}
    owner: dict[str, dict] = {}
    for r in reversed(rows):
        gid = r.get("goal_id")
        if not gid:
            continue
        last.setdefault(gid, r)
        payload = r.get("payload")
        if gid not in owner and isinstance(payload, dict) and payload.get("pid"):
            owner[gid] = payload
    live: dict[str, dict] = {}
    for gid, r in last.items():
        if r.get("event") in TERMINAL or gid not in owner:
            continue
        if pid_alive(owner[gid]["pid"], owner[gid].get("pid_start")) or (
            walker_alive and phase_of(r) == "integrate"
        ):
            live[gid] = {"round": r.get("round"), "phase": phase_of(r)}
    return live


def all_rows(jsonl: Path) -> list[dict]:
    """Every row of an event index, in file order (not a tail: a long walk
    outgrows any window, and `started` needs its first rows)."""
    return tail_rows(jsonl, limit=10**9)


def ordered(rows: list[dict]) -> list[tuple[tuple[int, int], dict]]:
    """Rows with their order key: `ts_mono` (milliseconds; `ts` is whole
    seconds and a fast gate writes two rows in one second), then position in
    the file, so a later line wins a tie."""
    keyed = []
    for i, r in enumerate(rows):
        try:
            mono = int(r.get("ts_mono") or 0)
        except (TypeError, ValueError):
            mono = 0
        keyed.append(((mono, i), r))
    keyed.sort(key=lambda kr: kr[0])
    return keyed


def walk_liveness(rows: list[dict], walk_id: str) -> tuple[bool, int | None]:
    """Whether the walker of `walk_id` is alive, and when it began (`started`,
    the earliest `ts_mono` of a row carrying its pid and pid_start).

    Live: the newest `walk` row, or else the newest `dispatch` / `phase` row,
    of this walk carries a pid that is alive, and no `walk_end` row of this
    walk is newer than that row. The `walk` pid is run-goals.sh's and spans the
    gap between goals; the `dispatch` / `phase` pid is run-goal.sh's and makes a
    single /run-goal (which writes no `walk` row) live. A `walk_end` older than
    the live row is stale (an interrupt before the file's unlink, then a reuse).
    """
    mine = [(k, r) for k, r in ordered(rows) if r.get("walk_id") == walk_id]
    newest: dict[str, tuple[tuple[int, int], dict]] = {}
    for k, r in mine:
        ev = r.get("event")
        group = "walk" if ev == "walk" else "goal" if ev in ("dispatch", "phase") else ev
        if group in ("walk", "goal", "walk_end"):
            newest[group] = (k, r)
    chosen = None
    for group in ("walk", "goal"):
        if group not in newest:
            continue
        k, r = newest[group]
        p = r.get("payload") if isinstance(r.get("payload"), dict) else {}
        if p.get("pid") and pid_alive(p["pid"], p.get("pid_start")):
            chosen = (k, p)
            break
    if chosen is None:
        return False, None
    k, p = chosen
    if "walk_end" in newest and newest["walk_end"][0] > k:
        return False, None
    pid, start = p.get("pid"), " ".join(str(p.get("pid_start") or "").split())
    started = None
    for (mono, _), r in mine:
        q = r.get("payload") if isinstance(r.get("payload"), dict) else {}
        if q.get("pid") == pid and " ".join(str(q.get("pid_start") or "").split()) == start:
            started = mono
            break
    return True, started


def list_walks(sessions: set[str]) -> list[dict]:
    """Every walk file under the cache root launched by one of `sessions`:
    `{root, walk_id, journal, session, mtime, live, started}`. A file without
    `session` or `root`, or that does not parse, is skipped. A cache root that
    does not exist yet is no walks; one that cannot be listed raises OSError."""
    base = cache_root()
    if not base.exists():
        return []
    out = []
    for d in sorted(base.iterdir()):
        if not d.is_dir():
            continue
        try:
            files = sorted(d.glob("*.walk"))
        except OSError:
            continue
        for wf in files:
            data = read_walk_data(wf)
            if not data or not isinstance(data.get("session"), str) or data["session"] not in sessions \
                    or not isinstance(data.get("root"), str) or not data["root"] \
                    or not isinstance(data.get("walk_id"), str) or not data["walk_id"]:
                continue
            try:
                mtime = wf.stat().st_mtime_ns // 1_000_000
            except OSError:
                continue
            live, started = walk_liveness(all_rows(wf.with_suffix(".jsonl")), data["walk_id"])
            out.append({"root": data["root"], "walk_id": data["walk_id"],
                        "journal": data.get("journal") or "", "session": data["session"],
                        "mtime": mtime, "live": live, "started": started})
    return out


def goal_reason(rows: list[dict], goal_id: str) -> str:
    """Why a paused or bounced goal stopped, never empty: (a) the reason of the
    goal's newest `wake` / `bounced` row that has one, when newer than its
    newest `walk` / `dispatch` row; else (b) the newest goal-less `wake` with a
    reason newer than that row (the walker's own stops); else `stopped`."""
    keyed = ordered(rows)
    floor = (-1, -1)
    for k, r in keyed:
        if r.get("goal_id") == goal_id and r.get("event") in ("walk", "dispatch"):
            floor = k
    own = None
    loose = None
    for k, r in keyed:
        reason = str(r.get("reason") or "").strip()
        if not reason or r.get("event") not in ("wake", "bounced"):
            continue
        if r.get("goal_id") == goal_id:
            own = (k, reason)
        elif not r.get("goal_id") and r.get("event") == "wake":
            loose = (k, reason)
    if own and own[0] > floor:
        return own[1]
    if loose and loose[0] > floor:
        return loose[1]
    return "stopped"


def walk_status(start: Path) -> dict:
    """The goal an orchestrator is running now in the repo holding `start`:
    the newest of `live_goals`, with how many more run beside it (`others`).
    A GOALS.md that does not parse (one mid-write) raises, so a poller can keep
    what it showed rather than flash to idle.
    """
    idle = {"running": False}
    root = find_goals_root(start.resolve())
    if root is None:
        return idle
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import goals  # noqa: PLC0415 - the DAG reader beside this file

    try:
        _, data, _, _ = goals.load(root / "GOALS.md")
    except SystemExit as exc:  # goals.py reports a bad file by exiting
        raise ValueError(f"GOALS.md: {exc}") from exc
    journal = data.get("journal") or ""
    if not journal:
        return idle
    statuses = [g.get("status") for g in data.get("goals", [])]
    done, total = statuses.count("done"), len(statuses)
    live = live_goals(tail_rows(cache_root() / repo_id(root) / f"{slug_of(Path(journal))}.jsonl"))
    if not live:
        return {**idle, "done": done, "total": total}
    goal, now = next(iter(live.items()))
    rnd, phase = now["round"], now["phase"]
    more = f" +{len(live) - 1}" if len(live) > 1 else ""
    label = f"{goal}{f' r{rnd}' if rnd is not None else ''} \u00b7 {phase}{more} \u00b7 {done}/{total}"
    return {"running": True, "goal": goal, "round": rnd, "phase": phase, "others": len(live) - 1,
            "done": done, "total": total, "label": label}


# How a goal is drawn in the walk pane, by its state there.
GLYPH = {"done": "●", "running": "◉", "paused": "◐", "ready": "○",
         "waiting": "◌", "bounced": "✗"}


def lay_out(goals: list[dict]) -> list[dict]:
    """A goal DAG as git-graph rows, roots first, in GOALS.md order where the
    edges allow. Each dependency is a lane two cells wide running down from the
    goal to the one that waits on it: a goal with several dependents forks
    (`├─┬─╮`), one waiting on several takes the lanes in (`●─┼─╯`).

    A goal's row is `{goal, graph, col, cont}`: `col` the cell of its glyph,
    `cont` the lanes still running past it (what a detail line under it draws).
    A fork row is `{graph}` alone. Glyphs are by `state`, else `ready`.
    """
    ids = [g["id"] for g in goals]
    state = {g["id"]: g.get("state", "ready") for g in goals}
    known = set(ids)
    deps = {g["id"]: list(dict.fromkeys(d for d in (g.get("blocked_by") or []) if d in known and d != g["id"]))
            for g in goals}
    kids: dict[str, list[str]] = {i: [] for i in ids}
    for i in ids:
        for d in deps[i]:
            kids[d].append(i)
    pos = {i: n for n, i in enumerate(ids)}
    indeg = {i: len(deps[i]) for i in ids}
    ready = [i for i in ids if indeg[i] == 0]
    order: list[str] = []
    while ready:
        ready.sort(key=pos.__getitem__)
        n = ready.pop(0)
        order.append(n)
        for c in kids[n]:
            indeg[c] -= 1
            if indeg[c] == 0:
                ready.append(c)
    placed = set(order)
    order += [i for i in ids if i not in placed]  # a cycle (validate refuses one): drawn as roots
    at = {i: n for n, i in enumerate(order)}

    def join(cells: list[str], gaps: list[str]) -> str:
        return "".join(c + g for c, g in zip(cells, gaps)).rstrip()

    def bridge(cells: list[str], gaps: list[str], col: int, ends: list[int], last: str, mid: str) -> None:
        far = max(ends)
        for i in range(col + 1, far + 1):
            gaps[i - 1] = "─"
            if i in ends:
                cells[i] = last if i == far else mid
            elif cells[i] == "│":
                cells[i] = "┼"
            else:
                cells[i] = "─"

    rows: list[dict] = []
    lanes: list[str | None] = []  # each lane: the goal its edge runs down to
    done_ids: set[str] = set()
    for n in order:
        before = list(lanes)
        hits = [i for i, t in enumerate(lanes) if t == n]
        if hits:
            col = hits[0]
        else:
            col = lanes.index(None) if None in lanes else len(lanes)
            if col == len(lanes):
                lanes.append(None)
        for m in hits:
            lanes[m] = None
        done_ids.add(n)
        forks: list[int] = []
        later = sorted((k for k in kids[n] if k not in done_ids), key=at.__getitem__)
        if later:
            lanes[col] = later[0]
            for k in later[1:]:
                free = [i for i in range(col + 1, len(lanes)) if lanes[i] is None]
                i = free[0] if free else len(lanes)
                if i == len(lanes):
                    lanes.append(None)
                lanes[i] = k
                forks.append(i)
        width = max(len(before), col + 1, len(lanes))
        cells = ["│" if i < len(before) and before[i] is not None else " " for i in range(width)]
        cells[col] = GLYPH.get(state[n], GLYPH["ready"])
        gaps = [" "] * width
        if hits[1:]:
            bridge(cells, gaps, col, hits[1:], "╯", "┴")
        live = ["│" if i < len(lanes) and lanes[i] is not None else " " for i in range(width)]
        # A detail line sits between this row and its fork: the forked lanes start below it.
        cont = join([" " if i in forks else c for i, c in enumerate(live)], [" "] * width)
        rows.append({"goal": n, "graph": join(cells, gaps), "col": 2 * col, "cont": cont})
        if forks:
            cells = list(live)
            cells[col] = "├"
            gaps = [" "] * width
            bridge(cells, gaps, col, forks, "╮", "┬")
            rows.append({"graph": join(cells, gaps)})
        while lanes and lanes[-1] is None:
            lanes.pop()
    return rows


def short_model(model: str) -> str:
    for name in ("haiku", "deepseek", "opus", "sonnet"):
        if name in model:
            return name
    return model


def _add_cost(threads: dict, key: str, usd, basis) -> None:
    """One implementer cost value into THREADS ({thread: (basis, [usd...])}).
    No thread recorded: the last unnamed one, or a new one where it drops."""
    try:
        c = float(usd)
    except (TypeError, ValueError):
        return
    if not key:
        unnamed = [k for k in threads if k.startswith("#")]
        key = unnamed[-1] if unnamed and c >= max(threads[unnamed[-1]][1]) else f"#{len(unnamed)}"
    # A thread's basis is its first value's (cost-rollup.py judges each line;
    # they differ only on a thread with both bases, which no launcher writes).
    threads.setdefault(key, (str(basis or "thread"), []))[1].append(c)


def goal_stats(rows: list[dict], live: dict | set = frozenset()) -> dict[str, dict]:
    """Per goal from the event index: its last round, the model of its last
    implementer pass, whether a fallback ran, the time spent in its runs, and
    the implementer's cost.

    Time adds each run, `walk`/`dispatch` to a terminal event (to the last row
    naming the goal when its process died without one; to now while it runs).
    The cost follows lib/cost-rollup.py's rule (docs/features/deepseek-primary
    step 7): a pass's `cost_usd` with `cost_basis` `thread` (or none, as before
    the basis existed) is its thread's running total, so such a thread costs
    its largest value; `pass` values are summed. A pass that fell back also
    carries the primary's cost in `fallback_from` ("<thread> COST_USD=<x>
    COST_BASIS=<b>"), a value of the primary's thread. Threads are the payload's
    `thread`; a record from before that was kept starts a new one where the
    total drops. An estimate, and the implementer's alone (not the review's).
    """
    now = datetime.now(timezone.utc)
    stats: dict[str, dict] = {}
    for r in rows:
        gid = r.get("goal_id")
        if not gid:
            continue
        s = stats.setdefault(gid, {"round": None, "model": None, "fallback": False, "secs": 0.0,
                                   "_threads": {}, "_since": None, "_last": None})
        if r.get("round") is not None:
            s["round"] = r["round"]
        ev, t = r.get("event"), parse_ts(r.get("ts") or "")
        if t is not None:
            s["_last"] = t
            if ev in ("walk", "dispatch") and s["_since"] is None:
                s["_since"] = t
            elif ev in TERMINAL and s["_since"] is not None:
                s["secs"] += (t - s["_since"]).total_seconds()
                s["_since"] = None
        if ev == "implemented":
            p = r.get("payload") if isinstance(r.get("payload"), dict) else {}
            if p.get("model"):
                s["model"] = short_model(str(p["model"]))
            if p.get("fallback"):
                s["fallback"] = True
            fb = str(p.get("fallback_from") or "").split()
            if fb:
                fields = dict(f.split("=", 1) for f in fb[1:] if "=" in f)
                _add_cost(s["_threads"], fb[0], fields.get("COST_USD"), fields.get("COST_BASIS"))
            _add_cost(s["_threads"], str(p.get("thread") or ""), p.get("cost_usd"), p.get("cost_basis"))
    for gid, s in stats.items():
        if s["_since"] is not None:
            end = now if gid in live else s["_last"]
            s["secs"] += max(0.0, (end - s["_since"]).total_seconds())
        s["cost"] = round(sum(sum(v) if b == "pass" else max(v) for b, v in s["_threads"].values()), 4) \
            if s["_threads"] else None
        s["secs"] = int(s["secs"]) or None
        for k in ("_threads", "_since", "_last"):
            del s[k]
    return stats


def walk_graph(start: Path) -> dict:
    """The walk pane's model: every goal of the GOALS.md at or above `start`,
    laid out as git-graph rows, with its state and stats, and what runs now."""
    root = find_goals_root(start.resolve())
    if root is None:
        return {"found": False, "dir": str(start)}
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import goals  # noqa: PLC0415 - the DAG reader beside this file

    try:
        _, data, _, _ = goals.load(root / "GOALS.md")
    except SystemExit as exc:  # a GOALS.md mid-write: the pane keeps its last graph
        raise ValueError(f"GOALS.md: {exc}") from exc
    journal = data.get("journal") or ""
    feature = slug_of(Path(journal)) if journal else root.name
    rows = tail_rows(cache_root() / repo_id(root) / f"{feature}.jsonl", limit=20000) if journal else []
    # The header and every goal's state from the same read: the newest live goal leads.
    live = live_goals(rows)
    running = next(iter(live), None)
    stats = goal_stats(rows, live)
    last_goal_event = {r["goal_id"]: r.get("event") for r in rows if r.get("goal_id")}
    idx = goals.by_id(data)
    out: dict[str, dict] = {}
    for g in data.get("goals", []):
        gid, st = g["id"], g.get("status")
        waits = [b for b in g.get("blocked_by") or [] if b in idx and goals.unfinished(idx[b].get("status"))]
        if st == "done":
            state = "done"
        elif gid in live:
            state = "running"
        elif st == "bounced":
            state = "bounced"
        elif st == "in_progress" and last_goal_event.get(gid) == "recut":
            state = "ready"  # recut after a merge conflict: runs fresh in a later wave
        elif st == "in_progress":
            state = "paused"  # stopped mid-goal: the next walk resumes it first
        else:
            state = "waiting" if waits else "ready"
        s = stats.get(gid, {})
        out[gid] = {"title": g.get("title") or "", "state": state, "waits": waits,
                    "round": s.get("round"), "model": s.get("model"), "fallback": bool(s.get("fallback")),
                    "secs": s.get("secs"), "cost": s.get("cost"),
                    "phase": live[gid]["phase"] if state == "running" else None,
                    "reason": goal_reason(rows, gid) if state in ("paused", "bounced") else None}
    layout = lay_out([{"id": gid, "blocked_by": g.get("blocked_by"), "state": out[gid]["state"]}
                      for gid, g in ((g["id"], g) for g in data.get("goals", []))])
    return {"found": True, "dir": str(root), "feature": feature,
            "done": sum(1 for v in out.values() if v["state"] == "done"), "total": len(out),
            "running": running, "phase": live[running]["phase"] if running else None,
            "round": live[running]["round"] if running else None, "others": max(0, len(live) - 1),
            "width": max((len(r["graph"]) for r in layout), default=0),
            "rows": layout, "goals": out}


def fmt_secs(secs: int | None) -> str:
    if not secs:
        return ""
    h, rem = divmod(int(secs), 3600)
    m, s = divmod(rem, 60)
    return f"{h}h{m:02d}m" if h else f"{m}m{s:02d}s"


def graph_text(view: dict) -> str:
    """The pane's wide form as plain text, for a shell."""
    if not view.get("found"):
        return f"no GOALS.md at or above {view.get('dir')}"
    head = f"walk · {view['feature']} · {view['done']}/{view['total']} done"
    if view.get("running"):
        rnd = view.get("round")
        more = f" +{view['others']}" if view.get("others") else ""
        head += f" · {view['running']}{f' r{rnd}' if rnd is not None else ''} · {view.get('phase')}{more}"
    width = view["width"]
    idw = min(18, max((len(g) for g in view["goals"]), default=0))
    lines = [head]
    for row in view["rows"]:
        gid = row.get("goal")
        if gid is None:
            lines.append(row["graph"])
            continue
        g = view["goals"][gid]
        if g["state"] in ("done", "running", "paused", "bounced"):
            bits = [g["state"], f"r{g['round']}" if g["round"] is not None else "",
                    g["phase"] or g["model"] or "", fmt_secs(g["secs"]),
                    f"${g['cost']:.2f}" if g["cost"] is not None else ""]
            detail = " ".join(b for b in bits if b)
        elif g["state"] == "waiting":
            detail = "waits " + ",".join(g["waits"])
        else:
            detail = "ready"
        lines.append(f"{row['graph']:<{width}}  {gid:<{idw}}  {g['title'][:28]:<28}  {detail}".rstrip())
    return "\n".join(lines)


def cmd_graph(args: argparse.Namespace) -> int:
    start = Path(os.path.expanduser(args.dir)) if args.dir else Path.cwd()
    try:
        view = walk_graph(start)
    except (OSError, ValueError, KeyError, TypeError) as exc:  # a goal with no id, a list that is not one
        print(f"events.py graph: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(view) if args.json else graph_text(view))
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    try:
        status = walk_status(Path.cwd())
    except (OSError, ValueError) as exc:
        print(f"events.py status: {exc}", file=sys.stderr)
        return 1
    if args.json:
        # ASCII: the reader may run without a UTF-8 locale.
        print(json.dumps(status))
    else:
        print(status.get("label") or "no goal running")
    return 0


def cmd_walks(args: argparse.Namespace) -> int:
    try:
        walks = list_walks({s for s in args.session if s})
    except OSError as exc:
        print(f"events.py walks: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(walks) if args.json else "\n".join(
        f"{w['walk_id']}  {'live' if w['live'] else 'idle'}  {w['root']}" for w in walks))
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

    s = sub.add_parser("status")
    s.add_argument("--json", action="store_true")

    gr = sub.add_parser("graph")
    gr.add_argument("--json", action="store_true")
    gr.add_argument("--dir", default="")

    w = sub.add_parser("walks")
    w.add_argument("--session", action="append", default=[], required=True)
    w.add_argument("--json", action="store_true")

    args = p.parse_args(argv)
    if args.cmd == "walks":
        return cmd_walks(args)
    if args.cmd == "status":
        return cmd_status(args)
    if args.cmd == "graph":
        return cmd_graph(args)
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
