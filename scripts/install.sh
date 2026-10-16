#!/usr/bin/env bash
# Install house skills into the user Claude skill dir.
# The Architect is Claude Code, so skills live in ~/.claude/skills.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${CLAUDE_SKILLS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills}"
# Borrowed from github.com/mattpocock/skills, pinned. grilling, domain-modeling,
# codebase-design and setup-matt-pocock-skills are not called by the house
# directly: wayfinder and improve-codebase-architecture call them.
BORROWED=(wayfinder prototype research tdd handoff diagnosing-bugs improve-codebase-architecture
  grilling domain-modeling codebase-design setup-matt-pocock-skills)
MATTPOCOCK_SKILLS_DIR="${MATTPOCOCK_SKILLS_DIR:-$HOME/mattpocock-skills}"
MATTPOCOCK_SKILLS_PIN=49dd158d1076134a641b33efb035946536778336

# Directory of borrowed skill NAME inside the clone, or nothing.
borrowed_src() {
  local b
  for b in engineering productivity; do
    if [[ -f "$MATTPOCOCK_SKILLS_DIR/skills/$b/$1/SKILL.md" ]]; then
      printf '%s' "$MATTPOCOCK_SKILLS_DIR/skills/$b/$1"
      return 0
    fi
  done
  return 1
}

clone_hint() {
  echo "  git clone https://github.com/mattpocock/skills $MATTPOCOCK_SKILLS_DIR"
  echo "  git -C $MATTPOCOCK_SKILLS_DIR checkout $MATTPOCOCK_SKILLS_PIN"
}

find_claude() {
  if [[ -n "${CLAUDE_REAL_BIN:-}" && -x "${CLAUDE_REAL_BIN}" ]]; then
    printf '%s' "$CLAUDE_REAL_BIN"; return
  fi
  [[ -x "$HOME/.local/bin/claude" ]] && { printf '%s' "$HOME/.local/bin/claude"; return; }
  command -v claude 2>/dev/null || true
}

# The house's mods, each installed from the local marketplace
# (.claude-plugin/marketplace.json) as <name>@claude-coding-workflow.
MODS=(walk lessons)

# mod_copy_current NAME — true when the installed mod (a copy in the plugin
# cache) matches mods/NAME, the types the engine writes into a loaded mod aside
# (a mod's own types/index.d.ts contract, where it has one, is compared).
mod_copy_current() {
  local name="$1" copy
  copy="$(python3 - "$name" <<'EOF' 2>/dev/null
import json, os, sys
p = os.path.expanduser("~/.claude/plugins/installed_plugins.json")
rows = json.load(open(p)).get("plugins", {}).get(sys.argv[1] + "@claude-coding-workflow") or []
print(rows[0]["installPath"] if rows else "")
EOF
)"
  [[ -n "$copy" && -d "$copy" ]] || return 1
  diff -rq -x types -x .DS_Store "$ROOT/mods/$name" "$copy" >/dev/null 2>&1 || return 1
  [[ ! -f "$ROOT/mods/$name/types/index.d.ts" ]] ||
    diff -q "$ROOT/mods/$name/types/index.d.ts" "$copy/types/index.d.ts" >/dev/null 2>&1
}

find_grok() {
  if [[ -n "${GROK_BIN:-}" && -x "${GROK_BIN}" ]]; then
    printf '%s' "$GROK_BIN"; return
  fi
  local c
  c="$(command -v grok 2>/dev/null || true)"
  [[ -n "$c" ]] && { printf '%s' "$c"; return; }
  for c in "$HOME/.grok/bin/grok" "$HOME/.local/bin/grok" /opt/homebrew/bin/grok; do
    [[ -x "$c" ]] && { printf '%s' "$c"; return; }
  done
  return 1
}

