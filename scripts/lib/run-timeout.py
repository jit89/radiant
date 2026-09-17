#!/usr/bin/env python3
"""run-timeout.py SECS CMD... — timeout(1) for hosts without coreutils.

CMD runs in its own session, so a terminal Ctrl-C does not reach it and the
caller decides when it dies. SECS=0 means no time limit. Exits 124 on timeout,
the command's status otherwise (128+N if a signal killed it).

On SIGTERM/SIGINT the whole session is stopped (TERM, then KILL after 5s)
before exiting 128+N. Exiting without that would orphan the command.
"""
import os
import signal
import subprocess
import sys

GRACE = 5

secs = int(sys.argv[1])
p = subprocess.Popen(sys.argv[2:], start_new_session=True)


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

try:
    rc = p.wait(timeout=secs or None)
except subprocess.TimeoutExpired:
    stop()
    sys.exit(124)
sys.exit(rc if rc >= 0 else 128 - rc)
