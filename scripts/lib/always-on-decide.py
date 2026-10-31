#!/usr/bin/env python3
"""always-on-decide.py — the user's side of the always-on house, at the Mac
(docs/features/always-on/PLAN.md steps 1-3, 14). scripts/cw-decide.sh runs it.

  status [--json]        the queue, each entry's state and last stop, spend
                         (--json: one array of {id, repo, status, hold}, for
                         the walk mod's push; nothing else)
  sign <repo> [jobs=N]   queue a walk of <repo> at its HEAD (N 2-4, default 2)
  resume <entry>         clear a hold; the supervisor dispatches one rerun
  skip <entry>           drop an entry that is not running from the queue
  stop | start           the kill file / remove it and load the LaunchAgents
  doctor                 the Mac's readiness checks; nonzero on any FAIL
  heartbeat              the daily message (the heartbeat LaunchAgent)

<entry> is an id or a unique prefix of one (status prints them).

sign refuses, naming what is missing, unless the repo is a git toplevel with a
clean tree, a GOALS.md that validates, a committed `ARCHITECT decompose`
record in the plan's journal, and either a last `## Oracle round` verdict of
VERDICT: APPROVED in the PLAN-REVIEW-LOG.md beside the plan or a committed
`ARCHITECT oracle-review override` record; and it refuses the house itself (a
toplevel holding scripts/cw-supervisor.sh). It writes the entry with the
current HEAD, replacing a held or done entry for the same repo (its state
moves to state/old/); an entry queued, waiting or running for the repo is
refused.

resume and skip write one fixed-shape record to the target journal,
`## <utc> — ARCHITECT always-on <resume|skip>`, committed alone on a clean
tree. resume is refused while an attempt runs, when the signed paths changed
since the signature (sign the new HEAD), and on serial-goal-in-progress (the
serial walker finishes that goal). It changes no counter: a resume adds no
count, so a goal at its cap stays there and the user's rerun is the only
extra one (a further stop of that kind holds again). sign, resume and skip
take the supervisor's turn lock, so a turn never runs beside them.
"""
import datetime
import fcntl
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


sup = _load("always_on_supervisor", "always-on-supervisor.py")
attempt = sup.attempt
LAUNCH_AGENTS = os.path.expanduser(os.environ.get("CW_AO_LAUNCH_AGENTS") or "~/Library/LaunchAgents")
LABELS = ("com.cw.always-on", "com.cw.always-on.heartbeat")
LAUNCHCTL = os.environ.get("CW_AO_LAUNCHCTL") or "launchctl"


def die(msg, code=1):
    print(f"cw-decide: {msg}", file=sys.stderr)
    sys.exit(code)


def git(repo, *args):
    return sup.git(repo, *args)


def queue_lines():
    try:
        with open(sup.QUEUE, encoding="utf-8") as f:
            return [l.rstrip("\n") for l in f if l.strip()]
    except OSError:
        return []


def write_queue(lines):
    os.makedirs(sup.HOME, mode=0o700, exist_ok=True)
    tmp = f"{sup.QUEUE}.tmp-{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("".join(l + "\n" for l in lines))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, sup.QUEUE)


def entries():
    """(id, entry, state) for every valid queue line."""
    out = []
    for eid, e in sup.load_queue():
        out.append((eid, e, sup.load_state(eid, e)))
    return out


def find(prefix):
    hits = [x for x in entries() if x[0].startswith(prefix)]
    if not prefix or len(hits) != 1:
        die(f"no single entry starts with {prefix!r} (cw-decide.sh status lists them)")
    return hits[0]


def running(st):
    """A live attempt, whatever acted_attempt says (a held entry can still have
    one: an error hold after its walk started); a never-started one counts only
    while it is still to be acted on (the supervisor would start it)."""
    if not (st and st["attempt"]):
        return False
    rs = attempt.state(sup.attempt_dir(st))
    return rs == "running" or (rs == "not-started" and st["acted_attempt"] != st["attempt"])


def locked():
    """The supervisor's turn lock, or exit: a turn can take minutes (a decider call)."""
    fd = sup.turn_lock(timeout=float(os.environ.get("CW_AO_TURN_WAIT") or 60))
    if fd is None:
        die("the supervisor is mid-turn (a decider call can take minutes); try again shortly")
    return fd


