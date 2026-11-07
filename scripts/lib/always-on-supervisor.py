#!/usr/bin/env python3
"""always-on-supervisor.py — the always-on supervisor's loop
(docs/features/always-on/PLAN.md steps 3-12). scripts/cw-supervisor.sh runs it
under the LaunchAgent; nothing here holds a Claude session.

  always-on-supervisor.py [--once]

One supervisor at a time (an exclusive flock on <home>/supervisor.lock, held
for its life; a second exits 75). Each turn (every 60 s; --once runs one):

1. The kill file <home>/STOP: every running attempt under attempts/ (queued
   or not: the world, not the queue) is signalled once, and the turn ends.
2. Every entry: a DECIDER line left pending is written first; then its current
   attempt n, unless acted on (acted_attempt == n), from the world
   (lib/always-on-attempt.py): running is left alone (adopted, polled);
   not-started is started again after the same checks as a dispatch (at most
   three starts, then interrupted); finished is acted on once; interrupted
   holds A. An exception on one entry holds it A supervisor-error and the turn
   goes on with the others.
3. A waiting entry whose wait_until has passed (wall clock) is queued again.
4. When no attempt is running anywhere (one walk at a time), the first queued
   entry is checked (the claude version, the key file, the signature of step
   3, the spend ceilings, the DeepSeek balance; STOP skips) and dispatched as
   attempt n+1, the number written to its state file first.

Acting on a finished attempt (step 5): the decider when the class calls for it
(answering into memory; STOP present when it returns defers everything), then
ONE state rename holding acted_attempt = n, the outcome and the DECIDER line
to write, and only then that line, the message or a dispatch. The
classes (lib/always-on-classify.py on the copy in result.json; a classifier
failure, a stop with no copy, or a copy it could not make is A):
  exit 0, no stop        done (a walk-end message)
  A / B                  held
  F only                 queued again, no count (a fourth in a row holds A)
  wait only              waiting until a reset time or 15/30/60 min by the
                         entry's rate-limit stops in 24 h (a fourth holds A)
  C / D                  each such goal's count (C at most 2, D at most 1; past
                         it the entry holds needs-human) is checked, then the
                         decider: rerun (counts up; waiting instead when a goal
                         also waits) or needs_human (held)

Files, under <home> (CW_AO_HOME, default ~/.config/cw-always-on): queue.jsonl,
STOP, supervisor.lock, state/<id>.json, state/old/, attempts/<id>/<n>/. Under
<cache> (CW_AO_CACHE, default ~/.cache/claude-coding-workflow/always-on):
spend.jsonl (the ledger), halt, decisions.jsonl, supervisor.log. Every state
write is a temporary file, fsync, rename. An entry's id is the sha256 of its
queue line.
"""
import datetime
import fcntl
import hashlib
import importlib.util
import json
import os
import random
import re
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
HOUSE = os.path.dirname(os.path.dirname(HERE))
HOME = os.path.expanduser(os.environ.get("CW_AO_HOME") or "~/.config/cw-always-on")
CACHE = os.path.expanduser(os.environ.get("CW_AO_CACHE") or "~/.cache/claude-coding-workflow/always-on")
QUEUE = os.path.join(HOME, "queue.jsonl")
STOP = os.path.join(HOME, "STOP")
STATE = os.path.join(HOME, "state")
ATTEMPTS = os.path.join(HOME, "attempts")
LEDGER = os.path.join(CACHE, "spend.jsonl")
DECISIONS = os.path.join(CACHE, "decisions.jsonl")
LOG = os.path.join(CACHE, "supervisor.log")
RUN_GOALS = os.environ.get("CW_AO_RUN_GOALS") or os.path.join(HOUSE, "scripts", "run-goals.sh")
DECIDE = os.environ.get("CW_AO_DECIDE") or os.path.join(HOUSE, "scripts", "claude-decide.sh")
NOTIFY = os.environ.get("CW_AO_NOTIFY") or os.path.join(HOUSE, "scripts", "lib", "notify.sh")
BALANCE = os.environ.get("CW_AO_BALANCE") or os.path.join(HOUSE, "scripts", "lib", "always-on-balance.sh")
BALANCE_FLOOR = float(os.environ.get("CW_AO_BALANCE_FLOOR") or 2)
KEY_FILE = os.path.expanduser(os.environ.get("CW_AO_KEY_FILE") or "~/.config/cw-secrets/anthropic-decider.key")
# The claude binary as the launchers resolve it (claude-decide.sh,
# claude-goal-review.sh): ~/.local/bin/claude first, then PATH.
CLAUDE_BIN = os.environ.get("CW_AO_CLAUDE") or (
    os.path.expanduser("~/.local/bin/claude") if os.access(os.path.expanduser("~/.local/bin/claude"), os.X_OK)
    else "claude")
