#!/usr/bin/env python3
"""run-timeout.py [--wall GAP] SECS CMD... — timeout(1) for hosts without coreutils.

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
if args[:1] == ["--wall"]:
    gap = float(args[1])
    args = args[2:]
secs = int(args[0])
p = subprocess.Popen(args[1:], start_new_session=True)


def stop() -> None:
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
    stop()
    sys.exit(128 + signum)


signal.signal(signal.SIGTERM, on_signal)
signal.signal(signal.SIGINT, on_signal)
signal.signal(signal.SIGHUP, on_signal)

if gap is None:
    try:
        rc = p.wait(timeout=secs or None)
    except subprocess.TimeoutExpired:
        stop()
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
            sys.exit(125)
        last = now
        if deadline is not None and now >= deadline:
            stop()
            sys.exit(124)
sys.exit(rc if rc >= 0 else 128 - rc)
