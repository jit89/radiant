# shellcheck shell=bash
# Host git the implementer cannot hijack.
#
# deepseek-code.sh makes .git writable inside the Codex sandbox so the
# implementer can checkpoint-commit. Hooks and config in there name programs
# git runs — as the host user, outside the sandbox, invisible to the review
# diff, and still armed on the human's next `git status`. So:
#   1. every host git call runs with hooks, fsmonitor and signing off;
#   2. .git config / hooks / info are fingerprinted without running git, and
#      once git_meta_init has run, every host git call re-checks them first —
#      the walker, a signal's stop record, and a later run alike;
#   3. once a change is seen, host git refuses to run at all — filter and
#      textconv drivers named in config cannot be switched off by flag.
#
# The saved fingerprint is per gitdir, shared by run-goal.sh and run-goals.sh,
# and outlives a stop: the next run of either checks against it. Callers
# delete it (git_meta_forget) only when a goal or walk ends cleanly.
#
# Callers: git_meta_init once (inside the repo); git_meta_verify where a
# change must become a stop with its own reason.

GIT_META_TAINTED=0
GIT_META_DIRS=()
GIT_META_SAVED=""

git() {
  if [[ "${GIT_META_TAINTED:-0}" -eq 0 && -n "${GIT_META_SAVED:-}" ]]; then
    git_meta_verify "$GIT_META_SAVED" || true
  fi
  if [[ "${GIT_META_TAINTED:-0}" -eq 0 && -n "${GITFILE_SAVED:-}" ]]; then
    gitfile_verify || true
  fi
  if [[ "${GIT_META_TAINTED:-0}" -eq 1 ]]; then
    echo "git $1: skipped — .git metadata changed; inspect it first" >&2
    return 1
  fi
  if [[ -n "${GIT_PIN_DIR:-}" ]]; then
    # A linked worktree, pinned (parallel walker, Amendment 5): git never reads
    # its .git gitfile or the admin folder's commondir, which a goal could
    # point at another gitdir.
    GIT_DIR="$GIT_PIN_DIR" GIT_COMMON_DIR="$GIT_PIN_COMMON" GIT_WORK_TREE="$GIT_PIN_TREE" \
      command git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.quotePath=false \
      -c commit.gpgSign=false -c tag.gpgSign=false "$@"
    return
  fi
  command git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.quotePath=false \
    -c commit.gpgSign=false -c tag.gpgSign=false "$@"
}

# GIT_PIN_DIR / GIT_PIN_COMMON / GIT_PIN_TREE: when set, every host git call
# runs with GIT_DIR, GIT_COMMON_DIR and GIT_WORK_TREE set to them. Recorded
# when the worktree was created, before anything else ran in it.
GIT_PIN_DIR="${GIT_PIN_DIR:-}"
GIT_PIN_COMMON="${GIT_PIN_COMMON:-}"
GIT_PIN_TREE="${GIT_PIN_TREE:-}"

# Per-worktree gitdir plus the common gitdir when they differ. Arms the check
# in git() against the saved fingerprint for these gitdirs.
git_meta_init() {
  local d c
  if [[ -n "${GIT_PIN_DIR:-}" ]]; then
    # Pinned (a goal of a parallel walk): the recorded dirs, never re-resolved.
    d="$GIT_PIN_DIR"
    c="$GIT_PIN_COMMON"
  else
    d="$(command git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
    c="$(command git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || c="$d"
  fi
  GIT_META_DIRS=("$d")
  [[ "$c" == "$d" ]] || GIT_META_DIRS+=("$c")
  local cache="$HOME/.cache/claude-coding-workflow"
  mkdir -p "$cache"
  GIT_META_SAVED="$cache/git-meta-$(printf '%s\n' "${GIT_META_DIRS[@]}" | shasum -a 256 | cut -c1-16).txt"
}

# The goal or walk ended cleanly: the next run starts a fresh baseline, so a
# config change the human makes between runs is not taken for tampering.
git_meta_forget() {
  [[ -z "$GIT_META_SAVED" ]] || rm -f "$GIT_META_SAVED"
}

GIT_META_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-meta.py"

