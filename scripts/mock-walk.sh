#!/usr/bin/env bash
#
# mock-walk.sh — fake a 4-goal run-goals walk. No DeepSeek, no Opus.
# Exercises refresh → progress bar → status flips. Usage:
#   mock-walk.sh            # temp repo, 1s per goal
#   mock-walk.sh --quick    # no sleep (install.sh --check)
#   mock-walk.sh --dir DIR  # reuse / print this repo
#
# Prints MOCK_DIR: on stdout.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GOALS_PY="$HERE/goals.py"
FIXTURE="$HERE/fixtures/GOALS.mock.md"
SLEEP=1
DIR=""

usage() {
  echo "usage: mock-walk.sh [--quick] [--dir DIR]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) SLEEP=0; shift ;;
    --dir)
      [[ $# -ge 2 ]] || usage
      DIR="$2"
      shift 2
      ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

if [[ -z "$DIR" ]]; then
  DIR="$(mktemp -d "${TMPDIR:-/tmp}/grok-mock-walk-XXXXXX")"
fi
mkdir -p "$DIR/docs/journal"
cd "$DIR"

if [[ ! -d .git ]]; then
  git init -q
  git -c user.email=mock@localhost -c user.name=mock \
    commit --allow-empty -q -m "chore: mock walk root"
fi
cp "$FIXTURE" GOALS.md
printf '# Journal: mock\n' > docs/journal/mock.md
git add -- GOALS.md docs/journal/mock.md
git -c user.email=mock@localhost -c user.name=mock \
  diff --cached --quiet || \
  git -c user.email=mock@localhost -c user.name=mock \
    commit -q -m "chore: mock DAG"

export GOALS_COLOR="${GOALS_COLOR:-1}"
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost

print_status() {
  echo "=== graph ==="
  "$GOALS_PY" GOALS.md graph
  echo "=== progress ==="
  "$GOALS_PY" GOALS.md progress
}

echo "MOCK_DIR: $DIR"
"$GOALS_PY" GOALS.md validate
print_status

while :; do
  "$GOALS_PY" GOALS.md refresh
  git add -- GOALS.md
  git diff --cached --quiet || git commit -q -m "chore: orchestrator refresh"
  print_status
  id="$("$GOALS_PY" GOALS.md frontier | head -n1)"
  if [[ -z "$id" || "$id" == "(empty)" ]]; then
    echo "=== walk-end ==="
    echo "MOCK_DIR: $DIR"
    exit 0
  fi
  echo "=== mock walk ${id} ==="
  "$GOALS_PY" GOALS.md set "$id" in_progress
  print_status
  if [[ "$SLEEP" != "0" ]]; then
    sleep "$SLEEP"
  fi
  "$GOALS_PY" GOALS.md set "$id" done
  git add -- GOALS.md
  git diff --cached --quiet || git commit -q -m "chore(${id}): mock done"
  echo "GOAL ${id} DONE"
done
