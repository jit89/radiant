#!/usr/bin/env bash
# Self-test: tool_path (docs/features/rust-toolchain-gates). The GOALS.md key's
# directories lead PATH for a goal's own processes only (implementer, proof,
# reviewer), never for the host's commands; an empty value changes nothing.
# A fake `cargo` finds `cargo-<sub>` on PATH only, as real cargo does once
# proof_exec has pointed CARGO_HOME at an empty deps folder (the M0 failure).
set -euo pipefail
export CW_MUTATIONS=0

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-toolpath-XXXXXX")"
export TMPDIR="$TMP"
TMP="$(cd "$TMP" && pwd -P)"
# The tool folders live in the house checkout: the proof sandbox denies reads
# under the temp areas, and goals.py rejects a tool_path there.
TROOT="${CW_TEST_TOOLS_ROOT:-$HERE/../.test-tools}"; mkdir -p "$TROOT" && TOOLS="$(mktemp -d "$TROOT/toolpath-XXXXXX")"
trap '[[ -n "${KEEP_TMP:-}" ]] || rm -rf "$TMP" "$TOOLS"' EXIT
export HOME="$TMP/home" EVENTS_CACHE="$TMP/cache" OUTSIDE="$TMP/outside"
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
export DEEPSEEK_API_KEY=stub-deepseek-key
unset MAX_FIX_ROUNDS PROOF_TIMEOUT PROOF_ENV_KEEP PROOF_TOOL_PATH
# A fixed PATH: the developer's own (a ~/.cargo/bin with cargo-clippy) must not
# decide the "no tool_path" checks. git and python3 come by link, not by their
# folder (a Homebrew bin may also hold cargo-clippy); the links sit with the
# tool folders, where the proof sandbox can read them.
mkdir -p "$TOOLS/sysbin" && for t in git python3; do ln -s "$(command -v "$t")" "$TOOLS/sysbin/$t"; done
export PATH="$TOOLS/sysbin:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$HOME" "$OUTSIDE"
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

# The tool directory: a fake cargo, its two subcommands, and logging wrappers
# for `date` and `mktemp`, which the host calls on every run and no goal
# process here does (a log line means the prefix leaked into the host).
TP="$TOOLS/toolbin"
mkdir -p "$TP"
cat >"$TP/cargo" <<'EOF'
#!/bin/sh
sub="$1"; shift
p="$(command -v "cargo-$sub" 2>/dev/null)" || { echo "error: no such command: \`$sub\`" >&2; exit 101; }
exec "$p" "$sub" "$@"
EOF
printf '#!/bin/sh\necho clippy-ran >clippy.ran\n' >"$TP/cargo-clippy"
printf '#!/bin/sh\necho fmt-ran >fmt.ran\n' >"$TP/cargo-fmt"
for t in date mktemp; do
  real="$(command -v "$t")"
  printf '#!/bin/sh\necho "%s $*" >>"%s/host-calls"\nexec %s "$@"\n' "$t" "$OUTSIDE" "$real" >"$TP/$t"
done
chmod +x "$TP"/*

HOUSE="$TMP/house"
mkdir -p "$HOUSE/scripts"
cp -R "$HERE/." "$HOUSE/scripts/"
# The implementer and the reviewer record where cargo-clippy resolves for them.
printf '%s\n' '#!/usr/bin/env bash' \
  '{ command -v cargo-clippy || echo none; } >"$OUTSIDE/impl-path"' \
  'echo impl >impl.txt && git add impl.txt && git commit -qm "wip(g1-store): impl"' \
  'printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: t1"' >"$HOUSE/scripts/claude-implement.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  '{ command -v cargo-clippy || echo none; } >"$OUTSIDE/review-path"' \
  'printf "%s\n" "CLAUDE_REVIEW_RESULT: error (exit 1)" "SESSION_ID: s1" "VERDICT: MISSING" "VERDICT_FILE: /dev/null"' \
  'exit 1' >"$HOUSE/scripts/claude-goal-review.sh"
chmod +x "$HOUSE/scripts/"*.sh

# run_goal TOOL_PATH_LINE PROOF — a fresh repo whose g1-store proof is PROOF,
# GOALS.md carrying TOOL_PATH_LINE (empty: no key), run once.
run_goal() {
  rm -rf "$TMP/repo" "$OUTSIDE"/* "$HOME/.cache/claude-coding-workflow"
  mkdir -p "$TMP/repo/docs/journal" && cd "$TMP/repo"
  git init -q
  sed -e "/id: g1-store/,/status:/s#proof: true#proof: $2#" "$HERE/../GOALS.example.md" >GOALS.md
  [[ -z "$1" ]] || sed -i '' "s|^journal: docs/journal/example.md\$|journal: docs/journal/example.md\\
$1|" GOALS.md
  printf '# Plan\n' >PLAN.md
  printf '.gitignore\nclippy.ran\nfmt.ran\nplanted.ran\n' >.gitignore
  printf '# Journal: example\n' >docs/journal/example.md
  [[ -z "${PRE:-}" ]] || eval "$PRE"
  git add -A && git commit -q -m base
  "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 || true
  local stop
  stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)"
  reason="$(sed -n 's/^- reason: //p' "$stop" 2>/dev/null || true)"
  detail="$(sed -n 's/^- detail: //p' "$stop" 2>/dev/null || true)"
  [[ -z "${TP_DEBUG:-}" ]] || { echo "== $2: $reason / $detail"; tail -n 15 "$TMP/out"; for p in "$HOME"/.cache/claude-coding-workflow/runs/*/proof-*.txt; do echo "-- $p"; head -n 20 "$p"; done; } >&2
}
handoff() { cat "$HOME"/.cache/claude-coding-workflow/handoffs/run-goal-g1-store-*/handoff-g1-store-r0.md 2>/dev/null || true; }
yn() { [[ -e "$1" ]] && echo yes || echo no; }

