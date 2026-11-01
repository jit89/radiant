#!/usr/bin/env python3
"""Generate mods/walk/hooks/fixtures.ts: real `events.py walks` and `graph`
output for the walk mod's end-to-end scenarios (docs/features/walk-tasks,
VERIFICATION item 1). Each scenario is built from real walk files and event
logs in a throwaway cache, with this process as the live walker; each step
records what `walks` and `graph` print. The mod's tests feed those steps into
the real poll; scripts/tests/walk-tasks-test.sh regenerates the file and fails
when events.py's output has drifted from it.

Usage: gen-walk-fixtures.py [OUT]   (default: mods/walk/hooks/fixtures.ts)
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
EVENTS = HERE / "events.py"
GOALS = HERE / "goals.py"
EXAMPLE = HERE.parent / "GOALS.example.md"
SESSION = "S1"
KEEP_GOAL = ("title", "state", "round", "phase", "reason")


def lstart(pid: int) -> str:
    out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True).stdout
    return " ".join(out.split())


class Gen:
    def __init__(self, tmp: Path):
        self.tmp = tmp
        tmp.mkdir(parents=True)
        self.cache = tmp / "cache"
        self.env = {**os.environ, "EVENTS_CACHE": str(self.cache), "HOME": str(tmp / "home"), "TMPDIR": str(tmp)}
        self.env.pop("CLAUDE_CODE_SESSION_ID", None)
        (tmp / "home").mkdir()
        self.live = (os.getpid(), lstart(os.getpid()))
        dead = int(subprocess.run(["sh", "-c", "echo $$"], capture_output=True, text=True).stdout)
        self.dead = (dead, "Thu Jan 1 00:00:00 2015")
        self.repos: dict[str, Path] = {}
        self.wids: dict[str, str] = {}  # real walk_id -> a fixed one per repo

    def repo(self, name: str) -> Path:
        r = (self.tmp / name).resolve()
        (r / "docs" / "journal").mkdir(parents=True)
        subprocess.run(["git", "init", "-q"], cwd=r, check=True, env=self.env)
        shutil.copy(EXAMPLE, r / "GOALS.md")
        (r / "docs" / "journal" / "example.md").write_text("# Journal\n")
        self.repos[name] = r
        return r

    def rid(self, r: Path) -> Path:
        return self.cache / hashlib.sha256(str(r.resolve()).encode()).hexdigest()[:16]

    def ensure(self, r: Path) -> str:
        out = subprocess.run([sys.executable, str(EVENTS), "ensure-walk", "docs/journal/example.md"], cwd=r,
                             capture_output=True, text=True, check=True,
                             env={**self.env, "CLAUDE_CODE_SESSION_ID": SESSION}).stdout.strip()
        wid = out.split("\t")[-1]
        name = next(n for n, p in self.repos.items() if p == r)
        self.wids.setdefault(wid, f"{name * 8}-0000-4000-8000-{len(self.wids) + 1:012d}")
        with (r / "docs" / "journal" / "example.md").open("a") as fh:
            fh.write(f"## x — ORCHESTRATOR walk-start walk_id={wid}\n")
        return wid

    def row(self, r: Path, wid: str, event: str, goal: str | None, mono: int, who=None, reason: str | None = None):
        payload = {}
        if who:
            payload = {"pid": who[0], "pid_start": who[1]}
        line = {"ts": "2026-10-14T00:00:00Z", "ts_mono": mono, "walk_id": wid, "goal_id": goal, "event": event,
                "reason": reason, "payload": payload}
        p = self.rid(r) / "example.jsonl"
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open("a") as fh:
            fh.write(json.dumps(line) + "\n")

    def status(self, r: Path, goal: str, st: str):
        subprocess.run([sys.executable, str(GOALS), "GOALS.md", "set", goal, st], cwd=r, check=True,
                       capture_output=True, env=self.env)

    def touch(self, r: Path, secs: int):
        wf = self.rid(r) / "example.walk"
        if wf.exists():
            os.utime(wf, (secs, secs))

    def end(self, r: Path):
        subprocess.run([sys.executable, str(EVENTS), "end-walk", "docs/journal/example.md"], cwd=r, check=True,
                       env=self.env)

    def norm(self, text: str) -> str:
        for name, r in self.repos.items():
            text = text.replace(str(r), f"/W/{name}")
        for real, fixed in self.wids.items():
            text = text.replace(real, fixed)
        return text

    def snapshot(self, extra_roots: tuple[str, ...] = ()) -> dict:
        walks = json.loads(subprocess.run([sys.executable, str(EVENTS), "walks", "--session", SESSION, "--json"],
                                          capture_output=True, text=True, check=True, env=self.env).stdout)
        names = {name for name, r in self.repos.items() if any(w["root"] == str(r) for w in walks)} | set(extra_roots)
        graphs = {}
        for name in sorted(names):
            g = json.loads(subprocess.run([sys.executable, str(EVENTS), "graph", "--json", "--dir", str(self.repos[name])],
                                          capture_output=True, text=True, check=True, env=self.env).stdout)
            graphs[f"/W/{name}"] = {"found": g["found"], "dir": g["dir"],
                                    "goals": {gid: {k: v.get(k) for k in KEEP_GOAL} for gid, v in g["goals"].items()}}
        snap = json.loads(self.norm(json.dumps({"walks": walks, "graphs": graphs})))
        snap["walks"].sort(key=lambda w: (w["root"], w["walk_id"]))
        return snap


def build(tmp: Path) -> dict:
    out: dict[str, list] = {}

    # A gate-stopped launch does not take the list.
    g = Gen(tmp / "gate")
    a = g.repo("a"); wa = g.ensure(a); g.touch(a, 1000)
    g.status(a, "g1-store", "in_progress")
    g.row(a, wa, "walk", "g1-store", 100, g.live)
    g.row(a, wa, "dispatch", "g1-store", 110, g.live)
    s0 = g.snapshot()
    g.row(a, wa, "walk", "g1-store", 200, g.dead)  # its walker is gone
    g.row(a, wa, "dispatch", "g1-store", 210, g.dead)
    b = g.repo("b"); wb = g.ensure(b); g.touch(b, 2000)
    g.row(b, wb, "wake", None, 300, None, "dirty-tree")  # stopped before any pid row
    out["gateStopped"] = [s0, g.snapshot()]

    # Between goals the walk stays live.
    g = Gen(tmp / "gap")
    a = g.repo("a"); wa = g.ensure(a); g.touch(a, 1000)
    g.row(a, wa, "walk", "g1-store", 100, g.live)
    g.row(a, wa, "dispatch", "g1-store", 110, g.dead)
    g.row(a, wa, "done", "g1-store", 120)
    g.status(a, "g1-store", "done")
    out["betweenGoals"] = [g.snapshot()]

    # Walk-end with an older leftover listed: the finished walk is applied once.
    g = Gen(tmp / "end")
    c = g.repo("c"); g.ensure(c); g.touch(c, 500)
    a = g.repo("a"); wa = g.ensure(a); g.touch(a, 1000)
    g.status(a, "g1-store", "in_progress")
    g.row(a, wa, "walk", "g1-store", 100, g.live)
    s0 = g.snapshot()
    g.status(a, "g1-store", "done")
    g.status(a, "g2-ack", "in_progress")
    g.row(a, wa, "done", "g1-store", 200)
    g.row(a, wa, "walk", "g2-ack", 210, g.live)
    g.row(a, wa, "wake", "g2-ack", 220, None, "proof-red")
    g.row(a, wa, "walk_end", None, 230)
    g.end(a)
    out["walkEnd"] = [s0, g.snapshot(extra_roots=("a",))]

    # Two live walks: the latest started keeps the list when the older starts its next goal.
    g = Gen(tmp / "two")
    a = g.repo("a"); wa = g.ensure(a); g.touch(a, 1000)
    g.row(a, wa, "walk", "g1-store", 10, g.live)
    b = g.repo("b"); wb = g.ensure(b); g.touch(b, 900)
    g.row(b, wb, "walk", "g1-store", 50, g.live)
    s0 = g.snapshot()
    g.ensure(a)  # A's next goal (same session: the file is left alone)
    g.row(a, wa, "walk", "g2-ack", 60, g.live)
    out["twoLive"] = [s0, g.snapshot()]

    # A single /run-goal (dispatch rows only, no walk row) is live and current.
    g = Gen(tmp / "rungoal")
    a = g.repo("a"); wa = g.ensure(a); g.touch(a, 1000)
    g.status(a, "g1-store", "in_progress")
    g.row(a, wa, "dispatch", "g1-store", 100, g.live)
    g.row(a, wa, "phase", "g1-store", 110, g.live)
    out["runGoalOnly"] = [g.snapshot()]

    # A new live walk replaces the walk on screen.
    g = Gen(tmp / "replace")
    a = g.repo("a"); wa = g.ensure(a); g.touch(a, 1000)
    g.row(a, wa, "walk", "g1-store", 100, g.live)
    s0 = g.snapshot()
    g.row(a, wa, "walk", "g1-store", 200, g.dead)
    b = g.repo("b"); wb = g.ensure(b); g.touch(b, 2000)
    g.row(b, wb, "walk", "g1-store", 300, g.live)
    out["newLiveReplaces"] = [s0, g.snapshot()]

    # A gate stop on a goal not yet started keeps its plain title.
    g = Gen(tmp / "gateplain")
    a = g.repo("a"); wa = g.ensure(a); g.touch(a, 1000)
    g.status(a, "g1-store", "in_progress")
    g.row(a, wa, "walk", "g1-store", 100, g.live)
    s0 = g.snapshot()
    g.status(a, "g1-store", "done")
    g.row(a, wa, "done", "g1-store", 200)
    g.row(a, wa, "walk", "g1-store", 210, g.dead)
    g.row(a, wa, "wake", "g2-ack", 300, None, "dirty-tree")  # /run-goal g2 stopped before set in_progress
    out["gateUnstarted"] = [s0, g.snapshot()]
    return out


def main(argv: list[str]) -> int:
    dest = Path(argv[0]) if argv else HERE.parent / "mods" / "walk" / "hooks" / "fixtures.ts"
    tmp = Path(tempfile.mkdtemp(prefix="cw-walk-fixtures-"))
    try:
        data = build(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    body = json.dumps(data, indent=2, sort_keys=True)
    dest.write_text(
        "// Generated by scripts/gen-walk-fixtures.py from real events.py output. Do not edit:\n"
        "// rerun it (scripts/tests/walk-tasks-test.sh fails when this file is stale).\n"
        "import type { WalkGoal, WalkWalk } from '../types'\n\n"
        "/** A graph as the generator keeps it: only the goal fields the task list reads. */\n"
        "export type FixtureGraph = { found: boolean; dir: string; goals: Record<string, Pick<WalkGoal, 'title' | 'state' | 'round' | 'phase' | 'reason'>> }\n"
        "export type FixtureStep = { walks: WalkWalk[]; graphs: Record<string, FixtureGraph> }\n\n"
        f"export const SCENARIOS: Record<string, FixtureStep[]> = {body}\n"
    )
    print(dest)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
