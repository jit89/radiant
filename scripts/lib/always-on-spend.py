#!/usr/bin/env python3
"""always-on-spend.py — the always-on spend ledger (docs/features/always-on, step 9).

The ledger is append-only JSONL of OBSERVATIONS, not amounts: one line each
time a cost is seen, {"ts", "entry", "kind", "id", "cumulative_usd"}, where
`id` is the thread or session the cost belongs to and `cumulative_usd` that
thread's or session's total so far as the provider reports it. Amounts are
derived at read time: for each id, its observations in time order, each
contributing its rise over the previous one (the first contributes all of it,
a fall nothing), dated at that observation. Observing the same total twice
adds nothing, however many times a caller records it.

  observe LEDGER ENTRY KIND ID CUMULATIVE_USD
      append one observation (KIND: implementer, reviewer, mutations, decider,
      stand-in). A CUMULATIVE_USD that is not a number is refused (exit 2).
  bump LEDGER ENTRY KIND ID DELTA_USD
      for a model call killed before it reported (step 9): append an
      observation of ID at its highest cumulative so far plus DELTA_USD (the
      stand-in), so a later resume of that session adds only its rise.
  check LEDGER ENTRY [--stop FILE] [--day USD] [--walk USD] [--week USD]
      exit 0: under every ceiling (and a halt file beside the ledger is
      removed); 3: over one (the halt file is written; stdout names it);
      4: the kill file (--stop) is present. Defaults: $10 / 24 h, $20 for
      ENTRY, $50 / 7 days.
  sum LEDGER [ENTRY]
      print the derived 24 h, 7 d and ENTRY totals (for status and digests).

Every append and read holds an exclusive fcntl.flock on LEDGER + ".lock", as
events.py locks; this Mac has no flock(1). A line that does not parse is an
error (exit 5): an undefined sum must not pass a ceiling.
"""
import fcntl
import json
import math
import os
import sys
import time

DAY = 24 * 3600
WEEK = 7 * DAY


class LedgerError(Exception):
    pass


def lock(ledger):
    os.makedirs(os.path.dirname(os.path.abspath(ledger)), exist_ok=True)
    fd = os.open(ledger + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def read(ledger):
    if not os.path.exists(ledger):
        return []
    rows = []
    with open(ledger, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            if not line.strip():
                continue
            try:
                r = json.loads(line)
                row = (float(r["ts"]), str(r["entry"]), str(r["id"]), float(r["cumulative_usd"]))
                if not (math.isfinite(row[0]) and math.isfinite(row[3]) and row[3] >= 0):
                    raise ValueError("not a finite, non-negative cost")
                rows.append(row)
            except (ValueError, KeyError, TypeError) as e:
                raise LedgerError(f"{ledger}:{n}: not an observation ({e})")
    return rows


def amounts(rows):
    """(ts, entry, amount) per observation: its rise over the previous one of its id."""
    last, out = {}, []
    for ts, entry, oid, cum in sorted(rows, key=lambda r: r[0]):
        rise = max(0.0, cum - last.get(oid, 0.0))
        last[oid] = max(cum, last.get(oid, 0.0))
        out.append((ts, entry, rise))
    return out


def totals(rows, entry=None, now=None):
    now = time.time() if now is None else now
    a = amounts(rows)
    day = sum(x for ts, _, x in a if now - ts <= DAY)
    week = sum(x for ts, _, x in a if now - ts <= WEEK)
    walk = sum(x for _, e, x in a if entry is not None and e == entry)
    return day, week, walk


def cmd_observe(argv):
    if len(argv) != 5:
        sys.exit(__doc__)
    ledger, entry, kind, oid, cum = argv
    try:
        value = float(cum)
    except ValueError:
        print(f"always-on-spend: not a cost: {cum!r}", file=sys.stderr)
        return 2
    if not math.isfinite(value) or value < 0:
        print(f"always-on-spend: not a cost: {cum!r}", file=sys.stderr)
        return 2
    line = json.dumps({"ts": time.time(), "entry": entry, "kind": kind, "id": oid, "cumulative_usd": value})
    fd = lock(ledger)
    try:
        with open(ledger, "a", encoding="utf-8") as f:
            f.write(line + "\n")
            f.flush()
            os.fsync(f.fileno())
    finally:
        os.close(fd)
    return 0


def cmd_bump(argv):
    if len(argv) != 5:
        sys.exit(__doc__)
    ledger, entry, kind, oid, delta = argv
    try:
        d = float(delta)
    except ValueError:
        d = -1.0
    if not math.isfinite(d) or d < 0:
        print(f"always-on-spend: not a cost: {delta!r}", file=sys.stderr)
        return 2
    fd = lock(ledger)
    try:
        try:
            prev = max([c for _, _, i, c in read(ledger) if i == oid] or [0.0])
        except LedgerError as e:
            print(f"always-on-spend: {e}", file=sys.stderr)
            return 5
        line = json.dumps({"ts": time.time(), "entry": entry, "kind": kind, "id": oid, "cumulative_usd": prev + d})
        with open(ledger, "a", encoding="utf-8") as f:
            f.write(line + "\n")
            f.flush()
            os.fsync(f.fileno())
    finally:
        os.close(fd)
    return 0


def opt(argv, name, default):
    if name in argv:
        i = argv.index(name)
        v = argv[i + 1]
        del argv[i:i + 2]
        return v
    return default


def cmd_check(argv):
    stop = opt(argv, "--stop", "")
    day_c = float(opt(argv, "--day", "10"))
    walk_c = float(opt(argv, "--walk", "20"))
    week_c = float(opt(argv, "--week", "50"))
    if len(argv) != 2:
        sys.exit(__doc__)
    ledger, entry = argv
    if stop and os.path.exists(stop):
        print(f"kill file present: {stop}")
        return 4
    halt = os.path.join(os.path.dirname(os.path.abspath(ledger)), "halt")
    fd = lock(ledger)
    try:
        day, week, walk = totals(read(ledger), entry)
    except LedgerError as e:
        print(f"always-on-spend: {e}", file=sys.stderr)
        return 5
    finally:
        os.close(fd)
    over = []
    if day > day_c:
        over.append(f"24 h ${day:.2f} > ${day_c:.2f}")
    if walk > walk_c:
        over.append(f"entry ${walk:.2f} > ${walk_c:.2f}")
    if week > week_c:
        over.append(f"7 d ${week:.2f} > ${week_c:.2f}")
    if over:
        with open(halt, "w", encoding="utf-8") as f:
            f.write("; ".join(over) + "\n")
        print(f"spend ceiling: {'; '.join(over)} (halt: {halt})")
        return 3
    try:
        os.unlink(halt)
    except FileNotFoundError:
        pass
    return 0


def cmd_sum(argv):
    if len(argv) not in (1, 2):
        sys.exit(__doc__)
    ledger = argv[0]
    entry = argv[1] if len(argv) == 2 else None
    fd = lock(ledger)
    try:
        day, week, walk = totals(read(ledger), entry)
    except LedgerError as e:
        print(f"always-on-spend: {e}", file=sys.stderr)
        return 5
    finally:
        os.close(fd)
    print(json.dumps({"day_usd": round(day, 6), "week_usd": round(week, 6), "entry_usd": round(walk, 6)}))
    return 0


def main(argv):
    if not argv:
        sys.exit(__doc__)
    cmd, rest = argv[0], argv[1:]
    return {"observe": cmd_observe, "bump": cmd_bump, "check": cmd_check, "sum": cmd_sum}.get(cmd, lambda a: sys.exit(__doc__))(rest)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