SPEND = os.path.join(HERE, "always-on-spend.py")
CLASSIFY = os.path.join(HERE, "always-on-classify.py")
GOALS_PY = os.path.join(HOUSE, "scripts", "goals.py")
ORACLE_FILES = os.path.join(HERE, "oracle-files.py")
EVENTS_PY = os.path.join(HOUSE, "scripts", "events.py")
INTERVAL = int(os.environ.get("CW_AO_INTERVAL") or 60)  # seconds between turns
CAP_C, CAP_D, CAP_F, CAP_RATE, CAP_STARTS = 2, 1, 3, 3, 3
LADDER = (15 * 60, 30 * 60, 60 * 60)
DECIDER_STANDIN = 0.50
CLASSES = ("A", "B", "C", "D", "wait", "F")


def _load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


attempt = _load("always_on_attempt", "always-on-attempt.py")


# ---- small helpers -------------------------------------------------------------

def utc(ts=None):
    return datetime.datetime.fromtimestamp(ts if ts is not None else time.time(),
                                           datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg):
    """Best effort: a log that cannot be written must never stop a hold."""
    try:
        os.makedirs(CACHE, exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{utc()} {msg}\n")
    except (OSError, ValueError):
        pass


def run(cmd, **kw):
    kw.setdefault("capture_output", True)
    kw.setdefault("text", True)
    kw.setdefault("timeout", 120)
    if "input" not in kw:
        kw.setdefault("stdin", subprocess.DEVNULL)  # never the caller's stdin
    try:
        return subprocess.run(cmd, **kw)
    except (OSError, subprocess.SubprocessError) as e:
        return subprocess.CompletedProcess(cmd, 127, "", repr(e))


def kv(text, key):
    val = None
    for line in (text or "").splitlines():
        if line.startswith(key + ": "):
            val = line[len(key) + 2:].strip()
    return val


def entry_id(line):
    return hashlib.sha256(line.encode("utf-8")).hexdigest()


# ---- the queue and the state ---------------------------------------------------

def load_queue():
    """The queue's entries in order: (id, entry); a malformed line is logged and
    skipped, and so is a second line for a repo (one entry per repo)."""
    try:
        with open(QUEUE, encoding="utf-8") as f:
            lines = [l.rstrip("\n") for l in f if l.strip()]
    except OSError:
        return []
    out, repos = [], set()
    for line in lines:
        try:
            e = json.loads(line)
            ok = (isinstance(e, dict) and isinstance(e.get("repo"), str) and os.path.isabs(e["repo"])
                  and isinstance(e.get("signed"), str) and re.fullmatch(r"[0-9a-f]{40}", e["signed"])
                  and isinstance(e.get("jobs"), int) and 2 <= e["jobs"] <= 4)
        except ValueError:
            ok = False
        if not ok:
            log(f"queue: malformed line skipped: {line[:200]!r}")
            continue
        if e["repo"] in repos:
            log(f"queue: a second entry for {e['repo']} skipped")
            continue
        repos.add(e["repo"])
        out.append((entry_id(line), e))
    return out


def state_path(eid):
    return os.path.join(STATE, f"{eid}.json")


def load_state(eid, e):
    """The entry's state; a new entry starts queued. None when the file exists
    but cannot be read (the entry is then left alone and reported)."""
    p = state_path(eid)
    if not os.path.exists(p):
        return {"id": eid, "repo": e["repo"], "signed": e["signed"], "jobs": e["jobs"],
                "status": "queued", "attempt": 0, "acted_attempt": 0,
                "counts": {"C": {}, "D": {}}, "f_only": 0, "rate_stops": [],
                "wait_until": None, "hold": None}
    d = attempt.read_json(p)
    if d is None or d.get("id") != eid:
        return None
    return d


def save_state(st):
    os.makedirs(STATE, exist_ok=True)
    st["updated"] = utc()
    attempt.write_atomic(state_path(st["id"]), json.dumps(st, sort_keys=True) + "\n")


def attempt_dir(st, n=None):
    return os.path.join(ATTEMPTS, st["id"], str(n if n is not None else st["attempt"]))


def notify(kind, st, cls="", reason="", extra=""):
    """A message of fixed fields only (step 13): never stop text or findings."""
    # Only a reason code reaches a message: a stop's reason line is free text.
    if not re.fullmatch(r"[a-z0-9_-]{1,40}", reason or ""):
        reason = "unlisted-reason" if reason else ""
    fields = [kind, os.path.basename(st["repo"]), st["id"][:12], cls, reason, extra]
    if not os.access(NOTIFY, os.X_OK):
        log(f"notify (no notifier): {' | '.join(fields)}")
        return
    r = run([NOTIFY] + fields, timeout=60)
    if r.returncode != 0:
        log(f"notify failed rc={r.returncode}: {' | '.join(fields)}")


def hold(st, cls, reason, why=""):
    """Hold the entry. The reason kept is a code: a stop's reason line is free
    text, so anything else is stored as unlisted-reason (its first 80
    characters, cleaned, go to why, which no message carries)."""
    if reason and not re.fullmatch(r"[a-z0-9_-]{1,40}", reason):
        why = (re.sub(r"[^A-Za-z0-9 ._:/,=-]", "", reason)[:80] + "; " + why).strip("; ")
        reason = "unlisted-reason"
    st["status"] = "held"
    st["hold"] = {"class": cls, "reason": reason, "why": why[:300], "utc": utc()}


# ---- the signature (step 3) -----------------------------------------------------

def git(repo, *args, timeout=60):
    return run(["git", "-C", repo] + list(args), timeout=timeout,
               env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})