# --- with tool_path: every goal process sees it, the host does not ---------
LINT_PROOF="\"$TP/cargo\" clippy --workspace \&\& \"$TP/cargo\" fmt --all --check"
run_goal "tool_path: [$TP]" "$LINT_PROOF"
check "proof: cargo found cargo-clippy on PATH" yes "$(yn "$TMP/repo/clippy.ran")"
check "proof: cargo found cargo-fmt on PATH" yes "$(yn "$TMP/repo/fmt.ran")"
check "implementer: cargo-clippy resolves into the tool dir" "$TP/cargo-clippy" "$(cat "$OUTSIDE/impl-path" 2>/dev/null)"
check "reviewer: cargo-clippy resolves into the tool dir" "$TP/cargo-clippy" "$(cat "$OUTSIDE/review-path" 2>/dev/null)"
check "host: no date/mktemp resolved into the tool dir" "" "$(cat "$OUTSIDE/host-calls" 2>/dev/null)"
check "handoff: names the tool path" yes "$(handoff | grep -qF -- "- Tool path (first on PATH for you, the proof and the reviewer): \`$TP\`" && echo yes || echo no)"
check "handoff: asks for the lint steps (a \"/abs/cargo\" clippy proof)" yes "$(handoff | grep -q "Run the proof's lint and format steps yourself" && echo yes || echo no)"

# --- without tool_path: the measured M0 failure, and no `.` on PATH --------
PRE='printf "#!/bin/sh\necho planted >planted.ran\n" >git && printf "#!/bin/sh\necho planted >planted.ran\n" >cargo && chmod +x git cargo' \
  run_goal "" "git --version \&\& { cargo --version || true; } \&\& \"$TP/cargo\" clippy"
check "no tool_path: cargo cannot find cargo-clippy" no "$(yn "$TMP/repo/clippy.ran")"
check "no tool_path: the proof went red on it" yes "$(grep -rqs 'no such command: `clippy`' "$HOME/.cache/claude-coding-workflow/runs" && echo yes || echo no)"
check "no tool_path: a planted ./git or ./cargo never ran" no "$(yn "$TMP/repo/planted.ran")"
check "no tool_path: implementer sees no cargo-clippy" none "$(cat "$OUTSIDE/impl-path" 2>/dev/null)"
check "no tool_path: no tool-path line" no "$(handoff | grep -q 'Tool path' && echo yes || echo no)"

# --- a proof with no lint step: no lint line --------------------------------
run_goal "tool_path: [$TP]" "true"
check "handoff: no lint line without clippy/fmt" no "$(handoff | grep -q "lint and format steps" && echo yes || echo no)"

# --- implementer_sandbox_skips (AUDIT-2026-11-08 F3): named in the handoff --
run_goal "implementer_sandbox_skips: [g10-seam::a_socket_is_bound_here, host::reads_sysctl]" "true"
check "skips: the handoff names each skipped test" yes "$(handoff | grep -qF -- "- Tests your sandbox cannot run (GOALS.md \`implementer_sandbox_skips\`; the host's proof runs them): \`g10-seam::a_socket_is_bound_here\`, \`host::reads_sysctl\`." && echo yes || echo no)"
check "skips: meta carries the list" '["g10-seam::a_socket_is_bound_here", "host::reads_sysctl"]' \
  "$("$HERE/goals.py" GOALS.md meta | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["implementer_sandbox_skips"]))')"
run_goal "" "true"
check "no skips: no skips line" no "$(handoff | grep -q 'Tests your sandbox cannot run' && echo yes || echo no)"
skips_err() {
  sed "s|^journal: docs/journal/example.md\$|journal: docs/journal/example.md\\
$1|" "$HERE/../GOALS.example.md" >"$TMP/skips.md"
  "$HERE/goals.py" "$TMP/skips.md" validate 2>&1 | grep -c 'implementer_sandbox_skips' || true
}
check "skips: an empty list is refused" 1 "$(skips_err 'implementer_sandbox_skips: []')"
check "skips: a shell character is refused" 1 "$(skips_err 'implementer_sandbox_skips: [a;rm]')"
check "skips: a good list validates" 0 "$(skips_err 'implementer_sandbox_skips: [g9-bulk-sys::host::x]')"

# --- resume after tool_path changed mid-goal: contract drift ----------------
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "%s\n" "IMPLEMENTER_RESULT: ok" "IMPLEMENTER_STATUS: BLOCKED" "THREAD_ID: t1"' >"$HOUSE/scripts/claude-implement.sh"
mkdir -p "$TOOLS/toolbin2"
run_goal "tool_path: [$TP]" "true"
check "resume setup: the goal paused" yes "$([[ -n "$reason" ]] && echo yes || echo no)"
sed -i '' "s|^tool_path: \[$TP\]\$|tool_path: [$TOOLS/toolbin2]|" GOALS.md
git add GOALS.md docs/journal/example.md && git commit -qm "edit tool_path while paused" || true
"$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out2" 2>&1 || true
check "resume: refused as a contract change" yes "$(grep -q 'contract changed since BASE_SHA' "$TMP/out2" && echo yes || echo "no: $(tail -3 "$TMP/out2")")"

# --- the proof_exec boundary: the prefix reaches the proof, not its caller --
mkdir -p "$TMP/gitlog"
real_git="$(command -v git)"
printf '#!/bin/sh\necho "git $*" >>"%s/git-calls"\nexec %s "$@"\n' "$OUTSIDE" "$real_git" >"$TMP/gitlog/git"
chmod +x "$TMP/gitlog/git"
rm -f "$OUTSIDE/git-calls"
(
  source "$HERE/lib/proof.sh"
  PROOF_TOOL_PATH="$TMP/gitlog" CW_PROOF_SANDBOX=off proof_exec 30 "$TMP/pe.out" "$TMP/pe-tmp" "git --version >/dev/null"
  git --version >/dev/null
)
check "proof_exec: the proof's git is the tool dir's" 1 "$(grep -c . "$OUTSIDE/git-calls" 2>/dev/null || echo 0)"
rm -f "$OUTSIDE/git-calls"
(
  source "$HERE/lib/proof.sh"
  # Run from the folder holding the logging git: an empty PATH component
  # would be `.`, and ./git would run.
  PROOF_TOOL_PATH="" CW_PROOF_SANDBOX=off proof_exec 30 "$TMP/pe.out" "$TMP/pe-tmp" "cd $(printf %q "$TMP/gitlog") && git --version >/dev/null"
)
check "proof_exec: an empty prefix adds nothing" 0 "$(grep -c . "$OUTSIDE/git-calls" 2>/dev/null || echo 0)"


# --- the lint-line match, every form PLAN step 3 names ----------------------
eval "$(sed -n '/^proof_has_lint_step() {/,/^}/p' "$HERE/run-goal.sh")"
lint_forms() {
  local c out=""
  for c in "$@"; do proof_has_lint_step "$c" && out+="T" || out+="F"; done
  echo "$out"
}
check "lint line: \"\$CARGO\", \$CARGO, \${CARGO}, cargo, /abs/cargo, \"/abs/cargo\", after &&" TTTTTTT \
  "$(lint_forms '"$CARGO" clippy -- -D warnings' '$CARGO fmt --all --check' '${CARGO} clippy' 'cargo fmt' \
    '/x/bin/cargo clippy' '"/x/bin/cargo" fmt' 'true && "$CARGO" clippy')"
check "lint line: near misses (cargo-clippy, cargo build, mycargo clippy, echo clippy, clippyx)" FFFFF \
  "$(lint_forms 'cargo-clippy' 'cargo build' 'mycargo clippy' 'echo clippy' '"$CARGO" clippyx')"

if [[ "$fails" -eq 0 ]]; then
  echo "tool-path: OK"
else
  echo "tool-path: $fails FAILURE(S)" >&2
  exit 1
fi
