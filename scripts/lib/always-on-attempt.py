#!/usr/bin/env python3
"""always-on-attempt.py — one walk attempt of the always-on supervisor
(docs/features/always-on/PLAN.md step 5).

  run DIR -- CMD...   the wrapper: run CMD (run-goals.sh --jobs N, in the
                      target repo) as an attempt whose folder is DIR
                      (attempts/<entry>/<n>/, made by the supervisor, which
                      starts this in a session of its own)
  state DIR           print running | finished | interrupted | not-started
  stop DIR [SIG]      signal the attempt once (default TERM); print signalled |
                      already-signalled | not-running

The wrapper holds an exclusive flock on DIR/lock for its life and records
itself there (pid, start time, group); without its own start time it refuses.
The walker starts behind a gate: it runs only once DIR/walker.json holds its
pid and start time, so a wrapper killed before that leaves no walker the state
cannot see, and a start time that cannot be read starts no walker. The
walker's stdout and stderr go to DIR/walker.out and DIR/walker.err (files, so
a walker outliving its wrapper never meets a broken pipe). TERM, INT and HUP
(as TERM) are forwarded; a signal before the gate opens starts no walker. On
any exit of its own (an exception) the wrapper TERMs the walker and waits.
When the walker exits it writes DIR/result.json once (a temporary file,
fsync, rename):
  {"exit": N, "walked": true|false, "stop_file": the last stdout line's
   STOP_FILE or null, "stop": "stop/stop.md" or null, "copy_errors": [...],
   "why": (when it did not walk), "signals": [...]}
The copy (DIR/stop/) is complete: the stop file and the files on its LOG: and
stderr: lines (a relative path from the stop's folder, as the classifier reads
it); for a wave-stop (the classifier's rule) each per-goal stop under its
Stopped bullets and their LOG: and stderr: files; every such path rewritten to
its copy, so the billing scan reads only copies after the run folder is pruned.
A named file that cannot be copied is a copy_errors entry {"goal", "path",
"why": missing | not-a-file | unreadable | ...} and its line is emptied.

The run state, from the world alone: running when the lock is held or the
recorded walker is alive (its pid's start time matches, read with LC_ALL=C
TZ=UTC, and its command holds run-goals.sh); else finished when result.json
exists; else interrupted when a walker was recorded; else not-started (no
walker can have run: the supervisor may start the attempt again).
"""
import errno
import fcntl
import json
import os
import re
import signal
import subprocess
import sys
import time

CAP = 8 << 20  # bytes copied from one named file (the classifier reads as many)
WALKER_MARK = "run-goals.sh"


def ps_field(pid, field):
    # One locale and zone for every caller: lstart is formatted with both, and
    # the wrapper and a later state check need not share an environment.
    try:
        out = subprocess.run(["ps", "-o", field + "=", "-p", str(int(pid))],
                             capture_output=True, text=True, timeout=5,
                             env={**os.environ, "LC_ALL": "C", "TZ": "UTC"}).stdout
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        return None
    out = " ".join(out.split())
    return out or None


def alive(rec, mark=None):
    """The process a record names is alive: same pid, same start time (a reused
    pid reads as gone), and, with `mark`, a command line holding it."""
    try:
        pid = int(rec["pid"])
        os.kill(pid, 0)
    except (KeyError, TypeError, ValueError, ProcessLookupError):
        return False
    except PermissionError:
        pass
    if not rec.get("start") or ps_field(pid, "lstart") != rec["start"]:
        return False
    if mark is not None and mark not in (ps_field(pid, "command") or ""):
        return False
    return True


def write_atomic(path, data):
    tmp = f"{path}.tmp-{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    fd = os.open(os.path.dirname(path) or ".", os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


# ---- the copy ---------------------------------------------------------------

def copy_file(src, dst_dir, name, errors, goal):
    """Copy src (its first CAP bytes) to dst_dir/name; the copy's path, or ""
    when it cannot be made (recorded in errors, naming the goal)."""
    if not os.path.lexists(src):
        errors.append({"goal": goal, "path": src, "why": "missing"})
        return ""
    if not os.path.isfile(src):
        errors.append({"goal": goal, "path": src, "why": "not-a-file"})
        return ""
    dst = os.path.join(dst_dir, name)
    try:
        with open(src, "rb") as f:
            data = f.read(CAP)
        with open(dst, "wb") as f:
            f.write(data)
    except OSError as e:
        errors.append({"goal": goal, "path": src,
                       "why": "unreadable" if e.errno in (errno.EACCES, errno.EPERM) else f"error {e.errno}"})
        return ""
    return dst


NAMED = re.compile(r"^(- (?:LOG|stderr): ?)(.*)$")


