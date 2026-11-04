#!/usr/bin/env bash
# postgres-probe.sh — can Postgres run inside a proof? (rust-axum-sqlx-rules
# step 2b, the stopped Postgres half; FUTURE-WORK item 35.) Every probe runs
# through the house's proof_exec under the proof sandbox, with TMPDIR placed
# where run-goal.sh puts it ($HOME/.cache/claude-coding-workflow/runs/
# run-goal-<id>-XXXXXX/tmp). The console transcript is the evidence:
#   fixture/postgres-probe.sh > postgres-probe.txt 2>&1
# Needs Homebrew postgresql@18 (keg-only) at PG.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOUSE="$(cd "$HERE/../../../.." && pwd)"
PG="${PG:-/opt/homebrew/opt/postgresql@18/bin}"
WORK="${AXS_WORK:-$HOME/dogfood/axum-sqlx}"
RUNS="$HOME/.cache/claude-coding-workflow/runs"
export CW_PROOF_DENIALS=off
# shellcheck disable=SC1091
source "$HOUSE/scripts/lib/proof.sh"
git() { command git "$@"; }
ROOT="$WORK/probe-root"
mkdir -p "$ROOT" "$WORK/logs"
"$PG/postgres" --version

denials() {
  sleep 3
  /usr/bin/log show --start "$1" --predicate 'sender == "Sandbox"' --style compact 2>/dev/null |
    grep 'deny(' | grep -v 'vfs\.disk-space' | sed 's/.*Sandbox: //; s/([0-9]*)//' | sort | uniq -c | sort -rn || true
}
# segments created by PID, then removed: a refused shmctl(IPC_RMID) would
# otherwise leave one behind.
reap_segments() {
  local pid="$1" id cpid
  [[ -n "$pid" ]] || return 0
  ipcs -m -p | awk 'NR>3 && $1=="m" {print $2, $7}' | while read -r id cpid; do
    if [[ "$cpid" == "$pid" ]]; then echo "removing System V segment $id (created by postgres pid $pid)"; ipcrm -m "$id"; fi
  done
}
probe() {
  local id="$1" mode="$2" label="$3" base tmp out start rc=0 pid cmd
  base="$(mktemp -d "$RUNS/run-goal-$id-XXXXXX")"; tmp="$base/tmp"; out="$WORK/logs/pgprobe-$label.log"
  mkdir -p "$tmp" && chmod 700 "$tmp"
  echo "== $label: goal id ${#id} chars; socket path $(( ${#tmp} + 15 )) bytes ($tmp/.s.PGSQL.5432)"
  local initdb="'$PG/initdb' -D \"\$TMPDIR/pg\" -U postgres -A trust --no-sync --locale=C --encoding=UTF8 >/dev/null"
  if [[ "$mode" == server-only ]]; then
    "$PG/initdb" -D "$tmp/pg" -U postgres -A trust --no-sync --locale=C --encoding=UTF8 >/dev/null 2>&1 && echo "initdb outside the sandbox: ok"
    initdb=":"
  fi
  cmd="$initdb &&
{ '$PG/postgres' -D \"\$TMPDIR/pg\" -k \"\$TMPDIR\" -c listen_addresses='' -c shared_memory_type=mmap -c dynamic_shared_memory_type=mmap -F & PGPID=\$!; } &&
trap 'kill \$PGPID 2>/dev/null; wait \$PGPID 2>/dev/null' EXIT &&
for i in \$(seq 100); do [ -S \"\$TMPDIR/.s.PGSQL.5432\" ] && break; sleep 0.1; done &&
'$PG/psql' -h \"\$TMPDIR\" -U postgres -d postgres -Atc 'select 1' && echo PROBE-OK"
  start="$(date '+%Y-%m-%d %H:%M:%S')"
  PROOF_ROOT="$ROOT" PROOF_NETWORK=none proof_exec 60 "$out" "$tmp" "$cmd" || rc=$?
  echo "rc=$rc; reached the server: $(grep -c PROBE-OK "$out")"
  grep -E 'FATAL|could not|shmctl|Operation not permitted' "$out" | head -4
  pid="$(sed -n 's/.*\[\([0-9]*\)\] FATAL.*/\1/p' "$out" | head -1)"
  [[ -f "$tmp/pg/postmaster.pid" ]] && pid="$(head -1 "$tmp/pg/postmaster.pid")"
  if [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1; then echo "LEFTOVER postgres pid $pid"; kill "$pid"; else echo "no leftover server"; fi
  reap_segments "$pid"
  echo "-- denials:"; denials "$start"
  rm -rf "$base"
}
probe g1 full initdb-inside-id2
probe parse-notes1 full initdb-inside-id12
probe notes-create-and-get-24 full initdb-inside-id23
probe g1 server-only server-inside-id2
echo "-- System V segments owned by $(id -un) after the probes:"; ipcs -m | awk -v u="$(id -un)" '$5==u'
