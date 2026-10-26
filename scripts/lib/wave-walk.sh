# shellcheck shell=bash
# The parallel walker: run-goals.sh --jobs N (N > 1) sources this in place of
# its one-goal-at-a-time loop and never returns from it.
# docs/features/parallel-walker/PLAN.md is the contract (steps 2-9 and
# Amendments 1-3; Amendment 3 wins where they differ).
#
# Fork-join waves. The walker takes the frontier, builds a wave of at most N
# goals no two of which name each other in conflicts_with, commits them
# in_progress (the wave base), cuts a fresh worktree per goal, runs
# worktree_setup, starts `run-goal.sh --worktree` in each and waits for all of
# them. At the join it checks each finished goal's result file against its
# branch, records every verified goal as `finished` in one commit, then
# integrates them one at a time in a scratch worktree (merge, setup, merged
# proofs, done) and fast-forwards the walk branch only when all of it is green.
# Nothing is ever reset. A goal that stopped is recut and starts fresh. The
# walker is the single writer of GOALS.md, of the walk branch and of every
# merge; goals report through their exit status (0 done, 3 bounced, else a
# stop) and, on done, the result file.
#
# Needs, from run-goals.sh: ROOT, HERE, GOALS_PY, RUN_GOAL, JOURNAL,
# JOURNAL_EXPECT, JOBS, REPO_ID, walk_stop, meta_stop, journal_line,
# walk_stuck, print_status, the git() wrapper, events_*, cw cache helpers.

# shellcheck disable=SC1091
source "$HERE/lib/proof.sh"

PROOF_SECS="${PROOF_TIMEOUT:-600}"
MAIN_ROOT="$(pwd -P)"
REPO_ID="${REPO_ID:-$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:16])' "$MAIN_ROOT")}"
WT_BASE="$CW_CACHE/worktrees/$REPO_ID"
# Verified result files, kept until the goal is integrated or recut: if the
# `finished` commit does not land, the next start writes it from these.
RESULTS_DIR="$WT_BASE/.results"
# Scratch worktrees for integration, one new folder per attempt.
INT_DIR="$WT_BASE/.integrate"
WAVE_DIR=""
WALK_BRANCH=""
WALK_TIP=""
GIT_COMMON=""
WORKTREE_SETUP=""
PLAN_PATH=""
WAVE_N=0
# Members of the running wave.
RUNNING_PIDS=()
RUNNING_IDS=()
EXIT_AT=()
# One "<goal>|<reason>|<stop file>" per stopped goal, for the combined stop.
STOPS=()
# Merge conflicts awaiting their automatic recut ("<goal> <verified sha>"), and
# the goals recut that way in this run (docs/features/merge-conflict-recut).
CONFLICT_RECUTS=()
RECUT_DONE=()
# 1 from a wave's start to its join's end (and while a start-of-walk
# integration runs): every stop then goes into the combined stop.
IN_WAVE=0
WAVE_STOPPING=0
# The scratch worktree of the integration in progress, named in a stop, and
# its admin folder as git created it: host git into it is pinned to these
# (Amendment 5), never reading its .git file or commondir.
CUR_SCRATCH=""
S_TREE=""
S_ADMIN=""
# A replace ref swaps the tree a merge or a merge-base sees while no ref moves.
# Ignored by every git the walker and its goals run.
export GIT_NO_REPLACE_OBJECTS=1

utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

wt_path() { printf '%s/%s' "$WT_BASE" "$1"; }

# The shared .git paths no goal may write (PLAN step 6, Amendment 1). Resolved
# from the main checkout, so a main checkout that is itself a linked worktree
# names its own HEAD and index.
main_git_path() { command git -C "$MAIN_ROOT" rev-parse --path-format=absolute --git-path "$1"; }

# Locks that must not exist when the walker writes: one left behind by a goal
# would make the walker's next ref update fail (Amendment 1).
stray_locks() {
  local p
  for p in "$(main_git_path HEAD).lock" "$(main_git_path index).lock" "$(main_git_path logs/HEAD).lock" \
    "$GIT_COMMON/packed-refs.lock" "$GIT_COMMON/refs/heads/$WALK_BRANCH.lock" \
    "$GIT_COMMON/logs/refs/heads/$WALK_BRANCH.lock"; do
    [[ ! -e "$p" ]] || echo "$p"
  done
  if [[ -d "$GIT_COMMON/refs/heads/cw" ]]; then
    find "$GIT_COMMON/refs/heads/cw" "$GIT_COMMON/logs/refs/heads/cw" -name '*.lock' 2>/dev/null || true
  fi
}

# walk_problem — "<reason>|<detail>" for the first thing that makes a walker
# git write unsafe, or nothing: HEAD is not the walk branch at the tip this
# walker last wrote, a stray lock, a replace ref. walk_check stops on it; the
# combined stop checks it before its own commit.
walk_problem() {
  local head locks replaced
  head="$(git symbolic-ref -q HEAD || echo detached)"
  if [[ "$head" != "refs/heads/$WALK_BRANCH" || "$(git rev-parse HEAD)" != "$WALK_TIP" ]]; then
    echo "walk-branch-moved|the main checkout is at $head $(git rev-parse --short HEAD 2>/dev/null), not $WALK_BRANCH at ${WALK_TIP:0:12}, which this walker last wrote. Something switched or committed in the main checkout during the walk. Put it back (git switch $WALK_BRANCH; inspect what was added), then rerun."
    return 0
  fi
  locks="$(stray_locks | paste -sd ' ' -)"
  if [[ -n "$locks" ]]; then
    echo "git-lock-stray|lock files left in the shared .git: $locks. A goal (or a crashed git) left them; nothing was deleted. Make sure no git process is running, look at them, delete them, then rerun."
    return 0
  fi
  replaced="$(git for-each-ref --format='%(refname)' refs/replace 2>/dev/null | paste -sd ' ' -)"
  if [[ -n "$replaced" ]]; then
    echo "git-replace-ref|refs/replace/ holds $replaced. A replace ref can swap the tree a merge sees; this walker ignores replace refs and will not go on while one exists. Inspect it (git replace -l), delete what you did not make (git replace -d <sha>), then rerun."
  fi
  return 0
}

# walk_check's test without the stop: 0 when the walker may write, else
# SOFT_WHY says why (the conflict recut inside wave_stop).
walk_ok() {
  local problem
  git_meta_verify "$GIT_META_SAVED" || { SOFT_WHY=".git changed: ${GIT_META_CHANGED}"; return 1; }
  problem="$(walk_problem)"
  [[ -z "$problem" ]] || { SOFT_WHY="${problem#*|}"; return 1; }
}

# Before every walker git write.
walk_check() {
  local problem
  problem="$(walk_problem)"
  [[ -z "$problem" ]] || walk_stop "${problem%%|*}" "${problem#*|}"
}

# A goal's stop as "<goal>|<reason>|<stop file>".
add_stop() { STOPS+=("$1|$2|$3"); }

# A goal's stop with its own small stop file.
goal_stop() {
  local g="$1" reason="$2" detail="$3" f
  f="$WAVE_DIR/$g-$reason-stop.md"
  printf '# Stop: %s\n\n- reason: %s\n- detail: %s\n- utc: %s\n' "$g" "$reason" "$detail" "$(utc)" >"$f"
  add_stop "$g" "$reason" "$f"
}

