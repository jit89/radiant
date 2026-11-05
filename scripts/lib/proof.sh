# shellcheck shell=bash
# A goal's proof on the host, shared by run-goal.sh (the host proof) and
# run-goals.sh (the merged proofs after an integration): the same timeout,
# environment and tamper check in both, not two copies.
#
# Needs the git() wrapper (lib/git-guard.sh). Sets CHILD_PID while a step runs,
# for the caller's signal handler to stop.

PROOF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHILD_PID="${CHILD_PID:-}"
# shellcheck disable=SC1091
source "$PROOF_LIB_DIR/proof-sandbox.sh"
# Set by proof_exec when the sandbox itself stopped the run (not a red proof):
# proof-hardlink or proof-sandbox-path. The caller wakes with it.
PROOF_SANDBOX_REASON=""

# run_step SECS OUT ERR CMD... — CMD under a timeout (0 = none), in its own
# process group, in the background. Waiting with `wait` rather than in the
# foreground is what lets INT/TERM act now instead of when CMD ends. ERR equal
# to OUT merges the streams.
run_step() {
  local secs="$1" out="$2" err="$3"
  shift 3
  local timer=(python3 "$PROOF_LIB_DIR/run-timeout.py" "$secs")
  # RUN_STEP_SESSION=1: run-timeout.py --reap only. It starts CMD in a session
  # of its own (no controlling terminal) and, however CMD ends, KILLs whatever
  # is left in that session; GNU timeout would only reach its own group.
  if [[ "${RUN_STEP_SESSION:-0}" == 1 ]]; then
    timer=(python3 "$PROOF_LIB_DIR/run-timeout.py" --reap "$secs")
  elif command -v gtimeout >/dev/null 2>&1; then
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
# CREDENTIAL(S) — and every CW_* setting (the house's and the walker's, as
# claude-implement.sh strips them, so a proof sees the same environment run by
# the host as by the implementer: FUTURE-WORK item 28), except names in
# PROOF_ENV_KEEP and git's own GIT_CONFIG_*. The proof runs
# implementer-written code on the host; it gets PATH and the rest, not the keys.
proof_env_unsets() {
  local name keep=" ${PROOF_ENV_KEEP:-} "
  for name in $(compgen -e); do
    [[ "$keep" != *" $name "* && "$name" != GIT_CONFIG_* ]] || continue
    if [[ "$name" == CW_* ]]; then printf '%s\n' -u "$name"; continue; fi
    if grep -qiE '(^|_)(API)?KEY(_|$)|(^|_)(TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIALS?)(_|$)' <<<"$name"; then
      printf '%s\n' -u "$name"
    fi
  done
}

# proof_exec SECS OUT TMP CMD — run a proof (or worktree_setup) string with
# plain `bash -c` (not -lc: the gate must not depend on the user's interactive
# profile), credential variables stripped, and PYTHONDONTWRITEBYTECODE: a
# Python proof would otherwise write .pyc files under tests/acceptance/, which
# the ignored-file contract rule (rightly) calls tampering (D-09). TMP is the
# proof's private TMPDIR (made 700 here), so proofs running side by side do
# not share one. Returns the command's exit status (124: timed out; 126 with
# PROOF_SANDBOX_REASON set: the sandbox stopped it before it ran).
#
# Under the sandbox (house item 12; CW_PROOF_SANDBOX=off is the user's only
# way out) the caller also sets, for the call:
#   PROOF_ROOT     the checkout CMD runs in (required)
#   PROOF_WALK     more trees the hard-link pre-check walks (a worktree's
#                  common gitdir), space-separated
#   PROOF_NETWORK  none|loopback|true (GOALS.md proof_network); default none
#   PROOF_DEPS     the walk's dependency folder (read-only to a proof)
#   PROOF_SETUP    1 for worktree_setup: network, and PROOF_DEPS writable
proof_exec() {
  local secs="$1" out="$2" tmp="$3" cmd="$4" u unsets=() envs=() rc=0 start
  PROOF_SANDBOX_REASON=""
  while IFS= read -r u; do unsets+=("$u"); done < <(proof_env_unsets)
  [[ -n "$tmp" ]] || { echo "proof_exec: no TMPDIR given" >"$out"; PROOF_SANDBOX_REASON=proof-sandbox-path; return 126; }
  mkdir -p "$tmp" && chmod 700 "$tmp"
  local deps="${PROOF_DEPS:-$tmp}"
  envs=("TMPDIR=$tmp" PYTHONDONTWRITEBYTECODE=1
    "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_SYSTEM=/dev/null"
    "npm_config_cache=$deps/npm" "npm_config_store_dir=$deps/pnpm-store"
    npm_config_package_import_method=copy npm_config_update_notifier=false
    "UV_CACHE_DIR=$deps/uv" UV_LINK_MODE=copy "PIP_CACHE_DIR=$deps/pip"
    "CARGO_HOME=$deps/cargo" "GOMODCACHE=$deps/gomod"
    "GOCACHE=$tmp/go-build" "XDG_CACHE_HOME=$tmp/xdg-cache")
  # tool_path (docs/features/rust-toolchain-gates): the caller's non-exported
  # PROOF_TOOL_PATH leads PATH for the proof only. Only when non-empty: an empty
  # component would be `.`, the checkout the proof runs in.
  [[ -z "${PROOF_TOOL_PATH:-}" ]] || envs+=("PATH=$PROOF_TOOL_PATH:$PATH")
  if proof_sandbox_off; then
    run_step "$secs" "$out" "$out" \
      env -u SSH_AUTH_SOCK "${unsets[@]+"${unsets[@]}"}" "${envs[@]}" bash -c "$cmd"
    return
  fi
  if [[ -z "${PROOF_ROOT:-}" || ! -d "${PROOF_ROOT:-}" ]]; then
    echo "proof_exec: no checkout (PROOF_ROOT) to run in" >"$out"
    PROOF_SANDBOX_REASON=proof-sandbox-path
    return 126
  fi
  # A hard link left before the run can reach a file outside these trees.
  local walk=("$PROOF_ROOT" "$tmp") w
  for w in ${PROOF_WALK:-}; do walk+=(--gitdir "$w"); done
  [[ -z "${PROOF_DEPS:-}" ]] || walk+=("$PROOF_DEPS")
  if ! python3 "$PROOF_LIB_DIR/hardlink-check.py" "${walk[@]}" >"$out.links" 2>&1; then
    { echo "proof-hardlink: these files have a name outside the proof's trees (a hard link):"; cat "$out.links"; } >"$out"
    PROOF_SANDBOX_REASON=proof-hardlink
    return 126
  fi
  : >"$out"
  local gen=(--root "$PROOF_ROOT" --tmp "$tmp" --out "$out" --network "${PROOF_NETWORK:-none}")
  [[ -z "${PROOF_DEPS:-}" ]] || gen+=(--deps "$PROOF_DEPS")
  [[ "${PROOF_SETUP:-0}" != 1 ]] || gen+=(--setup)
  if ! python3 "$PROOF_LIB_DIR/proof-sandbox.py" "${gen[@]}" >"$out.sb" 2>"$out.sb.err"; then
    { echo "proof-sandbox-path: the sandbox profile could not be made:"; cat "$out.sb.err"; } >"$out"
    PROOF_SANDBOX_REASON=proof-sandbox-path
    return 126
  fi
  start="$(date '+%Y-%m-%d %H:%M:%S')"
  # A session of its own (run-timeout.py --reap): no controlling terminal to
  # inject keystrokes into, and when the proof ends everything still in its
  # session is killed (a child that makes its own session escapes: a known limit).
  RUN_STEP_SESSION=1 run_step "$secs" "$out" "$out" \
    "$PSB_SANDBOX_EXEC" -f "$out.sb" \
    env -u SSH_AUTH_SOCK "${unsets[@]+"${unsets[@]}"}" "${envs[@]}" bash -c "$cmd" </dev/null || rc=$?
  # Diagnosis only, never a red signal: the sandbox's denials in the run's
  # window. The kernel log names no run, so other proofs may show here too.
  # CW_PROOF_DENIALS=off skips it (~4 s a red proof; run-all.sh sets it).
  if [[ "$rc" -ne 0 && "$rc" -ne 124 && "${CW_PROOF_DENIALS:-on}" != off ]]; then
    sleep 3
    { echo
      echo "--- proof sandbox denials logged during this proof (may include other proofs running at the same time) ---"
      /usr/bin/log show --start "$start" --predicate 'sender == "Sandbox"' --style compact 2>/dev/null |
        grep 'deny(' | grep -v 'vfs\.disk-space' | sed 's/.*Sandbox: //' | sort | uniq -c | sort -rn | head -40 || true
    } >>"$out" 2>/dev/null || true
  fi
  return "$rc"
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
