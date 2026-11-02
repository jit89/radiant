#!/usr/bin/env python3
"""proof-sandbox.py — the Seatbelt profile a proof runs under (house item 12).

  proof-sandbox.py --root DIR --tmp DIR [--out FILE] [--deps DIR]
                   [--network none|loopback|true] [--setup]

Prints an SBPL profile for `sandbox-exec -f`. docs/features/proof-sandbox/
PLAN.md is the contract (steps 1-3, Amendment 1); EVIDENCE.md is why each rule
is here. In short:
- everything is denied, then a proof may fork, exec, read the filesystem and
  write only --root (the checkout), --tmp (its private TMPDIR) and --out (its
  output file, metadata and data only);
- hard links only with both ends inside the allowed trees (--root, --tmp,
  and --deps under --setup): Seatbelt checks each end against the rules;
- no network unless --network loopback|true; --setup (worktree_setup) gets the
  network, may write --deps, and gets pnpm's TLS trust lookup and lock folder;
- no mach service lookups at all otherwise (Launch Services, AppleEvents,
  launchd, securityd are unreachable);
- the secret list, the house's own state and the shared temp areas are denied
  after the allows, so they win; --tmp is re-allowed after them, and only the
  named denials of the write operations no proof needs (WRITE_EXTRA) and the
  hard-link rules come later.

Exit 2 with a message on any path outside [A-Za-z0-9._/@+-], or a --root
that sits under a denied path (it could never be proved).
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HOUSE = os.path.dirname(os.path.dirname(HERE))
HOME = os.path.expanduser("~")
CACHE = os.path.join(HOME, ".cache", "claude-coding-workflow")
SAFE = re.compile(r"^[A-Za-z0-9._/@+-]+$")
# Writes, as the wildcard and the named operations together. Seatbelt lets a
# rule naming an operation beat a wildcard rule whatever their order (measured:
# a file-write-create allow beats a later file-write* deny), so every write
# allow and every write deny names these operations, and a later deny wins as
# written. Since macOS 27, setting a file's times is checked under an operation
# none of the names match, which only file-write* covers; between two wildcard
# rules the later wins. So each rule carries both forms, and the denials stay
# after the allows (docs/features/sandbox-write-times).
WRITE = ("file-write* file-write-create file-write-data file-write-flags "
         "file-write-mode file-write-owner file-write-setugid file-write-times "
         "file-write-unlink file-write-xattr")
# Named write operations the wildcard would also open but no proof needs; denied
# by name on the allowed trees, after every write allow.
WRITE_EXTRA = "file-write-acl file-write-finderinfo file-write-mount file-write-unmount"


def die(msg):
    print(f"proof-sandbox: {msg}", file=sys.stderr)
    sys.exit(2)


def lit(p):
    """An SBPL string literal; never escaped by hand, refused if unsafe."""
    if not SAFE.match(p):
        die(f"path outside [A-Za-z0-9._/@+-]: {p!r}")
    return '"' + p + '"'


def expand(line):
    if line.startswith("~/"):
        return os.path.join(HOME, line[2:])
    if line.startswith("@HOUSE/"):
        return os.path.join(HOUSE, line[7:])
    return line


def forms(p):
    """Every form a path may be opened by: resolved if it exists; else the
    literal path and the path under its resolved parent (a file created later
    is still covered)."""
    p = os.path.abspath(os.path.expanduser(p))
    if os.path.lexists(p):
        return sorted({p, os.path.realpath(p)})
    return sorted({p, os.path.join(os.path.realpath(os.path.dirname(p)), os.path.basename(p))})


def real(p):
    return os.path.realpath(os.path.abspath(p))


def secret_paths():
    out = []
    with open(os.path.join(HERE, "secret-paths.txt"), encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                out.extend(forms(expand(line)))
    return out


def under(p, d):
    return p == d or p.startswith(d.rstrip("/") + "/")


def subpaths(paths):
    return " ".join(f"(subpath {lit(p)})" for p in paths)


def parents(paths):
    out = set()
    for p in paths:
        d = os.path.dirname(p)
        while d and d != "/":
            out.add(d)
            d = os.path.dirname(d)
    return sorted(out)


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--tmp", required=True)
    ap.add_argument("--out")
    ap.add_argument("--deps")
    ap.add_argument("--network", choices=("none", "loopback", "true"), default="none")
    ap.add_argument("--setup", action="store_true")
    a = ap.parse_args()

    for p in [a.root, a.tmp] + ([a.deps] if a.deps else []):
        if not os.path.isdir(p):
            die(f"not a directory: {p}")
    root, tmp = real(a.root), real(a.tmp)
    deps = real(a.deps) if a.deps else None
    out = real(a.out) if a.out else None

    secrets = secret_paths()
    state = [os.path.join(CACHE, d) for d in ("runs", "grok", "logs", "keys", "handoffs")]
    state = [f for p in state for f in forms(p)]
    temp_areas = ["/tmp", "/private/tmp", "/private/var/folders"]
    # A checkout under a secret or the house's state can never be proved. One
    # under a temp area can: its own subtree is re-allowed after that denial.
    for d in secrets + state:
        if under(root, d):
            die(f"--root {root} is under a denied path ({d}); it cannot be proved there")

    L = [
        "(version 1)",
        "(deny default)",
        "(debug deny)",
        "(allow process-fork)",
        "(allow process-exec)",
        "(allow signal (target same-sandbox))",
        "(allow sysctl-read)",
        "(allow file-read*)",
        "(allow file-ioctl)",
        '(allow file-write* (literal "/dev/null") (literal "/dev/zero") '
        '(literal "/dev/tty") (literal "/dev/dtracehelper"))',
        f"(allow {WRITE} (subpath {lit(root)}) (subpath {lit(tmp)}))",
        # No terminal ioctls: a proof must not reach the user's terminal
        # (TIOCSTI); it also runs in a session of its own (lib/proof.sh).
        '(deny file-ioctl (literal "/dev/tty") (regex #"^/dev/ttys"))',
    ]
    if a.setup:
        if deps:
            L.append(f"(allow {WRITE} (subpath {lit(deps)}))")
        L.append('(allow mach-lookup (global-name "com.apple.trustd.agent"))')
    # A proof's own unix sockets (a test database) stay usable in every mode,
    # in its TMPDIR only: the checkout (in serial mode the user's own) may hold
    # sockets unsandboxed processes listen on (git's fsmonitor, a dev server).
    L.append(f"(allow network-bind network-inbound (local unix-socket (subpath {lit(tmp)})))")
    L.append(f"(allow network-outbound (remote unix-socket (subpath {lit(tmp)})))")
    if a.setup or a.network == "true":
        # IP only, and the one unix socket DNS needs: `(allow network*)` would
        # also open every unix socket (Docker, ssh and 1Password agents).
        L.append('(allow network-bind network-inbound (local ip "*:*"))')
        L.append('(allow network-outbound (remote ip "*:*"))')
        L.append('(allow network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))')
    elif a.network == "loopback":
        L.append('(allow network-bind network-inbound (local ip "localhost:*"))')
        L.append('(allow network-outbound (remote ip "localhost:*"))')

    # The shared temp areas, then the trees a proof works in re-allowed for
    # reads (a checkout or deps folder may sit under a temp area), all before
    # the secret and house-state denials, so those win inside the trees too.
    L.append(f"(deny file-read* {subpaths(temp_areas)})")
    L.append(f"(allow file-read* (subpath {lit(root)}))")
    if deps:
        L.append(f"(allow file-read* (subpath {lit(deps)}))")
    if a.setup:
        # pnpm's fixed lock folder, reached through /tmp (metadata only there).
        lock = f"/private/tmp/pnpm-store-operation-locks-{os.getuid()}"
        L.append(f"(allow file-read* {WRITE} (subpath {lit(lock)}))")
        L.append('(allow file-read-metadata (literal "/tmp") (literal "/private/tmp"))')
    # Denials that win over the allows above.
    L.append(f"(deny file-read* {WRITE} file-link {subpaths(secrets)})")
    L.append(f"(deny file-read* {WRITE} file-link {subpaths(state)})")
    # The run-goal-* artifact folders, including ones created after this
    # profile. Only "." and "+" can need escaping, given the SAFE set.
    for c in forms(CACHE):
        rx = "^" + re.sub(r"([.+])", r"\\\1", lit(os.path.join(c, "run-goal-"))[1:-1])
        L.append(f'(deny file-read* {WRITE} file-link (regex #"{rx}"))')
    L.append(f"(deny {WRITE} file-link (subpath {lit(os.path.join(root, '.git'))}))")
    L.append("(deny process-exec " + " ".join(
        f'(literal "{b}")' for b in ("/usr/bin/open", "/usr/bin/osascript", "/bin/launchctl",
                                     "/usr/bin/security", "/usr/bin/sandbox-exec")) + ")")
    # Metadata only on the parents of the trees a proof works in: compilers
    # resolve their TMPDIR through folders denied above (EVIDENCE: cc1).
    keep = [root, tmp] + ([deps] if deps else []) + ([out] if out else [])
    L.append("(allow file-read-metadata " + " ".join(f"(literal {lit(p)})" for p in parents(keep)) + ")")
    if out:
        L.append(f"(allow file-read-metadata file-write-data (literal {lit(out)}))")
    # --tmp sits under a denied house folder; it is fresh per run.
    L.append(f"(allow file-read* {WRITE} (subpath {lit(tmp)}))")
    # After every write allow (the --tmp re-allow included), so no later
    # file-write* allow reopens them.
    extra = [root, tmp] + ([deps] if deps else []) + ([lock] if a.setup else [])
    L.append(f"(deny {WRITE_EXTRA} {subpaths(extra)})")
    # Hard links last: an explicit deny (the implicit default deny loses to
    # the named write allows, measured), then the trees a link may touch. Each
    # end is checked on its own, so a link between two allowed trees is
    # allowed and one to or from anywhere else is refused (measured). Secrets
    # and the root's .git are denied again after, so no allow re-opens them.
    trees = [root, tmp] + ([deps] if (deps and a.setup) else [])
    L.append("(deny file-link)")
    L.extend(f"(allow file-link (subpath {lit(t)}))" for t in trees)
    L.append(f"(deny file-link {subpaths(secrets)} (subpath {lit(os.path.join(root, '.git'))}))")
    print("\n".join(L))


if __name__ == "__main__":
    main()
