#!/usr/bin/env python3
"""always-on-classify.py STOP_FILE [--table TSV] — classify a walker stop for
the always-on supervisor (docs/features/always-on/PLAN.md steps 7, 7a).

Prints one JSON object:
  {"stop": path, "kind": "single"|"wave", "class": A|B|C|D|wait|F,
   "reason": the deciding reason, "hold": true for A or B,
   "goals": [{"goal", "reason", "class", "billing": null or why, "file"}]}

A single stop (`# Stop: <goal>` or `# Stop: walk`) gives one reason from its
`- reason:` line. A wave-stop gives one per `- <goal>: <reason> — <file>`
bullet under `## Stopped`; nothing else in it is read. Each reason is looked
up in always-on-classes.tsv; one not there, or empty, is A. Before the table,
the billing scan: an error envelope on a stop's `LOG:` line with
api_error_status 401/402/403, or a text marker on its `- detail:` line, in its
`stderr:` file, or in an error envelope on `LOG:` (never a successful result,
which may quote anything), makes that goal A `budget`. The class of the stop
is its worst goal's: A, B, D, C, wait, F. An unreadable stop file is A, and so
is any failure here (a `classify-error` object, exit 0); a usage error exits 2.
"""
import json
import os
import re
import sys
from fnmatch import fnmatchcase

HERE = os.path.dirname(os.path.abspath(__file__))
TABLE = os.path.join(HERE, "always-on-classes.tsv")
ORDER = ["A", "B", "D", "C", "wait", "F"]
MARKERS = (
    "credits_required", "requires usage credits", "spend limit", "spend_limit",
    "billing_error", "insufficient balance", "enforced_spend_limit_reached",
    "http 402", "status 402", "invalid api key",
)
STATUSES = {401, 402, 403}
CAP = 8 << 20  # bytes read from one named file


def load_table(path):
    exact, patterns = {}, []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            reason, cls = line.split("\t")
            if cls not in ORDER:
                raise ValueError(f"{path}: unknown class {cls!r} for {reason!r}")
            if reason in exact or any(reason == p for p, _ in patterns):
                raise ValueError(f"{path}: {reason!r} listed twice")
            (patterns.append((reason, cls)) if "*" in reason else exact.__setitem__(reason, cls))
    return exact, patterns


def class_of(reason, table):
    exact, patterns = table
    if not reason:
        return "A"
    if reason in exact:
        return exact[reason]
    for pat, cls in patterns:
        if fnmatchcase(reason, pat):
            return cls
    return "A"


def read_text(path):
    """A regular file's text (its first CAP bytes), or None: a FIFO or a device
    named in free text must not block the supervisor's turn."""
    try:
        if not os.path.isfile(path):
            return None
        with open(path, "rb") as f:
            return f.read(CAP).decode("utf-8", "replace")
    except (OSError, ValueError):
        return None


def marker_in(text):
    low = text.lower()
    for m in MARKERS:
        if m in low:
            return m
    return None


def envelopes(text):
    """The JSON objects in a raw output: the whole file, else each {...} line."""
    try:
        d = json.loads(text)
        if isinstance(d, list):  # --output-format json --verbose: an array
            return [x for x in d if isinstance(x, dict)]
        return [d] if isinstance(d, dict) else []
    except ValueError:
        pass
    out = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if isinstance(d, dict):
                out.append(d)
    return out


def status_of(d):
    s = d.get("api_error_status")
    try:
        return int(s)
    except (TypeError, ValueError):
        return None


def named(stop_text, key, base):
    """The paths on a stop file's `- KEY:` lines (relative ones from its folder)."""
    out = []
    for m in re.finditer(r"^- " + re.escape(key) + r": ?(.*)$", stop_text, re.M):
        p = m.group(1).strip()
        if p:
            out.append(p if os.path.isabs(p) else os.path.join(base, p))
    return out


