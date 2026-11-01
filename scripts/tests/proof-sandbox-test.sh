#!/usr/bin/env bash
# Self-test: lib/proof-sandbox.py's profile, each rule against a real
# sandbox-exec run (docs/features/proof-sandbox/PLAN.md steps 1-2, Amendment 1).
# Secrets are planted in this test's private HOME; nothing reads the real one.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cw-proof-sandbox-XXXXXX")" && pwd -P)"
export TMPDIR="$TMP" HOME="$TMP/home"
mkdir -p "$HOME"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
GEN="$HERE/lib/proof-sandbox.py"
PY=/usr/bin/python3
fails=0

check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name: want [$want] got [$got]"
    fails=$((fails + 1))
  fi
}
has() { [[ "$2" == *"$1"* ]] && echo yes || echo "no: $2"; }

ROOT="$TMP/root"; T="$HOME/.cache/claude-coding-workflow/runs/r1/tmp"; OUT="$TMP/out"
mkdir -p "$ROOT/.git" "$T"
: >"$OUT"
# profile [generator args...] — writes $TMP/p.sb for ROOT/T/OUT.
profile() { "$GEN" --root "$ROOT" --tmp "$T" --out "$OUT" "$@" >"$TMP/p.sb"; }
# sbx CMD — run CMD (a sh string) in ROOT under the profile, output to OUT;
# prints yes when it exits 0, no otherwise.
sbx() { (cd "$ROOT" && TMPDIR="$T" sandbox-exec -f "$TMP/p.sb" /bin/sh -c "$1" >"$OUT" 2>&1) && echo yes || echo no; }
errno() { (cd "$ROOT" && TMPDIR="$T" sandbox-exec -f "$TMP/p.sb" "$PY" -c "$1" >"$OUT" 2>/dev/null); cat "$OUT"; }

echo "== the generator"
"$GEN" --root "$TMP/has space" --tmp "$T" >/dev/null 2>"$TMP/err" && rc=0 || rc=$?
check "a missing --root: exit 2" 2 "$rc"
mkdir -p "$TMP/has space"
"$GEN" --root "$TMP/has space" --tmp "$T" >/dev/null 2>"$TMP/err" && rc=0 || rc=$?
check "a path with a space: exit 2" 2 "$rc"
check "  ...named" yes "$(has 'outside [A-Za-z0-9._/@+-]' "$(cat "$TMP/err")")"
mkdir -p "$HOME/.ssh/repo" "$HOME/.cache/claude-coding-workflow/runs/x/repo"
for r in "$HOME/.ssh/repo" "$HOME/.cache/claude-coding-workflow/runs/x/repo"; do
  "$GEN" --root "$r" --tmp "$T" >/dev/null 2>"$TMP/err" && rc=0 || rc=$?
  check "a root under a denied path: exit 2 (${r#"$HOME"/})" 2 "$rc"
done
"$GEN" --root "$ROOT" --tmp "$T" --network maybe >/dev/null 2>&1 && rc=0 || rc=$?
check "--network takes none|loopback|true only" 2 "$rc"

echo "== writes"
profile
check "write inside the root" yes "$(sbx 'echo x >inside && cat inside')"
check "write outside the root" no "$(sbx ": >\"$HOME/outside\"")"
check "write the root's .git" no "$(sbx ': >.git/hook')"
check "write the private TMPDIR (under a denied house folder)" yes "$(sbx ": >\"$T/t\" && cat \"$T/t\"")"
check "write another run folder" no "$(sbx ": >\"$HOME/.cache/claude-coding-workflow/runs/x/w\"")"
check "outside the sandbox .GIT is the root's .git" yes "$(: >"$ROOT/.GIT/probe" && [[ -e "$ROOT/.git/probe" ]] && rm "$ROOT/.git/probe" && echo yes || echo no)"
check "write .GIT (case)" no "$(sbx ': >.GIT/hook')"
check "write .Git/config (case)" no "$(sbx ': >.Git/config')"
check "write the root through the firmlink" yes "$(sbx ": >\"/System/Volumes/Data$ROOT/fw\"")"
check "write the root's .git through the firmlink" no "$(sbx ": >\"/System/Volumes/Data$ROOT/.git/hook\"")"