def retire(eid):
    """Move an entry's state to state/old/ (kept, never deleted)."""
    p = sup.state_path(eid)
    if os.path.exists(p):
        old = os.path.join(sup.STATE, "old")
        os.makedirs(old, exist_ok=True)
        shutil.move(p, os.path.join(old, f"{eid}-{int(time.time())}.json"))


def utc():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def journal_record(st, word):
    """`## <utc> — ARCHITECT always-on <word>`, committed alone; None or why not."""
    repo = st["repo"]
    if word == "skip" and not os.path.isdir(repo):
        print(f"cw-decide: {repo} no longer exists: skipped without a journal record")
        return None
    j = sup.journal_path(st)
    if not j or os.path.isabs(j) or ".." in j.split("/"):
        return "the journal path cannot be read, or is outside the repo"
    if git(repo, "ls-files", "--error-unmatch", "--", j).returncode != 0:
        return "the journal is not a tracked file"
    status = git(repo, "status", "--porcelain")
    if status.returncode != 0 or status.stdout.strip():
        return "the tree is not clean (commit or restore your changes first)"
    with open(os.path.join(repo, j), "a", encoding="utf-8") as f:
        f.write(f"\n## {utc()} — ARCHITECT always-on {word}\n")
    c = git(repo, "commit", "-q", "-m", f"chore: always-on {word}", "--", j)
    if c.returncode != 0:
        git(repo, "checkout", "--", j)
        return "the commit failed"
    return None


# ---- sign ----------------------------------------------------------------------------

def sign_problems(repo):
    """What the repo lacks for a signature (step 2); [] when it may be signed."""
    probs = []
    top = git(repo, "rev-parse", "--show-toplevel")
    if top.returncode != 0 or os.path.realpath(top.stdout.strip()) != os.path.realpath(repo):
        return [f"{repo} is not the toplevel of a git checkout"]
    if (os.path.exists(os.path.join(repo, "scripts", "cw-supervisor.sh"))
            or os.path.realpath(repo) == os.path.realpath(sup.HOUSE)):
        return ["this is the house itself: house work stays in-session"]
    if not os.path.isdir(os.path.join(repo, ".git")):
        return ["a linked worktree (its .git is a file): sign the main checkout"]
    if git(repo, "cat-file", "-e", "HEAD:GOALS.md").returncode != 0:
        return ["GOALS.md is not committed at HEAD"]
    st = git(repo, "status", "--porcelain")
    if st.returncode != 0 or st.stdout.strip():
        probs.append("the tree is not clean")
    goals = os.path.join(repo, "GOALS.md")
    v = sup.run(["python3", sup.GOALS_PY, goals, "validate"], cwd=repo)
    if v.returncode != 0:
        probs.append("GOALS.md does not validate (goals.py GOALS.md validate)")
        return probs
    meta = sup.run(["python3", sup.GOALS_PY, goals, "meta"])
    try:
        m = json.loads(meta.stdout)
    except ValueError:
        return probs + ["GOALS.md's meta cannot be read"]
    journal, plan = m.get("journal") or "", m.get("plan") or ""
    jt = git(repo, "show", f"HEAD:{journal}") if journal else None
    jtext = jt.stdout if jt is not None and jt.returncode == 0 else ""
    if not re.search(r"^## \S+ — ARCHITECT decompose\b", jtext, re.M):
        probs.append(f"no committed `ARCHITECT decompose` record in {journal or 'the journal'}")
    override = re.search(r"^## \S+ — ARCHITECT oracle-review override\b", jtext, re.M)
    log = os.path.join(os.path.dirname(plan), "PLAN-REVIEW-LOG.md") if plan else ""
    lt = git(repo, "show", f"HEAD:{log}") if log else None
    ltext = lt.stdout if lt is not None and lt.returncode == 0 else ""
    rounds = re.split(r"^## Oracle round \d+\b.*$", ltext, flags=re.M)
    last = rounds[-1] if len(rounds) > 1 else ""
    # The round's own text, up to the next level-2 heading.
    last = re.split(r"^## ", last, maxsplit=1, flags=re.M)[0]
    verdicts = re.findall(r"^VERDICT: (\S+)\s*$", last, re.M)
    approved = bool(verdicts) and verdicts[-1] == "APPROVED"
    if not approved and not override:
        probs.append(f"no last oracle-review VERDICT: APPROVED in {log or 'PLAN-REVIEW-LOG.md'} "
                     "and no committed `ARCHITECT oracle-review override` record")
    return probs


