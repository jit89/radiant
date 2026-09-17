#!/usr/bin/env bash
# Self-test: what may reach a journal the host commits under its own name
# (F3-03), and which in-flight journals a resume accepts (F3-05).
#
# The journal is shared: the host appends ORCHESTRATOR records, the
# implementer appends its own. Both are records — "## <utc> — <ROLE> ..."
# and the lines under them — naming this goal. Loose text is not committed,
# and a documented implementer record does not block recovery.
# Launchers are stubs; nothing calls a model.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-journal-XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" EVENTS_CACHE="$TMP/cache" STUBS="$TMP/stubs"
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
export DEEPSEEK_API_KEY=stub-not-a-key
unset ANTHROPIC_API_KEY MAX_FIX_ROUNDS
mkdir -p "$HOME"
J=docs/journal/example.md
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

# --- the validator itself ---------------------------------------------------
V() {  # V <appended text> [goal] -> "ok" or the problem
  printf '# Journal\n' >"$TMP/head.md"
  { cat "$TMP/head.md"; printf '%s' "$1"; } >"$TMP/work.md"
  python3 "$HERE/lib/orch-files.py" journal "$TMP/head.md" "$TMP/work.md" \
    --records "${2-g1-store}" && echo ok
}
REC='\n## 2026-09-18T00:00:00Z — IMPLEMENTER start g1-store\ng1-store: beginning\n'
check "orchestrator record" "ok" "$(V "$(printf '\n## 2026-09-18T00:00:00Z — ORCHESTRATOR dispatch g1-store r0 BASE_SHA=abc\n')")"
check "implementer record with a body" "ok" "$(V "$(printf "$REC")")"
check "reviewer record" "ok" "$(V "$(printf '\n## 2026-09-18T00:00:00Z — REVIEWER note g1-store\n')")"
check "no additions at all" "ok" "$(V "")"
check "bare note" "appended line 2 is outside any record: 'USER PRIVATE NOTE: do not commit this'" \
  "$(V "$(printf '\nUSER PRIVATE NOTE: do not commit this\n')")"
check "note after an ORCHESTRATOR record" \
  "appended line 4 follows a one-line ORCHESTRATOR record: 'USER PRIVATE NOTE'" \
  "$(V "$(printf '\n## 2026-09-18T00:00:00Z — ORCHESTRATOR dispatch g1-store r0 BASE_SHA=abc\n\nUSER PRIVATE NOTE\n')")"
check "record for another goal" "appended line 2 is a record for g2-ack, not g1-store" \
  "$(V "$(printf '\n## 2026-09-18T00:00:00Z — IMPLEMENTER start g2-ack\n')")"
check "unknown role" "appended line 2 is a INTRUDER record, which this run does not commit: '## 2026-09-18T00:00:00Z — INTRUDER start g1-store'" \
  "$(V "$(printf '\n## 2026-09-18T00:00:00Z — INTRUDER start g1-store\n')")"
check "an ARCHITECT note is the Architect's to commit" \
  "appended line 2 is a ARCHITECT record, which this run does not commit: '## 2026-09-18T00:00:00Z — ARCHITECT decompose g1-store'" \
  "$(V "$(printf '\n## 2026-09-18T00:00:00Z — ARCHITECT decompose g1-store\n')")"
check "heading without a timestamp" "appended line 2 is a heading in no known shape: '## notes'" \
  "$(V "$(printf '\n## notes\n')")"
check "records mode needs a goal" "1" \
  "$(python3 "$HERE/lib/orch-files.py" journal "$TMP/head.md" "$TMP/head.md" --records >/dev/null 2>&1; echo $?)"

# --- run-goal.sh ------------------------------------------------------------
HOUSE="$TMP/house"
mkdir -p "$HOUSE/scripts"
cp -R "$HERE/." "$HOUSE/scripts/"
stub() {
  printf '#!/usr/bin/env bash\necho "%s" >>"$STUBS"\n%s\n' "$1" "$2" >"$HOUSE/scripts/$1"
  chmod +x "$HOUSE/scripts/$1"
}
stub claude-goal-review.sh 'printf "%s\n" "CLAUDE_REVIEW_RESULT: error (exit 1)" \
  "SESSION_ID: s1" "VERDICT: MISSING" "VERDICT_FILE: /dev/null"; exit 1'

