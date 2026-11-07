#!/usr/bin/env python3
"""reap-strays.py ROOT SINCE KEEP_PID — end what an agent step left running in the checkout.

An implementer or reviewer runs commands through its own harness, which can
detach them (a new session, a parent that exits), so they outlive the step and
run_step's process group: an orphaned `cargo test` once ran at full CPU for 38
minutes through the next review and the mutations. macOS shows no other
process's environment, so a step's processes cannot be tagged; they are found
by what they hold instead.

A process is a stray when all hold: it is this user's; it started at or after
SINCE (epoch seconds, fractions allowed: the step's start; the kernel's
microsecond start time is compared, and when it cannot be read a process
counts as started before the step, so it is spared); it has no controlling terminal (a
person's shell in the checkout always has one); its working directory is ROOT
or below; and it is neither an ancestor nor a descendant of KEEP_PID (the
running host script), nor this process. Each stray gets TERM, then KILL after
3 s. Prints one `<pid> <command>` line per stray; exit 0 even when there are
none or a listing fails (best effort: the host never stops on this).
"""
import ctypes
import os
import signal
import subprocess
import sys
import time


def etime_seconds(text: str) -> int:
    """`ps -o etime`: [[dd-]hh:]mm:ss."""
    days = 0
    if "-" in text:
        d, text = text.split("-", 1)
        days = int(d)
    parts = [int(p) for p in text.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0)
    h, m, s = parts[-3:]
    return ((days * 24 + h) * 60 + m) * 60 + s


_LIBPROC = None


class _BsdInfo(ctypes.Structure):
    """<sys/proc_info.h> struct proc_bsdinfo (PROC_PIDTBSDINFO)."""

    _fields_ = [
        ("ids", ctypes.c_uint32 * 12),
        ("comm", ctypes.c_char * 16),
        ("name", ctypes.c_char * 32),
        ("rest", ctypes.c_uint32 * 6),
        ("start_sec", ctypes.c_uint64),
        ("start_usec", ctypes.c_uint64),
    ]


def start_time(pid: int) -> float | None:
    """The process's start, in epoch seconds to the microsecond, or None."""
    global _LIBPROC
    try:
        if _LIBPROC is None:
            _LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib")
        info = _BsdInfo()
        size = _LIBPROC.proc_pidinfo(pid, 3, ctypes.c_uint64(0), ctypes.byref(info), ctypes.sizeof(info))
    except OSError:
        return None
    if size != ctypes.sizeof(info):
        return None
    return info.start_sec + info.start_usec / 1e6


def processes() -> dict[int, dict]:
    out = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,uid=,tty=,etime=,command="],
        capture_output=True, text=True, check=True,
    ).stdout
    procs = {}
    for line in out.splitlines():
        f = line.split(None, 5)
        if len(f) < 5:
            continue
        procs[int(f[0])] = {
            "ppid": int(f[1]), "uid": int(f[2]), "tty": f[3],
            "etime": etime_seconds(f[4]), "command": f[5] if len(f) > 5 else "",
        }
    return procs


def cwds(pids: list[int]) -> dict[int, str]:
    if not pids:
        return {}
    out = subprocess.run(
        ["lsof", "-a", "-d", "cwd", "-Fpn", "-p", ",".join(map(str, pids))],
        capture_output=True, text=True,
    ).stdout
    found, pid = {}, None
    for line in out.splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("n") and pid is not None:
            found[pid] = line[1:]
    return found


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__.splitlines()[0], file=sys.stderr)
        return 2
    root = os.path.realpath(sys.argv[1])
    since, keep = float(sys.argv[2]), int(sys.argv[3])
    try:
        procs = processes()
    except (OSError, subprocess.CalledProcessError):
        return 0
    spared = {os.getpid(), keep}
    p = keep
    while p in procs and p > 1:  # ancestors
        p = procs[p]["ppid"]
        spared.add(p)
    children: dict[int, list[int]] = {}
    for pid, info in procs.items():
        children.setdefault(info["ppid"], []).append(pid)
    stack = [keep, os.getpid()]
    while stack:  # descendants
        for c in children.get(stack.pop(), []):
            if c not in spared:
                spared.add(c)
                stack.append(c)
    uid = os.getuid()
    candidates = [
        pid for pid, info in procs.items()
        if pid not in spared and info["uid"] == uid and info["tty"] in ("??", "-")
        and (started := start_time(pid)) is not None and started >= since
    ]
    strays = [
        pid for pid, cwd in cwds(candidates).items()
        if (real := os.path.realpath(cwd)) == root or real.startswith(root + os.sep)
    ]
    for pid in strays:
        print(f"{pid} {procs[pid]['command'][:200]}")
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    deadline = time.time() + 3
    alive = list(strays)
    while alive and time.time() < deadline:
        time.sleep(0.2)
        alive = [pid for pid in alive if _alive(pid)]
    for pid in alive:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    return 0


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


if __name__ == "__main__":
    sys.exit(main())
