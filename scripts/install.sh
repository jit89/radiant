#!/usr/bin/env bash
# Install house skills into the user Claude skill dir.
# The Architect is Claude Code, so skills live in ~/.claude/skills.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${CLAUDE_SKILLS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills}"
BORROWED=(wayfinder prototype research caveman tdd handoff diagnosing-bugs improve-codebase-architecture)

find_claude() {
  if [[ -n "${CLAUDE_REAL_BIN:-}" && -x "${CLAUDE_REAL_BIN}" ]]; then
    printf '%s' "$CLAUDE_REAL_BIN"; return
  fi
  [[ -x "$HOME/.local/bin/claude" ]] && { printf '%s' "$HOME/.local/bin/claude"; return; }
  command -v claude 2>/dev/null || true
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
  chmod +x \
    "$ROOT/scripts/grok-review.sh" \
    "$ROOT/scripts/claude-goal-review.sh" \
    "$ROOT/scripts/deepseek-code.sh" \
    "$ROOT/scripts/run-goal.sh" \
    "$ROOT/scripts/run-goals.sh" \
    "$ROOT/scripts/goals.py" \
    "$ROOT/scripts/events.py" \
    "$ROOT/scripts/logs.sh" \
    "$ROOT/scripts/install.sh" \
    "$ROOT/scripts/tests/findings-test.sh" \
    "$ROOT/scripts/lib/agent-result.py"
  echo "launchers: grok-review.sh claude-goal-review.sh deepseek-code.sh goals.py"
}

do_check() {
  local rc=0
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
  if "$ROOT/scripts/tests/findings-test.sh" >/dev/null 2>&1; then
    echo "findings parser: OK"
  else
    echo "findings parser: FAIL"; rc=1
    "$ROOT/scripts/tests/findings-test.sh" || true
  fi
  if "$ROOT/scripts/goals.py" "$ROOT/GOALS.example.md" validate \
    && "$ROOT/scripts/goals.py" "$ROOT/GOALS.example.md" todos \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d)==3'; then
    echo "goals.py: OK"
  else
    echo "goals.py: FAIL"; rc=1
  fi
  if "$ROOT/scripts/mock-walk.sh" --quick >/tmp/cw-mock-walk-check.out \
    && grep -q 'GOAL g4-delta DONE' /tmp/cw-mock-walk-check.out \
    && grep -q 'walk-end' /tmp/cw-mock-walk-check.out; then
    echo "mock-walk: OK"
  else
    echo "mock-walk: FAIL"; rc=1
  fi
  rltmp="$(mktemp -t grok-rl-XXXXXX.json)"
  printf '%s\n' '{"is_error":true,"api_error_status":429,"result":"You hit your session limit","terminal_reason":"api_error"}' >"$rltmp"
  # shellcheck disable=SC1091
  source "$ROOT/scripts/lib/dotenv.sh"
  grtmp="$(mktemp -t grok-rl-XXXXXX.json)"
  printf '%s\n' '{"error":{"message":"429 Too Many Requests"},"stopReason":"error"}' >"$grtmp"
  oktmp="$(mktemp -t grok-ok-XXXXXX.json)"
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
    export EVENTS_CACHE="$waketmp/cache"
    export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
    export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
    cd "$waketmp"
    git init -q
    mkdir -p docs/journal
    cp "$ROOT/GOALS.example.md" GOALS.md
    printf '# Journal: example\n' > docs/journal/example.md
    git add -- GOALS.md docs/journal/example.md
    git -c user.email=mock@localhost -c user.name=mock \
      commit -q -m "chore: wake-check DAG"
    echo dirt > dirt.txt
    set +e
    "$ROOT/scripts/run-goal.sh" g1-store >/tmp/cw-wake-check.out 2>/tmp/cw-wake-check.err
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
    # Borrowed skills may live in the Claude skill dir (symlinked from
    # ~/mattpocock-skills by that repo's installer) or in ~/.agents/skills.
    if [[ ! -e "$DEST/$s" && ! -e "$DEST/$s/SKILL.md" \
       && ! -e "$HOME/.agents/skills/$s" && ! -e "$HOME/.agents/skills/$s/SKILL.md" ]]; then
      missing+=("$s")
    fi
  done
  if ((${#missing[@]})); then
    echo "borrowed skills missing from $DEST and ~/.agents/skills: ${missing[*]}"
    echo "  (house still works; /crucible research/prototype/tdd/wayfinder will not)"
  else
    echo "borrowed skills: present"
  fi
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