make_repo() {
  rm -rf "$TMP/repo" "$STUBS"
  mkdir -p "$TMP/repo/docs/journal" && cd "$TMP/repo"
  git init -q
  cp "$HERE/../GOALS.example.md" GOALS.md
  printf '# Plan\n' >PLAN.md
  printf '# Journal: example\n' >"$J"
  git add -- GOALS.md PLAN.md "$J"
  git commit -q -m base
}
run() {
  "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 || true
  local stop
  stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)"
  reason="$(sed -n 's/^- reason: //p' "$stop" 2>/dev/null || true)"
  reviewed="$(count claude-goal-review)"
  dispatched="$(count deepseek-code)"
}
count() {  # matching stub invocations, 0 when nothing ran at all
  local n
  n="$(grep -c "$1" "$STUBS" 2>/dev/null || true)"
  echo "${n:-0}"
}
journal_committed() { git log --format= -p -- "$J" | grep -c "$1" || true; }

# The implementer appends its documented records: the run proceeds.
stub deepseek-code.sh 'printf "\n## 2026-09-18T00:00:00Z — IMPLEMENTER start g1-store\nbeginning\n" >>docs/journal/example.md
echo impl >impl.txt && git add impl.txt && git commit -qm "wip(g1-store): impl"
printf "%s\n" "DEEPSEEK_RESULT: ok" "THREAD_ID: t1"'
make_repo
run
check "implementer records reach review" "reviewer-error" "$reason"
check "implementer records: reviewer called" "1" "$reviewed"

# Loose text appended during the run: stop before review and before any commit.
stub deepseek-code.sh 'printf "\nUSER PRIVATE NOTE\n" >>docs/journal/example.md
echo impl >impl.txt && git add impl.txt && git commit -qm "wip(g1-store): impl"
printf "%s\n" "DEEPSEEK_RESULT: ok" "THREAD_ID: t1"'
make_repo
head_before="$(git rev-parse HEAD)"
run
check "loose journal text: journal-tamper" "journal-tamper" "$reason"
check "loose journal text: no review" "0" "$reviewed"
check "loose journal text: not committed" "0" "$(journal_committed 'USER PRIVATE NOTE')"
check "loose journal text: still in the file" "1" "$(grep -c 'USER PRIVATE NOTE' "$J" || true)"

# A record for another goal is not this goal's work either.
stub deepseek-code.sh 'printf "\n## 2026-09-18T00:00:00Z — IMPLEMENTER start g2-ack\nwrong goal\n" >>docs/journal/example.md
echo impl >impl.txt && git add impl.txt && git commit -qm "wip(g1-store): impl"
printf "%s\n" "DEEPSEEK_RESULT: ok" "THREAD_ID: t1"'
make_repo
run
check "cross-goal record: journal-tamper" "journal-tamper" "$reason"
check "cross-goal record: no review" "0" "$reviewed"

# --- resume (F3-05) ---------------------------------------------------------
# A crash leaves the journal mid-record. Each documented checkpoint must
# resume; anything else must refuse before a launcher runs.
stub deepseek-code.sh 'printf "%s\n" "DEEPSEEK_RESULT: error (stub)"; exit 1'
resume_with() {  # resume_with <name> <appended journal text> <want dispatched>
  make_repo
  local base
  base="$(git rev-parse HEAD)"
  "$HERE/goals.py" GOALS.md set g1-store in_progress >/dev/null
  printf '\n## 2026-09-18T00:00:00Z — ORCHESTRATOR dispatch g1-store r0 BASE_SHA=%s THREAD_ID=- SESSION_ID=-\n' "$base" >>"$J"
  printf '%b' "$2" >>"$J"
  local bytes
  bytes="$(shasum "$J" | awk '{print $1}')"
  run
  check "$1: dispatched" "$3" "$dispatched"
  if [[ "$3" == "0" ]]; then
    check "$1: gate" "gate" "$reason"
    check "$1: journal bytes untouched" "$bytes" "$(shasum "$J" | awk '{print $1}')"
  fi
}
resume_with "resume after dispatch only" "" 1
resume_with "resume after IMPLEMENTER start" \
  '\n## 2026-09-18T00:00:01Z — IMPLEMENTER start g1-store\ng1-store: beginning the implementation\n' 1
