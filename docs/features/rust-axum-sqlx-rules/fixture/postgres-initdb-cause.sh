#!/usr/bin/env bash
# postgres-initdb-cause.sh — which denial makes initdb fail inside a proof?
# Runs initdb under the real generated proof profile, then under the same
# profile plus one allow (mach-lookup com.apple.system.opendirectoryd.libinfo,
# the lookup behind getpwuid). The allow is a diagnostic only, never proposed
# for the profile. Output is the evidence:
#   fixture/postgres-initdb-cause.sh > postgres-initdb-cause.txt 2>&1
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOUSE="$(cd "$HERE/../../../.." && pwd)"
PG="${PG:-/opt/homebrew/opt/postgresql@18/bin}"
WORK="${AXS_WORK:-$HOME/dogfood/axum-sqlx}"
RUNS="$HOME/.cache/claude-coding-workflow/runs"
ROOT="$WORK/probe-root"; mkdir -p "$ROOT"
# ids of the user's System V segments, to remove any a try leaves behind (a
# server initdb starts can create one before a later step is refused).
seg_ids() { ipcs -m | awk -v u="$(id -un)" '$1=="m" && $5==u {print $2}' | sort; }
try() {
  local label="$1" extra="$2" base tmp prof rc=0 before id
  base="$(mktemp -d "$RUNS/run-goal-g1-XXXXXX")"; tmp="$base/tmp"; mkdir -p "$tmp" && chmod 700 "$tmp"
  prof="$base/p.sb"
  python3 "$HOUSE/scripts/lib/proof-sandbox.py" --root "$ROOT" --tmp "$tmp" >"$prof"
  [[ -z "$extra" ]] || echo "$extra" >>"$prof"
  echo "== $label"
  before="$(seg_ids)"
  (cd "$ROOT" && TMPDIR="$tmp" /usr/bin/sandbox-exec -f "$prof" "$PG/initdb" -D "$tmp/pg" -U postgres -A trust --no-sync --locale=C --encoding=UTF8 >"$base/out" 2>&1) || rc=$?
  echo "rc=$rc"; grep -E 'could not|Success|syncing' "$base/out" | head -3
  for id in $(comm -13 <(echo "$before") <(seg_ids)); do echo "removing System V segment $id left by this try"; ipcrm -m "$id"; done
  rm -rf "$base"
}
try "the proof profile as generated" ""
try "the same plus (allow mach-lookup (global-name \"com.apple.system.opendirectoryd.libinfo\"))" \
  '(allow mach-lookup (global-name "com.apple.system.opendirectoryd.libinfo"))'
