#!/usr/bin/env bash
# Self-test: model verdicts are read from the final line only, in the full
# "VERDICT: <TOKEN>" form (F-03, F-04); the review brief does not contradict
# the reviewer prompt's FIX: format (F-05). Launchers are stubs.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-verdict-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
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

# Each launcher's own verdict_of, lifted out of the script as the review did.
sed -n '/^verdict_of() {/,/^}/p' "$HERE/grok-review.sh" >"$TMP/grok.sh"
sed -n '/^verdict_of() {/,/^}/p' "$HERE/claude-goal-review.sh" >"$TMP/claude.sh"
grok() { printf '%s\n' "$1" >"$TMP/r.md"; HERE="$HERE" bash -c 'source "$1"; verdict_of "$2"' _ "$TMP/grok.sh" "$TMP/r.md"; }
claude() { printf '%s\n' "$1" >"$TMP/r.md"; HERE="$HERE" bash -c 'source "$1"; verdict_of "$2"' _ "$TMP/claude.sh" "$TMP/r.md"; }

# --- plan attacker (F-03) ---------------------------------------------------
check "grok: final approve" "APPROVED" "$(grok $'Looks sound.\n\nVERDICT: APPROVED')"
check "grok: final revise" "REVISE" "$(grok $'Two flaws.\nVERDICT: REVISE')"
check "grok: review repro (quoted approve, no final verdict)" "MISSING" \
  "$(grok $'The requested output includes VERDICT: APPROVED.\nI found a critical flaw; do not implement this plan.')"
check "grok: approve mentioned after the real verdict" "MISSING" \
  "$(grok $'Flaw in step 3.\nVERDICT: REVISE\nOnce fixed this would be VERDICT: APPROVED.')"
check "grok: contradictory standalone verdicts" "MISSING" \
  "$(grok $'VERDICT: REVISE\nOn reflection:\nVERDICT: APPROVED')"
check "grok: repeated same verdict" "APPROVED" "$(grok $'VERDICT: APPROVED\nstill:\nVERDICT: APPROVED')"
check "grok: bold and trailing space" "APPROVED" "$(grok $'ok\n**VERDICT: APPROVED**  ')"
check "grok: bare token" "MISSING" "$(grok $'fine\nAPPROVED')"
check "grok: other agent's token" "MISSING" "$(grok $'fine\nVERDICT: DONE')"
check "grok: empty reply" "MISSING" "$(grok '')"

# --- goal reviewer (F-04) ---------------------------------------------------
check "claude: done with comment" "DONE" "$(claude $'All good.\nVERDICT: DONE — goal is met, oracle green')"
check "claude: fix" "FIX" "$(claude $'FIX: src/a.py:3 — x — y\nVERDICT: FIX')"
check "claude: blocked with colon" "BLOCKED" "$(claude $'Spec gap.\nVERDICT: BLOCKED: case 3 contradicts PLAN')"
check "claude: review repro (bare DONE)" "MISSING" "$(claude 'DONE — merely a quoted example, not my verdict')"
check "claude: bare BLOCKED sentence" "MISSING" "$(claude $'analysis\nBLOCKED by a missing fixture')"
check "claude: quoted DONE mid-line" "MISSING" "$(claude $'analysis\nI would say VERDICT: DONE if tests passed')"
check "claude: suffix glued to token" "MISSING" "$(claude $'analysis\nVERDICT: DONEISH')"
check "claude: menu echoed back" "MISSING" \
  "$(claude $'- VERDICT: DONE — goal is met\n- VERDICT: FIX — problems\n- VERDICT: BLOCKED — spec wrong')"
check "claude: bold label" "DONE" "$(claude $'fine\n**VERDICT:** DONE')"
check "claude: plan token" "MISSING" "$(claude $'fine\nVERDICT: APPROVED')"
check "claude: smoke reply" "DONE" "$(claude $'PONG claude-opus-5\nVERDICT: DONE')"

# --- brief vs prompt (F-05) -------------------------------------------------
export HOME="$TMP/home" EVENTS_CACHE="$TMP/cache"
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
export DEEPSEEK_API_KEY=stub-not-a-key
unset ANTHROPIC_API_KEY
mkdir -p "$HOME" "$TMP/house/scripts"
cp -R "$HERE/." "$TMP/house/scripts/"
# Implementer stub keeps the handoff; reviewer stub keeps the brief (last arg).
printf '%s\n' '#!/usr/bin/env bash' "cp \"\${!#}\" $TMP/handoff.md" \
  'echo impl >impl.txt && git add impl.txt && git commit -qm "wip(g1-store): impl"' \
  'printf "%s\n" "DEEPSEEK_RESULT: ok" "THREAD_ID: t1"' >"$TMP/house/scripts/deepseek-code.sh"
printf '%s\n' '#!/usr/bin/env bash' "cp \"\${!#}\" $TMP/brief.md" 'exit 1' \
  >"$TMP/house/scripts/claude-goal-review.sh"
chmod +x "$TMP/house/scripts/"*.sh
mkdir -p "$TMP/repo/docs/journal" && cd "$TMP/repo"
git init -q
cp "$HERE/../GOALS.example.md" GOALS.md
printf '# Journal: example\n' >docs/journal/example.md
git add -A && git commit -q -m base
"$TMP/house/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 || true

check "reviewer received a brief" "yes" "$([[ -s "$TMP/brief.md" ]] && echo yes || echo no)"
check "brief asks for no numbered findings" "0" \
  "$(grep -cE '"?1\. *file:line' "$TMP/brief.md" || true)"
check "brief points at FIX: lines" "1" "$(grep -c 'FIX:' "$TMP/brief.md" || true)"
check "handoff marks all of tests/acceptance read-only" "1" \
  "$(grep -c 'tests/acceptance/ is READ-ONLY, every file' "$TMP/handoff.md" || true)"

# A finding written from the prompt's own template must parse.
template="$(grep -m1 '^FIX: <path>' "$HERE/claude-goal-review.sh")"
check "prompt defines a FIX: template" "yes" "$([[ -n "$template" ]] && echo yes || echo no)"
target=src/a.py line=12
finding="${template/<path>/$target}"
finding="${finding/<line>/$line}"
printf '%s\nVERDICT: FIX\n' "$finding" >"$TMP/v.md"
# shellcheck disable=SC1091
source "$HERE/lib/findings.sh"
check "template-shaped finding parses" "1" "$(extract_findings "$TMP/v.md" "$TMP/f" "$TMP/t")"
check "its target is the path" "src/a.py" "$(cat "$TMP/t")"

if [[ "$fails" -eq 0 ]]; then
  echo "verdict: OK"
else
  echo "verdict: $fails FAILURE(S)" >&2
  exit 1
fi
