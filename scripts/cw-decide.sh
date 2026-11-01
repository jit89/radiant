#!/usr/bin/env bash
# cw-decide.sh — the user's commands for the always-on house, at the Mac
# (docs/features/always-on/PLAN.md step 14): status, sign, resume, skip, stop,
# start, doctor, heartbeat. The commands are lib/always-on-decide.py.
set -euo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd)/lib/always-on-decide.py" "$@"