echo "== reads"
mkdir -p "$HOME/.ssh" "$HOME/.config/cw-secrets/p" "$HOME/.cache/claude-coding-workflow/run-goal-g1" "$HOME/.cache/claude-coding-workflow/logs"
echo k >"$HOME/.ssh/id_test"; echo s >"$HOME/.config/cw-secrets/p/env"
echo a >"$HOME/.cache/claude-coding-workflow/run-goal-g1/fix-r0.md"; echo l >"$HOME/.cache/claude-coding-workflow/logs/events.jsonl"
echo v >"$TMP/elsewhere-in-var-folders"
echo plain >"$HOME/plain.txt"
profile
check "read a plain file outside the list (Q2 (b))" yes "$(sbx 'cat /etc/hosts >/dev/null')"
check "read ~/.ssh" no "$(sbx "cat \"$HOME/.ssh/id_test\"")"
check "read ~/.config/cw-secrets" no "$(sbx "cat \"$HOME/.config/cw-secrets/p/env\"")"
check "read a run-goal-* artifact folder" no "$(sbx "cat \"$HOME/.cache/claude-coding-workflow/run-goal-g1/fix-r0.md\"")"
check "read the logs" no "$(sbx "cat \"$HOME/.cache/claude-coding-workflow/logs/events.jsonl\"")"
check "read the temp area outside root and TMPDIR" no "$(sbx "cat \"$TMP/elsewhere-in-var-folders\"")"
check "read the root itself (under the temp area)" yes "$(sbx 'cat inside')"
check "a symlink in the root to a secret" no "$(sbx "ln -s \"$HOME/.ssh/id_test\" sym && cat sym")"
# The temp area through the firmlink under /System/Volumes/Data (FUTURE-WORK
# item 12): shown to reach the file outside the sandbox first. The secret
# rule's spellings are probed inside the root below, where the temp-area rule
# cannot refuse them.
FW="/System/Volumes/Data"
check "outside the sandbox the firmlink reaches the temp area" v "$(cat "$FW$TMP/elsewhere-in-var-folders")"
check "read the temp area through the firmlink" no "$(sbx "cat \"$FW$TMP/elsewhere-in-var-folders\"")"

# The same denials inside the root: a HOME under the checkout, so only the
# secret and house-state rules can refuse these (the temp-area rule cannot:
# the root is re-allowed after it). This is the rule order that must hold.
IH="$ROOT/h"
mkdir -p "$IH/.ssh" "$IH/.config/cw-secrets/p" "$IH/.cache/claude-coding-workflow/run-goal-g1" "$IH/.cache/claude-coding-workflow/logs"
echo k >"$IH/.ssh/id_test"; echo s >"$IH/.config/cw-secrets/p/env"
echo a >"$IH/.cache/claude-coding-workflow/run-goal-g1/fix-r0.md"; echo l >"$IH/.cache/claude-coding-workflow/logs/events.jsonl"
HOME="$IH" "$GEN" --root "$ROOT" --tmp "$T" --out "$OUT" >"$TMP/p.sb"
check "inside the root: a plain file is readable" yes "$(sbx 'cat inside')"
check "inside the root: ~/.ssh refused" no "$(sbx "cat \"$IH/.ssh/id_test\"")"
check "inside the root: ~/.ssh not writable either" no "$(sbx ": >\"$IH/.ssh/new\"")"
# Other spellings of the same secret: any case on a case-insensitive volume,
# and the firmlink. Each reaches the file outside the sandbox, and a plain
# file in the root is readable through the firmlink inside it, so a refusal
# is the secret rule's.
check "inside the root: outside the sandbox the case and firmlink spellings reach the secret" "k k k" \
  "$(cat "$IH/.SSH/id_test") $(cat "$FW$IH/.ssh/id_test") $(cat "$FW$IH/.Ssh/id_test")"