resume_with "resume after start and end" \
  '\n## 2026-09-18T00:00:01Z — IMPLEMENTER start g1-store\nbeginning\n\n## 2026-09-18T00:00:09Z — IMPLEMENTER end g1-store\nOutcome: BLOCKED\n' 1
resume_with "resume with a loose note" '\nUSER PRIVATE NOTE\n' 0
resume_with "resume with another goal's record" \
  '\n## 2026-09-18T00:00:01Z — IMPLEMENTER start g2-ack\nwrong goal\n' 0
resume_with "resume with an unknown heading" '\n## 2026-09-18T00:00:01Z — INTRUDER start g1-store\n' 0

# --- the walker (F4-03) -----------------------------------------------------
# run-goals.sh recovers the same way, for the one goal that is in progress:
# another goal's uncommitted record must not reach HEAD ahead of the child.
cat >"$HOUSE/scripts/run-goal.sh" <<'SH'
#!/usr/bin/env bash
echo "run-goal $1" >>"$STUBS"
exit 1
SH
chmod +x "$HOUSE/scripts/run-goal.sh"

walk_with() {  # walk_with <name> <goals.py set args, ';'-separated> <record> <want committed>
  make_repo
  local base pairs pair
  base="$(git rev-parse HEAD)"
  IFS=';' read -r -a pairs <<<"$2"
  for pair in "${pairs[@]}"; do
    "$HERE/goals.py" GOALS.md set ${pair} >/dev/null
  done
  printf '\n## 2026-09-18T00:00:00Z — ORCHESTRATOR dispatch g1-store r0 BASE_SHA=%s THREAD_ID=- SESSION_ID=-\n' "$base" >>"$J"
  printf '%b' "$3" >>"$J"
  local bytes
  bytes="$(shasum "$J" | awk '{print $1}')"
  "$HOUSE/scripts/run-goals.sh" >"$TMP/walk.out" 2>&1 || true
  check "$1: record committed" "$4" \
    "$(git show HEAD:"$J" | grep -c "$5" || true)"
  if [[ "$4" == "0" ]]; then
    check "$1: journal bytes untouched" "$bytes" "$(shasum "$J" | awk '{print $1}')"
    check "$1: walk stopped" "yes" \
      "$(grep -q 'orchestration-files-dirty' "$TMP/walk.out" && echo yes || echo no)"
  fi
}
walk_with "walk, the in-progress goal's own record" "g1-store in_progress" \
  '\n## 2026-09-18T00:00:01Z — IMPLEMENTER start g1-store\nmine\n' 1 'IMPLEMENTER start g1-store'
walk_with "walk, another goal's record" "g1-store in_progress" \
  '\n## 2026-09-18T00:00:01Z — IMPLEMENTER start g2-ack\nforeign\n' 0 'IMPLEMENTER start g2-ack'
walk_with "walk, a record for a goal that does not exist" "g1-store in_progress" \
  '\n## 2026-09-18T00:00:01Z — IMPLEMENTER start g9-nope\nfictional\n' 0 'IMPLEMENTER start g9-nope'
walk_with "walk, two goals in progress" "g1-store in_progress;g3-other in_progress" \
  '\n## 2026-09-18T00:00:01Z — IMPLEMENTER start g1-store\nmine\n' 0 'IMPLEMENTER start g1-store'

if [[ "$fails" -eq 0 ]]; then
  echo "journal records: OK"
else
  echo "journal records: $fails FAILURE(S)" >&2
  exit 1
fi