def billing(stop_path):
    """Why this stop file is a billing stop, or None."""
    text = read_text(stop_path) if stop_path else None
    if text is None:
        return None
    base = os.path.dirname(stop_path)
    for m in re.finditer(r"^- detail: ?(.*)$", text, re.M):
        hit = marker_in(m.group(1))
        if hit:
            return f"detail: {hit}"
    for p in named(text, "LOG", base):
        raw = read_text(p)
        if raw is None:
            continue
        errs = [d for d in envelopes(raw) if d.get("is_error") is True or d.get("api_error_status") is not None]
        if not errs:
            continue
        for d in errs:
            s = status_of(d)
            if s in STATUSES:
                return f"LOG: api_error_status {s}"
        # Only the error envelopes, and not the tool inputs the model wrote
        # (permission_denials): a successful result may quote anything.
        hit = marker_in(" ".join(json.dumps({k: v for k, v in d.items() if k != "permission_denials"})
                                 for d in errs))
        if hit:
            return f"LOG: {hit}"
    for p in named(text, "stderr", base):
        raw = read_text(p)
        hit = marker_in(raw) if raw else None
        if hit:
            return f"stderr: {hit}"
    return None


def reason_line(text):
    m = re.search(r"^- reason: ?(.*)$", text, re.M)
    return m.group(1).strip() if m else ""


BULLET = re.compile(r"^- (\S+?): (\S*) — (.*)$")


def wave_goals(text, base):
    out, inside = [], False
    for line in text.splitlines():
        if line.startswith("## "):
            inside = line.strip() == "## Stopped"
            continue
        if not inside:
            continue
        m = BULLET.match(line)
        if not m and line.startswith("- "):
            # A bullet the walker's printf cannot write: never read as fewer goals.
            out.append(("?", "unparsed-bullet", None))
        if m:
            f = m.group(3).strip()
            if f == "(no stop file)" or not f:
                f = None
            elif not os.path.isabs(f):
                f = os.path.join(base, f)
            out.append((m.group(1), m.group(2), f))
    return out


def classify(stop_path, table):
    text = read_text(stop_path)
    if text is None:
        return {"stop": stop_path, "kind": "single", "class": "A", "reason": "stop-unreadable",
                "hold": True, "goals": [{"goal": "?", "reason": "stop-unreadable", "class": "A",
                                         "billing": None, "file": stop_path}]}
    head = text.splitlines()[0] if text else ""
    m = re.match(r"^# Stop: (\S+)", head)
    if m and m.group(1) == "walk" and reason_line(text) == "wave-stop":
        kind = "wave"
        items = wave_goals(text, os.path.dirname(stop_path))
    else:
        kind = "single"
        items = [(m.group(1) if m else "?", reason_line(text), stop_path)]
    goals = []
    for g, r, f in items:
        why = billing(f)
        goals.append({"goal": g, "reason": r, "class": "A" if why else class_of(r, table),
                      "billing": why, "file": f})
    if not goals:
        return {"stop": stop_path, "kind": kind, "class": "A", "reason": "", "hold": True, "goals": []}
    worst = min(goals, key=lambda x: (ORDER.index(x["class"]), x["billing"] is None))
    reason = "budget" if worst["billing"] else worst["reason"]
    return {"stop": stop_path, "kind": kind, "class": worst["class"], "reason": reason,
            "hold": worst["class"] in ("A", "B"), "goals": goals}


def main(argv):
    try:
        return run(argv)
    except Exception as e:  # anything else is A, never a traceback without JSON
        print(json.dumps({"stop": argv[-1] if len(argv) > 1 else None, "kind": "single", "class": "A",
                          "reason": "classify-error", "hold": True, "error": repr(e)[:500],
                          "goals": []}))
        return 0


def run(argv):
    args = argv[1:]
    table = TABLE
    if "--table" in args:
        i = args.index("--table")
        table = args[i + 1]
        del args[i:i + 2]
    if len(args) != 1:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    print(json.dumps(classify(args[0], load_table(table))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