check "inside the root: a plain file through the firmlink is readable" yes "$(sbx "cat \"$FW$ROOT/inside\"")"
check "inside the root: ~/.SSH refused (case)" no "$(sbx "cat \"$IH/.SSH/id_test\"")"
check "inside the root: ~/.ssh refused through the firmlink" no "$(sbx "cat \"$FW$IH/.ssh/id_test\"")"
check "inside the root: ~/.Ssh refused through the firmlink" no "$(sbx "cat \"$FW$IH/.Ssh/id_test\"")"
check "inside the root: ~/.config/cw-secrets refused" no "$(sbx "cat \"$IH/.config/cw-secrets/p/env\"")"
check "inside the root: a run-goal-* folder refused" no "$(sbx "cat \"$IH/.cache/claude-coding-workflow/run-goal-g1/fix-r0.md\"")"
check "inside the root: the logs refused" no "$(sbx "cat \"$IH/.cache/claude-coding-workflow/logs/events.jsonl\"")"
# A secret path that did not exist when the profile was made, created after it.
check "inside the root: a secret path made after the profile" no \
  "$(mkdir -p "$IH/.aws" && echo c >"$IH/.aws/credentials"; sbx "cat \"$IH/.aws/credentials\"")"
profile

echo "== hard links"
check "link inside the root" yes "$(sbx 'echo n >n && ln n n2')"
check "link an outside file into the root" no "$(sbx "ln \"$HOME/plain.txt\" pulled")"
check "link an outside file into TMPDIR" no "$(sbx "ln \"$HOME/plain.txt\" \"$T/pulled\"")"
check "link from the root out to the home folder" no "$(sbx "ln n \"$HOME/pushed\"")"
check "link a secret into the root" no "$(sbx "ln \"$HOME/.ssh/id_test\" leaked")"

echo "== network"
PUBLIC='import socket,errno
s=socket.socket(); s.settimeout(3)
try: s.connect(("1.1.1.1",443)); print("connected")
except OSError as e: print("EPERM" if e.errno==errno.EPERM else "errno=%d" % e.errno)'
"$PY" -c "
import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR,1); s.bind(('127.0.0.1',0)); s.listen(5)
open('$TMP/hostport','w').write(str(s.getsockname()[1])); time.sleep(60)" &
listener=$!
for _ in $(seq 50); do [[ -s "$TMP/hostport" ]] && break; sleep 0.1; done
HOSTLISTENER="import socket,errno
s=socket.socket(); s.settimeout(3)
try: s.connect(('127.0.0.1',$(cat "$TMP/hostport"))); print('connected')
except OSError as e: print('EPERM' if e.errno==errno.EPERM else 'errno=%d' % e.errno)"
profile
check "default: a public address is EPERM" EPERM "$(errno "$PUBLIC")"
check "default: a host loopback listener is EPERM" EPERM "$(errno "$HOSTLISTENER")"
profile --network loopback
check "loopback: a public address is still EPERM" EPERM "$(errno "$PUBLIC")"
check "loopback: a host loopback listener is reachable" connected "$(errno "$HOSTLISTENER")"
profile --network true
check "true: a public connect is not refused by the sandbox" yes "$([[ "$(errno "$PUBLIC")" != EPERM ]] && echo yes || echo no)"
kill "$listener" 2>/dev/null || true; wait "$listener" 2>/dev/null || true

echo "== setup: IP network and DNS only, no unix sockets"
# Unix socket paths are capped at 104 bytes and run-all's TMPDIR is deep:
# every socket here is bound and reached by a short relative path.
"$PY" -c "
import socket,time,os; os.chdir('$TMP'); s=socket.socket(socket.AF_UNIX); s.bind('u.sock'); s.listen(1); time.sleep(30)" &
usock=$!
for _ in $(seq 50); do [[ -S "$TMP/u.sock" ]] && break; sleep 0.1; done
UNIX="import socket,errno
s=socket.socket(socket.AF_UNIX)
try: s.connect('../u.sock'); print('connected')
except OSError as e: print('EPERM' if e.errno==errno.EPERM else 'errno=%d' % e.errno)"
profile --setup
check "setup: a unix socket outside the root is EPERM" EPERM "$(errno "$UNIX")"
check "setup: DNS resolves (the mDNSResponder socket)" yes "$(errno 'import socket; socket.getaddrinfo("example.com", 443); print("yes")')"
profile --network true
check "--network true: a unix socket outside the root is EPERM" EPERM "$(errno "$UNIX")"
kill "$usock" 2>/dev/null || true; wait "$usock" 2>/dev/null || true

