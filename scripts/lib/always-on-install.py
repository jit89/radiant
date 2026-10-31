#!/usr/bin/env python3
"""always-on-install.py — what `install.sh --always-on` writes
(docs/features/always-on/PLAN.md step 15): the two LaunchAgent plists and the
~/.config/cw-always-on/ skeleton. It loads neither agent (`cw-decide.sh start`
does) and never overwrites notify.conf.

  com.cw.always-on            caffeinate -is <house>/scripts/cw-supervisor.sh;
                              RunAtLoad, KeepAlive, ProcessType Standard
  com.cw.always-on.heartbeat  <house>/scripts/cw-decide.sh heartbeat at 09:00

Both get an absolute PATH, DISABLE_UPDATES=1 and DISABLE_AUTOUPDATER=1 (step
0f), and log under <cache>. CW_AO_HOME, CW_AO_CACHE and CW_AO_LAUNCH_AGENTS
move the folders (tests).
"""
import os
import plistlib
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HOUSE = os.path.dirname(os.path.dirname(HERE))
HOME = os.path.expanduser(os.environ.get("CW_AO_HOME") or "~/.config/cw-always-on")
CACHE = os.path.expanduser(os.environ.get("CW_AO_CACHE") or "~/.cache/claude-coding-workflow/always-on")
AGENTS = os.path.expanduser(os.environ.get("CW_AO_LAUNCH_AGENTS") or "~/Library/LaunchAgents")
PATH = ":".join([os.path.expanduser("~/.local/bin"), "/opt/homebrew/bin", "/usr/local/bin",
                 "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
ENV = {"PATH": PATH, "DISABLE_UPDATES": "1", "DISABLE_AUTOUPDATER": "1"}
NOTIFY_TEMPLATE = (
    "# The always-on iMessage recipient (docs/features/always-on/SETUP.md):\n"
    "# your phone number in international form, or your Apple ID's email.\n"
    "recipient=\n"
)


def plists():
    sup = {
        "Label": "com.cw.always-on",
        "ProgramArguments": ["/usr/bin/caffeinate", "-is", os.path.join(HOUSE, "scripts", "cw-supervisor.sh")],
        "RunAtLoad": True,
        "KeepAlive": True,
        "ProcessType": "Standard",
        "WorkingDirectory": HOUSE,
        "EnvironmentVariables": dict(ENV),
        "StandardOutPath": os.path.join(CACHE, "launchd-supervisor.out"),
        "StandardErrorPath": os.path.join(CACHE, "launchd-supervisor.err"),
    }
    beat = {
        "Label": "com.cw.always-on.heartbeat",
        "ProgramArguments": [os.path.join(HOUSE, "scripts", "cw-decide.sh"), "heartbeat"],
        "StartCalendarInterval": {"Hour": 9, "Minute": 0},
        "ProcessType": "Background",
        "WorkingDirectory": HOUSE,
        "EnvironmentVariables": dict(ENV),
        "StandardOutPath": os.path.join(CACHE, "launchd-heartbeat.out"),
        "StandardErrorPath": os.path.join(CACHE, "launchd-heartbeat.err"),
    }
    return [sup, beat]


def write_atomic(path, data, mode):
    tmp = f"{path}.tmp-{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def main(argv):
    for d in (HOME, os.path.join(HOME, "state"), os.path.join(HOME, "attempts")):
        os.makedirs(d, mode=0o700, exist_ok=True)
        os.chmod(d, 0o700)
    os.makedirs(CACHE, mode=0o700, exist_ok=True)
    os.makedirs(AGENTS, exist_ok=True)
    conf = os.path.join(HOME, "notify.conf")
    if not os.path.exists(conf):
        write_atomic(conf, NOTIFY_TEMPLATE.encode(), 0o600)
        print(f"always-on: wrote {conf} (fill in recipient=)")
    else:
        os.chmod(conf, 0o600)
        print(f"always-on: kept {conf}")
    for p in plists():
        path = os.path.join(AGENTS, f"{p['Label']}.plist")
        write_atomic(path, plistlib.dumps(p), 0o644)
        print(f"always-on: wrote {path} (not loaded)")
    print("always-on: next, docs/features/always-on/SETUP.md; then cw-decide.sh start; then cw-decide.sh doctor")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
