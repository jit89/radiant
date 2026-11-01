#!/usr/bin/env bash
#
# logs.sh — query the host event index (JSONL in cache).
# Run from the target repo (the directory that holds GOALS.md).
#
#   logs.sh errors   [--last N] [--since 5m|ISO|walk] [--goal ID]
#   logs.sh warnings [--last N] [--since 5m|ISO|walk] [--goal ID]
#   logs.sh last [N]
#   logs.sh goal <id>
#   logs.sh walk [current|<walk_id>]
#   logs.sh since <5m|ISO|walk>
#   logs.sh path
#
# Journal.md is still the source of truth. This is the machine index.
# Models call these verbs; do not invent SQL.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
EVENTS_PY="$HERE/events.py"
GOALS_PY="$HERE/goals.py"

usage() {
  echo "usage: logs.sh errors|warnings|last|goal|walk|since|path [args]" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
cmd="$1"
shift

JOURNAL="${JOURNAL:-}"
if [[ -z "$JOURNAL" && -f GOALS.md ]]; then
  JOURNAL="$("$GOALS_PY" GOALS.md meta | python3 -c 'import json,sys; print(json.load(sys.stdin).get("journal") or "")')"
fi
[[ -n "$JOURNAL" ]] || {
  echo "logs.sh: no journal (run from a repo with GOALS.md, or set JOURNAL=)" >&2
  exit 1
}

take_last() {
  if [[ $# -gt 0 && "${1:-}" =~ ^[0-9]+$ ]]; then
    extra+=(--last "$1")
    return 0
  fi
  extra+=(--last 20)
  return 1
}

extra=()
case "$cmd" in
  errors)
    extra=(--errors)
    take_last "$@" && shift || true
    ;;
  warnings)
    extra=(--warnings)
    take_last "$@" && shift || true
    ;;
  last)
    extra=()
    take_last "$@" && shift || true
    ;;
  goal)
    [[ $# -ge 1 ]] || usage
    extra=(--goal "$1")
    shift
    ;;
  walk)
    extra=(--walk "${1:-current}")
    [[ $# -gt 0 ]] && shift || true
    ;;
  since)
    [[ $# -ge 1 ]] || usage
    extra=(--since "$1")
    shift
    ;;
  path)
    python3 "$EVENTS_PY" path "$JOURNAL"
    exit 0
    ;;
  -h|--help) usage ;;
  *) usage ;;
esac

# Further flags (--since, --goal, --json, --last, --errors, --warnings, --walk)
# pass through so `logs.sh errors --since 5m --goal g1` works. The first
# positional after `errors`/`warnings`/`last` is already consumed as N.
while [[ $# -gt 0 ]]; do
  extra+=("$1")
  shift
done

python3 "$EVENTS_PY" query "$JOURNAL" "${extra[@]}"