def signature_problem(st):
    """Why the repo no longer matches its signature, or None."""
    repo, sha = st["repo"], st["signed"]
    if not os.path.isdir(os.path.join(repo, ".git")):
        return f"{repo} is not a git checkout"
    if git(repo, "merge-base", "--is-ancestor", sha, "HEAD").returncode != 0:
        return f"the signed {sha[:12]} is not an ancestor of HEAD"
    signed_goals = git(repo, "show", f"{sha}:GOALS.md")
    if signed_goals.returncode != 0:
        return "GOALS.md is missing at the signed commit"
    tmp = os.path.join(attempt_dir(st, "sig"), "GOALS.signed.md")
    os.makedirs(os.path.dirname(tmp), exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(signed_goals.stdout)
    meta = run(["python3", GOALS_PY, tmp, "meta"])
    try:
        plan = json.loads(meta.stdout).get("plan") or ""
    except ValueError:
        return "the signed GOALS.md does not parse"
    oracles = run(["python3", ORACLE_FILES, tmp], cwd=repo)
    if oracles.returncode != 0:
        return "the signed GOALS.md's oracle files cannot be listed"
    paths = [p for p in [plan] + oracles.stdout.split() if p] + ["tests/acceptance", "tests/e2e"]
    if git(repo, "diff", "--quiet", sha, "HEAD", "--", *paths).returncode != 0:
        return "the plan, an oracle, tests/acceptance or tests/e2e changed since the signature"
    head = git(repo, "show", "HEAD:GOALS.md")
    if head.returncode != 0:
        return "GOALS.md is missing at HEAD"
    head_goals = os.path.join(os.path.dirname(tmp), "GOALS.head.md")
    with open(head_goals, "w", encoding="utf-8") as f:
        f.write(head.stdout)
    tr = run(["python3", GOALS_PY, head_goals, "status-transitions", tmp, "*=*:*"])
    if tr.returncode != 0:
        return "GOALS.md changed since the signature beyond status moves"
    return None


# ---- spend and money ----------------------------------------------------------------

def spend_check(eid):
    """None when under every ceiling, else the reason (step 9)."""
    os.makedirs(CACHE, exist_ok=True)
    r = run(["python3", SPEND, "check", LEDGER, eid, "--stop", STOP])
    if r.returncode == 0:
        return None
    return {3: "over a spend ceiling", 4: "the kill file"}.get(r.returncode, f"the spend ledger cannot be read (exit {r.returncode})")


def balance_problem():
    r = run([BALANCE], timeout=90)
    amount = kv(r.stdout, "BALANCE_USD")
    try:
        usd = float(amount)
    except (TypeError, ValueError):
        return "the DeepSeek balance cannot be read"
    return None if usd >= BALANCE_FLOOR else f"the DeepSeek balance {usd:.2f} is under {BALANCE_FLOOR:.2f}"


def observe(eid, kind, sid, cost):
    run(["python3", SPEND, "observe", LEDGER, eid, kind, sid, str(cost)])


def bump(eid, kind, sid, delta):
    run(["python3", SPEND, "bump", LEDGER, eid, kind, sid, str(delta)])


# ---- dispatch ---------------------------------------------------------------------

def claude_version():
    r = run([CLAUDE_BIN, "--version"], timeout=60)
    return r.stdout.strip() if r.returncode == 0 else None


def walker_env(st):
    """The walker's environment: no CW_* but the always-on switches, no
    credential but the API key from its file (step 6)."""
    drop = re.compile(r"^(CW_|ANTHROPIC_|CLAUDE_|DEEPSEEK_|OPENAI_|XAI_|GROK_|GH_|GITHUB_|AWS_)|(_API_KEY|_TOKEN|_SECRET)$")
    env = {k: v for k, v in os.environ.items() if not drop.search(k)}
    with open(KEY_FILE, encoding="utf-8") as f:
        env["ANTHROPIC_API_KEY"] = f.readline().strip()
    env["CW_ALWAYS_ON_LEDGER"] = LEDGER
    env["CW_ALWAYS_ON_ENTRY"] = st["id"]
    env["CW_ALWAYS_ON_STOP"] = STOP
    env["DISABLE_UPDATES"] = env["DISABLE_AUTOUPDATER"] = "1"
    env["GIT_TERMINAL_PROMPT"] = "0"
    return env


def key_present():
    try:
        with open(KEY_FILE, encoding="utf-8") as f:
            return bool(f.readline().strip())
    except OSError:
        return False


def checks(st, version):
    """Every check before a walk starts, a first start or a restart alike
    (step 3: every dispatch and rerun re-checks the entry). True when it may
    start; False when held; None when STOP appeared (skip, nothing held)."""
    if os.path.exists(STOP):
        return None
    now_version = claude_version()
    if version is None or now_version != version:
        hold(st, "A", "claude-version-changed", f"{version} -> {now_version}")
        return False
    if not key_present():
        # An empty key would bill the subscription login instead (step 0b).
        hold(st, "A", "always-on-config", "the API key file is missing or empty")
        return False
    why = signature_problem(st)
    if why:
        hold(st, "A", "contract-drift", why)
        return False
    why = spend_check(st["id"])
    if why == "the kill file":
        return None
    if why:
        hold(st, "A", "budget", why)
        return False
    why = balance_problem()
    if why:
        hold(st, "A", "budget", why)
        return False
    return True


def dispatch(st, version):
    """Check the entry and start attempt n+1, or hold it. True when started,
    False when held, None when skipped (STOP)."""
    ok = checks(st, version)
    if not ok:
        return ok
    n = st["attempt"] + 1
    if os.path.exists(attempt_dir(st, n)):
        hold(st, "A", "always-on-config", f"attempt folder {n} already exists")
        return False
    st["attempt"] = n
    st["status"] = "queued"
    st["starts"] = 1
    save_state(st)  # the number first: a crash after this never reuses it
    start_attempt(st)
    log(f"dispatch {st['id'][:12]} attempt {n} in {st['repo']}")
    return True


def start_attempt(st):
    """Start the wrapper for the entry's current attempt (again, when it never
    started: the wrapper's lock and walker record refuse a second walker)."""
    d = attempt_dir(st)
    try:
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "wrapper.log"), "ab") as out:
            subprocess.Popen(
                ["python3", os.path.join(HERE, "always-on-attempt.py"), "run", d, "--",
                 RUN_GOALS, "--jobs", str(st["jobs"])],
                cwd=st["repo"], env=walker_env(st), stdin=subprocess.DEVNULL,
                stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
    except OSError as e:  # counted as a start: the next turn sees not-started
        log(f"start of {st['id'][:12]} attempt {st['attempt']} failed: {e!r}")


# ---- acting on a result -------------------------------------------------------------

def classify(path):
    r = run(["python3", CLASSIFY, path])
    try:
        d = json.loads(r.stdout)
    except ValueError:
        d = None
    if r.returncode != 0 or not isinstance(d, dict) or d.get("class") not in CLASSES \
            or not isinstance(d.get("goals"), list):
        return {"class": "A", "reason": "classify-error", "goals": []}
    return d


RETRY_AFTER = re.compile(r"retry-after:?\s*(\d{1,6})\b", re.I)
MAX_WAIT = 24 * 3600  # a longer named wait is not trusted: the ladder instead
RESETS = re.compile(r"resets\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b", re.I)


def reset_time(goal_files, now):
    """A reset time named in a waiting goal's stop or its copied LOG/stderr, or None."""
    for f in goal_files:
        texts = []
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                stop = fh.read(1 << 20)
        except OSError:
            continue
        texts.append(stop)
        for m in re.finditer(r"^- (?:LOG|stderr): ?(.+)$", stop, re.M):
            try:
                with open(m.group(1).strip(), encoding="utf-8", errors="replace") as fh:
                    texts.append(fh.read(1 << 20))
            except OSError:
                pass
        for text in texts:
            m = RETRY_AFTER.search(text)
            if m and int(m.group(1)) <= MAX_WAIT:
                return now + int(m.group(1))
            m = RESETS.search(text)
            if m and 1 <= int(m.group(1)) <= 12 and int(m.group(2) or 0) <= 59:
                hour = int(m.group(1)) % 12 + (12 if m.group(3).lower() == "pm" else 0)
                local = datetime.datetime.fromtimestamp(now).replace(
                    hour=hour, minute=int(m.group(2) or 0), second=0, microsecond=0)
                ts = local.timestamp()
                return ts if ts > now else ts + 24 * 3600
    return None


def wait_outcome(st, goal_files, now):
    """Waiting until a reset time or the ladder; held A after CAP_RATE in 24 h."""
    recent = [t for t in st.get("rate_stops", []) if now - t < 24 * 3600]
    if len(recent) >= CAP_RATE:
        hold(st, "A", "rate-limit-repeated", f"{len(recent) + 1} rate-limit stops in 24 h")
        return
    until = reset_time(goal_files, now)
    if until is None:
        until = now + LADDER[len(recent)]
    st["rate_stops"] = recent + [now]
    st["wait_until"] = until + random.randint(60, 120)
    st["status"] = "waiting"


def packet(st, cls, n):
    """The decider's packet: fixed fields, and the journal tail as quoted untrusted data."""
    stops = [{"goal": g["goal"], "class": g["class"], "reason": g["reason"],
              "counts": {"C": st["counts"]["C"].get(g["goal"], 0), "D": st["counts"]["D"].get(g["goal"], 0)}}
             for g in cls["goals"]]
    tail = ""
    j = journal_path(st)
    if j:
        try:
            with open(os.path.join(st["repo"], j), encoding="utf-8", errors="replace") as f:
                tail = "".join(f.readlines()[-40:])[-6000:]
        except OSError:
            tail = ""
    graph = run(["python3", GOALS_PY, os.path.join(st["repo"], "GOALS.md"), "graph"])
    statuses = [l.split()[1] for l in graph.stdout.splitlines() if len(l.split()) >= 2]
    return {"entry": st["id"][:12], "attempt": n, "stops": stops,
            "goals_done": statuses.count("done"), "goals_total": len(statuses),
            "journal_tail": "<untrusted>" + strip_tags(tail) + "</untrusted>"}


def strip_tags(text):
    """No spelling of the untrusted tags survives, nested ones included
    (<unt<untrusted>rusted> becomes nothing, not <untrusted>)."""
    while True:
        out = re.sub(r"<\s*/?\s*untrusted\s*>", "", text, flags=re.I)
        if out == text:
            return out
        text = out


def decide(st, cls, n):
    """The decider's action ('rerun' or 'needs_human') and its record."""
    pk = json.dumps(packet(st, cls, n), sort_keys=True)
    r = run([DECIDE], input=pk, timeout=900)
    action = kv(r.stdout, "DECIDER_ACTION")
    if r.returncode != 0 or action not in ("rerun", "needs_human"):
        action = "needs_human"
    sid = kv(r.stdout, "DECIDER_SESSION") or "-"
    cost = kv(r.stdout, "DECIDER_COST_USD") or ""
    result = kv(r.stdout, "DECIDER_RESULT") or ""
    try:
        observe(st["id"], "decider", sid if sid != "-" else f"decider:{st['id'][:12]}:{n}", float(cost))
        spent = float(cost)
    except ValueError:
        spent = None
        # A call that ran and reported nothing (a timeout, no envelope), or a
        # launcher that died: the stand-in. Not when it never called the model.
        if result == "timeout" or result.startswith("error (exit") or r.returncode != 0:
            bump(st["id"], "stand-in", f"killed:decider:{st['id'][:12]}:{n}", DECIDER_STANDIN)
    rec = {"utc": utc(), "entry": st["id"], "attempt": n, "action": action,
           "result": result or f"exit {r.returncode}",
           "reason": kv(r.stdout, "DECIDER_REASON") or "", "session": sid, "cost_usd": spent,
           "packet_sha256": hashlib.sha256(pk.encode()).hexdigest()}
    os.makedirs(CACHE, exist_ok=True)
    with open(DECISIONS, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")
    return action, spent


def journal_path(st):
    r = run(["python3", GOALS_PY, os.path.join(st["repo"], "GOALS.md"), "meta"])
    try:
        return json.loads(r.stdout).get("journal") or None
    except ValueError:
        return None


def journal_decider(st, action, spent):
    """The one fixed-shape DECIDER line, committed alone on a clean tree (step 12);
    None, or why it could not be (any failure: the entry then holds A)."""
    try:
        repo, j = st["repo"], journal_path(st)
        if not j or os.path.isabs(j) or ".." in j.split("/"):
            return "the journal path cannot be read, or is outside the repo"
        if git(repo, "ls-files", "--error-unmatch", "--", j).returncode != 0:
            return "the journal is not a tracked file"
        status = git(repo, "status", "--porcelain")
        if status.returncode != 0:
            return "git status failed"
        if status.stdout.strip():
            return "the tree is not clean"
        path = os.path.join(repo, j)
        with open(path, "a", encoding="utf-8") as f:
            f.write(f"\n## {utc()} — DECIDER {action}\n")
        c = git(repo, "commit", "-q", "-m", f"chore: always-on decider {action}", "--", j)
        if c.returncode != 0:
            git(repo, "checkout", "--", j)
            return "the commit failed"
        run(["python3", EVENTS_PY, "append", path, "--event", "decision", "--severity", "info",
             "--summary", f"decider {action}", "--reason", action,
             "--payload", json.dumps({"action": action, "cost_usd": spent})], cwd=repo)
        return None
    except Exception as e:  # noqa: BLE001
        return f"the journal line failed: {e!r}"[:200]


class Deferred(Exception):
    """STOP appeared while the decider ran: nothing is written; the next turn
    after STOP acts on the attempt again from the start."""


def digest(st):
    """The walk-end digest (step 13), fixed fields only: goals done, the
    entry's decisions with one in five marked for a spot check, its spend."""
    graph = run(["python3", GOALS_PY, os.path.join(st["repo"], "GOALS.md"), "graph"])
    statuses = [l.split()[1] for l in graph.stdout.splitlines() if len(l.split()) >= 2]
    times = []
    try:
        with open(DECISIONS, encoding="utf-8") as f:
            for line in f:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if isinstance(d, dict) and d.get("entry") == st["id"]:
                    times.append(str(d.get("utc", "")))
    except OSError:
        pass
    k = len(times)
    spot = sorted(random.sample(range(1, k + 1), (k + 4) // 5)) if k else []
    s = run(["python3", SPEND, "sum", LEDGER, st["id"]])
    try:
        spent = f"${json.loads(s.stdout)['entry_usd']:.2f}"
    except (ValueError, KeyError, TypeError):
        spent = "unknown"
    return (f"spend {spent}, goals {statuses.count('done')}/{len(statuses)}, decisions {k}"
            + (f" (spot check #{', #'.join(map(str, spot))} in decisions.jsonl)" if spot else ""))


def act(st, n, rs, notes):
    """Act once on attempt n (finished or interrupted): the outcome in st, and
    acted_attempt = n; the caller saves both in one rename. A decided action is
    kept as pending_journal in the same rename, so its line is never lost."""
    now = time.time()
    if rs == "interrupted":
        hold(st, "A", "interrupted", f"attempt {n} ended with no result")
    else:
        res = attempt.read_json(os.path.join(attempt_dir(st, n), "result.json")) or {}
        if res.get("walked") is not True:
            hold(st, "A", "attempt-not-walked", res.get("why") or "the walker never started")
        elif res.get("exit") == 0 and not res.get("stop_file"):
            st["status"] = "done"
            st["hold"] = None
            notes.append(("done", "", "walk-end", digest(st)))
        elif not res.get("stop_file"):
            hold(st, "A", "no-stop-file", f"exit {res.get('exit')} with no STOP_FILE line")
        elif not res.get("stop"):
            hold(st, "A", "stop-unreadable", "the stop file could not be copied")
        elif any(e.get("why") != "missing" for e in res.get("copy_errors") or []):
            hold(st, "A", "stop-copy-incomplete", "a file the stop names could not be copied")
        else:
            cls = classify(os.path.join(attempt_dir(st, n), res["stop"]))
            c = cls["class"]
            goals = cls["goals"]
            waits = [g["file"] for g in goals if g["class"] == "wait" and g.get("file")]
            if c in ("A", "B"):
                hold(st, c, cls.get("reason") or "")
            elif c == "F":
                st["f_only"] = st.get("f_only", 0) + 1
                if st["f_only"] > CAP_F:
                    hold(st, "A", "finished-not-integrated-repeated", f"{st['f_only']} stops in a row")
                else:
                    st["status"] = "queued"
            elif c == "wait":
                wait_outcome(st, waits, now)
            else:  # C or D
                over = [g["goal"] for g in goals
                        if (g["class"] == "C" and st["counts"]["C"].get(g["goal"], 0) >= CAP_C)
                        or (g["class"] == "D" and st["counts"]["D"].get(g["goal"], 0) >= CAP_D)]
                if over:
                    hold(st, "needs-human", "count-cap", "past its count: " + ",".join(over))
                else:
                    action, spent = decide(st, cls, n)
                    # Step 11: STOP is read again when it returns; a TERM to the
                    # supervisor meanwhile (a restart) defers the same way.
                    if os.path.exists(STOP) or STOPPING:
                        raise Deferred()
                    st["pending_journal"] = {"action": action, "cost_usd": spent}
                    if action != "rerun":
                        hold(st, "needs-human", "decider", "the decider answered needs_human")
                    else:
                        for g in goals:
                            if g["class"] in ("C", "D"):
                                st["counts"][g["class"]][g["goal"]] = st["counts"][g["class"]].get(g["goal"], 0) + 1
                        st["f_only"] = 0
                        if any(g["class"] == "wait" for g in goals):
                            wait_outcome(st, waits, now)
                        else:
                            st["status"] = "queued"
    if st["status"] == "held":
        notes.append(("held", st["hold"]["class"], st["hold"]["reason"]))
    st["acted_attempt"] = n


def write_pending_journal(st, notes):
    """The DECIDER line a decision left pending (same rename as the decision);
    a failure holds A commit-failed. Cleared, and saved, either way."""
    p = st.get("pending_journal")
    if not p:
        return
    why = journal_decider(st, p["action"], p.get("cost_usd"))
    st["pending_journal"] = None
    if why:
        hold(st, "A", "commit-failed", why)
        notes.append(("held", "A", "commit-failed"))
    save_state(st)


def latest_attempts():
    """Every entry's latest attempt folder under attempts/, queued or not: what
    runs, and what STOP reaches, is read from the world, not from the queue
    (an edited or unreadable queue line must not hide a live walk)."""
    out = []
    try:
        ids = os.listdir(ATTEMPTS)
    except OSError:
        return out
    for eid in ids:
        try:
            ns = [int(x) for x in os.listdir(os.path.join(ATTEMPTS, eid)) if x.isdigit()]
        except OSError:
            continue
        if ns:
            out.append(os.path.join(ATTEMPTS, eid, str(max(ns))))
    return out


UNSAVED = set()  # entries whose supervisor-error hold could not be saved
STOPPING = []  # a TERM arrived (main's handler): treated as STOP after a decider call


def entry_error(st, e, notes):
    """A deterministic failure on one entry must not wedge the loop: log it,
    hold the entry A supervisor-error, and go on with the others. The hold is
    put on the last SAVED state, not the half-built one (counts raised for a
    rerun that never happened stay unraised), and sticks: its attempt is marked
    acted on and any DECIDER line still pending is dropped (the decision is in
    decisions.jsonl), so the next turn neither redoes the work nor messages again."""
    saved = attempt.read_json(state_path(st["id"]))
    if saved and saved.get("id") == st["id"]:
        st.clear()
        st.update(saved)
    hold(st, "A", "supervisor-error", repr(e)[:200])
    st["acted_attempt"] = st["attempt"]
    st["pending_journal"] = None
    # The messages match the saved state: an outcome thrown away is not sent.
    notes[:] = [("held", "A", "supervisor-error")]
    try:
        save_state(st)
    except Exception as e2:  # noqa: BLE001
        # The hold cannot stick on disk: this process leaves the entry alone
        # for its life (no paid decider call, no message, every minute); the
        # message says so, as a supervisor restart acts on it again.
        UNSAVED.add(st["id"])
        notes[:] = [("held", "A", "supervisor-error-unsaved")]
        log(f"entry {st['id'][:12]}: its state could not be saved: {e2!r}")
    log(f"entry {st['id'][:12]} failed: {e!r}")


# ---- the turn -------------------------------------------------------------------

def turn_lock(timeout=None):
    """An exclusive flock on <home>/turn.lock: held by the supervisor for each
    turn and by cw-decide.sh's sign, resume and skip, so neither changes the
    queue or a state file under the other. timeout None waits; a number gives
    up after that many seconds (returns None)."""
    os.makedirs(HOME, exist_ok=True)
    fd = os.open(os.path.join(HOME, "turn.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    end = None if timeout is None else time.time() + timeout
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | (0 if end is None else fcntl.LOCK_NB))
            return fd
        except BlockingIOError:
            if time.time() >= end:
                os.close(fd)
                return None
            time.sleep(0.5)


def turn(version):
    fd = turn_lock()
    try:
        _turn(version)
    finally:
        os.close(fd)


def _turn(version):
    if os.path.exists(STOP):
        for d in latest_attempts():
            if attempt.state(d) == "running":
                r = attempt.stop(d)
                if r == "signalled":
                    log(f"STOP: signalled {d}")
        return
    running = any(attempt.state(d) == "running" for d in latest_attempts())
    states = []
    for eid, e in load_queue():
        if eid in UNSAVED:
            continue
        st = load_state(eid, e)
        if st is None:
            log(f"state of {eid[:12]} cannot be read; left alone")
            continue
        notes = []
        try:
            write_pending_journal(st, notes)
            n = st["attempt"]
            if n and st["acted_attempt"] != n:
                rs = attempt.state(attempt_dir(st))
                if rs == "not-started":
                    # No walker can have run (a crash between the number and
                    # the start, or a restart before the wrapper locked): start
                    # it again after the same checks as any start, at most
                    # CAP_STARTS times.
                    if st.get("starts", 0) >= CAP_STARTS:
                        rs = "interrupted"
                    elif not running:
                        ok = checks(st, version)
                        if ok:
                            st["starts"] = st.get("starts", 0) + 1
                            save_state(st)
                            start_attempt(st)
                            log(f"restart {eid[:12]} attempt {n} (start {st['starts']})")
                            running = True
                        elif ok is False:
                            st["acted_attempt"] = n
                            save_state(st)
                            notes.append(("held", st["hold"]["class"], st["hold"]["reason"]))
                        states.append(st)
                        continue
                    else:
                        states.append(st)
                        continue
                if rs == "running":
                    states.append(st)
                    continue
                if rs in ("finished", "interrupted"):
                    try:
                        act(st, n, rs, notes)
                    except Deferred:
                        log(f"STOP during the decider for {eid[:12]}: deferred")
                        return
                    save_state(st)  # acted_attempt, the outcome, any pending line: one rename
                    write_pending_journal(st, notes)
        except Exception as ex:  # noqa: BLE001
            entry_error(st, ex, notes)
        finally:
            for note in notes:
                notify(note[0], st, note[1], note[2], note[3] if len(note) > 3 else f"attempt {st['attempt']}")
        states.append(st)
    now = time.time()
    for st in states:
        if st["status"] == "waiting" and st.get("wait_until") is not None and st["wait_until"] <= now:
            st["status"] = "queued"
            st["wait_until"] = None
            save_state(st)
    if running or any(attempt.state(d) == "running" for d in latest_attempts()):
        return
    # One entry per repo (load_queue), one walk at a time: the first queued entry.
    for st in states:
        if st["status"] != "queued" or (st["attempt"] and st["acted_attempt"] != st["attempt"]):
            continue
        try:
            started = dispatch(st, version)
        except Exception as ex:  # noqa: BLE001
            notes = []
            entry_error(st, ex, notes)
            for kind, cls, reason in notes:
                notify(kind, st, cls, reason, "before dispatch")
            if any(attempt.state(d) == "running" for d in latest_attempts()):
                return  # it failed after its walk started: never a second beside it
            continue
        if started is False:
            save_state(st)
            notify("held", st, st["hold"]["class"], st["hold"]["reason"], "before dispatch")
            continue
        return


def main(argv):
    once = "--once" in argv[1:]
    os.makedirs(HOME, exist_ok=True)
    os.makedirs(CACHE, exist_ok=True)
    lock = os.open(os.path.join(HOME, "supervisor.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        # Under KeepAlive an exit is a relaunch 10 s later: in loop mode wait a
        # turn for the other supervisor (one finishing after a restart) first.
        got = False
        for _ in range(0 if once else INTERVAL):
            time.sleep(1)
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                got = True
                break
            except BlockingIOError:
                continue
        if not got:
            print("always-on-supervisor: another supervisor holds the lock", file=sys.stderr)
            return 75
    os.ftruncate(lock, 0)
    os.write(lock, f"{os.getpid()}\n".encode())
    version = claude_version()
    log(f"supervisor {os.getpid()} up; claude {version}")
    stopping = STOPPING
    signal.signal(signal.SIGTERM, lambda *_: stopping.append(1))
    while True:
        try:
            turn(version)
        except Exception as e:  # noqa: BLE001 — one bad turn must not end the loop
            log(f"turn failed: {e!r}")
            if once:
                raise
        if once or stopping:
            return 0
        for _ in range(INTERVAL):
            if stopping:
                return 0
            time.sleep(1)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
