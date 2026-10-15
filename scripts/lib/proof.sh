# shellcheck shell=bash
# A goal's proof on the host, shared by run-goal.sh (the host proof) and
# run-goals.sh (the merged proofs after an integration): the same timeout,
# environment and tamper check in both, not two copies.
#
# Needs the git() wrapper (lib/git-guard.sh). Sets CHILD_PID while a step runs,
# for the caller's signal handler to stop.

PROOF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHILD_PID="${CHILD_PID:-}"

# run_step SECS OUT ERR CMD... — CMD under a timeout (0 = none), in its own
# process group, in the background. Waiting with `wait` rather than in the
# foreground is what lets INT/TERM act now instead of when CMD ends. ERR equal
# to OUT merges the streams.
run_step() {
  local secs="$1" out="$2" err="$3"
  shift 3
  local timer=(python3 "$PROOF_LIB_DIR/run-timeout.py" "$secs")
  if command -v gtimeout >/dev/null 2>&1; then
    timer=(gtimeout --kill-after=5 "$secs")
  elif command -v timeout >/dev/null 2>&1; then
    timer=(timeout --kill-after=5 "$secs")
  fi
  if [[ "$err" == "$out" ]]; then
    "${timer[@]}" "$@" >"$out" 2>&1 &
  else
    "${timer[@]}" "$@" >"$out" 2>"$err" &
  fi
  CHILD_PID=$!
  local rc=0
  wait "$CHILD_PID" || rc=$?
  CHILD_PID=""
  return "$rc"
}

# `env -u` arguments for every exported variable named like a credential — a
# whole _-separated part KEY, APIKEY, TOKEN, SECRET, PASSWORD, PASSWD or
# CREDENTIAL(S) — except names in PROOF_ENV_KEEP and git's own GIT_CONFIG_*.
# The proof runs implementer-written code on the host; it gets PATH and the
# rest, not the keys.
proof_env_unsets() {
  local name keep=" ${PROOF_ENV_KEEP:-} "
  for name in $(compgen -e); do
    [[ "$keep" != *" $name "* && "$name" != GIT_CONFIG_* ]] || continue
    if grep -qiE '(^|_)(API)?KEY(_|$)|(^|_)(TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIALS?)(_|$)' <<<"$name"; then
      printf '%s\n' -u "$name"
    fi
  done
}

# proof_exec SECS OUT TMP CMD — run a proof (or worktree_setup) string with
# plain `bash -c` (not -lc: the gate must not depend on the user's interactive
# profile), credential variables stripped, and PYTHONDONTWRITEBYTECODE: a
# Python proof would otherwise write .pyc files under tests/acceptance/, which
# the ignored-file contract rule (rightly) calls tampering (D-09). TMP, when
# not empty, is the proof's private TMPDIR (made 700 here), so proofs running
# side by side do not share one. Returns the command's exit status (124: timed
# out).
proof_exec() {
  local secs="$1" out="$2" tmp="$3" cmd="$4" u unsets=() tmpenv=()
  while IFS= read -r u; do unsets+=("$u"); done < <(proof_env_unsets)
  if [[ -n "$tmp" ]]; then
    mkdir -p "$tmp" && chmod 700 "$tmp"
    tmpenv=("TMPDIR=$tmp")
  fi
  run_step "$secs" "$out" "$out" \
    env "${unsets[@]+"${unsets[@]}"}" "${tmpenv[@]+"${tmpenv[@]}"}" PYTHONDONTWRITEBYTECODE=1 bash -c "$cmd"
}

# HEAD, tracked and staged changes, and every untracked path not ignored —
# what a proof must leave as it found. Artifact policy: output a project
# declares in .gitignore (caches, reports, coverage) is the proof's to write,
# and the next goal's clean-tree gate does not see it. Anything else a proof
# creates — source, config, a symlink — nobody reviews and it can steer the
# proof, so it is tampering. Under a contract path that policy does not
# apply: ignored files there are listed too, or a proof could drop an
# ignored script into tests/acceptance/ that no check and no reviewer sees.
# Contract paths: tests/acceptance, .claude, .mcp.json, $PLAN_PATH, $ORACLE,
# and any in PROOF_GUARDED_EXTRA (the walker's other goals' file oracles).
tree_snapshot() {
  git rev-parse HEAD
  git status --porcelain --untracked-files=all
  local guarded=(tests/acceptance .claude .mcp.json) p
  [[ -z "${ORACLE:-}" || "$ORACLE" == inline ]] || guarded+=("$ORACLE")
  [[ -z "${PLAN_PATH:-}" ]] || guarded+=("$PLAN_PATH")
  for p in ${PROOF_GUARDED_EXTRA:-}; do
    [[ "$p" == inline ]] || guarded+=("$p")
  done
  { git status --porcelain --ignored=matching -- "${guarded[@]}" || true; } |
    { grep '^!! ' || true; }
}

# proof_moved BEFORE AFTER — what changed between two tree_snapshot files, one
# finding a line (none: nothing moved). Nothing is restored here.
proof_moved() {
  local before="$1" after="$2" changed created
  if [[ "$(head -n1 "$before")" != "$(head -n1 "$after")" ]]; then
    echo "HEAD moved: $(git log --format=%h "$(head -n1 "$before")"..HEAD | paste -sd ' ' -)"
  fi
  changed="$({ diff <(sed 1d "$before") <(sed 1d "$after") || true; } |
    sed -n 's/^[<>] //p' | sort -u)"
  created="$({ grep '^?? ' <<<"$changed" || true; } | cut -c4- | paste -sd ',' -)"
  changed="$({ grep -v '^?? ' <<<"$changed" || true; } | cut -c4- | sed '/^$/d' | sort -u | paste -sd ',' -)"
  [[ -z "$changed" ]] || echo "tracked changes: $changed"
  [[ -z "$created" ]] || echo "new files not in .gitignore: $created (declare build output in .gitignore; anything else is unreviewed code)"
  return 0
}