echo "== a proof's own unix socket"
# Bound by a relative name from inside TMPDIR: this test's TMPDIR path is
# longer than the 104 bytes a unix socket path may have.
OWNSOCK="import socket,os
os.chdir(os.environ['TMPDIR'])
s=socket.socket(socket.AF_UNIX); s.bind('own.sock'); s.listen(1)
c=socket.socket(socket.AF_UNIX); c.connect('own.sock')
a,_=s.accept(); c.sendall(b'x'); a.sendall(a.recv(1)); print('connected' if c.recv(1)==b'x' else 'no-echo')"
profile
check "default: a unix socket in its own TMPDIR works" connected "$(errno "$OWNSOCK")"
ROOTSOCK="import socket,errno
s=socket.socket(socket.AF_UNIX)
try: s.bind('in-root.sock'); s.listen(1); print('bound')
except OSError as e: print('EPERM' if e.errno==errno.EPERM else 'errno=%d' % e.errno)"
check "default: a unix socket in the checkout is refused" EPERM "$(errno "$ROOTSOCK")"
"$PY" -c "
import socket,time,os; os.chdir('$TMP'); s=socket.socket(socket.AF_UNIX); s.bind('u2.sock'); s.listen(1); time.sleep(30)" &
usock2=$!
for _ in $(seq 50); do [[ -S "$TMP/u2.sock" ]] && break; sleep 0.1; done
ln -sf "$TMP/u2.sock" "$T/link.sock"
SYMSOCK="import socket,errno,os
os.chdir(os.environ['TMPDIR'])
s=socket.socket(socket.AF_UNIX)
try: s.connect('link.sock'); print('connected')
except OSError as e: print('EPERM' if e.errno==errno.EPERM else 'errno=%d' % e.errno)"
check "default: a symlink in TMPDIR to an outside socket is refused" EPERM "$(errno "$SYMSOCK")"
CLIENTSOCK="import socket,errno,os
os.chdir(os.environ['TMPDIR'])
s=socket.socket(socket.AF_UNIX); s.bind('client.sock')
os.chdir('$ROOT')
try: s.connect('../u2.sock'); print('connected')
except OSError as e: print('EPERM' if e.errno==errno.EPERM else 'errno=%d' % e.errno)"
check "default: a client bound in TMPDIR cannot reach an outside socket" EPERM "$(errno "$CLIENTSOCK")"
kill "$usock2" 2>/dev/null || true; wait "$usock2" 2>/dev/null || true

echo "== setup and the dependency folder"
DEPS="$TMP/deps"; mkdir -p "$DEPS"
profile --deps "$DEPS"
check "a proof cannot write the dependency folder" no "$(sbx ": >\"$DEPS/x\"")"
profile --deps "$DEPS" --setup
check "setup writes the dependency folder" yes "$(sbx ": >\"$DEPS/x\" && ln \"$DEPS/x\" \"$DEPS/y\"")"
check "setup has the network" yes "$([[ "$(errno "$PUBLIC")" != EPERM ]] && echo yes || echo no)"
check "setup still cannot read a secret" no "$(sbx "cat \"$HOME/.ssh/id_test\"")"
check "pnpm's trust lookup only under setup" "1 0" \
  "$(grep -c trustd "$TMP/p.sb") $("$GEN" --root "$ROOT" --tmp "$T" | grep -c trustd || true)"