find_codex() {
  if [[ -n "${CODEX_BIN:-}" && -x "${CODEX_BIN}" ]]; then
    printf '%s' "$CODEX_BIN"; return
  fi
  local c
  c="$(command -v codex 2>/dev/null || true)"
  [[ -n "$c" ]] && { printf '%s' "$c"; return; }
  c="$(ls -1d "$HOME"/.nvm/versions/node/*/bin/codex 2>/dev/null | tail -n1 || true)"
  [[ -n "$c" && -x "$c" ]] && { printf '%s' "$c"; return; }
  return 1
}

do_install() {
  mkdir -p "$DEST"
  for skill in crucible to-goals run-goal run-goals; do
    ln -sfn "$ROOT/skills/$skill" "$DEST/$skill"
    echo "installed: $DEST/$skill -> $ROOT/skills/$skill"
  done
  if [[ -d "$MATTPOCOCK_SKILLS_DIR/skills" ]]; then
    local s src
    for s in "${BORROWED[@]}"; do
      if ! src="$(borrowed_src "$s")"; then
        echo "borrowed: $s not found in $MATTPOCOCK_SKILLS_DIR (wrong pin?)"
        continue
      fi
      # A real directory is someone's own copy: leave it.
      if [[ -e "$DEST/$s" && ! -L "$DEST/$s" ]]; then
        echo "borrowed: $DEST/$s is a real directory, left alone"
        continue
      fi
      ln -sfn "$src" "$DEST/$s"
      echo "borrowed: $DEST/$s -> $src"
    done
  else
    echo "borrowed skills not linked: no clone at $MATTPOCOCK_SKILLS_DIR. Clone and pin it:"
    clone_hint
  fi
  # The mods: walk (the walk's goals in the session's task list, and the /walk pane)
  # and lessons (approved reminders from repeated failures, and /lessons),
  # installed through a local marketplace. `plugin install` copies a mod into
  # the plugin cache, so a changed mod is pushed there by `plugin update`
  # (which needs a new version in mods/<name>/.claude-plugin/plugin.json); open
  # sessions pick it up after a restart.
  local claude_bin
  claude_bin="$(find_claude)"
  if [[ -n "$claude_bin" ]]; then
    if ! "$claude_bin" plugin marketplace list 2>/dev/null | grep -q 'claude-coding-workflow'; then
      "$claude_bin" plugin marketplace add "$ROOT" >/dev/null 2>&1 &&
        echo "marketplace: claude-coding-workflow -> $ROOT" ||
        echo "marketplace: could not add $ROOT (run: claude plugin marketplace add $ROOT)"
    fi
    local mod refreshed=""
    for mod in "${MODS[@]}"; do
      if ! "$claude_bin" plugin list 2>/dev/null | grep -q "$mod@claude-coding-workflow"; then
        [[ -n "$refreshed" ]] || { "$claude_bin" plugin marketplace update claude-coding-workflow >/dev/null 2>&1 || true; refreshed=1; }
        "$claude_bin" plugin install "$mod@claude-coding-workflow" >/dev/null 2>&1 &&
          echo "mod: $mod installed (restart open sessions)" ||
          echo "mod: could not install $mod (run: claude plugin install $mod@claude-coding-workflow)"
      elif ! mod_copy_current "$mod"; then
        [[ -n "$refreshed" ]] || { "$claude_bin" plugin marketplace update claude-coding-workflow >/dev/null 2>&1 || true; refreshed=1; }
        "$claude_bin" plugin update "$mod@claude-coding-workflow" >/dev/null 2>&1 || true
        if mod_copy_current "$mod"; then
          echo "mod: $mod updated (restart open sessions)"
        else
          echo "mod: WARN $mod's installed copy differs from mods/$mod and was not updated:"
          echo "     bump the version in mods/$mod/.claude-plugin/plugin.json, re-run install.sh"
        fi
      fi
    done
  fi
  chmod +x \
    "$ROOT/scripts/grok-review.sh" \
    "$ROOT/scripts/claude-goal-review.sh" \
    "$ROOT/scripts/claude-implement.sh" \
    "$ROOT/scripts/deepseek-code.sh" \
    "$ROOT/scripts/run-goal.sh" \
    "$ROOT/scripts/run-goals.sh" \
    "$ROOT/scripts/goals.py" \
    "$ROOT/scripts/events.py" \
    "$ROOT/scripts/lessons.py" \
    "$ROOT/scripts/logs.sh" \
    "$ROOT/scripts/install.sh" \
    "$ROOT/scripts/tests/findings-test.sh" \
    "$ROOT/scripts/tests/orch-commit-test.sh" \
    "$ROOT/scripts/tests/git-guard-test.sh" \
    "$ROOT/scripts/tests/signal-test.sh" \
    "$ROOT/scripts/tests/result-parse-test.sh" \
    "$ROOT/scripts/tests/goals-contract-test.sh" \
    "$ROOT/scripts/tests/goals-body-test.sh" \
    "$ROOT/scripts/tests/blockers-test.sh" \
    "$ROOT/scripts/tests/resume-contract-test.sh" \
    "$ROOT/scripts/tests/verdict-test.sh" \
    "$ROOT/scripts/tests/resume-state-test.sh" \
    "$ROOT/scripts/tests/walk-end-test.sh" \
    "$ROOT/scripts/tests/proof-test.sh" \
    "$ROOT/scripts/tests/review-fallback-test.sh" \
    "$ROOT/scripts/tests/implement-test.sh" \
    "$ROOT/scripts/tests/walk-status-test.sh" \
    "$ROOT/scripts/tests/lessons-test.sh" \
    "$ROOT/scripts/tests/grok-review-test.sh" \
    "$ROOT/scripts/tests/tmp-hygiene-test.sh" \
    "$ROOT/scripts/tests/run-all.sh" \
    "$ROOT/scripts/lib/claude-meta.py" \
    "$ROOT/scripts/lib/oracle-files.py" \
    "$ROOT/scripts/lib/flagged-refusal.py" \
    "$ROOT/scripts/lib/resume-state.py" \
    "$ROOT/scripts/lib/verdict.py" \
    "$ROOT/scripts/lib/run-timeout.py" \
    "$ROOT/scripts/lib/tree-key.py" \
    "$ROOT/scripts/lib/agent-result.py"
  echo "launchers: grok-review.sh claude-goal-review.sh deepseek-code.sh goals.py"
}