def cmd_sign(args):
    if not args or len(args) > 2:
        die("usage: cw-decide.sh sign <repo> [jobs=N]", 2)
    repo = os.path.realpath(os.path.abspath(os.path.expanduser(args[0])))
    jobs = 2
    if len(args) == 2:
        m = re.fullmatch(r"jobs=([2-4])", args[1])
        if not m:
            die("jobs must be jobs=2, jobs=3 or jobs=4 (always-on walks in parallel mode)", 2)
        jobs = int(m.group(1))
    probs = sign_problems(repo)
    if probs:
        die("not signed:\n  - " + "\n  - ".join(probs))
    _lock = locked()
    head = git(repo, "rev-parse", "HEAD").stdout.strip()
    keep, replaced = [], []
    for line in queue_lines():
        try:
            e = json.loads(line)
        except ValueError:
            keep.append(line)
            continue
        if not isinstance(e, dict) or e.get("repo") != repo:
            keep.append(line)
            continue
        eid = sup.entry_id(line)
        st = sup.load_state(eid, e)
        if st is None:
            die(f"{repo} has an entry {eid[:12]} whose state cannot be read: look at "
                f"{sup.state_path(eid)} first (it may belong to a running walk)")
        if running(st) or st["status"] in ("queued", "waiting"):
            die(f"{repo} already has an entry {eid[:12]} that is {st['status'] if not running(st) else 'running'}; "
                "skip it first, or wait for it to end")
        replaced.append(eid)
    line = json.dumps({"repo": repo, "signed": head, "jobs": jobs})
    # The queue first: a turn between the two never sees an old line without
    # its state (it would take it for a new entry).
    write_queue(keep + [line])
    for eid in replaced:
        retire(eid)
    eid = sup.entry_id(line)
    print(f"signed {repo} at {head[:12]} (jobs={jobs}) as entry {eid[:12]}"
          + (f"; replaced {', '.join(x[:12] for x in replaced)}" if replaced else ""))


# ---- status, resume, skip ----------------------------------------------------------------

def spend_line():
    r = sup.run(["python3", sup.SPEND, "sum", sup.LEDGER])
    try:
        d = json.loads(r.stdout)
        return f"spend: ${d.get('day_usd', 0):.2f} in 24 h, ${d.get('week_usd', 0):.2f} in 7 days"
    except (ValueError, TypeError):
        return "spend: (the ledger cannot be read)"


def supervisor_alive():
    try:
        fd = os.open(os.path.join(sup.HOME, "supervisor.lock"), os.O_RDONLY)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    except BlockingIOError:
        return True
    finally:
        os.close(fd)


def cmd_status(args):
    if args == ["--json"]:
        rows = []
        for eid, e, st in entries():
            if st is None:
                continue
            h = st.get("hold") or None
            reason = h.get("reason") if h else None
            if reason and not re.fullmatch(r"[a-z0-9_-]{1,40}", reason):
                reason = "unlisted-reason"  # never free text to a push
            rows.append({"id": eid, "repo": os.path.basename(e["repo"]),
                         "status": "running" if running(st) else st["status"],
                         "hold": {"class": h.get("class"), "reason": reason, "utc": h.get("utc")}
                         if st["status"] == "held" and h else None})
        print(json.dumps(rows))
        return 0
    print(f"supervisor: {'running' if supervisor_alive() else 'not running'}"
          + ("; STOP present" if os.path.exists(sup.STOP) else ""))
    print(spend_line())
    rows = entries()
    if not rows:
        print("queue: empty")
    for eid, e, st in rows:
        if st is None:
            print(f"{eid[:12]}  {e['repo']}  (state unreadable)")
            continue
        state = "running" if running(st) else st["status"]
        h = st.get("hold") or {}
        hold = f"  held {h.get('class')} {h.get('reason')}" if state == "held" else ""
        wait = ""
        if state == "waiting" and st.get("wait_until"):
            wait = "  until " + time.strftime("%H:%M", time.localtime(st["wait_until"]))
        print(f"{eid[:12]}  {os.path.basename(e['repo'])}  {state}  attempt {st['attempt']}{hold}{wait}  ({e['repo']})")


