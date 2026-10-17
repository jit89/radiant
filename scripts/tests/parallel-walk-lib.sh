# shellcheck shell=bash
# Shared setup for parallel-walk-test.sh and parallel-walk-trust-test.sh: the
# temp HOME, check(), a house copy whose implementer and reviewer are stubs, and
# the four-goal fixture. Not named *-test.sh, so run-all.sh does not run it.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOALS_PY="$HERE/goals.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-${PW_NAME:-parallel}-XXXXXX")"
export TMPDIR="$TMP"
trap '[[ -n "${KEEP_TMP:-}" ]] || rm -rf "$TMP"' EXIT
export HOME="$TMP/home" EVENTS_CACHE="$TMP/cache"
# These scenarios test the walker's logic, and their proofs and setups record
# themselves in $CALLS, outside the checkout, which the proof sandbox (house
# item 12) refuses. They run unsandboxed; the sandbox in a walk has its own
# block at the end of parallel-walk-test.sh (CW_PROOF_SANDBOX unset there).
export CW_PROOF_SANDBOX=off
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
# No background auto-maintenance: a detached repack still writing .git/objects
# races the next scenario's rm -rf of the repo.
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
unset ANTHROPIC_API_KEY
mkdir -p "$HOME"
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

# --- the stubbed house and the fixture ---------------------------------------
# The real run-goals.sh and run-goal.sh; the implementer and the reviewer are
# stubs. g1-a and g2-b run together; g3-c names g1-a in conflicts_with, so it
# waits; g4-d is blocked by g1-a and g2-b.
HOUSE="$TMP/house"
mkdir -p "$HOUSE/scripts"
cp -R "$HERE/." "$HOUSE/scripts/"
CALLS="$TMP/calls"
mkdir -p "$CALLS"
export CALLS
# goals.py for a stub action that edits GOALS.md inside a worktree.
export STUB_GOALS="$HOUSE/scripts/goals.py"
cat >"$HOUSE/scripts/claude-implement.sh" <<'SH'
#!/usr/bin/env bash
# Stub implementer: writes <letter>.txt for its goal and commits it.
hand="${@: -1}"
gid="$(sed -n 's/^# .*Handoff: \(g[0-9]*-[a-z0-9-]*\).*/\1/p' "$hand" | head -n1)"
# The full arguments in a file of the goal's own: two stubs appending ~3 KB
# lines to one file at once can interleave them. The shared log gets a short
# line (an O_APPEND write under PIPE_BUF is not split).
printf '%s\n' "$*" >"$CALLS/args-$gid"
printf '%s\n' "$gid" >>"$CALLS/implement"
letter="${gid#*-}"
[[ -f "$CALLS/sleep-$gid" ]] && sleep "$(cat "$CALLS/sleep-$gid")"
if [[ -f "$CALLS/action-$gid" ]]; then
  source "$CALLS/action-$gid"
else
  echo "$gid" >"$letter.txt"
  git add "$letter.txt" && git commit -qm "feat($gid): $letter"
fi
printf '%s\n' "IMPLEMENTER_RESULT: ok" "THREAD_ID: haiku:t-$gid" "IMPLEMENTER_STATUS: DONE" "IMPLEMENTER_MODEL: stub"
SH
cat >"$HOUSE/scripts/claude-goal-review.sh" <<'SH'
#!/usr/bin/env bash
brief="${@: -1}"
gid="$(sed -n 's/^GOAL: //p' "$brief")"
v="$CALLS/verdict-$gid-$RANDOM.md"
verdict=DONE
[[ -f "$CALLS/verdict-$gid" ]] && verdict="$(cat "$CALLS/verdict-$gid")"
# A process left running in the worktree, committing while the review runs.
[[ -f "$CALLS/review-action-$gid" ]] && source "$CALLS/review-action-$gid"
printf 'VERDICT: %s\n' "$verdict" >"$v"
printf '%s\n' "CLAUDE_REVIEW_RESULT: ok" "SESSION_ID: s-$gid" "VERDICT: $verdict" "VERDICT_FILE: $v" "CLAUDE_REVIEW_MODEL: stub"
SH
chmod +x "$HOUSE/scripts/claude-implement.sh" "$HOUSE/scripts/claude-goal-review.sh"

# pwalk_repo: a fresh target repo with the four-goal DAG.
pwalk_repo() {
  rm -rf "$TMP/prepo" "$CALLS"/* "$HOME/.cache/claude-coding-workflow/worktrees"
  mkdir -p "$TMP/prepo/docs/journal" && cd "$TMP/prepo"
  git init -q -b walk
  cat >GOALS.md <<'GM'
# Goals: parallel fixture

```yaml
plan: PLAN.md
journal: docs/journal/p.md
goals:
  - id: g1-a
    title: A
    blocked_by: []
    conflicts_with: []
    proof: test -f a.txt
    oracle: inline
    status: ready
  - id: g2-b
    title: B
    blocked_by: []
    conflicts_with: []
    proof: test -f b.txt
    oracle: inline
    status: ready
  - id: g3-c
    title: C
    blocked_by: []
    conflicts_with: [g1-a]
    proof: test -f c.txt
    oracle: inline
    status: ready
  - id: g4-d
    title: D
    blocked_by: [g1-a, g2-b]
    conflicts_with: []
    proof: test -f d.txt && test -f a.txt && test -f b.txt
    oracle: inline
    status: blocked
```

## g1-a — A

| in | out |
|----|-----|
| x  | a   |

## g2-b — B

| in | out |
|----|-----|
| x  | b   |

## g3-c — C

| in | out |
|----|-----|
| x  | c   |

## g4-d — D

| in | out |
|----|-----|
| x  | d   |
GM
  printf '# Plan\n' >PLAN.md
  printf '# Journal: p\n' >docs/journal/p.md
  git add -A && git commit -q -m base
}
prun() {
  "$HOUSE/scripts/run-goals.sh" "$@" >"$TMP/pout" 2>&1 && prc=0 || prc=$?
  plast="$(tail -n1 "$TMP/pout")"
  pstop="$(sed -n 's/^STOP_FILE: //p' <<<"$plast")"
}
status_of() { "$GOALS_PY" GOALS.md show "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])'; }
jcount() { grep -c -- "$1" docs/journal/p.md || true; }
WTROOT="$HOME/.cache/claude-coding-workflow/worktrees"


reason_in() { sed -n "s/^- $1: \(.*\) — .*/\1/p" "$pstop" 2>/dev/null | head -n1; }
wt_of() { printf '%s' "$(ls -d "$WTROOT"/*/"$1" 2>/dev/null | head -n1)"; }

# wave_result_after MARKER GOAL — the GOAL.result file in a wave folder made
# after MARKER (a file touched before the walker started), or nothing. A test
# waiting on the newest folder alone can match an earlier scenario's.
wave_result_after() {
  local d
  d="$(find "$HOME/.cache/claude-coding-workflow/runs" -maxdepth 1 -name 'run-goals-wave-*' -newer "$1" 2>/dev/null | head -n1)"
  [[ -n "$d" && -s "$d/$2.result" ]] && echo "$d/$2.result"
  return 0
}