def copy_stop(src, dst_dir, errors, goal):
    """Copy one stop file and the files its LOG:/stderr: lines name (a relative
    one from the stop's folder, as the classifier reads it) into dst_dir, the
    lines rewritten to the copies; the copy's text, or None."""
    os.makedirs(dst_dir, exist_ok=True)
    if not os.path.isfile(src):  # a FIFO must not block the wrapper
        errors.append({"goal": goal, "path": src, "why": "missing" if not os.path.lexists(src) else "not-a-file"})
        return None
    try:
        with open(src, "rb") as f:
            text = f.read(CAP).decode("utf-8", "replace")
    except OSError:
        errors.append({"goal": goal, "path": src, "why": "unreadable"})
        return None
    base = os.path.dirname(src)
    out, k = [], 0
    for line in text.split("\n"):
        m = NAMED.match(line)
        if m and m.group(2).strip():
            k += 1
            p = m.group(2).strip()
            p = p if os.path.isabs(p) else os.path.join(base, p)
            line = m.group(1) + copy_file(p, dst_dir, f"named-{k}-{os.path.basename(p)[:80]}", errors, goal)
        out.append(line)
    return "\n".join(out)


BULLET = re.compile(r"^- (\S+?): (\S*) — (.*)$")


def copy_all(stop_file, dir_):
    """The complete copy under DIR/stop/: (relative path of the copied stop, errors)."""
    errors = []
    root = os.path.join(dir_, "stop")
    text = copy_stop(stop_file, root, errors, "walk")
    if text is None:
        return None, errors
    lines = text.split("\n")
    # The classifier's rule: `# Stop: walk` and the first reason line wave-stop.
    first = re.match(r"^# Stop: (\S+)", lines[0]) if lines else None
    reason = next((l[len("- reason:"):].strip() for l in lines if l.startswith("- reason:")), "")
    wave = bool(first) and first.group(1) == "walk" and reason == "wave-stop"
    sbase = os.path.dirname(stop_file)
    if wave:
        inside, j = False, 0
        for i, line in enumerate(lines):
            if line.startswith("## "):
                inside = line.strip() == "## Stopped"
                continue
            m = BULLET.match(line) if inside else None
            if not m:
                continue
            f = m.group(3).strip()
            if not f or f == "(no stop file)":
                continue
            f = f if os.path.isabs(f) else os.path.join(sbase, f)
            j += 1
            safe = re.sub(r"[^A-Za-z0-9_.-]", "_", m.group(1)).lstrip(".")[:60] or "goal"
            gdir = os.path.join(root, "goals", f"{j}-{safe}")
            gtext = copy_stop(f, gdir, errors, m.group(1))
            if gtext is None:
                lines[i] = f"- {m.group(1)}: {m.group(2)} — (no stop file)"
                continue
            gpath = os.path.join(gdir, "stop.md")
            write_atomic(gpath, gtext)
            lines[i] = f"- {m.group(1)}: {m.group(2)} — {gpath}"
    write_atomic(os.path.join(root, "stop.md"), "\n".join(lines))
    return "stop/stop.md", errors


# ---- the wrapper --------------------------------------------------------------

def take_lock(dir_):
    fd = os.open(os.path.join(dir_, "lock"), os.O_RDWR | os.O_CREAT, 0o600)
    for _ in range(50):  # a supervisor reading the state holds it for an instant
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            time.sleep(0.1)
    os.close(fd)
    return None


