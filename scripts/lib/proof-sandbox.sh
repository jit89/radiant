# shellcheck shell=bash
# The proof sandbox's gates (house item 12, docs/features/proof-sandbox/PLAN.md
# step 4 and Amendment 1 B). Sourced by lib/proof.sh. Never run.

PSB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The sandbox binary. Fixed: CW_PROOF_SANDBOX=off is the only way to change how
# proofs run. (The self-test's own test edits this line in a copy of lib/.)
PSB_SANDBOX_EXEC=/usr/bin/sandbox-exec

# proof_sandbox_off — true when the user launched with CW_PROOF_SANDBOX=off,
# the one way to run proofs unsandboxed. Read from the host's environment.
proof_sandbox_off() { [[ "${CW_PROOF_SANDBOX:-}" == off ]]; }

# proof_sandbox_selftest — 0 when sandbox-exec loads a generated profile and
# that profile holds: the root writable, the rest not, a planted secret
# unreadable, a public connect and a host loopback listener refused with
# EPERM. Prints what failed otherwise. A fake sandbox-exec that runs the
# command unsandboxed fails here.
proof_sandbox_selftest() {
  [[ -x "$PSB_SANDBOX_EXEC" ]] || { echo "$PSB_SANDBOX_EXEC is missing"; return 1; }
  local d rc=0 why=() port lpid vf
  d="$(mktemp -d "${TMPDIR:-/tmp}/cw-psb-selftest-XXXXXX")" || { echo "cannot make a self-test folder"; return 1; }
  d="$(cd "$d" && pwd -P)"
  # The fake HOME sits inside the root, so only the secret rule (not the
  # temp-area rule) can refuse its planted secret.
  mkdir -p "$d/root/home/.ssh" "$d/tmp"
  echo planted >"$d/root/home/.ssh/selftest"
  # Two files with an old stamp, for the file-time checks (macOS 27 checks
  # setting times under an operation only file-write* covers).
  mkdir -p "$d/root/.git"
  : >"$d/root/stamp"; : >"$d/root/.git/stamp"
  python3 -c "import os,sys; [os.utime(p, (1e9, 1e9)) for p in sys.argv[1:]]" "$d/root/stamp" "$d/root/.git/stamp"
  vf="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)cw-psb-selftest-$$"
  echo temp >"$vf" 2>/dev/null || vf=""
  : >"$d/out"
  if ! HOME="$d/root/home" python3 "$PSB_LIB_DIR/proof-sandbox.py" --root "$d/root" --tmp "$d/tmp" --out "$d/out" >"$d/p.sb" 2>"$d/gen.err"; then
    echo "the profile generator failed: $(head -c 300 "$d/gen.err")"; rm -rf "$d"; [[ -z "$vf" ]] || rm -f "$vf"; return 1
  fi
  _psb_run() { (cd "$d/root" && HOME="$d/root/home" TMPDIR="$d/tmp" "$PSB_SANDBOX_EXEC" -f "$d/p.sb" "$@" >"$d/out" 2>/dev/null); }
  # eperm PYTHON-OPEN-EXPRESSION — run it in the sandbox; 0 only on EPERM.
  _psb_eperm() { _psb_run /usr/bin/python3 -c "
import errno,sys
try: $1
except OSError as e: sys.exit(0 if e.errno == errno.EPERM else 3)
sys.exit(4)"; }
  _psb_run /usr/bin/true || why+=("a trivial command does not run under the profile")
  _psb_run /bin/sh -c ": >inside" || why+=("the root is not writable")
  [[ -f "$d/root/inside" ]] || why+=("a write in the root left no file")
  _psb_eperm "open('$d/outside','w')" || why+=("a write outside the root was not refused with EPERM")
  [[ -e "$d/outside" ]] && why+=("a file outside the root was created")
  _psb_eperm "open('$d/root/home/.ssh/selftest').read()" || why+=("a secret-list file inside the root was not refused with EPERM")
  _psb_run /usr/bin/python3 -c "import os; os.utime('$d/root/stamp', (2e9, 2e9))" &&
    [[ "$(stat -f %m "$d/root/stamp")" == 2000000000 ]] || why+=("setting a file's time in the root is refused")
  { _psb_eperm "__import__('os').utime('$d/root/.git/stamp', (2e9, 2e9))" &&
    [[ "$(stat -f %m "$d/root/.git/stamp")" == 1000000000 ]]; } || why+=("setting a file's time in the root's .git was not refused")
  if [[ -n "$vf" ]]; then
    _psb_eperm "open('$vf').read()" || why+=("a file under /private/var/folders was not refused with EPERM")
  fi
  _psb_run /usr/bin/python3 -c "
import socket,sys
try: socket.getaddrinfo('example.com', 443); sys.exit(1)
except socket.gaierror: sys.exit(0)" || why+=("a public DNS lookup was not refused")
  /usr/bin/python3 -c "
import socket,time; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(1)
open('$d/port','w').write(str(s.getsockname()[1])); time.sleep(20)" 2>/dev/null &
  lpid=$!
  for _ in $(seq 50); do [[ -s "$d/port" ]] && break; sleep 0.1; done
  port="$(cat "$d/port" 2>/dev/null || echo 9)"
  _psb_eperm "import socket; s=socket.socket(); s.settimeout(3); s.connect(('1.1.1.1',443))" ||
    why+=("a public connect was not refused with EPERM")
  _psb_eperm "import socket; s=socket.socket(); s.settimeout(3); s.connect(('127.0.0.1',$port))" ||
    why+=("a host loopback listener was not refused with EPERM")
  kill "$lpid" 2>/dev/null; wait "$lpid" 2>/dev/null || true
  rm -rf "$d"; [[ -z "$vf" ]] || rm -f "$vf"
  ((${#why[@]} == 0)) && return 0
  printf '%s\n' "${why[@]}"
  return 1
}

# secrets_in_checkout DIR... — print every entry named .env or .env.* (any
# case, any depth, a symlink or folder too), except the example files, outside
# .git and dependency folders. Exit 1 when any is found.
secrets_in_checkout() {
  python3 - "$@" <<'PY'
import os, re, sys
NAME = re.compile(r"^\.env(\..*)?$", re.I)
KEEP = {".env.example", ".env.sample", ".env.template"}
SKIP = {".git", "node_modules", ".venv", "venv", "site-packages", "target", "vendor"}
hits = []
for top in sys.argv[1:]:
    if not os.path.isdir(top):
        continue
    for dp, dns, fns in os.walk(top):
        for n in fns + dns:
            if NAME.match(n) and n.lower() not in KEEP:
                hits.append(os.path.join(dp, n))
        dns[:] = [x for x in dns if x not in SKIP and not NAME.match(x)]
for h in sorted(set(hits)):
    print(h)
sys.exit(1 if hits else 0)
PY
}