def cmd_resume(args):
    if len(args) != 1:
        die("usage: cw-decide.sh resume <entry>", 2)
    _lock = locked()
    eid, e, st = find(args[0])
    if st is None or st["status"] != "held":
        die(f"{eid[:12]} is not held")
    if running(st):
        die(f"{eid[:12]} still has a running attempt: cw-decide.sh stop, wait for it to end, then resume")
    h = st.get("hold") or {}
    if h.get("reason") == "serial-goal-in-progress":
        die("a serial run of this walk is mid-goal; always-on walks only in parallel mode. Finish it with:\n"
            f"  cd {st['repo']} && {sup.RUN_GOALS}\nthen sign the repo again")
    why = sup.signature_problem(st)
    if why:
        die(f"the signed contract changed ({why}): sign the new HEAD (cw-decide.sh sign {st['repo']})")
    why = journal_record(st, "resume")
    if why:
        die(f"not resumed: {why}")
    st["status"] = "queued"
    st["hold"] = None
    st["acted_attempt"] = st["attempt"]
    try:
        sup.save_state(st)
    except OSError as e:
        die(f"the resume record is committed but the state could not be saved ({e}); fix that and resume again")
    print(f"resumed {eid[:12]}: the supervisor dispatches one rerun on its next turn")
    if h.get("reason") == "claude-version-changed":
        print("  claude changed under the supervisor: restart it so it records the new version, or it holds again:\n"
              f"  launchctl kickstart -k gui/{os.getuid()}/com.cw.always-on")


def cmd_skip(args):
    if len(args) != 1:
        die("usage: cw-decide.sh skip <entry>", 2)
    _lock = locked()
    eid, e, st = find(args[0])
    latest = [d for d in sup.latest_attempts() if os.path.basename(os.path.dirname(d)) == eid]
    if (st is not None and running(st)) or (st is None and any(attempt.state(d) == "running" for d in latest)):
        die(f"{eid[:12]} is running: cw-decide.sh stop first, and wait for it to end")
    if st is not None:
        why = journal_record(st, "skip")
        if why:
            die(f"not skipped: {why}")
    else:
        print(f"cw-decide: {eid[:12]}'s state cannot be read: skipped without a journal record")
    write_queue([l for l in queue_lines() if sup.entry_id(l) != eid])
    retire(eid)
    print(f"skipped {eid[:12]}: dropped from the queue (its state is in state/old/)")


# ---- stop, start --------------------------------------------------------------------------

def cmd_stop(_args):
    os.makedirs(sup.HOME, mode=0o700, exist_ok=True)
    with open(sup.STOP, "a"):
        pass
    print(f"STOP written ({sup.STOP}): running walks are signalled on the supervisor's next turn; nothing new starts")


def agent_loaded(label):
    r = sup.run([LAUNCHCTL, "print", f"gui/{os.getuid()}/{label}"], timeout=30)
    return r.returncode == 0


def cmd_start(_args):
    for label in LABELS:
        plist = os.path.join(LAUNCH_AGENTS, f"{label}.plist")
        if not os.path.exists(plist):
            die(f"{plist} is missing: run install.sh --always-on first")
    if os.path.exists(sup.STOP):
        os.unlink(sup.STOP)
        print("STOP removed")
    for label in LABELS:
        plist = os.path.join(LAUNCH_AGENTS, f"{label}.plist")
        if agent_loaded(label):
            print(f"{label}: already loaded")
            continue
        r = sup.run([LAUNCHCTL, "bootstrap", f"gui/{os.getuid()}", plist], timeout=30)
        if r.returncode != 0:
            die(f"{label}: launchctl bootstrap failed: {(r.stderr or r.stdout).strip()[:200]}")
        print(f"{label}: loaded")


# ---- doctor, heartbeat -------------------------------------------------------------------

