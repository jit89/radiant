# shellcheck shell=bash
# GOALS.md and the journal are the orchestrators' to commit, and a commit takes
# the whole file: an edit someone else left there would ride along as
# "orchestrator" work. So both scripts refuse, before their first write, edits
# they did not make (a stopped run's own state excepted), and check each file
# again right before committing it.
#
# Needs GOALS_PY, JOURNAL and the git() wrapper (lib/git-guard.sh).

ORCH_FILES_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/orch-files.py"
ORCH_PROBLEMS=""

# GOALS.md against HEAD: equal except status moves ALLOW permits
# ("<id>=<old>:<new>,...", "*" = any; empty permits none). One problem a line.
orch_goals_problems() {
  local allow="$1" head
  head="$(mktemp "${TMPDIR:-/tmp}/orch-goals-XXXXXX")"
  if ! git show HEAD:GOALS.md >"$head" 2>/dev/null; then
    rm -f "$head"
    echo "GOALS.md: not committed"
    return 0
  fi
  { "$GOALS_PY" GOALS.md status-transitions "$head" "$allow" || true; } | sed 1d | sed 's/^/GOALS.md: /'
  rm -f "$head"
}

# The journal against HEAD, in MODE (lib/orch-files.py). One problem a line.
orch_journal_problems() {
  local mode="$1" head
  [[ -n "${JOURNAL:-}" ]] || return 0
  head="$(mktemp "${TMPDIR:-/tmp}/orch-journal-XXXXXX")"
  if ! git show "HEAD:$JOURNAL" >"$head" 2>/dev/null; then
    rm -f "$head"
    echo "$JOURNAL: not committed"
    return 0
  fi
  { python3 "$ORCH_FILES_PY" journal "$head" "$JOURNAL" "$mode" || true; } | sed "s|^|$JOURNAL: |"
  rm -f "$head"
}

orch_staged_problems() {
  local f
  for f in GOALS.md ${JOURNAL:+"$JOURNAL"}; do
    git diff --cached --quiet -- "$f" 2>/dev/null || echo "$f: has staged changes"
  done
}

# Before the first write: nothing staged, and each file equal to HEAD except
# the in-flight state a stopped run leaves (GOALS_ALLOW, JOURNAL_MODE). Sets
# ORCH_PROBLEMS ("; "-joined); returns 1 when refused.
orch_preflight() {
  ORCH_PROBLEMS="$({
    orch_staged_problems
    orch_goals_problems "$1"
    orch_journal_problems "$2"
  } | paste -sd ';' - | sed 's/;/; /g')"
  [[ -z "$ORCH_PROBLEMS" ]]
}

orch_refusal() {
  echo "GOALS.md / journal carry edits this workflow did not make — $ORCH_PROBLEMS. Nothing was committed. Commit them yourself (git commit -- GOALS.md ${JOURNAL:-<journal>}) or restore them, then rerun."
}
