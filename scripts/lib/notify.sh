#!/usr/bin/env bash
# notify.sh — the always-on supervisor's iMessage to the user
# (docs/features/always-on/PLAN.md step 13). Notify-only: nothing replies.
#
#   notify.sh KIND REPO ENTRY CLASS REASON EXTRA
#
# KIND is held, done or heartbeat. A message carries only these fixed fields
# (the repo's basename, a short entry id, the class, the reason code, counts and
# spend in EXTRA) and the commands to run: never stop-detail text, findings,
# diffs or secrets. Each field keeps only [A-Za-z0-9 ._:/,$+=()#-], 160
# characters at most (EXTRA, the counts and spend, 400). The recipient is
# `recipient=` in <home>/notify.conf (CW_AO_HOME, default
# ~/.config/cw-always-on; 0600). The text and the handle
# reach Messages as argv items of an AppleScript run handler, never spliced
# into script text. CW_AO_OSASCRIPT names the osascript binary (tests).
# Exit 0 when sent; 1 when not (no recipient, osascript failed).
set -euo pipefail

HOME_DIR="${CW_AO_HOME:-$HOME/.config/cw-always-on}"
OSA="${CW_AO_OSASCRIPT:-/usr/bin/osascript}"

clean() { printf '%s' "$1" | LC_ALL=C tr -cd 'A-Za-z0-9 ._:/,$+=()#-' | cut -c1-"${2:-160}"; }
kind="$(clean "${1:-}")"
repo="$(clean "${2:-}")"
entry="$(clean "${3:-}")"
entry="${entry:0:12}"
cls="$(clean "${4:-}")"
reason="$(clean "${5:-}")"
extra="$(clean "${6:-}" 400)"

recipient="$(sed -n 's/^recipient=//p' "$HOME_DIR/notify.conf" 2>/dev/null | head -n1 | tr -d '[:space:]')"
[[ -n "$recipient" ]] || { echo "notify: no recipient in $HOME_DIR/notify.conf" >&2; exit 1; }

case "$kind/$reason" in
  held/supervisor-error-unsaved) text="always-on: ${repo} (${entry}) held, class ${cls}: ${reason}; the hold could not be saved. At the Mac: launchctl kickstart -k gui/\$(id -u)/com.cw.always-on, then cw-decide.sh status." ;;
  held/*) text="always-on: ${repo} (${entry}) held, class ${cls}: ${reason}. ${extra}. At the Mac: cw-decide.sh status, then resume ${entry} or skip ${entry}." ;;
  done/*) text="always-on: ${repo} (${entry}) walk done. ${extra}. cw-decide.sh status" ;;
  heartbeat/*) text="always-on heartbeat: ${extra}" ;;
  *) text="always-on: ${kind} ${repo} (${entry}) ${cls} ${reason}. ${extra}" ;;
esac

"$OSA" - "$recipient" "$text" >/dev/null <<'APPLESCRIPT' || { echo "notify: osascript failed" >&2; exit 1; }
on run argv
	set theHandle to item 1 of argv
	set theText to item 2 of argv
	tell application "Messages"
		set theService to 1st account whose service type = iMessage
		set theBuddy to participant theHandle of theService
		send theText to theBuddy
	end tell
	return "sent"
end run
APPLESCRIPT