def cmd_doctor(_args):
    fails = 0

    def line(ok, what):
        nonlocal fails
        fails += 0 if ok else 1
        print(f"{'OK  ' if ok else 'FAIL'}  {what}")

    for label in LABELS:
        line(agent_loaded(label), f"LaunchAgent {label} loaded")
    batt = sup.run(["pmset", "-g", "batt"], timeout=30).stdout
    line("AC Power" in batt, "on AC power")
    al = sup.run(["defaults", "read", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser"], timeout=30)
    line(al.returncode == 0 and al.stdout.strip() != "", "automatic login is on (the Mac comes back after a restart)")
    try:
        mode = os.stat(sup.KEY_FILE).st_mode & 0o777
        line(sup.key_present() and mode & 0o077 == 0, f"the API key file is present, not empty, 0600 ({sup.KEY_FILE})")
    except OSError:
        line(False, f"the API key file is present ({sup.KEY_FILE})")
    b = sup.run([sup.BALANCE], timeout=90)
    try:
        bal = float(sup.kv(b.stdout, "BALANCE_USD"))
    except (TypeError, ValueError):
        bal = None
    line(bal is not None and bal >= sup.BALANCE_FLOOR,
         f"the DeepSeek balance is readable and at least ${sup.BALANCE_FLOOR:.2f}"
         + (f" (${bal:.2f})" if bal is not None else ""))
    conf = os.path.join(sup.HOME, "notify.conf")
    try:
        has = bool(re.search(r"^recipient=\S+", open(conf, encoding="utf-8").read(), re.M))
    except OSError:
        has = False
    line(has, f"a recipient in {conf}")
    # The account itself, which also asks for Automation consent when it is missing.
    m = sup.run(["osascript", "-e", 'tell application "Messages" to get id of 1st account whose service type = iMessage'],
                timeout=60)
    line(m.returncode == 0 and m.stdout.strip() != "", "Messages has an iMessage account this user may script")
    gs = sup.run(["git", "config", "--get", "commit.gpgsign"], timeout=30, cwd=os.path.expanduser("~"))
    line(gs.stdout.strip().lower() != "true",
         "git commits need no signing prompt (commit.gpgsign is not true; step 0g)")
    v = sup.claude_version()
    line(v is not None, f"claude --version answers ({v})")
    print("doctor: all OK" if not fails else f"doctor: {fails} FAIL")
    return 1 if fails else 0


def cmd_heartbeat(_args):
    rows = entries()
    counts = {}
    for _eid, _e, st in rows:
        k = "running" if running(st) else (st["status"] if st else "unreadable")
        counts[k] = counts.get(k, 0) + 1
    states = ", ".join(f"{n} {k}" for k, n in sorted(counts.items())) or "queue empty"
    now = time.time()
    decisions = 0
    try:
        with open(sup.DECISIONS, encoding="utf-8") as f:
            for l in f:
                try:
                    ts = datetime.datetime.strptime(json.loads(l)["utc"], "%Y-%m-%dT%H:%M:%SZ").replace(
                        tzinfo=datetime.timezone.utc).timestamp()
                except (ValueError, KeyError, TypeError):
                    continue
                decisions += now - ts < 24 * 3600
    except OSError:
        pass
    live = [os.path.basename(os.path.dirname(d))[:12] for d in sup.latest_attempts() if attempt.state(d) == "running"]
    if supervisor_alive():
        extra = f"alive. {states}. {decisions} decisions in 24 h. {spend_line()}"
    else:
        extra = (f"the supervisor is NOT running: at the Mac, cw-decide.sh doctor. {states}. "
                 + (f"still running without it: {', '.join(live)}. " if live else "")
                 + spend_line())
    print(extra)
    r = sup.run([sup.NOTIFY, "heartbeat", "", "", "", "", extra], timeout=60)
    return 0 if r.returncode == 0 else 1


COMMANDS = {"status": cmd_status, "sign": cmd_sign, "resume": cmd_resume, "skip": cmd_skip,
            "stop": cmd_stop, "start": cmd_start, "doctor": cmd_doctor, "heartbeat": cmd_heartbeat}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        return 2
    return COMMANDS[argv[1]](argv[2:]) or 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