# run-goals.sh's walk_stop writes a stop of one reason and exits. While a wave
# or its join runs, or once a stop is collected, a walk-level stop goes into
# the combined stop instead (PLAN Amendment 3 D).
eval "$(declare -f walk_stop | sed '1s/^walk_stop /walk_stop_single /')"
walk_stop() {
  if [[ "$WAVE_STOPPING" -eq 0 ]] && { [[ "$IN_WAVE" -eq 1 ]] || ((${#STOPS[@]})); }; then
    goal_stop "(walk)" "$1" "$2"
    wave_stop 1
  fi
  walk_stop_single "$@"
}

# The preconditions for any walker commit, without stopping: "" when it is safe.
commit_problem() {
  local p
  p="$(walk_problem)"
  [[ -z "$p" ]] || { echo "${p%%|*}"; return 0; }
  if [[ -n "$JOURNAL" && -f "$JOURNAL" ]] && ! cmp -s "$JOURNAL" "$JOURNAL_EXPECT"; then
    echo "the journal holds more than the walker wrote"
    return 0
  fi
  p="$({ orch_staged_problems; orch_goals_problems "${1:-}"; } | paste -sd ';' -)"
  [[ -z "$p" ]] || echo "$p"
  return 0
}

# wave_commit MSG ALLOW [soft] — commit GOALS.md and the journal together, after
# the fail-closed checks: GOALS.md moved only by ALLOW, the journal is exactly
# what this walker expects, nothing else staged in either. Updates WALK_TIP. A
# refusal stops the walk, or with "soft" sets SOFT_WHY and returns 1 (the
# conflict recut, where walk_stop could exit without the stop file).
SOFT_WHY=""
wave_commit() {
  local msg="$1" allow="$2" soft="${3:-}" problems
  if [[ -n "$soft" ]]; then
    walk_ok || return 1
  else
    walk_check
  fi
  problems="$(commit_problem "$allow")"
  if [[ -n "$problems" ]]; then
    [[ -z "$soft" ]] || { SOFT_WHY="not committed ($msg): $problems"; return 1; }
    walk_stop orchestration-files-changed "not committed ($msg): $problems. Something other than the walker edited GOALS.md or the journal; review, then commit or restore."
  fi
  local files=(GOALS.md)
  [[ -n "$JOURNAL" && -f "$JOURNAL" ]] && files+=("$JOURNAL")
  if ! git add -- "${files[@]}"; then
    [[ -z "$soft" ]] || { SOFT_WHY="git add failed ($msg)"; return 1; }
    walk_stop commit-failed "$msg"
  fi
  if ! git diff --cached --quiet -- "${files[@]}"; then
    if ! git commit -q -m "$msg" -- "${files[@]}"; then
      [[ -z "$soft" ]] || { SOFT_WHY="the commit failed ($msg)"; return 1; }
      walk_stop commit-failed "$msg"
    fi
  fi
  WALK_TIP="$(git rev-parse HEAD)"
}

# expect_from_tree — the journal as the tree now holds it is what the walker
# expects (after a fast-forward the walker made itself).
expect_from_tree() {
  [[ -n "$JOURNAL" && -f "$JOURNAL" ]] && cp "$JOURNAL" "$JOURNAL_EXPECT"
  return 0
}

goal_field() { "$GOALS_PY" GOALS.md show "$1" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$2') or '')"; }

# conflicts A B — true when either names the other in conflicts_with.
conflicts() {
  python3 -c '
import json, sys
x, y, a, b = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), json.loads(sys.argv[4])
sys.exit(0 if y in (a.get("conflicts_with") or []) or x in (b.get("conflicts_with") or []) else 1)
' "$1" "$2" "$("$GOALS_PY" GOALS.md show "$1")" "$("$GOALS_PY" GOALS.md show "$2")"
}

branch_exists() { git show-ref --verify --quiet "refs/heads/cw/$1"; }

reason_of() { sed -n 's/^- reason: //p' "$1" 2>/dev/null | head -n1; }

# walk_record GOAL — from the walk journal at HEAD (walker-written, committed),
# what the walker last recorded for GOAL: "finished <sha>" when a `finished`
# record follows its last wave membership or recut, "member" when it was a
# wave member with no record since, "none" when it never was one.
walk_record() {
  local f="$WAVE_DIR/walk-journal-head"
  git show "HEAD:$JOURNAL" >"$f" 2>/dev/null || { echo error; return 0; }
  python3 - "$1" "$f" <<'PY' || echo error
import re, sys
g, path = sys.argv[1], sys.argv[2]
state = "none"
# Bytes, decoded with replacement: a goal record may carry invalid UTF-8.
text = open(path, "rb").read().decode("utf-8", "replace")
# "\n" only, as journal-merge.py does: \r and other separators are not a line
# start, so a goal record cannot hide a walker record behind one.
for line in text.split("\n"):
    m = re.match(r"^## \S+ — ORCHESTRATOR (wave \d+ |recut |finished )(.*)$", line)
    if not m:
        continue
    kind, rest = m.group(1).strip(), m.group(2)
    if not rest.split():
        continue
    if kind.startswith("wave") and g in rest.split()[0].split(","):
        state = "member"
    elif kind == "recut" and rest.split()[0] == g:
        state = "member"
    elif kind == "finished" and rest.split()[0] == g:
        h = re.search(r"head=([0-9a-f]{40}|[0-9a-f]{64})\b", rest)
        if h:
            state = "finished " + h.group(1)
print(state)
PY
}

# need_record VAR GOAL — walk_record into VAR, or a stop when the walk journal
# cannot be read. Not in $(...): the stop must end the walker, not a subshell.
need_record() {
  local r
  r="$(walk_record "$2")"
  [[ "$r" =~ ^(none|member|finished\ [0-9a-f]{40}|finished\ [0-9a-f]{64})$ ]] ||
    walk_stop journal-unreadable "the walk journal at HEAD could not be read for $2's record"
  printf -v "$1" '%s' "$r"
}

# check_result GOAL FILE — the goal's report against its branch (PLAN
# Amendment 3 B). Prints the done SHA, or a reason on stderr and returns 1.
check_result() {
  local g="$1" f="$2" reviewed done tip
  reviewed="$(sed -n 's/^reviewed=\([0-9a-f]*\)$/\1/p' "$f" 2>/dev/null | head -n1)"
  done="$(sed -n 's/^done=\([0-9a-f]*\)$/\1/p' "$f" 2>/dev/null | head -n1)"
  tip="$(git rev-parse -q --verify "refs/heads/cw/$g" || true)"
  if [[ -z "$reviewed" || -z "$done" ]]; then
    echo "no result file from $g (or it is malformed): $f" >&2
    return 1
  fi
  if [[ "$tip" != "$done" ]]; then
    echo "cw/$g is at ${tip:-nothing}, not at $done, the commit $g reported after its review. Something moved the branch." >&2
    return 1
  fi
  if [[ "$(git rev-parse -q --verify "$done^" || true)" != "$reviewed" ]] ||
    [[ "$(git -c core.quotePath=false diff --name-only "$reviewed" "$done")" != "$JOURNAL" ]]; then
    echo "$done is not a journal-only commit on $reviewed, the tip the reviewer judged" >&2
    return 1
  fi
  echo "$done"
}

# record_finished "GOAL SHA"... — one walker commit holding a `finished`
# record for each, before any of them is integrated.
record_finished() {
  local pair
  (($#)) || return 0
  # Checked before a line is written: a stop must not leave the journal dirty.
  walk_check
  for pair in "$@"; do
    journal_line "## $(utc) — ORCHESTRATOR finished ${pair%% *} head=${pair#* }"
  done
  wave_commit "chore: orchestrator finished $(for pair in "$@"; do printf '%s ' "${pair%% *}"; done)" ""
}

# The walker's own cut of a worktree; its admin folder, as git named it, kept
# for the deny list before any goal runs.
cut_worktree() {
  local g="$1" wt
  wt="$(wt_path "$g")"
  walk_check
  git worktree prune
  if ! git worktree add -q -b "cw/$g" "$wt" "$WAVE_BASE" >"$WAVE_DIR/$g.wtadd" 2>&1; then
    goal_stop "$g" worktree-add-failed "git worktree add of cw/$g at $wt failed: $(tail -n 2 "$WAVE_DIR/$g.wtadd" | paste -sd ' ' -). Remove what is left (git worktree remove -f -f $wt; git branch -D cw/$g) and rerun."
    return 1
  fi
  # Absolute even with worktree.useRelativePaths; read before any goal runs.
  command git -C "$wt" rev-parse --absolute-git-dir >"$WAVE_DIR/$g.admin" ||
    { goal_stop "$g" worktree-add-failed "cannot read the admin folder of $wt"; return 1; }
  return 0
}

# recut GOAL [SHA [REASON [soft]]] — drop a goal's old attempt: its journal
# suffix onto the walk journal when it passes the journal check (walker-only
# records refused), a `recut` record, then its worktree and branch are removed
# (PLAN Amendment 3 C). SHA: the commit to keep the suffix from (the verified
# one for a conflict, not the live branch); REASON goes on every form of the
# record; soft: a refusal sets SOFT_WHY and returns 1.
recut() {
  local g="$1" sha="${2:-}" reason="${3:-}" soft="${4:-}" tip base m note=""
  if [[ -n "$soft" ]]; then
    walk_ok || return 1
  else
    walk_check
  fi
  if [[ -n "$sha" ]] || branch_exists "$g"; then
    tip="${sha:-$(git rev-parse "refs/heads/cw/$g")}"
    base="$(git merge-base HEAD "$tip" || true)"
    if [[ -n "$base" ]]; then
      git show "$base:$JOURNAL" >"$WAVE_DIR/$g.rbase" 2>/dev/null || : >"$WAVE_DIR/$g.rbase"
      git show "HEAD:$JOURNAL" >"$WAVE_DIR/$g.rours"
      git show "$tip:$JOURNAL" >"$WAVE_DIR/$g.rtheirs" 2>/dev/null || cp "$WAVE_DIR/$g.rbase" "$WAVE_DIR/$g.rtheirs"
      if m="$(python3 "$HERE/lib/journal-merge.py" "$WAVE_DIR/$g.rbase" "$WAVE_DIR/$g.rours" "$WAVE_DIR/$g.rtheirs" "$g" "$WAVE_DIR/$g.rmerged")"; then
        cp "$WAVE_DIR/$g.rmerged" "$JOURNAL"
        cp "$WAVE_DIR/$g.rmerged" "$JOURNAL_EXPECT"
      else
        note=" abandoned-records-not-kept=($m)"
      fi
    fi
  fi
  # The reason first: a reader takes the goal id as the first word.
  journal_line "## $(utc) — ORCHESTRATOR recut $g${reason:+ reason=$reason}${note}"
  wave_commit "chore($g): orchestrator recut" "" "$soft" || return 1
  walker_mark "$g" recut
  # The record is in: the old result must never be integrated or kept again,
  # nor kept back by wave_stop's member scan from the wave's own copy.
  rm -f "$RESULTS_DIR/$g" "${WAVE_DIR:+$WAVE_DIR/$g.result}"
  git worktree remove -f -f "$(wt_path "$g")" 2>/dev/null || rm -rf "$(wt_path "$g")"
  git worktree prune
  if branch_exists "$g" && ! git branch -q -D "cw/$g"; then
    [[ -z "$soft" ]] || { SOFT_WHY="cannot delete cw/$g"; return 1; }
    walk_stop commit-failed "delete cw/$g"
  fi
}

# in_recut GOAL — true when GOAL was recut for a merge conflict in this run.
in_recut() {
  local s
  for s in ${RECUT_DONE[@]+"${RECUT_DONE[@]}"}; do [[ "$s" != "$1" ]] || return 0; done
  return 1
}

# The one stop file for everything that stopped (PLAN step 9, Amendment 3 D).
# It never exits any other way: a commit it cannot make safely is a note.
# in_stops GOAL — true when GOAL already has an entry in the combined stop.
in_stops() {
  local s
  for s in ${STOPS[@]+"${STOPS[@]}"}; do [[ "${s%%|*}" != "$1" ]] || return 0; done
  return 1
}

wave_stop() {
  local code="${1:-1}" dir stop s g r f ids="" why i
  trap - INT TERM
  WAVE_STOPPING=1
  # A conflict recut still queued is done first, without stopping on a refusal.
  flush_conflict_recuts soft
  # Every member of the wave, from its state (Amendment 5): nothing is lost
  # whatever order the join or a signal stopped in.
  for i in ${RUNNING_IDS[@]+"${!RUNNING_IDS[@]}"}; do
    g="${RUNNING_IDS[$i]}"
    ! in_stops "$g" || continue
    ! in_recut "$g" || continue
    [[ "$(goal_field "$g" status 2>/dev/null || true)" != done ]] || continue
    f="$(cat "$WAVE_DIR/$g.ptr" 2>/dev/null || true)"
    if [[ -z "${EXIT_AT[$i]:-}" ]]; then
      add_stop "$g" interrupted "$f"
      continue
    fi
    case "${RCS[$i]:-1}" in
      0)
        if check_result "$g" "$WAVE_DIR/$g.result" >"$WAVE_DIR/$g.why" 2>&1 && keep_result "$g"; then
          add_stop "$g" finished-not-integrated ""
        else
          add_stop "$g" integration-unverified "$WAVE_DIR/$g.why"
        fi
        ;;
      3) add_stop "$g" bounced-not-recorded "$f" ;;
      *)
        # TERMed before it could write its own stop file: no reason of its own.
        r="$(reason_of "$f" || true)"
        add_stop "$g" "${r:-interrupted}" "$f"
        ;;
    esac
  done
  dir="$(mktemp -d "$CW_CACHE/runs/run-goals-wave-stop-XXXXXX")"
  chmod 700 "$dir"
  stop="$dir/stop.md"
  for s in ${STOPS[@]+"${STOPS[@]}"}; do
    IFS='|' read -r g r f <<<"$s"
    ids="${ids:+$ids,}$g:$r"
  done
  why="$(commit_problem "")"
  if [[ -z "$why" ]]; then
    journal_line "## $(utc) — ORCHESTRATOR wave-stop $WAVE_N $ids"
    git add -- GOALS.md "$JOURNAL" 2>/dev/null &&
      git commit -q -m "chore: orchestrator wave-stop" -- GOALS.md "$JOURNAL" 2>/dev/null &&
      WALK_TIP="$(git rev-parse HEAD)" || why="the wave-stop commit failed"
  fi
  {
    printf '# Stop: walk (wave %s)\n\n- reason: wave-stop\n- utc: %s\n' "$WAVE_N" "$(utc)"
    printf -- '- detail: %s stop(s); each has its own stop file below. A goal listed finished-not-integrated passed review and is recorded as finished: a rerun integrates it without dispatch.\n' "${#STOPS[@]}"
    [[ -z "$why" ]] || printf -- '- wave-stop line not committed: %s\n' "$why"
    [[ -z "$CUR_SCRATCH" ]] || printf -- '- an integration was in progress in the scratch worktree %s (kept; git -C %s merge --abort if a merge is open)\n' "$CUR_SCRATCH" "$CUR_SCRATCH"
    printf '\n## Stopped\n'
    for s in ${STOPS[@]+"${STOPS[@]}"}; do
      IFS='|' read -r g r f <<<"$s"
      printf -- '- %s: %s — %s\n' "$g" "$r" "${f:-(no stop file)}"
    done
    if ((${#RECUT_DONE[@]})); then
      printf '\n## Recut\n'
      for g in "${RECUT_DONE[@]}"; do
        printf -- '- %s: recut (merge-conflict): runs fresh on rerun\n' "$g"
      done
    fi
    printf '\n## graph\n'
    "$GOALS_PY" GOALS.md graph
  } >"$stop"
  echo "=== wave-stop ==="
  cat "$stop"
  events_append --event wake --severity error --reason wave-stop --summary "wave-stop $WAVE_N: $ids"
  echo "STOP_FILE: $stop"
  exit "$code"
}

# INT/TERM: stop every member still running (each records its own stop), then
# the combined stop. A goal started with & ignores terminal INT, so it gets TERM.
wave_on_signal() {
  local sig="$1" code="$2" i
  trap - INT TERM
  if [[ -n "${CHILD_PID:-}" ]]; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  # A member that already exited but was not yet reaped keeps its exit status.
  for i in ${RUNNING_PIDS[@]+"${!RUNNING_PIDS[@]}"}; do
    [[ -z "${EXIT_AT[$i]:-}" ]] || continue
    if ! kill -0 "${RUNNING_PIDS[$i]}" 2>/dev/null; then
      RCS[$i]=0
      wait "${RUNNING_PIDS[$i]}" 2>/dev/null || RCS[$i]=$?
      EXIT_AT[$i]="$(date +%s)"
    fi
  done
  for i in ${RUNNING_PIDS[@]+"${!RUNNING_PIDS[@]}"}; do
    [[ -n "${EXIT_AT[$i]:-}" ]] || kill -TERM "${RUNNING_PIDS[$i]}" 2>/dev/null || true
  done
  # Each one TERMed keeps its own exit status: 0 if it finished first.
  for i in ${RUNNING_PIDS[@]+"${!RUNNING_PIDS[@]}"}; do
    [[ -z "${EXIT_AT[$i]:-}" ]] || continue
    RCS[$i]=0
    wait "${RUNNING_PIDS[$i]}" 2>/dev/null || RCS[$i]=$?
    EXIT_AT[$i]="$(date +%s)"
  done
  # wave_stop lists every member from its state: interrupted, exited, kept.
  echo "=== walk interrupted (SIG${sig}) ===" >&2
  WAVE_STOPPING=0
  goal_stop "(walk)" interrupted "SIG${sig}; a merge in a scratch worktree, if one was running, is left there (git -C <scratch> merge --abort); the walk branch was not moved"
  wave_stop "$code"
}

# The paths a goal's implementer may not write: the walker's, and every other
# member's (PLAN step 6, Amendments 1 and 3). One per line into FILE.
deny_list() {
  local me="$1" out="$2" m p
  {
    for p in "$(main_git_path HEAD)" "$(main_git_path index)" "$(main_git_path logs/HEAD)" \
      "$GIT_COMMON/refs/heads/$WALK_BRANCH" "$GIT_COMMON/logs/refs/heads/$WALK_BRANCH"; do
      printf '%s\n%s.lock\n' "$p" "$p"
    done
    # packed-refs.lock stays writable: denying it makes every commit print a
    # false error (git 2.54); the walker checks for a stray one instead.
    printf '%s\n' "$GIT_COMMON/packed-refs"
    # The walker's evidence of conflicted attempts (refs/cw-conflict/<g>/<n>):
    # no goal writes or pre-plants one.
    printf '%s\n%s\n' "$GIT_COMMON/refs/cw-conflict" "$GIT_COMMON/logs/refs/cw-conflict"
    for m in "${WAVE_MEMBERS[@]}"; do
      [[ "$m" != "$me" ]] || continue
      for p in "$GIT_COMMON/refs/heads/cw/$m" "$GIT_COMMON/logs/refs/heads/cw/$m"; do
        printf '%s\n%s.lock\n' "$p" "$p"
      done
      # The admin folder as git named it when the walker cut the worktree.
      [[ ! -s "$WAVE_DIR/$m.admin" ]] || cat "$WAVE_DIR/$m.admin"
    done
    # Its own link files: rewritten, they point host git at another gitdir
    # (Amendment 4). run-goal.sh also byte-checks them before every git call.
    printf '%s\n' "$(wt_path "$me")/.git"
    if [[ -s "$WAVE_DIR/$me.admin" ]]; then
      p="$(cat "$WAVE_DIR/$me.admin")"
      printf '%s\n%s\n' "$p/commondir" "$p/gitdir"
    fi
  } >"$out"
}

# run_setup GOAL DIR OUT — worktree_setup in DIR. 0 ok; else SETUP_REASON is
# worktree-setup-failed or worktree-setup-dirty and it returns 1. Not called
# in $(...): the walker's signal handler must be able to stop the setup.
SETUP_REASON=""
run_setup() {
  local g="$1" dir="$2" out="$3" rc=0 st
  SETUP_REASON=""
  [[ -n "$WORKTREE_SETUP" ]] || return 0
  PROOF_ROOT="$dir" PROOF_WALK="$GIT_COMMON_P" PROOF_DEPS="$DEPS_DIR" PROOF_SETUP=1 \
    proof_exec "$PROOF_SECS" "$out" "$WAVE_DIR/tmp-setup-$g" "cd $(printf '%q' "$dir") && $WORKTREE_SETUP" || rc=$?
  if [[ -n "$PROOF_SANDBOX_REASON" ]]; then
    SETUP_REASON="$PROOF_SANDBOX_REASON"
    return 1
  fi
  if [[ "$rc" -ne 0 ]]; then
    SETUP_REASON=worktree-setup-failed
    return 1
  fi
  if [[ "$dir" == "$S_TREE" ]]; then
    st="$(sgit status --porcelain)" || { SETUP_REASON=worktree-setup-failed; return 1; }
  elif [[ -s "$WAVE_DIR/$g.admin" && "$dir" == "$(wt_path "$g")" ]]; then
    st="$(in_pinned "$(goal_admin "$g")" "$dir" git status --porcelain)" || { SETUP_REASON=worktree-setup-failed; return 1; }
  else
    st="$(git -C "$dir" status --porcelain)" || { SETUP_REASON=worktree-setup-failed; return 1; }
  fi
  if [[ -n "$st" ]]; then
    SETUP_REASON=worktree-setup-dirty
    return 1
  fi
  return 0
}

# done_this_walk JOURNAL_COPY — goals done in this walk, for the merged proofs:
# those with an `integrated` record after this walk's walk-start in a copy of
# the walk tip's journal, and those a serial (--jobs 1) run of the same walk
# finished (FUTURE-WORK item 30): a goal GOALS.md marks done whose host ledger
# in this checkout (orch_host_ledger, which no sandboxed goal can write) holds
# an `ORCHESTRATOR done <goal>` record stamped at or after that walk-start (a
# serial goal handed back since is left out; an integrated one counts whatever
# its status now). Whole headings only, split on "\n" only, as walk_record: a
# merged goal record may carry a body line that reads like either record
# (journal-merge.py refuses walker-only headings, so a journal heading is the
# walker's own). With no walk-start found every record counts: more proofs,
# never fewer.
done_this_walk() {
  local g l ids ledgers=()
  ids="$("$GOALS_PY" GOALS.md todos | python3 -c 'import json,sys; print("\n".join(t["id"] for t in json.load(sys.stdin) if t.get("goal_status") == "done"))')" || return 1
  for g in $ids; do
    l="$(orch_host_ledger "$g")" || return 1
    ledgers+=("$g=$l")
  done
  python3 - "$1" "${WALK_ID:-}" "${ledgers[@]+"${ledgers[@]}"}" <<'PY'
import os, re, sys
path, wid, *ledgers = sys.argv[1:]
lines = open(path, "rb").read().decode("utf-8", "replace").split("\n")
start, since = 0, ""
for i, l in enumerate(lines):
    m = re.match(r"^## (\S+) \u2014 ORCHESTRATOR walk-start walk_id=" + re.escape(wid) + r"(\s|$)", l)
    if m:
        start, since = i, m.group(1)
done = []
for l in lines[start:]:
    m = re.match(r"^## \S+ \u2014 ORCHESTRATOR integrated (g\d+-[a-z0-9-]+) ", l)
    if m and m.group(1) not in done:
        done.append(m.group(1))
for pair in ledgers:
    g, ledger = pair.split("=", 1)
    if g in done or not os.path.isfile(ledger):
        continue
    text = open(ledger, "rb").read().decode("utf-8", "replace")
    for l in text.split("\n"):
        m = re.match(r"^## (\S+) \u2014 ORCHESTRATOR done " + re.escape(g) + r" r\d+$", l)
        if m and m.group(1) >= since:
            done.append(g)
            break
print("\n".join(done))
PY
}

# conflict_recuts_used GOAL — how many times GOAL was recut for a merge
# conflict in this walk: its `recut <g> reason=merge-conflict` records in the
# walk journal at HEAD after this walk's walk-start (whole headings only). A
# journal it cannot read counts as used (fail closed: the conflict stops).
# The Python is a heredoc, as walk_record's: its em dash must not depend on the
# locale the command line is read in.
conflict_recuts_used() {
  local f="$WAVE_DIR/budget-journal"
  git show "HEAD:$JOURNAL" >"$f" 2>/dev/null || { echo 1; return 0; }
  python3 - "$1" "${WALK_ID:-}" "$f" <<'PY' || echo 1
import re, sys
g, wid, path = sys.argv[1:4]
text = open(path, "rb").read().decode("utf-8", "replace")
n = 0
for line in text.split("\n"):
    if re.match(r"^## \S+ \u2014 ORCHESTRATOR walk-start walk_id=" + re.escape(wid) + r"(\s|$)", line):
        n = 0
    elif re.match(r"^## \S+ \u2014 ORCHESTRATOR recut " + re.escape(g) + r" reason=merge-conflict(\s|$)", line):
        n += 1
print(n)
PY
}

# flush_conflict_recuts [soft] — recut each goal queued in CONFLICT_RECUTS
# from its verified SHA: the attempt kept at refs/cw-conflict/<g>/<n>
# (create-only), a `recut <g> reason=merge-conflict` record, an info `recut`
# event naming the conflicted paths. soft (inside wave_stop): a refusal lists
# the goal as a merge-conflict stop instead of stopping the walk.
# Entries leave the queue one at a time, so a stop or a signal part way
# through leaves the rest for wave_stop's own flush. A goal whose recut fails
# is a merge-conflict stop in either mode; the flush goes on to the next.
flush_conflict_recuts() {
  local soft="${1:-}" e g sha n ref paths
  while ((${#CONFLICT_RECUTS[@]})); do
    e="${CONFLICT_RECUTS[0]}"
    CONFLICT_RECUTS=(${CONFLICT_RECUTS[@]+"${CONFLICT_RECUTS[@]:1}"})
    g="${e%% *}"
    sha="${e#* }"
    SOFT_WHY=""
    if ! walk_ok; then
      :
    elif ! n="$(git for-each-ref --format='%(refname)' "refs/cw-conflict/$g/" 2>/dev/null |
      sed -n "s|^refs/cw-conflict/$g/\([1-9][0-9]*\)\$|\1|p" | sort -n | tail -n1)"; then
      SOFT_WHY="cannot list refs/cw-conflict/$g/"
    elif ref="refs/cw-conflict/$g/$(( ${n:-0} + 1 ))" && ! git update-ref "$ref" "$sha" "" 2>/dev/null; then
      SOFT_WHY="cannot create $ref"
    elif recut "$g" "$sha" merge-conflict "$soft"; then
      RECUT_DONE+=("$g")
      paths="$(python3 -c 'import json,sys; print(json.dumps([p.decode("utf-8","replace") for p in open(sys.argv[1],"rb").read().split(b"\0") if p]))' \
        "$WAVE_DIR/$g.conflict-files" 2>/dev/null || echo '[]')"
      events_append --event recut --severity info --goal "$g" --summary "recut $g: merge conflict, runs fresh" \
        --payload "{\"reason\":\"merge-conflict\",\"files\":$paths,\"evidence\":\"$ref\"}"
      continue
    fi
    goal_stop "$g" merge-conflict "cw/$g conflicted and its automatic recut failed: $SOFT_WHY. Its verified commit is $sha. Hand it back ($GOALS_PY GOALS.md set $g ready, commit) and rerun to recut it."
  done
}

# integration_stop GOAL REASON DETAIL [SCRATCH] — an integration failure.
integration_stop() {
  local g="$1" reason="$2" detail="$3" s="${4:-}" f
  f="$WAVE_DIR/$g-integrate-stop.md"
  {
    printf '# Stop: %s\n\n- reason: %s\n- detail: %s\n- utc: %s\n' "$g" "$reason" "$detail" "$(utc)"
    printf -- '- the walk branch was not moved; nothing was reset\n'
    [[ -z "$s" ]] || printf -- '- scratch worktree (evidence, kept): %s\n' "$s"
    printf -- '- branch: cw/%s (kept), worktree: %s (kept)\n' "$g" "$(wt_path "$g")"
    printf -- '- next: fix the walk branch and rerun (the same reviewed commit is integrated again), or hand the goal back: %s GOALS.md set %s ready (commit GOALS.md), then rerun; the walker recuts it\n' "$GOALS_PY" "$g"
  } >"$f"
  add_stop "$g" "$reason" "$f"
  CUR_SCRATCH=""
  events_append --event wake --severity error --goal "$g" --reason "$reason" --summary "integrate $g: $reason"
}

# keep_result GOAL — the goal's verified result file, copied for a later start
# (a temp file, then a rename: a crash never leaves half a copy).
keep_result() {
  cp "$WAVE_DIR/$1.result" "$RESULTS_DIR/.$1.tmp" && mv -f "$RESULTS_DIR/.$1.tmp" "$RESULTS_DIR/$1"
}

# in_pinned ADMIN TREE CMD... — CMD in TREE with host git pinned to ADMIN and
# the common dir (Amendment 5).
in_pinned() {
  local admin="$1" tree="$2"
  shift 2
  [[ -n "$admin" && -n "$tree" ]] || return 1
  (
    cd "$tree" || exit 1
    export GIT_PIN_DIR="$admin" GIT_PIN_COMMON="$GIT_COMMON_P" GIT_PIN_TREE="$tree"
    "$@"
  )
}
# in_scratch CMD... — CMD in the scratch tree with host git pinned to it.
in_scratch() { in_pinned "$S_ADMIN" "$S_TREE" "$@"; }
sgit() { in_scratch git "$@"; }
# A goal worktree's recorded admin folder, physical.
goal_admin() { (cd "$(cat "$WAVE_DIR/$1.admin")" && pwd -P); }

# check_merge S M BASE SHA GOAL — the integrate commit M in scratch tree S is what
# the walker merged (Amendment 4): parents the walk tip and SHA only; every
# path the walk tip's or the goal's version, the journal the checked
# resolution; S clean at M. Prints why and returns 1 otherwise.
check_merge() {
  local s="$1" m="$2" base="$3" sha="$4" g="$5" tree blob mode expected
  if [[ "$(git rev-list --parents -n1 "$m")" != "$m $WALK_TIP $sha" ]]; then
    echo "the integrate commit $m does not have exactly the walk tip and $sha as parents"
    return 1
  fi
  # The merge as git makes it, independently of the scratch tree, with the
  # journal replaced by the checked resolution (Amendment 5).
  # No --merge-base: merge-tree picks the bases as `git merge` does (a
  # criss-cross history included). It reads .gitattributes from the main
  # checkout, which integrate checked clean at its start.
  tree="$(git merge-tree --write-tree "$WALK_TIP" "$sha" 2>/dev/null | head -n1 || true)"
  [[ "$tree" =~ ^[0-9a-f]{40,64}$ ]] || { echo "git merge-tree gave no tree for $WALK_TIP and $sha"; return 1; }
  blob="$(git hash-object -w --path="$JOURNAL" -- "$WAVE_DIR/$g.jmerged")" || { echo "cannot store the checked journal"; return 1; }
  mode="$(git ls-tree "$WALK_TIP" -- "$JOURNAL" | awk '{print $1}')"
  rm -f "$WAVE_DIR/$g.index"
  expected="$(
    export GIT_INDEX_FILE="$WAVE_DIR/$g.index"
    git read-tree "$tree" && git update-index --add --cacheinfo "${mode:-100644},$blob,$JOURNAL" && git write-tree
  )" || { echo "cannot build the expected tree"; return 1; }
  if [[ "$(git rev-parse "$m^{tree}")" != "$expected" ]]; then
    echo "the integrate commit's tree is not the merge of the walk tip and $sha with the checked journal"
    return 1
  fi
  check_scratch_at "$s" "$m"
}

# check_scratch_at S C — scratch tree S is clean with HEAD at C.
check_scratch_at() {
  if [[ "$(sgit rev-parse HEAD 2>/dev/null)" != "$2" ]]; then
    echo "the scratch tree's HEAD moved off $2"
    return 1
  fi
  if [[ -n "$(sgit status --porcelain)" ]]; then
    echo "the scratch tree is not clean at $2"
    return 1
  fi
  return 0
}

# integrate GOAL SHA — PLAN Amendment 3 B. Everything happens in a new scratch
# worktree; the walk branch moves only by a fast-forward to its green result.
# 0: integrated. 1: stopped, the join goes on. 2: stopped, the join ends (the
# main checkout is not clean). 4: a plain merge conflict, queued for its
# automatic recut (CONFLICT_RECUTS): not integrated, not a stop.
integrate() {
  local g="$1" sha="$2" s base m mrc conflicted p proof out rc moved=() red=() expect M F done_list
  walk_check
  # The main checkout clean from the start: merge-tree reads its attributes.
  if [[ -n "$(git status --porcelain)" ]]; then
    integration_stop "$g" integration-dirty "the main checkout is not clean, so $g was not integrated. Run git status, then restore the working tree to HEAD (git restore --staged --worktree . ; git clean -fd). Do not move HEAD: it holds this wave's finished records, and dropping them would recut those goals. Then rerun."
    return 2
  fi
  mkdir -p "$INT_DIR" && chmod 700 "$INT_DIR"
  s="$(mktemp -d "$INT_DIR/$g-XXXXXX")"
  CUR_SCRATCH="$s"
  git worktree add -q --detach "$s" "$WALK_TIP" >"$WAVE_DIR/$g.int-add" 2>&1 ||
    { integration_stop "$g" merge-failed "git worktree add of the scratch tree failed: $(tail -n 2 "$WAVE_DIR/$g.int-add" | paste -sd ' ' -)"; return 1; }
  # Its paths as git created them, read at once: every later call is pinned.
  S_TREE="$(cd "$s" && pwd -P)" && s="$S_TREE" &&
    S_ADMIN="$(command git -C "$s" rev-parse --absolute-git-dir)" && S_ADMIN="$(cd "$S_ADMIN" && pwd -P)" ||
    { integration_stop "$g" merge-failed "cannot read the scratch tree's admin folder" "$s"; return 1; }
  # The journal check: both sides pure appends, the goal's only its records.
  base="$(git merge-base "$WALK_TIP" "$sha")"
  git show "$base:$JOURNAL" >"$WAVE_DIR/$g.jbase" 2>/dev/null || : >"$WAVE_DIR/$g.jbase"
  git show "$WALK_TIP:$JOURNAL" >"$WAVE_DIR/$g.jours"
  git show "$sha:$JOURNAL" >"$WAVE_DIR/$g.jtheirs"
  if ! m="$(python3 "$HERE/lib/journal-merge.py" "$WAVE_DIR/$g.jbase" "$WAVE_DIR/$g.jours" "$WAVE_DIR/$g.jtheirs" "$g" "$WAVE_DIR/$g.jmerged")"; then
    integration_stop "$g" journal-tamper "$m — nothing was merged" "$s"
    return 1
  fi
  mrc=0
  sgit merge --no-ff --no-commit -q "$sha" >"$WAVE_DIR/$g.merge.out" 2>&1 || mrc=$?
  # 0, or 1 for the normal journal conflict (both sides appended).
  if [[ "$mrc" -gt 1 ]] || ! sgit rev-parse -q --verify MERGE_HEAD >/dev/null; then
    integration_stop "$g" merge-failed "git merge of $sha exited $mrc without a merge in progress: $(tail -n 3 "$WAVE_DIR/$g.merge.out" | paste -sd ' ' -)" "$s"
    return 1
  fi
  cp "$WAVE_DIR/$g.jmerged" "$s/$JOURNAL" && sgit add -- "$JOURNAL" ||
    { integration_stop "$g" merge-failed "cannot stage the checked journal" "$s"; return 1; }
  conflicted="$(sgit diff --name-only --diff-filter=U | paste -sd ',' -)"
  if [[ -n "$conflicted" ]]; then
    # One automatic recut per goal per walk (docs/features/merge-conflict-recut):
    # the paths saved before the abort clears them, the scratch tree removed,
    # the recut queued; status 4 is "not integrated, not a stop".
    if [[ "$(conflict_recuts_used "$g")" == 0 ]]; then
      sgit diff -z --name-only --diff-filter=U >"$WAVE_DIR/$g.conflict-files" 2>/dev/null || : >"$WAVE_DIR/$g.conflict-files"
      sgit merge --abort >/dev/null 2>&1 || true
      git worktree remove -f -f "$s" >/dev/null 2>&1 || rm -rf "$s"
      git worktree prune
      CUR_SCRATCH=""
      S_TREE="" S_ADMIN=""
      CONFLICT_RECUTS+=("$g $sha")
      echo "merge conflict: $g, recut to run fresh from the new tip (its one automatic recut in this walk)"
      return 4
    fi
    integration_stop "$g" merge-conflict "cw/$g conflicts with the walk branch in: $conflicted. This goal's automatic recut for a merge conflict was already used in this walk (or the walk journal could not be read to tell). Merge it by hand, or rework the goal; declare conflicts_with next time." "$s"
    return 1
  fi
  if ! sgit diff --cached --quiet HEAD -- GOALS.md; then
    integration_stop "$g" integration-goals-edited "merging $sha would change GOALS.md, which only the walker writes; see git diff $base $sha -- GOALS.md" "$s"
    return 1
  fi
  sgit commit -q -m "chore($g): orchestrator integrate" ||
    { integration_stop "$g" merge-failed "the integrate commit failed" "$s"; return 1; }
  # From here on the scratch tree is judged by its commits (Amendment 4).
  M="$(sgit rev-parse HEAD)"
  if ! m="$(check_merge "$s" "$M" "$base" "$sha" "$g")"; then
    integration_stop "$g" integration-tamper "$m" "$s"
    return 1
  fi
  # worktree_setup in the scratch tree: the merge may have changed a lockfile.
  if ! run_setup "$g" "$s" "$WAVE_DIR/$g.setup-int.out"; then
    integration_stop "$g" "$SETUP_REASON" "worktree_setup in the scratch tree after merging $g (output: $WAVE_DIR/$g.setup-int.out)" "$s"
    return 1
  fi
  if ! m="$(check_scratch_at "$s" "$M")"; then
    integration_stop "$g" integration-tamper "after worktree_setup: $m" "$s"
    return 1
  fi
  # Merged proofs, in the scratch tree: this goal and every goal done earlier
  # in this walk.
  PLAN_PATH="$("$GOALS_PY" GOALS.md meta | python3 -c 'import json,sys; print(json.load(sys.stdin).get("plan") or "")')"
  # The walk tip's journal (copied for the journal check above); a list it
  # cannot read stops the goal rather than run fewer proofs.
  if ! done_list="$(done_this_walk "$WAVE_DIR/$g.jours")"; then
    integration_stop "$g" merge-failed "cannot read the goals done in this walk (the walk tip's journal, GOALS.md, the host ledgers)" "$s"
    return 1
  fi
  PROOF_GUARDED_EXTRA="$(for p in $done_list "$g"; do goal_field "$p" oracle; done | sort -u | paste -sd ' ' -)"
  for p in $(printf '%s\n' $done_list | grep -vx "$g" || true) "$g"; do
    proof="$(goal_field "$p" proof)"
    case "$proof" in "" | true | inline | "(case table)") continue ;; esac
    ORACLE="$(goal_field "$p" oracle)"
    out="$WAVE_DIR/$g.merged-proof-$p.txt"
    in_scratch tree_snapshot >"$WAVE_DIR/$g.before"
    rc=0
    PROOF_ROOT="$s" PROOF_WALK="$GIT_COMMON_P" PROOF_NETWORK="$PROOF_NET" PROOF_DEPS="$DEPS_DIR" \
      proof_exec "$PROOF_SECS" "$out" "$WAVE_DIR/tmp-proof-$g-$p" "cd $(printf '%q' "$s") && $proof" || rc=$?
    if [[ -n "$PROOF_SANDBOX_REASON" ]]; then
      integration_stop "$g" "$PROOF_SANDBOX_REASON" "the proof sandbox stopped the merged proof of $p before it ran (output: $out)" "$s"
      return 1
    fi
    in_scratch tree_snapshot >"$WAVE_DIR/$g.after"
    moved=()
    while IFS= read -r m; do [[ -z "$m" ]] || moved+=("$m"); done < <(in_scratch proof_moved "$WAVE_DIR/$g.before" "$WAVE_DIR/$g.after")
    if ((${#moved[@]})); then
      integration_stop "$g" integration-tamper "the merged proof of $p changed the scratch tree — $(printf '%s; ' "${moved[@]}")output: $out" "$s"
      return 1
    fi
    if [[ "$rc" -ne 0 ]] || grep -q 'Ran 0 tests' "$out"; then
      red+=("$p (exit $rc, $out)")
    fi
  done
  if ! m="$(check_scratch_at "$s" "$M")"; then
    integration_stop "$g" integration-tamper "after the merged proofs: $m" "$s"
    return 1
  fi
  if ((${#red[@]})); then
    integration_stop "$g" integration-red "merged proofs red after merging $g: $(printf '%s; ' "${red[@]}")" "$s"
    return 1
  fi
  # done, in the scratch tree, byte-checked against the expected journal.
  # GOALS.md: the walk tip's, with only this goal set done, byte for byte.
  git show "$WALK_TIP:GOALS.md" >"$WAVE_DIR/$g.goals-expect" &&
    "$GOALS_PY" "$WAVE_DIR/$g.goals-expect" set "$g" done >/dev/null &&
    cp "$WAVE_DIR/$g.goals-expect" "$s/GOALS.md" ||
    { integration_stop "$g" merge-failed "cannot set $g done in the scratch tree" "$s"; return 1; }
  expect="$WAVE_DIR/$g.jexpect"
  cp "$WAVE_DIR/$g.jmerged" "$expect"
  printf '\n%s\n' "## $(utc) — ORCHESTRATOR integrated $g merge=$(git rev-parse --short "$M")" >>"$expect"
  cp "$expect" "$s/$JOURNAL"
  sgit add -- GOALS.md "$JOURNAL" && sgit commit -q -m "chore($g): orchestrator integrated" -- GOALS.md "$JOURNAL" ||
    { integration_stop "$g" merge-failed "the integrated commit failed" "$s"; return 1; }
  # F, by its commit: one parent M, only GOALS.md and the journal changed, the
  # journal byte for byte what the walker wrote, GOALS.md moved only by done.
  F="$(sgit rev-parse HEAD)"
  if [[ "$(git rev-list --parents -n1 "$F")" != "$F $M" ]] ||
    [[ -n "$(git -c core.quotePath=false diff --no-renames --name-only "$M" "$F" | grep -vxF -e GOALS.md -e "$JOURNAL" || true)" ]] ||
    ! git show "$F:$JOURNAL" | cmp -s - "$expect" ||
    ! git show "$F:GOALS.md" | cmp -s - "$WAVE_DIR/$g.goals-expect"; then
    integration_stop "$g" integration-tamper "the integrated commit $F is not M plus the walker's done record" "$s"
    return 1
  fi
  # The fast-forward: the main checkout must be clean and still at WALK_TIP.
  walk_check
  if [[ -n "$(git status --porcelain)" ]]; then
    integration_stop "$g" integration-dirty "the main checkout is not clean, so $g's green integration (scratch $s) was not fast-forwarded. Run git status, then restore the working tree to HEAD (git restore --staged --worktree . ; git clean -fd). Do not move HEAD: it holds this wave's finished records, and dropping them would recut those goals. Then rerun." "$s"
    return 2
  fi
  # To the captured F, never to whatever the scratch HEAD names now.
  git merge -q --ff-only "$F" || walk_stop merge-failed "fast-forward of $WALK_BRANCH to $F failed"
  WALK_TIP="$(git rev-parse HEAD)"
  expect_from_tree
  events_append --event integrate --severity info --goal "$g" --summary "integrate $g" \
    --payload "{$(events_pid_json)}"
  events_append --event done --severity info --goal "$g" --summary "done $g (integrated)" \
    --payload "{$(events_pid_json)}"
  git worktree remove -f -f "$s" 2>/dev/null || true
  git worktree remove -f -f "$(wt_path "$g")" 2>/dev/null || true
  git worktree prune
  git branch -q -D "cw/$g" 2>/dev/null || true
  rm -f "$RESULTS_DIR/$g"
  CUR_SCRATCH=""
  S_TREE=""
  S_ADMIN=""
  echo "=== integrated $g ==="
  return 0
}

# bounce GOAL — step 7a: the goal's checked journal suffix onto the walk
# journal (no code), bounced committed, the worktree kept.
bounce() {
  local g="$1" tip base m f
  walk_check
  if ! cmp -s "$JOURNAL" "$JOURNAL_EXPECT"; then
    walk_stop orchestration-files-changed "$JOURNAL holds more than the walker wrote, before recording $g's bounce. Review, then commit or restore."
  fi
  tip="$(git rev-parse "refs/heads/cw/$g")"
  base="$(git merge-base HEAD "$tip")"
  git show "$base:$JOURNAL" >"$WAVE_DIR/$g.jbase" 2>/dev/null || : >"$WAVE_DIR/$g.jbase"
  git show "HEAD:$JOURNAL" >"$WAVE_DIR/$g.jours"
  git show "$tip:$JOURNAL" >"$WAVE_DIR/$g.jtheirs"
  if ! m="$(python3 "$HERE/lib/journal-merge.py" "$WAVE_DIR/$g.jbase" "$WAVE_DIR/$g.jours" "$WAVE_DIR/$g.jtheirs" "$g" "$WAVE_DIR/$g.jmerged")"; then
    integration_stop "$g" journal-tamper "$m — the bounce was not recorded"
    return 1
  fi
  cp "$WAVE_DIR/$g.jmerged" "$JOURNAL"
  cp "$WAVE_DIR/$g.jmerged" "$JOURNAL_EXPECT"
  "$GOALS_PY" GOALS.md set "$g" bounced >/dev/null || walk_stop commit-failed "set $g bounced"
  wave_commit "chore($g): orchestrator bounced" "$g=in_progress:bounced"
  f="$WAVE_DIR/$g-bounced-stop.md"
  printf '# Stop: %s\n\n- reason: bounced\n- detail: the reviewer (or a FIX naming the oracle) bounced %s; its records are on the walk journal, no code was merged. Its own stop: %s\n- worktree and branch kept: %s, cw/%s\n- next: fix the spec or oracle and commit, then %s GOALS.md set %s ready (commit GOALS.md) and rerun with --jobs; the walker recuts it from the next wave base\n- utc: %s\n' \
    "$g" "$g" "$(cat "$WAVE_DIR/$g.ptr" 2>/dev/null || echo none)" "$(wt_path "$g")" "$g" "$GOALS_PY" "$g" "$(utc)" >"$f"
  add_stop "$g" bounced "$f"
  return 0
}

# walker_mark GOAL EVENT — a line in GOAL's host ledger in this checkout
# (orch_host_ledger, which no sandboxed goal can write) saying the walker took
# the goal: EVENT is wave or recut. serial_goal_why reads it; resume-state.py
# and done_this_walk read only run-goal.sh's own records. A mark that cannot
# be written makes the serial check stricter, never looser.
walker_mark() {
  local l
  l="$(orch_host_ledger "$1")" || return 0
  (umask 077 && mkdir -p "$(dirname "$l")" && printf '## %s — ORCHESTRATOR walker %s %s\n' "$(utc)" "$2" "$1" >>"$l") 2>/dev/null || true
}

# serial_goal_why GOAL [uncommitted] — for an in_progress goal: when a serial
# run (run-goals.sh without --jobs) worked on it after the walker last took it,
# print why the walk cannot take it and return 0. That is: its in_progress is
# uncommitted ("uncommitted": the walker commits every status itself, so only a
# serial run leaves one), or its host ledger in this checkout holds a
# run-goal.sh record for it (any kind) after the last walker mark, or that
# ledger cannot be keyed or read. A parallel walk would recut the goal from the
# walk tip, and a serial goal's implementer commits straight onto the walk
# branch: whatever the stopped pass left would sit unreviewed in the new base
# (FUTURE-WORK item 31). Decides from GOALS.md and the ledger alone, never the
# journal (a serial implementer could forge a walker record there), and never
# from a branch or worktree (a goal a parallel walk bounced keeps both, then
# may run serially); the journal and the results folder shape only the advice. No ledger file (a goal paused before ledgers existed, 2026-10-23,
# a repo since moved, another HOME) is not serial unless uncommitted.
serial_goal_why() {
  local g="$1" ledger last="" kept=""
  [[ "${2:-}" != uncommitted ]] || last=uncommitted
  if [[ -z "$last" ]]; then
    if ledger="$(orch_host_ledger "$g")"; then
      [[ -f "$ledger" ]] || return 1
      last="$(python3 - "$ledger" "$g" <<'PY'
import re, sys
path, g = sys.argv[1], sys.argv[2]
last = "none"
for line in open(path, "rb").read().decode("utf-8", "replace").split("\n"):
    if re.match(r"^## \S+ \u2014 ORCHESTRATOR walker (wave|recut) " + re.escape(g) + r"$", line):
        last = "walker"
    elif re.match(r"^## \S+ \u2014 ORCHESTRATOR (?!walker )\S+ " + re.escape(g) + r"(\s|$)", line):
        last = "serial"
print(last)
PY
      )" || last=unreadable
    else
      last=unreadable
    fi
  fi
  [[ "$last" != none && "$last" != walker ]] || return 1
  if [[ "$last" == unreadable ]]; then
    printf '%s\n' "$g is in progress, and its host ledger in this checkout (${ledger:-not keyed}) cannot be read, so whether a serial run (run-goals.sh without --jobs) is mid-way through it is unknown. Make the ledger readable (ls -l it), or find out by hand, then rerun. Do not delete its cw/$g branch or worktree on this account: the walker may hold a reviewed result there."
    return 0
  fi
  if branch_exists "$g" || [[ -e "$(wt_path "$g")" ]]; then
    rec="$(walk_record "$g")"
    if [[ -f "$RESULTS_DIR/$g" || ( "$rec" != none && "$rec" != member ) ]]; then
      kept=" Its cw/$g branch may hold a result the walker recorded as reviewed (or its record cannot be read): inspect it (git log cw/$g) before anything else, and do not delete it unseen. Both ways forward drop that result: finishing serially needs the branch and worktree out of the way, and $GOALS_PY GOALS.md set $g ready (commit) sends the goal to a wave, where it is recut; revert what the serial pass left on the walk branch first."
    else
      kept=" First remove what an earlier parallel attempt kept, after looking at it (the serial walker will not run a goal with a cw/ branch): git worktree remove -f -f $(wt_path "$g") || rm -rf $(wt_path "$g"); git branch -D cw/$g."
    fi
  fi
  local from="from a serial run (run-goals.sh without --jobs)"
  [[ "$last" != uncommitted ]] || from="with its in_progress uncommitted in GOALS.md, as a serial run (run-goals.sh without --jobs) stopped by a wake leaves it (or a hand edit, or a walker commit that failed)"
  printf '%s\n' "$g is in progress $from. A parallel walk would recut it from the walk tip, where whatever that run's stopped pass left (commits on the walk branch, GOALS.md or journal edits, uncommitted files) would never be reviewed.$kept Finish it serially: $HERE/run-goals.sh without --jobs resumes it from its own base. Then rerun with --jobs."
  return 0
}

# --- start --------------------------------------------------------------------
WAVE_DIR="$(mktemp -d "$CW_CACHE/runs/run-goals-wave-XXXXXX")"
chmod 700 "$WAVE_DIR"
mkdir -p "$WT_BASE" "$RESULTS_DIR" && chmod 700 "$CW_CACHE/worktrees" "$WT_BASE" "$RESULTS_DIR"
GIT_COMMON="$(command git rev-parse --path-format=absolute --git-common-dir)"
GIT_COMMON_P="$(cd "$GIT_COMMON" && pwd -P)"
WALK_BRANCH="$(git symbolic-ref -q --short HEAD || true)"
[[ -n "$WALK_BRANCH" ]] || walk_stop walk-branch-moved "the main checkout is on a detached HEAD; a parallel walk merges into a branch. git switch <branch>, then rerun."
WALK_TIP="$(git rev-parse HEAD)"
WORKTREE_SETUP="$("$GOALS_PY" GOALS.md meta | python3 -c 'import json,sys; print(json.load(sys.stdin).get("worktree_setup") or "")')"

# A goal a serial run is mid-way through is not the walker's to take
# (FUTURE-WORK item 31): checked first, so its uncommitted in_progress (a serial
# run leaves it so when a wake stops it) gets this answer, not the dirty-file
# refusal below, whose "restore" would make the goal start over with that
# pass's commits in its base.
git show HEAD:GOALS.md >"$WAVE_DIR/goals-at-head.md" 2>/dev/null || : >"$WAVE_DIR/goals-at-head.md"
while IFS= read -r g; do
  [[ -n "$g" ]] || continue
  committed=""
  [[ "$("$GOALS_PY" "$WAVE_DIR/goals-at-head.md" graph 2>/dev/null | awk -v g="$g" '$1 == g { print $2 }')" == in_progress ]] || committed=uncommitted
  if why="$(serial_goal_why "$g" $committed)"; then
    walk_stop serial-goal-in-progress "$why"
  fi
done < <("$GOALS_PY" GOALS.md graph | awk '$2 == "in_progress" { print $1 }')
# The walker commits every status itself: at start both files equal HEAD.
orch_preflight "" --none || walk_stop orchestration-files-dirty "$(orch_refusal)"
expect_from_tree
walk_check

# The proof sandbox (docs/features/proof-sandbox/PLAN.md step 4, Amendment 1
# B, D): once per walk, before any worktree is cut or set up (setup has the
# network). Each member's run-goal.sh checks the .env files again and
# journals an override as its own goal's record. The walker's worktree_setup
# and merged proofs run under the same overrides, and a resume that only
# integrates has no member to journal them, so the walker journals them too
# (WALK_NOTE, after walk-start; FUTURE-WORK item 12).
# Members skip the self-test itself (CW_PROOF_SANDBOX_CHECKED=1, below).
WALK_NOTE=""
if [[ "${CW_ALLOW_DOTENV:-}" == 1 ]]; then
  WALK_NOTE+=" dotenv=allowed"
  echo "NOTE: CW_ALLOW_DOTENV=1 — .env files in the checkouts stay readable to proofs and implementers"
else
  checkouts=()
  while IFS= read -r wt; do [[ -z "$wt" ]] || checkouts+=("$wt"); done \
    < <(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
  [[ ${#checkouts[@]} -gt 0 ]] || checkouts=("$MAIN_ROOT")
  if dotenvs="$(secrets_in_checkout "${checkouts[@]}")"; then :; else
    walk_stop secrets-in-checkout "live .env files in the repo's checkouts — move the secrets to ~/.config/cw-secrets/<project>/ (proofs and implementers cannot read it) and leave no symlink; or rerun with CW_ALLOW_DOTENV=1 to walk anyway: $(printf '%s ' $dotenvs)"
  fi
fi
if proof_sandbox_off; then
  WALK_NOTE+=" proof-sandbox=off"
  echo "NOTE: CW_PROOF_SANDBOX=off — proofs, worktree_setup and merged proofs run unsandboxed"
elif ! sbx_why="$(proof_sandbox_selftest)"; then
  walk_stop proof-sandbox-unavailable "the proof sandbox self-test failed — ${sbx_why//$'\n'/; }. CW_PROOF_SANDBOX=off runs proofs unsandboxed, deliberately."
fi
PROOF_NET="$("$GOALS_PY" GOALS.md meta | python3 -c 'import json,sys; print(json.load(sys.stdin).get("proof_network") or "none")')"
[[ "$PROOF_NET" != loopback ]] || echo "NOTE: proof_network: loopback — proofs reach every loopback service on this Mac, and a server a proof binds to all interfaces is reachable from the LAN"
[[ "$PROOF_NET" != true ]] || echo "NOTE: proof_network: true — proofs have the full network"
# One dependency folder for the walk: worktree_setup writes it, proofs read it.
DEPS_DIR="$(mktemp -d "$CW_CACHE/deps/walk-XXXXXX")"
chmod 700 "$DEPS_DIR"

trap 'wave_on_signal INT 130' INT
trap 'wave_on_signal TERM 143' TERM

events_ensure_walk
events_journal_walk_start
if [[ "${EVENTS_MINTED:-0}" -eq 1 ]]; then
  cp "$JOURNAL" "$JOURNAL_EXPECT"
  wave_commit "chore: orchestrator walk-start" ""
fi
if [[ -n "$WALK_NOTE" ]]; then
  walk_check
  journal_line "## $(utc) — ORCHESTRATOR overrides walk${WALK_NOTE}"
  wave_commit "chore: orchestrator overrides" ""
fi

# Start (PLAN Amendment 3 C). A list, not a read loop: a merged proof run below
# must not read its stdin.
INFLIGHT=()
while IFS= read -r g; do
  [[ -z "$g" ]] || INFLIGHT+=("$g")
done < <("$GOALS_PY" GOALS.md graph | awk '$2 == "in_progress" { print $1 }')
# A verified result whose `finished` commit never landed is recorded now.
PENDING=()
for g in ${INFLIGHT[@]+"${INFLIGHT[@]}"}; do
  [[ -f "$RESULTS_DIR/$g" ]] || continue
  need_record rec "$g"
  [[ "$rec" != finished* ]] || continue
  if done_sha="$(check_result "$g" "$RESULTS_DIR/$g" 2>"$WAVE_DIR/$g.copy.why")"; then
    PENDING+=("$g $done_sha")
  else
    echo "note: $g's saved result no longer matches its branch ($(cat "$WAVE_DIR/$g.copy.why")); it will be recut" >&2
  fi
done
record_finished ${PENDING[@]+"${PENDING[@]}"}
# Finished goals are integrated without dispatch; the rest are recut at their
# wave.
IN_WAVE=1
for g in ${INFLIGHT[@]+"${INFLIGHT[@]}"}; do
  need_record rec "$g"
  [[ "$rec" == finished* ]] || continue
  sha="${rec#finished }"
  if [[ "$(git rev-parse -q --verify "refs/heads/cw/$g" || true)" != "$sha" ]]; then
    integration_stop "$g" integration-unverified "$g is recorded finished at $sha, but cw/$g is at $(git rev-parse -q --verify "refs/heads/cw/$g" || echo nothing). A commit after the review is never merged. Put the branch back (git branch -f cw/$g $sha), or hand the goal back: $GOALS_PY GOALS.md set $g ready (commit) and rerun to recut it."
    continue
  fi
  rc=0
  integrate "$g" "$sha" || rc=$?
  [[ "$rc" -ne 2 ]] || wave_stop 1
done
flush_conflict_recuts
IN_WAVE=0
((${#STOPS[@]} == 0)) || wave_stop 1
# Goals integrated at a rerun's start landed too: a strict walk stops here.
mutation_gaps_stop

while :; do
  walk_check
  "$GOALS_PY" GOALS.md refresh >/dev/null
  wave_commit "chore: orchestrator refresh" "*=blocked:ready,*=ready:blocked"
  print_status
  FRONTIER=()
  while IFS= read -r g; do
    [[ -z "$g" || "$g" == "(empty)" ]] || FRONTIER+=("$g")
  done < <("$GOALS_PY" GOALS.md frontier)
  if ((${#FRONTIER[@]} == 0)); then
    remaining="$("$GOALS_PY" GOALS.md remaining)"
    [[ -z "$remaining" ]] || walk_stuck "$remaining"
    echo "=== walk-end ==="
    walk_check
    git worktree prune
    leftover="$(git worktree list --porcelain | awk '/^branch refs\/heads\/cw\// { sub("refs/heads/", "", $2); print $2 }' | paste -sd ',' -)"
    scratch_left="$(ls -d "$INT_DIR"/* 2>/dev/null | paste -sd ',' - || true)"
    [[ -z "$scratch_left" ]] || leftover="${leftover:+$leftover,}$scratch_left"
    [[ -z "$leftover" ]] || echo "leftover worktrees (not deleted): $leftover"
    mutation_walk_summary
    # Every goal recut for a merge conflict in this walk, one line each: no
    # stop said so. (A heredoc, as walk_record: the em dash and the locale.)
    git show "HEAD:$JOURNAL" >"$WAVE_DIR/end-journal" 2>/dev/null || : >"$WAVE_DIR/end-journal"
    python3 - "${WALK_ID:-}" "$WAVE_DIR/end-journal" <<'PY' || true
import re, sys
wid, path = sys.argv[1:3]
text = open(path, "rb").read().decode("utf-8", "replace")
seen = []
for line in text.split("\n"):
    if re.match(r"^## \S+ \u2014 ORCHESTRATOR walk-start walk_id=" + re.escape(wid) + r"(\s|$)", line):
        seen = []
    m = re.match(r"^## \S+ \u2014 ORCHESTRATOR recut (\S+) reason=merge-conflict(\s|$)", line)
    if m:
        seen.append(m.group(1))
for g in seen:
    print(f"recut after a merge conflict: {g} (ran fresh; the old attempt is under refs/cw-conflict/{g}/)")
PY
    journal_line "## $(utc) — ORCHESTRATOR walk-end${leftover:+ leftover=$leftover}"
    events_append --event walk_end --severity info --summary "walk-end"
    wave_commit "chore: orchestrator walk-end" ""
    events_end_walk
    git_meta_forget
    case "$DEPS_DIR" in */deps/walk-*) rm -rf "$DEPS_DIR" ;; esac
    exit 0
  fi

  # Spend and the kill file (always-on, step 9): once per wave, before it is
  # built, so a stop leaves the repo as it was (no recut committed); the
  # members spawn together, so a check per member would see the same ledger.
  # The previous wave is joined, so nothing is running.
  ao_gate

  # Build the wave (PLAN step 3.3, Amendment 3 C).
  WAVE_MEMBERS=()
  for g in "${FRONTIER[@]}"; do
    ((${#WAVE_MEMBERS[@]} < JOBS)) || break
    clash=0
    for m in ${WAVE_MEMBERS[@]+"${WAVE_MEMBERS[@]}"}; do
      if conflicts "$g" "$m"; then clash=1; break; fi
    done
    [[ "$clash" -eq 0 ]] || continue
    st="$(goal_field "$g" status)"
    if branch_exists "$g" || [[ -e "$(wt_path "$g")" ]]; then
      need_record rec "$g"
      if [[ "$st" == in_progress || "$rec" != none ]]; then
        # Ours: a stopped attempt, or a bounce the Architect has reset.
        recut "$g"
      else
        goal_stop "$g" worktree-exists "cw/$g or $(wt_path "$g") already exists for a goal this walk never started. Inspect it, then remove it (git worktree remove -f -f $(wt_path "$g"); git branch -D cw/$g) and rerun."
        continue
      fi
    elif [[ "$st" == in_progress ]] && ! in_recut "$g"; then
      # Stopped before its worktree was cut: a recut record, nothing to remove.
      # (A goal recut for a conflict in this run has its record already.)
      recut "$g"
    fi
    WAVE_MEMBERS+=("$g")
  done
  ((${#WAVE_MEMBERS[@]})) || wave_stop 1
  # The conflict recuts listed in a stop are this wave's own.
  RECUT_DONE=()

  WAVE_N=$((WAVE_N + 1))
  walk_check
  allow=""
  for g in "${WAVE_MEMBERS[@]}"; do
    if [[ "$(goal_field "$g" status)" == ready ]]; then
      "$GOALS_PY" GOALS.md set "$g" in_progress >/dev/null || walk_stop commit-failed "set $g in_progress"
      allow="${allow:+$allow,}$g=ready:in_progress"
    fi
  done
  journal_line "## $(utc) — ORCHESTRATOR wave $WAVE_N $(IFS=,; echo "${WAVE_MEMBERS[*]}")"
  wave_commit "chore: orchestrator wave $WAVE_N" "$allow"
  for g in "${WAVE_MEMBERS[@]}"; do walker_mark "$g" wave; done
  WAVE_BASE="$WALK_TIP"
  # A fresh attempt: no earlier result of a member may be recorded for it.
  for g in "${WAVE_MEMBERS[@]}"; do rm -f "$RESULTS_DIR/$g"; done
  IN_WAVE=1
  echo "=== wave $WAVE_N: ${WAVE_MEMBERS[*]} ==="
  # A walk row per member: it marks the goal as started for the pane.
  for g in "${WAVE_MEMBERS[@]}"; do
    events_append --event walk --severity info --goal "$g" --summary "wave $WAVE_N $g" \
      --payload "{$(events_pid_json)}"
  done

  # Every worktree first, then setup in each (PLAN step 3.5).
  CUT=()
  for g in "${WAVE_MEMBERS[@]}"; do
    if cut_worktree "$g"; then CUT+=("$g"); fi
  done
  STARTABLE=()
  for g in ${CUT[@]+"${CUT[@]}"}; do
    if ! run_setup "$g" "$(wt_path "$g")" "$WAVE_DIR/$g.setup.out"; then
      goal_stop "$g" "$SETUP_REASON" "worktree_setup ($WORKTREE_SETUP) in $(wt_path "$g"); output: $WAVE_DIR/$g.setup.out. The goal never started; a rerun recuts it."
      continue
    fi
    STARTABLE+=("$g")
  done

  RUNNING_PIDS=()
  RUNNING_IDS=()
  EXIT_AT=()
  # Every member's handoff folder first, so each member, building its read
  # denials at start, finds the others (docs/features/proof-sandbox step 6).
  HANDOFFS=()
  for g in ${STARTABLE[@]+"${STARTABLE[@]}"}; do
    HANDOFFS+=("$(mktemp -d "$CW_CACHE/handoffs/run-goal-$g-XXXXXX")")
  done
  hi=0
  for g in ${STARTABLE[@]+"${STARTABLE[@]}"}; do
    deny_list "$g" "$WAVE_DIR/$g.deny"
    : >"$WAVE_DIR/$g.ptr"
    rm -f "$WAVE_DIR/$g.result"
    ( cd "$(wt_path "$g")" && exec env CW_PROOF_SANDBOX_CHECKED=1 CW_DENY_WRITE_FILE="$WAVE_DIR/$g.deny" CW_PROOF_DEPS="$DEPS_DIR" CW_PROOF_NETWORK="$PROOF_NET" \
      CW_PIN_ADMIN="$(goal_admin "$g")" CW_PIN_COMMON="$GIT_COMMON_P" \
      RUN_GOAL_STOP_PTR="$WAVE_DIR/$g.ptr" "$RUN_GOAL" --worktree "$MAIN_ROOT" \
      --base "$WAVE_BASE" --result "$WAVE_DIR/$g.result" --handoff-dir "${HANDOFFS[$hi]}" "$g" ) &
    hi=$((hi + 1))
    RUNNING_PIDS+=("$!")
    RUNNING_IDS+=("$g")
  done

  # Join (PLAN step 3.8): poll so each goal's own exit time is known.
  RCS=()
  left=${#RUNNING_PIDS[@]}
  while ((left > 0)); do
    for i in "${!RUNNING_PIDS[@]}"; do
      [[ -z "${EXIT_AT[$i]:-}" ]] || continue
      if ! kill -0 "${RUNNING_PIDS[$i]}" 2>/dev/null; then
        RCS[$i]=0
        wait "${RUNNING_PIDS[$i]}" || RCS[$i]=$?
        EXIT_AT[$i]="$(date +%s)"
        left=$((left - 1))
      fi
    done
    ((left == 0)) || sleep 1
  done
  if ((${#RUNNING_IDS[@]})); then
    last_exit=0
    for i in "${!EXIT_AT[@]}"; do ((EXIT_AT[i] > last_exit)) && last_exit=${EXIT_AT[i]}; done
    waits="$(for i in "${!RUNNING_IDS[@]}"; do printf '"%s":%d,' "${RUNNING_IDS[$i]}" $((last_exit - EXIT_AT[i])); done)"
    events_append --event join_wait --severity info --summary "wave $WAVE_N join" \
      --payload "{\"wave\":$WAVE_N,\"waits\":{${waits%,}},$(events_pid_json)}"
  fi

  meta_stop "during wave $WAVE_N"
  # Every outcome before any integration: verify and keep each exit-0 goal's
  # result (no git write), record every other stop, then the bounces, then
  # the finished records in one commit, then the integrations. A stop in any
  # step still lists every member (wave_stop reads their state).
  PENDING=()
  for i in ${RUNNING_IDS[@]+"${!RUNNING_IDS[@]}"}; do
    g="${RUNNING_IDS[$i]}"
    [[ "${RCS[$i]}" -eq 0 ]] || continue
    if done_sha="$(check_result "$g" "$WAVE_DIR/$g.result" 2>"$WAVE_DIR/$g.result.why")" && keep_result "$g"; then
      PENDING+=("$g $done_sha")
    else
      integration_stop "$g" integration-unverified "$(cat "$WAVE_DIR/$g.result.why") Nothing was merged."
    fi
  done
  for i in ${RUNNING_IDS[@]+"${!RUNNING_IDS[@]}"}; do
    g="${RUNNING_IDS[$i]}"
    case "${RCS[$i]}" in
      0 | 3) ;;
      *)
        f="$(cat "$WAVE_DIR/$g.ptr" 2>/dev/null || true)"
        add_stop "$g" "$(reason_of "$f" || true)" "$f"
        ;;
    esac
  done
  for i in ${RUNNING_IDS[@]+"${!RUNNING_IDS[@]}"}; do
    [[ "${RCS[$i]}" -ne 3 ]] || bounce "${RUNNING_IDS[$i]}" || true
  done
  record_finished ${PENDING[@]+"${PENDING[@]}"}
  for pair in ${PENDING[@]+"${PENDING[@]}"}; do
    rc=0
    integrate "${pair%% *}" "${pair#* }" || rc=$?
    [[ "$rc" -ne 2 ]] || wave_stop 1
  done
  # Before any stop (Q3): a conflicted goal recut now runs fresh next wave.
  flush_conflict_recuts
  IN_WAVE=0
  ((${#STOPS[@]} == 0)) || wave_stop 1
  # The wave's goals landed: a strict walk stops on their survivors.
  mutation_gaps_stop
done