echo "== escapes"
profile
# A mach lookup straight from a process, not through a refused executable:
# bootstrap_look_up of securityd returns 1100 (BOOTSTRAP_NOT_PRIVILEGED).
MACH='import ctypes, ctypes.util
lib = ctypes.CDLL(ctypes.util.find_library("System"))
port = ctypes.c_uint(0)
print(lib.bootstrap_look_up(ctypes.c_uint.in_dll(lib, "bootstrap_port"), b"com.apple.SecurityServer", ctypes.byref(port)))'
check "outside the sandbox securityd is found" 0 "$("$PY" -c "$MACH")"
check "a mach lookup of securityd is refused" 1100 "$(errno "$MACH")"
profile --setup
check "a mach lookup of securityd is refused under setup too" 1100 "$(errno "$MACH")"
profile
check "open is refused" no "$(sbx '/usr/bin/open -g -j -a Calculator')"
check "osascript is refused" no "$(sbx "/usr/bin/osascript -e 'return 1'")"
check "security is refused" no "$(sbx '/usr/bin/security list-keychains')"
check "a nested sandbox-exec is refused" no "$(sbx "/usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/touch \"$HOME/nested\"")"
check "the output file takes the proof's output" yes "$(sbx 'echo through-out' >/dev/null; has through-out "$(cat "$OUT")")"

echo "== the secrets-in-checkout scan"
# shellcheck disable=SC1091
source "$HERE/lib/proof-sandbox.sh"
SC="$TMP/scan"; mkdir -p "$SC/sub/deeper" "$SC/node_modules/pkg" "$SC/.git"
scan() { secrets_in_checkout "$SC" | sed "s|^$SC/||" | paste -sd ' ' -; }
check "a clean checkout: nothing" "" "$(scan)"
secrets_in_checkout "$SC" >/dev/null && rc=0 || rc=$?
check "a clean checkout: exit 0" 0 "$rc"
: >"$SC/.env.example"; : >"$SC/.env.sample"; : >"$SC/.env.template"; : >"$SC/node_modules/pkg/.env"; : >"$SC/.git/.env"
check "examples, node_modules and .git are not hits" "" "$(scan)"
: >"$SC/.env"; : >"$SC/sub/.ENV.local"; : >"$SC/sub/deeper/.env.prod"
ln -s "$HOME/plain.txt" "$SC/sub/.env.link"; mkdir -p "$SC/.env.d"
check "every live .env entry, any case, depth, a symlink and a folder" ".env .env.d sub/.ENV.local sub/.env.link sub/deeper/.env.prod" "$(scan)"
secrets_in_checkout "$SC" >/dev/null && rc=0 || rc=$?
check "hits: exit 1" 1 "$rc"

echo "== the hard-link pre-check"
HL="$TMP/hl"; mkdir -p "$HL/tree/.git/objects/ab" "$HL/elsewhere"
echo a >"$HL/tree/a"; ln "$HL/tree/a" "$HL/tree/a2"
hl() { python3 "$HERE/lib/hardlink-check.py" "$HL/tree" | sed "s|^$HL/||" | paste -sd ' ' -; }
check "links wholly inside the tree: fine" "" "$(hl)"
echo s >"$HL/elsewhere/secret"; ln "$HL/elsewhere/secret" "$HL/tree/leak"
check "a name outside the tree: found" "tree/leak" "$(hl)"
python3 "$HERE/lib/hardlink-check.py" "$HL/tree" >/dev/null && rc=0 || rc=$?
check "  ...exit 1" 1 "$rc"
check "  ...not when the other tree is walked too" "" "$(python3 "$HERE/lib/hardlink-check.py" "$HL/tree" "$HL/elsewhere" | paste -sd ' ' -)"
rm "$HL/tree/leak"
echo o >"$HL/elsewhere/obj"; chmod 444 "$HL/elsewhere/obj"; ln "$HL/elsewhere/obj" "$HL/tree/.git/objects/ab/cdef"
check "a read-only git object linked from another repo: skipped" "" "$(hl)"
echo w >"$HL/elsewhere/wobj"; ln "$HL/elsewhere/wobj" "$HL/tree/.git/objects/ab/planted"
check "a writable file planted under objects/: found" "tree/.git/objects/ab/planted" "$(hl)"