def last_stop_line(path):
    """The walker's STOP_FILE: its stdout's last non-empty line (run-goal.sh's
    and run-goals.sh's contract), or None. A wave member's line earlier in the
    output is never taken for the walk's."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 65536))
            tail = f.read().decode("utf-8", "replace")
    except OSError:
        return None
    last = next((l for l in reversed(tail.splitlines()) if l.strip()), "")
    return last[len("STOP_FILE: "):].strip() or None if last.startswith("STOP_FILE: ") else None


def run(dir_, cmd):
    if not os.path.isdir(dir_):
        print(f"always-on-attempt: no attempt folder {dir_}", file=sys.stderr)
        return 2
    lock = take_lock(dir_)
    if lock is None:
        print("always-on-attempt: the attempt's lock is held", file=sys.stderr)
        return 75
    if os.path.exists(os.path.join(dir_, "result.json")) or os.path.exists(os.path.join(dir_, "walker.json")):
        print("always-on-attempt: this attempt already ran", file=sys.stderr)
        return 2
    me = {"pid": os.getpid(), "start": ps_field(os.getpid(), "lstart"), "pgid": os.getpgid(0)}
    if not me["start"]:
        # A record that can never match could never be signalled: refuse.
        print("always-on-attempt: cannot read this process's start time", file=sys.stderr)
        return 2
    os.ftruncate(lock, 0)
    os.write(lock, (json.dumps(me) + "\n").encode())
    os.fsync(lock)

    gate_r, gate_w = os.pipe()
    walker = None
    signalled = []

    def forward(sig, _frame):
        signalled.append(sig)
        if walker is not None and walker.poll() is None:
            try:  # HUP as TERM: the walker traps INT and TERM only
                walker.send_signal(signal.SIGTERM if sig == signal.SIGHUP else sig)
            except ProcessLookupError:
                pass

    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(s, forward)
    walked, why = False, None
    out_path, err_path = os.path.join(dir_, "walker.out"), os.path.join(dir_, "walker.err")
    try:
        # The walker's output goes to files, never a pipe: a walker that
        # outlives a killed wrapper must not die of SIGPIPE on its next line.
        with open(out_path, "ab") as out, open(err_path, "ab") as err:
            # The gate, on the walker's stdin: sh waits for "go", then becomes
            # the walker (the same pid, the same start time) with stdin from
            # /dev/null; EOF without it (this wrapper gone) ends sh, no walker.
            walker = subprocess.Popen(
                ["/bin/sh", "-c", 'IFS= read -r go && [ "$go" = go ] && exec "$@" </dev/null', "sh"] + cmd,
                stdin=gate_r, stdout=out, stderr=err)
        os.close(gate_r)
        rec = {"pid": walker.pid, "start": ps_field(walker.pid, "lstart"), "pgid": os.getpgid(0)}
        if not rec["start"]:
            why = "the walker's start time could not be read; it was never started"
        else:
            write_atomic(os.path.join(dir_, "walker.json"), json.dumps(rec) + "\n")
            if not signalled:  # stopped before the gate opened: no walker at all
                try:
                    os.write(gate_w, b"go\n")
                    walked = True
                except BrokenPipeError:
                    why = "the gate closed before the walker started"
            else:
                why = "stopped before the walker started"
        os.close(gate_w)
        gate_w = None
        while True:
            try:
                rc = walker.wait()
                break
            except InterruptedError:
                continue
    except BaseException:
        if gate_w is not None:
            os.close(gate_w)
        if walker is not None and walker.poll() is None:
            try:
                walker.terminate()
            except ProcessLookupError:
                pass
            walker.wait()
        raise
    status = rc if rc >= 0 else 128 - rc
    stop_file = last_stop_line(out_path) if walked else None
    stop, errors = (None, [])
    if stop_file:
        try:
            stop, errors = copy_all(stop_file, dir_)
        except Exception as e:  # noqa: BLE001 — a failed copy is recorded, not lost
            stop, errors = None, [{"goal": "walk", "path": stop_file, "why": f"copy failed: {e!r}"[:300]}]
    result = {"exit": status, "walked": walked, "stop_file": stop_file, "stop": stop, "copy_errors": errors}
    if why:
        result["why"] = why
    if signalled:
        result["signals"] = sorted({signal.Signals(s).name for s in signalled})
    write_atomic(os.path.join(dir_, "result.json"), json.dumps(result) + "\n")
    os.close(lock)
    return 0


# ---- the state ----------------------------------------------------------------

def lock_held(dir_):
    try:
        fd = os.open(os.path.join(dir_, "lock"), os.O_RDONLY)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return False
    except BlockingIOError:
        return True
    finally:
        os.close(fd)


def state(dir_):
    """running | finished | interrupted | not-started (no walker record, no
    result, the lock free: no walker can have run, so the attempt may start)."""
    if lock_held(dir_):
        return "running"
    w = read_json(os.path.join(dir_, "walker.json"))
    if w and alive(w, WALKER_MARK):
        return "running"
    if read_json(os.path.join(dir_, "result.json")) is not None:
        return "finished"
    return "interrupted" if os.path.exists(os.path.join(dir_, "walker.json")) else "not-started"


def stop(dir_, sig=signal.SIGTERM):
    """Signal the attempt once: the walker's pid while its record is alive (its
    own handlers stop its goals and their model calls; a second TERM would cut
    that cleanup short), else the wrapper's before the gate opened (it starts
    no walker then). Never a group, never a recycled pid, never twice for the
    same record (DIR/stop-sent)."""
    sent = read_json(os.path.join(dir_, "stop-sent"))
    for rec, mark in ((read_json(os.path.join(dir_, "walker.json")), WALKER_MARK),
                      (_lock_rec(dir_), "always-on-attempt")):
        if not (rec and alive(rec, mark)):
            continue
        key = {"pid": rec["pid"], "start": rec["start"]}
        if sent == key:
            return "already-signalled"
        try:
            os.kill(int(rec["pid"]), sig)
        except (ProcessLookupError, PermissionError, ValueError):
            continue
        write_atomic(os.path.join(dir_, "stop-sent"), json.dumps(key) + "\n")
        return "signalled"
    return "not-running"


def _lock_rec(dir_):
    try:
        with open(os.path.join(dir_, "lock"), encoding="utf-8") as f:
            d = json.loads(f.read() or "null")
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def main(argv):
    if len(argv) >= 4 and argv[1] == "run" and argv[3] == "--" and len(argv) > 4:
        return run(argv[2], argv[4:])
    if len(argv) == 3 and argv[1] == "state":
        print(state(argv[2]))
        return 0
    if len(argv) in (3, 4) and argv[1] == "stop":
        sig = getattr(signal, "SIG" + argv[3]) if len(argv) == 4 else signal.SIGTERM
        print(stop(argv[2], sig))
        return 0
    print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
