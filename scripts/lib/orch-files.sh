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

# orch_host_ledger GOAL — the records run-goal.sh wrote for GOAL in this
# checkout, one a line (journal_line appends each before writing it to the
# journal). What a resume reads (lib/resume-state.py), not the journal. Under
# the goal's artifact folder, which outlives a stop and which the implementer's
# sandbox cannot write (a proof under CW_PROOF_SANDBOX=off runs its code
# unsandboxed and could); keyed by the checkout's own git dir (a linked
# worktree's, not the common one), so two checkouts of one plan, a --jobs
# member and the main checkout included, keep apart (FUTURE-WORK item 25).
# Fails, printing nothing, when git names no git dir (host git off after a
# tamper): a key of nothing would join every checkout's ledger.
orch_host_ledger() {
  local dir
  dir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  [[ -n "$dir" ]] || return 1
  printf '%s\n' "$HOME/.cache/claude-coding-workflow/run-goal-$1/host-records-$(printf '%s' "$dir" | shasum | cut -c1-12)"
}

# The journal against HEAD, in MODE (lib/orch-files.py), for goal $2 when the
# mode takes one; --records also holds ORCHESTRATOR records to the goal's
# ledger (FUTURE-WORK item 25). One problem a line.
orch_journal_problems() {
  local mode="$1" goal="${2:-}" head host=()
  [[ -n "${JOURNAL:-}" ]] || return 0
  head="$(mktemp "${TMPDIR:-/tmp}/orch-journal-XXXXXX")"
  if ! git show "HEAD:$JOURNAL" >"$head" 2>/dev/null; then
    rm -f "$head"
    echo "$JOURNAL: not committed"
    return 0
  fi
  # run-goal.sh keyed its goal's ledger once, while git was trusted (HOST_LEDGER);
  # a ledger that cannot be keyed holds nothing.
  if [[ "$mode" == --records && -n "$goal" ]]; then
    if [[ "$goal" == "${GOAL_ID:-}" && -n "${HOST_LEDGER:-}" ]]; then
      host=(--host "$HOST_LEDGER")
    else
      host=(--host "$(orch_host_ledger "$goal" || echo /nonexistent/no-ledger)")
    fi
  fi
  { python3 "$ORCH_FILES_PY" journal "$head" "$JOURNAL" "$mode" ${goal:+"$goal"} "${host[@]+"${host[@]}"}" || true; } |
    sed "s|^|$JOURNAL: |"
  rm -f "$head"
}

# The journal along its history since BASE (lib/orch-files.py journal-chain):
# its copy at BASE, at each first-parent commit that touched it, then the
# working copy. HEAD can carry a committed edit of a record, which the check
# against HEAD alone does not see. One problem a line.
orch_journal_chain_problems() {
  local base="$1" dir c revs args=()
  [[ -n "${JOURNAL:-}" ]] || return 0
  # Fail closed: run-goal.sh needs the journal committed before BASE_SHA is
  # set, so a copy or a history it cannot read is a problem, not a pass.
  if ! revs="$(git rev-list --reverse --first-parent "$base..HEAD" -- "$JOURNAL")"; then
    echo "$JOURNAL: its history since ${base:0:12} cannot be listed"
    return 0
  fi
  dir="$(mktemp -d "${TMPDIR:-/tmp}/orch-chain-XXXXXX")"
  if ! git show "$base:$JOURNAL" >"$dir/base" 2>/dev/null; then
    rm -rf "$dir"
    echo "$JOURNAL: not committed at BASE_SHA ${base:0:12}"
    return 0
  fi
  args=("BASE_SHA ${base:0:12}" "$dir/base")
  for c in $revs; do
    git show "$c:$JOURNAL" >"$dir/$c" 2>/dev/null || rm -f "$dir/$c"
    args+=("commit ${c:0:12}" "$dir/$c")
  done
  args+=("the working copy" "$JOURNAL")
  { python3 "$ORCH_FILES_PY" journal-chain "${args[@]}" || true; } | sed "s|^|$JOURNAL: |"
  rm -rf "$dir"
}

# The journal must still start with FILE, taken before a pass that may also
# rewrite the history the chain walks (lib/orch-files.py --prefix).
orch_journal_kept_problems() {
  local file="$1" label="$2"
  [[ -n "${JOURNAL:-}" && -f "$file" ]] || return 0
  { python3 "$ORCH_FILES_PY" journal "$file" "$JOURNAL" --prefix || true; } |
    sed "s|^|$JOURNAL: against $label: |"
}

orch_staged_problems() {
  local f
  for f in GOALS.md ${JOURNAL:+"$JOURNAL"}; do
    git diff --cached --quiet -- "$f" 2>/dev/null || echo "$f: has staged changes"
  done
}

# Before the first write: nothing staged, and each file equal to HEAD except
# the in-flight state a stopped run leaves (GOALS_ALLOW, JOURNAL_MODE, and the
# goal whose records the journal may already carry). Sets ORCH_PROBLEMS
# ("; "-joined); returns 1 when refused.
orch_preflight() {
  ORCH_PROBLEMS="$({
    orch_staged_problems
    orch_goals_problems "$1"
    orch_journal_problems "$2" "${3:-}"
  } | paste -sd ';' - | sed 's/;/; /g')"
  [[ -z "$ORCH_PROBLEMS" ]]
}

orch_refusal() {
  echo "GOALS.md / journal carry edits this workflow did not make — $ORCH_PROBLEMS. Nothing was committed. Commit them yourself (git commit -- GOALS.md ${JOURNAL:-<journal>}) or restore them, then rerun."
}