check "a checkout made to look like a gitdir gets no objects exception" "tree/objects/ab/cd" \
  "$(mkdir -p "$HL/tree/objects/ab" && : >"$HL/tree/HEAD" && echo r >"$HL/elsewhere/ro" && chmod 444 "$HL/elsewhere/ro" && ln "$HL/elsewhere/ro" "$HL/tree/objects/ab/cd" && hl | tr ' ' '\n' | grep -x 'tree/objects/ab/cd')"
check "a read-only FIFO under a gitdir's objects/ is still checked" yes \
  "$(mkfifo "$HL/elsewhere/fifo" && chmod 444 "$HL/elsewhere/fifo" && mkdir -p "$HL/gd/objects/zz" && ln "$HL/elsewhere/fifo" "$HL/gd/objects/zz/f"; found="$(python3 "$HERE/lib/hardlink-check.py" --gitdir "$HL/gd" || true)"; [[ "$found" == *objects/zz/f* ]] && echo yes || echo no)"
check "  ...but a tree named --gitdir does" "" \
  "$(python3 "$HERE/lib/hardlink-check.py" --gitdir "$HL/tree" | grep 'objects/ab/cd' || true)"

echo "== proof_network in GOALS.md"
for v in loopback true false yes True; do
  sed "s/^journal: .*/&\nproof_network: $v/" "$HERE/../GOALS.example.md" >"$TMP/G.md"
  python3 "$HERE/goals.py" "$TMP/G.md" validate >/dev/null 2>&1 && r=accepted || r=refused
  case "$v" in loopback | true) want=accepted ;; *) want=refused ;; esac
  check "proof_network: $v is $want" "$want" "$r"
done
check "proof_network absent: none" none "$(python3 "$HERE/goals.py" "$HERE/../GOALS.example.md" meta | python3 -c 'import json,sys; print(json.load(sys.stdin)["proof_network"])')"

echo "== the self-test"
proof_sandbox_selftest >"$TMP/st" && rc=0 || rc=$?
check "the self-test passes on this machine" 0 "$rc"
# On a copy of lib/ (never the house's own: other tests run beside this one).
cp -R "$HERE/lib" "$TMP/libcopy" && rm "$TMP/libcopy/proof-sandbox.py"
(source "$TMP/libcopy/proof-sandbox.sh" && proof_sandbox_selftest) >"$TMP/st" && rc=0 || rc=$?
check "the self-test fails when the profile cannot be made" 1 "$rc"
check "  ...and says why" yes "$(has 'generator failed' "$(cat "$TMP/st")")"
# A sandbox-exec that runs the command unsandboxed must fail the self-test.
printf '#!/bin/bash\nshift 2; exec "$@"\n' >"$TMP/fake-sbx"; chmod +x "$TMP/fake-sbx"
cp -R "$HERE/lib" "$TMP/libfake"
sed -i '' "s|^PSB_SANDBOX_EXEC=/usr/bin/sandbox-exec$|PSB_SANDBOX_EXEC=$TMP/fake-sbx|" "$TMP/libfake/proof-sandbox.sh"
check "the fake is planted in the copy only" "1 0" \
  "$(grep -c "fake-sbx" "$TMP/libfake/proof-sandbox.sh") $(grep -c "fake-sbx" "$HERE/lib/proof-sandbox.sh")"
(source "$TMP/libfake/proof-sandbox.sh" && proof_sandbox_selftest) >"$TMP/st" && rc=0 || rc=$?
check "an unsandboxed sandbox-exec fails the self-test" 1 "$rc"
check "  ...named: the write outside" yes "$(has 'write outside the root' "$(cat "$TMP/st")")"
check "  ...named: the secret" yes "$(has 'secret-list file' "$(cat "$TMP/st")")"
check "  ...named: the network" yes "$(has 'public connect' "$(cat "$TMP/st")")"

if [[ "$fails" -eq 0 ]]; then
  echo "proof-sandbox-test: all passed"
else
  echo "proof-sandbox-test: $fails failed" >&2
  exit 1
fi