# The house tests run once, side by side (scripts/tests/run-all.sh: each in its
# own TMPDIR and HOME, a leak counts as a failure); the steps below read the
# results. CW_TEST_JOBS sets how many at a time (default 4). A full run of this
# same tree (run-all.sh's tests/last/, its key from lib/tree-key.py still
# matching) is reused instead; CW_CHECK_RERUN=1 runs the suite regardless.
TEST_RESULTS=""
test_ok() { [[ "$(cat "$TEST_RESULTS/$1.rc" 2>/dev/null)" == 0 ]]; }
test_show() { cat "$TEST_RESULTS/$1.out" 2>/dev/null || echo "(no output: $1 did not run)"; }

do_check() {
  local rc=0
  local suite_rc=0
  local key
  TEST_RESULTS="$(mktemp -d "${TMPDIR:-/tmp}/cw-check-tests-XXXXXX")"
  # Removed on any exit: set -e can end --check before its last line.
  trap 'rm -rf "$TEST_RESULTS"' EXIT
  key="$(python3 "$ROOT/scripts/lib/tree-key.py" "$ROOT" 2>/dev/null || true)"
  # A copy, so a run publishing meanwhile cannot change what is read. Its key
  # line holds the tree's key and that run's fail count.
  local kept=""
  if [[ "${CW_CHECK_RERUN:-0}" != 1 && -n "$key" ]] &&
    cp -R "$HOME/.cache/claude-coding-workflow/tests/last/." "$TEST_RESULTS/" 2>/dev/null &&
    kept="$(cat "$TEST_RESULTS/key" 2>/dev/null)" && [[ "${kept%% *}" == "$key" ]]; then
    [[ "$kept" == "$key 0" ]] || suite_rc=1
    echo "tests: reused the full run of $(cat "$TEST_RESULTS/when" 2>/dev/null) (this tree; CW_CHECK_RERUN=1 to rerun)"
  else
    rm -rf "${TEST_RESULTS:?}"/* "$TEST_RESULTS"/.[!.]* 2>/dev/null || true
    # In the background so a signal to --check reaches the runner rather than
    # orphaning it (a background job starts with INT ignored, so Ctrl-C is
    # passed on as TERM); the runner stops its tests and dies of the signal.
    # `|| true` on the waits: under set -e the runner's 143 would end the trap
    # before its own exit status.
    "$ROOT/scripts/tests/run-all.sh" --results "$TEST_RESULTS" >"$TEST_RESULTS/summary" 2>&1 &
    RUNNER_PID=$!
    trap 'kill -TERM "$RUNNER_PID" 2>/dev/null; wait "$RUNNER_PID" 2>/dev/null || true; exit 130' INT
    trap 'kill -TERM "$RUNNER_PID" 2>/dev/null; wait "$RUNNER_PID" 2>/dev/null || true; exit 143' TERM
    wait "$RUNNER_PID" || suite_rc=$?
    trap - INT TERM
    # Killed rather than failed: stop here, not with every step reading FAIL.
    if [[ "$suite_rc" -gt 128 ]]; then
      echo "tests: interrupted (exit $suite_rc)"
      exit "$suite_rc"
    fi
  fi
  if [[ "$suite_rc" -eq 0 ]]; then
    echo "tests: OK ($(tail -n1 "$TEST_RESULTS/summary"))"
  else
    echo "tests: FAIL"; rc=1
    # Names only: each failing step below prints its test's output.
    grep -E '^(FAIL|LEAK) ' "$TEST_RESULTS/summary" || true
  fi
  local claude codex grok
  claude="$(find_claude || true)"
  if [[ -n "$claude" ]]; then
    echo "claude: $claude ($("$claude" --version 2>/dev/null | head -n1))"
  else
    echo "claude: MISSING"; rc=1
  fi
  if grok="$(find_grok)"; then
    echo "grok: $grok ($("$grok" --version 2>/dev/null | head -n1))"
  else
    echo "grok: MISSING (plan attacker unavailable)"; rc=1
  fi
  if codex="$(find_codex)"; then
    echo "codex: $codex ($("$codex" --version 2>/dev/null | head -n1))"
  else
    echo "codex: MISSING"; rc=1
  fi
  if test_ok findings-test.sh; then
    echo "findings parser: OK"
  else
    echo "findings parser: FAIL"; rc=1
    test_show findings-test.sh
  fi
  if test_ok orch-commit-test.sh; then
    echo "orchestrator commits: OK (narrow; no foreign GOALS.md or journal edits)"
  else
    echo "orchestrator commits: FAIL"; rc=1
    test_show orch-commit-test.sh
  fi
  if test_ok git-guard-test.sh; then
    echo "git guard: OK (.git plus its config include graph, checked before every host git call)"
  else
    echo "git guard: FAIL"; rc=1
    test_show git-guard-test.sh
  fi
  if test_ok signal-test.sh; then
    echo "signals: OK (INT/TERM stop nonzero, no orphans)"
  else
    echo "signals: FAIL"; rc=1
    test_show signal-test.sh
  fi
  if test_ok result-parse-test.sh; then
    echo "launcher results: OK (missing/timeout classified)"
  else
    echo "launcher results: FAIL"; rc=1
    test_show result-parse-test.sh
  fi
  if test_ok goals-contract-test.sh; then
    echo "GOALS.md contract: OK (bodies frozen, status only)"
  else
    echo "GOALS.md contract: FAIL"; rc=1
    test_show goals-contract-test.sh
  fi
  if test_ok goals-body-test.sh; then
    echo "goal bodies: OK (exact id, every goal needs one body)"
  else
    echo "goal bodies: FAIL"; rc=1
    test_show goals-body-test.sh
  fi
  if test_ok blockers-test.sh; then
    echo "blockers gate: OK (no dispatch past an unfinished blocker)"
  else
    echo "blockers gate: FAIL"; rc=1
    test_show blockers-test.sh
  fi
  if test_ok resume-contract-test.sh; then
    echo "resume contract: OK (committed, staged, unstaged, untracked and ignored drift refused)"
  else
    echo "resume contract: FAIL"; rc=1
    test_show resume-contract-test.sh
  fi
  if test_ok verdict-test.sh; then
    echo "verdicts: OK (final VERDICT: line only; brief matches prompt)"
  else
    echo "verdicts: FAIL"; rc=1
    test_show verdict-test.sh
  fi
  if test_ok resume-state-test.sh; then
    echo "resume state: OK (same thread/session, pending FIX restored)"
  else
    echo "resume state: FAIL"; rc=1
    test_show resume-state-test.sh
  fi
  if test_ok walk-end-test.sh; then
    echo "walk end: OK (exit 0 only when every goal is done)"
  else
    echo "walk end: FAIL"; rc=1
    test_show walk-end-test.sh
  fi
  if test_ok journal-records-test.sh; then
    echo "journal records: OK (only this goal's records are committed; resume takes them)"
  else
    echo "journal records: FAIL"; rc=1
    test_show journal-records-test.sh
  fi
  if test_ok plan-freeze-test.sh; then
    echo "plan freeze: OK (agents read the plan at BASE_SHA; edits are tamper)"
  else
    echo "plan freeze: FAIL"; rc=1
    test_show plan-freeze-test.sh
  fi
  if test_ok proof-test.sh; then
    echo "proof: OK (timeout, no credentials, repo unchanged; ignored files only outside the contract)"
  else
    echo "proof: FAIL"; rc=1
    test_show proof-test.sh
  fi
  if test_ok implement-test.sh; then
    echo "implementer: OK (Haiku sandboxed and key-free; one DeepSeek fallback on a refusal or decline, none on a rate limit)"
  else
    echo "implementer: FAIL"; rc=1
    test_show implement-test.sh
  fi
  if test_ok grok-review-test.sh; then
    echo "grok review: OK (a turn that did not end normally is an error, never a review)"
  else
    echo "grok review: FAIL"; rc=1
    test_show grok-review-test.sh
  fi
  if test_ok tmp-hygiene-test.sh; then
    echo "temp hygiene: OK (launcher output in the caller's folder; wake evidence under ~/.cache, 0700, pruned past 14 days)"
  else
    echo "temp hygiene: FAIL"; rc=1
    test_show tmp-hygiene-test.sh
  fi
  if test_ok lessons-test.sh; then
    echo "lessons: OK (extract, redaction, the evidence queue, distil cage, /lessons, render, detach)"
  else
    echo "lessons: FAIL"; rc=1
    test_show lessons-test.sh
  fi
  if test_ok walk-status-test.sh; then
    echo "walk status: OK (the running goal from the event index; idle once stopped or its process is gone)"
  else
    echo "walk status: FAIL"; rc=1
    test_show walk-status-test.sh
  fi
  local cbin
  cbin="$(find_claude)"
  if [[ -n "$cbin" ]]; then
    local mod
    for mod in "${MODS[@]}"; do
      if "$cbin" plugin test "$ROOT/mods/$mod" >/dev/null 2>&1; then
        echo "$mod mod: OK (tests pass)"
      else
        echo "$mod mod: FAIL"; rc=1
        "$cbin" plugin test "$ROOT/mods/$mod" || true
      fi
      if "$cbin" plugin list 2>/dev/null | grep -A4 "$mod@claude-coding-workflow" | grep -q 'enabled'; then
        echo "$mod mod: installed and enabled"
        if mod_copy_current "$mod"; then
          echo "$mod mod: installed copy matches the repo"
        else
          echo "$mod mod: WARN installed copy differs from mods/$mod (bump its version, re-run install.sh)"
        fi
      else
        echo "$mod mod: not installed (re-run install.sh)"
      fi
    done
  fi
  if "$ROOT/scripts/goals.py" "$ROOT/GOALS.example.md" validate \
    && "$ROOT/scripts/goals.py" "$ROOT/GOALS.example.md" todos \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d)==3'; then
    echo "goals.py: OK"
  else
    echo "goals.py: FAIL"; rc=1
  fi
  mwtmp="$(mktemp -d "${TMPDIR:-/tmp}/cw-mock-walk-check-XXXXXX")"
  if "$ROOT/scripts/mock-walk.sh" --quick --dir "$mwtmp/repo" >"$mwtmp/out" \
    && grep -q 'GOAL g4-delta DONE' "$mwtmp/out" \
    && grep -q 'walk-end' "$mwtmp/out"; then
    echo "mock-walk: OK"
  else
    echo "mock-walk: FAIL"; rc=1
  fi
  rm -rf "$mwtmp"
  rltmp="$(mktemp "${TMPDIR:-/tmp}/grok-rl-XXXXXX")"
  printf '%s\n' '{"is_error":true,"api_error_status":429,"result":"You hit your session limit","terminal_reason":"api_error"}' >"$rltmp"
  # shellcheck disable=SC1091
  source "$ROOT/scripts/lib/dotenv.sh"
  grtmp="$(mktemp "${TMPDIR:-/tmp}/grok-rl-XXXXXX")"
  printf '%s\n' '{"error":{"message":"429 Too Many Requests"},"stopReason":"error"}' >"$grtmp"
  oktmp="$(mktemp "${TMPDIR:-/tmp}/grok-ok-XXXXXX")"
  printf '%s\n' '{"text":"PONG","stopReason":"end_turn","sessionId":"x"}' >"$oktmp"
  if is_transport_rate_limit 1 /dev/null "$rltmp" \
    && is_transport_rate_limit 1 /dev/null "$grtmp" \
    && ! is_transport_rate_limit 1 /dev/null "$oktmp"; then
    echo "rate-limit envelope: OK (claude + grok)"
  else
    echo "rate-limit envelope: FAIL"; rc=1
  fi
  rm -f "$rltmp" "$grtmp" "$oktmp"
  if python3 "$ROOT/scripts/events.py" --self-test; then
    echo "events.py: OK"
  else
    echo "events.py: FAIL"; rc=1
  fi
  # events_append must not clobber EVENTS_MINTED (walk-start commit skipped).
  mintedtmp="$(mktemp -d "${TMPDIR:-/tmp}/cw-minted-check-XXXXXX")"
  if (
    export EVENTS_CACHE="$mintedtmp/cache" HERE="$ROOT/scripts"
    # shellcheck disable=SC1091
    source "$ROOT/scripts/lib/events.sh"
    JOURNAL="$mintedtmp/j.md"
    printf '# Journal: t\n' >"$JOURNAL"
    utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
    journal_line() { printf '\n%s\n' "$1" >>"$JOURNAL"; }
    events_ensure_walk
    [[ "$EVENTS_MINTED" -eq 1 && -n "$WALK_ID" ]]
    events_append --event walk --severity info --summary "probe"
    [[ "$EVENTS_MINTED" -eq 1 ]]
  ); then
    echo "events minted-flag: OK"
  else
    echo "events minted-flag: FAIL"; rc=1
  fi
  rm -rf "$mintedtmp"
  evtmp="$(mktemp -d "${TMPDIR:-/tmp}/cw-logs-check-XXXXXX")"
  if (
    export EVENTS_CACHE="$evtmp/cache"
    cd "$evtmp"
    mkdir -p docs/journal
    cp "$ROOT/GOALS.example.md" GOALS.md
    printf '# Journal: example\n' > docs/journal/example.md
    info="$(python3 "$ROOT/scripts/events.py" ensure-walk docs/journal/example.md)"
    wid="${info##*$'\t'}"
    printf '\n## 2026-08-15T00:00:00Z — ORCHESTRATOR walk-start walk_id=%s\n' "$wid" \
      >> docs/journal/example.md
    python3 "$ROOT/scripts/events.py" append docs/journal/example.md \
      --event wake --severity error --summary "wake g1-store r0 reason=gate" \
      --goal g1-store --round 0 --reason gate
    "$ROOT/scripts/logs.sh" errors | grep -q 'wake g1-store'
  ); then
    echo "logs.sh: OK"
  else
    echo "logs.sh: FAIL"; rc=1
  fi
  rm -rf "$evtmp"
  waketmp="$(mktemp -d "${TMPDIR:-/tmp}/cw-wake-check-XXXXXX")"
  if (
    export EVENTS_CACHE="$waketmp/cache" HOME="$waketmp/home"
    mkdir -p "$HOME"
    export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
    export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
    cd "$waketmp"
    git init -q
    mkdir -p docs/journal
    cp "$ROOT/GOALS.example.md" GOALS.md
    printf '# Plan\n' > PLAN.md
    printf '# Journal: example\n' > docs/journal/example.md
    git add -- GOALS.md PLAN.md docs/journal/example.md
    git -c user.email=mock@localhost -c user.name=mock \
      commit -q -m "chore: wake-check DAG"
    echo dirt > dirt.txt
    set +e
    "$ROOT/scripts/run-goal.sh" g1-store >"$waketmp/out" 2>"$waketmp/err"
    wrc=$?
    set -e
    [[ "$wrc" -ne 0 ]]
    grep -q 'ORCHESTRATOR wake g1-store r0 reason=gate' docs/journal/example.md
    grep -q 'ORCHESTRATOR walk-start walk_id=' docs/journal/example.md
    "$ROOT/scripts/logs.sh" errors | grep -q 'reason=gate'
  ); then
    echo "run-goal wake: OK"
  else
    echo "run-goal wake: FAIL"; rc=1
  fi
  rm -rf "$waketmp"
  local missing=()
  local s
  for s in "${BORROWED[@]}"; do
    # -f follows the symlink: a dangling link counts as missing.
    if [[ -f "$DEST/$s/SKILL.md" ]]; then
      echo "borrowed $s: present"
    else
      echo "borrowed $s: MISSING"
      missing+=("$s")
    fi
  done
  if ((${#missing[@]})); then
    echo "borrowed skills missing from $DEST: ${missing[*]} (re-run install.sh)"
    echo "  (house still works; /crucible research/prototype/tdd/wayfinder will not)"
  fi
  local head
  if head="$(git -C "$MATTPOCOCK_SKILLS_DIR" rev-parse HEAD 2>/dev/null)"; then
    if [[ "$head" == "$MATTPOCOCK_SKILLS_PIN" ]]; then
      echo "mattpocock-skills pin: OK ($MATTPOCOCK_SKILLS_PIN)"
    else
      echo "mattpocock-skills pin: DRIFT (HEAD $head, pin $MATTPOCOCK_SKILLS_PIN)"
      echo "  git -C $MATTPOCOCK_SKILLS_DIR checkout $MATTPOCOCK_SKILLS_PIN"
    fi
  else
    echo "mattpocock-skills pin: no clone at $MATTPOCOCK_SKILLS_DIR"
    clone_hint
  fi
  rm -rf "$TEST_RESULTS"
  return "$rc"
}

case "${1:-}" in
  --check) do_check ;;
  -h|--help)
    echo "usage: install.sh [--check]"
    ;;
  "")
    do_install
    do_check || true
    ;;
  *)
    echo "usage: install.sh [--check]" >&2
    exit 2
    ;;
esac
