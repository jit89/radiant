#!/usr/bin/env bash
# Install house skills into the user Grok skill dir.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${GROK_HOME:-$HOME/.grok}/skills"
BORROWED=(wayfinder prototype research caveman tdd handoff diagnosing-bugs improve-codebase-architecture)

find_claude() {
  if [[ -n "${CLAUDE_REAL_BIN:-}" && -x "${CLAUDE_REAL_BIN}" ]]; then
    printf '%s' "$CLAUDE_REAL_BIN"; return
  fi
  [[ -x "$HOME/.local/bin/claude" ]] && { printf '%s' "$HOME/.local/bin/claude"; return; }
  command -v claude 2>/dev/null || true
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
    "$ROOT/scripts/claude-review.sh" \
    "$ROOT/scripts/claude-goal-review.sh" \
    "$ROOT/scripts/deepseek-code.sh" \
    "$ROOT/scripts/run-goal.sh" \
    "$ROOT/scripts/run-goals.sh" \
    "$ROOT/scripts/goals.py" \
    "$ROOT/scripts/install.sh" \
    "$ROOT/scripts/lib/claude-result.py"
  echo "launchers: claude-review.sh claude-goal-review.sh deepseek-code.sh goals.py"
}

do_check() {
  local rc=0
  local claude codex
  claude="$(find_claude || true)"
  if [[ -n "$claude" ]]; then
    echo "claude: $claude ($("$claude" --version 2>/dev/null | head -n1))"
  else
    echo "claude: MISSING"; rc=1
  fi
  if codex="$(find_codex)"; then
    echo "codex: $codex ($("$codex" --version 2>/dev/null | head -n1))"
  else
    echo "codex: MISSING"; rc=1
  fi
  if "$ROOT/scripts/goals.py" "$ROOT/GOALS.example.md" validate; then
    echo "goals.py: OK"
  else
    echo "goals.py: FAIL"; rc=1
  fi
  local missing=()
  local s
  for s in "${BORROWED[@]}"; do
    if [[ ! -e "$HOME/.agents/skills/$s" && ! -e "$HOME/.agents/skills/$s/SKILL.md" ]]; then
      missing+=("$s")
    fi
  done
  if ((${#missing[@]})); then
    echo "borrowed skills missing under ~/.agents/skills: ${missing[*]}"
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