# Write a sorted manifest (path, type, mode, content hash or link target) of
# everything in the gitdirs that can make git execute or hide something.
# Fails, printing the paths, on special or unreadable files (lib/git-meta.py).
git_meta_manifest() {
  python3 "$GIT_META_PY" manifest "$1" "${GIT_META_DIRS[@]}"
}

# Compare the gitdirs to the saved manifest; save one if there is none.
# On a change, or a path that cannot be fingerprinted: taint host git, set
# GIT_META_CHANGED, return 1. Call it directly, never in $(...) — the taint
# must land in the caller's shell.
GIT_META_CHANGED=""
git_meta_verify() {
  local saved="$1" out rc=0
  out="$(python3 "$GIT_META_PY" verify "$saved" "${GIT_META_DIRS[@]}" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || return 0
  GIT_META_CHANGED="$(printf '%s\n' "${out:-verification failed (exit $rc)}" | paste -sd ';' -) "
  GIT_META_TAINTED=1
  return 1
}

# A linked worktree's link files: its `.git` gitfile and its admin folder's
# `commondir` and `gitdir`. Whoever can write them points git at another
# gitdir, whose config (a filter driver) git then runs. Parallel walker, PLAN
# Amendment 4: run-goal.sh in worktree mode saves them at start, before any
# implementer runs, and every host git call compares them first, without
# running git. Empty GITFILE_SAVED (the main checkout) checks nothing.
GITFILE_SAVED=""
GITFILE_PATHS=()

gitfile_state() {
  local f
  for f in "${GITFILE_PATHS[@]}"; do
    if [[ -L "$f" ]]; then
      printf '%s link %s\n' "$f" "$(readlink "$f")"
    elif [[ -f "$f" ]]; then
      printf '%s file %s\n' "$f" "$(shasum -a 256 <"$f" | cut -c1-64)"
    else
      printf '%s absent\n' "$f"
    fi
  done
}

# gitfile_pin ADMIN COMMON TREE — pin host git (Amendment 5) to the admin
# folder and common dir the walker recorded when it cut the worktree at TREE,
# before anything else ran there. Never re-resolved from the worktree's own
# link files. Physical paths; ADMIN must sit under COMMON/worktrees/.
gitfile_pin() {
  local admin common tree
  admin="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  common="$(cd "$2" 2>/dev/null && pwd -P)" || return 1
  tree="$(cd "$3" 2>/dev/null && pwd -P)" || return 1
  [[ "$(dirname "$admin")" == "$common/worktrees" ]] || return 1
  GIT_PIN_DIR="$admin"
  GIT_PIN_COMMON="$common"
  GIT_PIN_TREE="$tree"
}

# gitfile_init TOPLEVEL — after gitfile_pin: the worktree's gitfile must name
# the pinned admin folder; save the link files' bytes for gitfile_verify.
# Fails when TOPLEVEL/.git is not such a gitfile.
gitfile_init() {
  local top="$1" line admin
  [[ -n "$GIT_PIN_DIR" && -f "$top/.git" && ! -L "$top/.git" ]] || return 1
  line="$(head -n1 "$top/.git")"
  [[ "$line" == "gitdir: "* ]] || return 1
  admin="${line#gitdir: }"
  [[ "$admin" == /* ]] || admin="$top/$admin"
  [[ "$(cd "$admin" 2>/dev/null && pwd -P)" == "$GIT_PIN_DIR" ]] || return 1
  GITFILE_PATHS=("$top/.git" "$GIT_PIN_DIR/commondir" "$GIT_PIN_DIR/gitdir")
  GITFILE_SAVED="$(gitfile_state)"
}

# Compare the link files with what gitfile_init saved; on a change, taint
# host git as a .git metadata change does. Call it directly, not in $(...).
gitfile_verify() {
  [[ -n "$GITFILE_SAVED" ]] || return 0
  [[ "$(gitfile_state)" != "$GITFILE_SAVED" ]] || return 0
  GIT_META_CHANGED="worktree link files changed (${GITFILE_PATHS[*]}) "
  GIT_META_TAINTED=1
  return 1
}

