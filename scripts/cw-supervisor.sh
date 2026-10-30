#!/usr/bin/env bash
# cw-supervisor.sh — the always-on supervisor (docs/features/always-on/PLAN.md
# step 4), as the LaunchAgent com.cw.always-on runs it under `caffeinate -is`.
# The loop is lib/always-on-supervisor.py; this file is what install.sh names
# and what `cw-decide.sh sign` uses to recognise the house (it refuses it).
set -euo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd)/lib/always-on-supervisor.py" "$@"
