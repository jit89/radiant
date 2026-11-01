#!/usr/bin/env python3
"""run-timeout.py [--wall GAP] [--reap] SECS CMD... — timeout(1) for hosts without coreutils.

CMD runs in its own session, so a terminal Ctrl-C does not reach it and the
caller decides when it dies. SECS=0 means no time limit. Exits 124 on timeout,
the command's status otherwise (128+N if a signal killed it).

--wall GAP: SECS is measured on the wall clock, so time the host spent asleep
counts, and a wall-clock jump of more than GAP seconds between two checks a
second apart (the host slept, and a network call in CMD may never return)
stops CMD and exits 125. GAP 0 turns that check off. A forward clock step of
more than GAP, or the caller held stopped (Ctrl-Z) that long, reads as a sleep
too: a void run, rerun it.

On SIGTERM/SIGINT/SIGHUP the whole session is stopped (TERM, then KILL after 5s)
before exiting 128+N. Exiting without that would orphan the command.

--reap (the proof sandbox, lib/proof.sh): when CMD ends for any reason (a
timeout, a signal, or its own exit), every process still in its session is
KILLed: a child that ignored TERM, or moved to another process group of the
session, does not outlive the run. A child that made a session of its own
(setsid) is beyond reach: a known limit.
"""
import os
import signal
import subprocess
import sys
import time

GRACE = 5
POLL = 1.0

args = sys.argv[1:]
gap = None
reap = False
while args[:1] in (["--wall"], ["--reap"]):
    if args[0] == "--wall":
        gap = float(args[1])
        args = args[2:]
    else:
        reap = True
        args = args[1:]
secs = int(args[0])
p = None
# A signal that arrives while the child is still being started (p not yet
# set) is held here and acted on as soon as p exists.
pending = []


def session_members(sid):
    out = subprocess.run(["/bin/ps", "-axo", "pid="], capture_output=True, text=True).stdout
    me = os.getpid()
    pids = []
    for tok in out.split():
        try:
            pid = int(tok)
            if pid != me and os.getsid(pid) == sid:
                pids.append(pid)
        except (ValueError, OSError):
            continue
    return pids


def reap_session() -> None:
    """KILL whatever is left in CMD's session (its id is CMD's pid)."""
    if not reap or p is None:
        return
    # The leader's group first: no fork needed, and the group id cannot be
    # reused while any member lives.
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except OSError:
        pass
    for _ in range(3):
        try:
            left = session_members(p.pid)
        except OSError:
            return  # cannot start ps (process limit): the group KILL above stands
        if not left:
            return
        for pid in left:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        time.sleep(0.1)


def stop() -> None:
    if p is None:
        return
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(p.pid, sig)
        except ProcessLookupError:
            return
        try:
            p.wait(timeout=GRACE)
            return
        except subprocess.TimeoutExpired:
            pass


def on_signal(signum, _frame) -> None:
    if p is None:
        pending.append(signum)
        return
    stop()
    reap_session()
    sys.exit(128 + signum)


# Before the child starts: a signal in between must not leave it timerless.
signal.signal(signal.SIGTERM, on_signal)
signal.signal(signal.SIGINT, on_signal)
signal.signal(signal.SIGHUP, on_signal)
p = subprocess.Popen(args[1:], start_new_session=True)
if pending:
    on_signal(pending[0], None)
# With no time limit, wait in short steps too, so a signal almost never lands
# inside a wait that holds the lock stop() needs (a non-blocking waitpid
# still holds it for microseconds; stop()'s group KILL covers that case).
if gap is None and secs == 0:
    gap = 0.0

if gap is None:
    try:
        rc = p.wait(timeout=secs or None)
    except subprocess.TimeoutExpired:
        stop()
        reap_session()
        sys.exit(124)
else:
    last = time.time()
    deadline = last + secs if secs else None
    while True:
        try:
            rc = p.wait(timeout=POLL)
            break
        except subprocess.TimeoutExpired:
            pass
        now = time.time()
        if gap and now - last > gap:
            stop()
            reap_session()
            sys.exit(125)
        last = now
        if deadline is not None and now >= deadline:
            stop()
            reap_session()
            sys.exit(124)
reap_session()
sys.exit(rc if rc >= 0 else 128 - rc)
