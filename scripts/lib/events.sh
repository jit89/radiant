# shellcheck shell=bash
# JSONL event helpers. JOURNAL must be set. HERE must be scripts/.
# Append is best-effort. Journal git commits stay fail-closed in the caller.

events_init() {
  # Do not touch WALK_ID / EVENTS_MINTED — append is called after a mint
  # and the caller still needs those flags to fail-close the journal commit.
  EVENTS_PY="${EVENTS_PY:-$HERE/events.py}"
}

events_ensure_walk() {
  events_init
  WALK_ID=""
  EVENTS_MINTED=0
  [[ -n "${JOURNAL:-}" && -f "$EVENTS_PY" ]] || return 0
  local info
  info="$(python3 "$EVENTS_PY" ensure-walk "$JOURNAL" 2>/dev/null || true)"
  [[ -n "$info" ]] || return 0
  WALK_ID="${info##*$'\t'}"
  if [[ "$info" == minted$'\t'* ]]; then
    EVENTS_MINTED=1
  fi
}

# Journal the walk-start line when we just minted. Caller commits (fail-closed).
events_journal_walk_start() {
  [[ "${EVENTS_MINTED:-0}" -eq 1 && -n "${WALK_ID:-}" ]] || return 0
  journal_line "## $(utc) — ORCHESTRATOR walk-start walk_id=${WALK_ID}"
  events_append --event walk_start --severity info \
    --summary "walk-start walk_id=${WALK_ID}"
}

events_end_walk() {
  events_init
  [[ -n "${JOURNAL:-}" && -f "$EVENTS_PY" ]] || return 0
  python3 "$EVENTS_PY" end-walk "$JOURNAL" 2>/dev/null || true
}

events_append() {
  events_init
  [[ -n "${JOURNAL:-}" && -f "$EVENTS_PY" ]] || return 0
  if ! python3 "$EVENTS_PY" append "$JOURNAL" "$@"; then
    echo "events: append failed (continuing)" >&2
  fi
  return 0
}
