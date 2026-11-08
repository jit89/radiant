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
# Mutation checks off here (docs/features/mutation-checks; mutation-test.sh turns them on).
export CW_MUTATIONS=0

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cw-journal-XXXXXX")"
export TMPDIR="$TMP"
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
H() {  # H <appended text> -> "ok" or the problem (--headings, against BASE_SHA's copy)
  printf '# Journal\n' >"$TMP/hbase.md"
  { cat "$TMP/hbase.md"; printf '%s' "$1"; } >"$TMP/hwork.md"
  python3 "$HERE/lib/orch-files.py" journal "$TMP/hbase.md" "$TMP/hwork.md" --headings && echo ok
}
check "headings: a full UTC time" ok "$(H "$(printf '\n## 2026-11-07T23:52:10Z — IMPLEMENTER end g1-store\nbody\n')")"
check "headings: a typed time (g30's 23:5x) is named" \
  "a heading with no UTC time from date -u: '## 2026-11-07T23:5x — IMPLEMENTER end g1-store'" \
  "$(H "$(printf '\n## 2026-11-07T23:5x — IMPLEMENTER end g1-store\nbody\n')")"
check "headings: a markdown heading inside a record is not one" ok "$(H "$(printf '\n## 2026-11-07T23:52:10Z — IMPLEMENTER end g1-store\n## Findings\n')")"
check "orchestrator record" "ok" "$(V "$(printf '\n## 2026-09-18T00:00:00Z — ORCHESTRATOR dispatch g1-store r0 BASE_SHA=abc\n')")"
check "implementer record with a body" "ok" "$(V "$(printf "$REC")")"
check "reviewer record" "ok" "$(V "$(printf '\n## 2026-09-18T00:00:00Z — REVIEWER note g1-store\n')")"
check "no additions at all" "ok" "$(V "")"
check "bare note" "appended line 2 is outside any record: 'USER PRIVATE NOTE: do not commit this'" \
  "$(V "$(printf '\nUSER PRIVATE NOTE: do not commit this\n')")"
check "note after an ORCHESTRATOR record" \
  "appended line 4 follows a one-line ORCHESTRATOR record: 'USER PRIVATE NOTE'" \
  "$(V "$(printf '\n## 2026-09-18T00:00:00Z — ORCHESTRATOR dispatch g1-store r0 BASE_SHA=abc\n\nUSER PRIVATE NOTE\n')")"
check "implementer record naming no goal" \
  "appended line 2 is a IMPLEMENTER record naming no goal, not g1-store" \
  "$(V "$(printf '\n## 2026-09-18T00:00:00Z — IMPLEMENTER start\nbody\n')")"
check "orchestrator walk-start names no goal" "ok" \
  "$(V "$(printf '\n## 2026-09-18T00:00:00Z — ORCHESTRATOR walk-start walk_id=abc\n')")"
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
H() {  # H <appended text> <ledger lines or MISSING> -> "ok" or the problem (--records --host)
  printf '# Journal\n' >"$TMP/head.md"
  { cat "$TMP/head.md"; printf '%b' "$1"; } >"$TMP/work.md"
  if [[ "$2" == MISSING ]]; then rm -f "$TMP/ledger"; else printf '%b' "$2" >"$TMP/ledger"; fi
  python3 "$HERE/lib/orch-files.py" journal "$TMP/head.md" "$TMP/work.md" --records g1-store --host "$TMP/ledger" && echo ok
}
D='## 2026-09-18T00:00:00Z — ORCHESTRATOR dispatch g1-store r0 BASE_SHA=abc'
check "ledger: a host record it holds" ok "$(H "\n$D\n" "$D\n")"
check "ledger: an IMPLEMENTER record needs none" ok "$(H '\n## 2026-09-18T00:00:00Z — IMPLEMENTER start g1-store\nbody\n' '')"
check "ledger: a record the host did not write" \
  "appended line 2 is an ORCHESTRATOR record the host did not write: '$D'" "$(H "\n$D\n" 'other\n')"
check "ledger: a missing ledger holds none" \
  "appended line 2 is an ORCHESTRATOR record the host did not write: '$D'" "$(H "\n$D\n" MISSING)"
P() {  # P <kept copy> <working copy> -> "ok" or the problem (--prefix)
  printf '%b' "$1" >"$TMP/kept.md"
  printf '%b' "$2" >"$TMP/work.md"
  python3 "$HERE/lib/orch-files.py" journal "$TMP/kept.md" "$TMP/work.md" --prefix && echo ok
}
check "prefix: anything appended" "ok" "$(P '# J\n' '# J\nloose text\n## notes\n')"
C() {  # C <version> ... -> "ok" or the problem (journal-chain; the last is the working copy)
  local i=0 args=()
  for v in "$@"; do
    i=$((i + 1))
    if [[ "$v" == MISSING ]]; then rm -f "$TMP/v$i"; else printf '%b' "$v" >"$TMP/v$i"; fi
    args+=("v$i" "$TMP/v$i")
  done
  python3 "$HERE/lib/orch-files.py" journal-chain "${args[@]}" && echo ok
}
check "chain: only appends" "ok" "$(C '# J\n' '# J\na\n' '# J\na\nb\n')"
check "chain: an edit committed, then appended to" \
  "text already in the journal at v2 was edited, not appended to (from v3 on)" \
  "$(C '# J\n' '# J\na\n' '# J\nA\n' '# J\nA\nb\n')"
check "chain: an edit put back, later lines kept" "ok" "$(C '# J\n' '# J\na\n' '# J\nA\n' '# J\na\nb\n')"
check "chain: a commit that deleted the journal, then restored" "ok" "$(C '# J\n' MISSING '# J\nb\n')"
check "chain: no readable first version" "the journal at v1 is unreadable" "$(C MISSING '# J\n')"
check "chain: the working copy deleted" \
  "text already in the journal at v1 was edited, not appended to (from v2 on)" "$(C '# J\n' MISSING)"
check "prefix: an edited line" "earlier text was edited, not appended to" \
  "$(P '# J\n## 2026-09-18T00:00:00Z — IMPLEMENTER start g1-store\n' '# J\n## 2026-09-18T00:00:09Z — IMPLEMENTER start g1-store\n')"

# --- run-goal.sh ------------------------------------------------------------
# host_dispatch BASE — a dispatch record as run-goal.sh writes it: in its
# ledger first (FUTURE-WORK item 25), then the journal.
# The ledger is keyed by the checkout (orch_host_ledger); make_repo clears
# the goal's, since every case rebuilds the repo at one path.
ledger() { (source "$HERE/lib/orch-files.sh" && orch_host_ledger g1-store); }
host_dispatch() {
  local line="## 2026-09-18T00:00:00Z — ORCHESTRATOR dispatch g1-store r0 BASE_SHA=$1 THREAD_ID=- SESSION_ID=-" l
  l="$(ledger)"
  mkdir -p "$(dirname "$l")" && printf '%s\n' "$line" >>"$l"
  printf '\n%s\n' "$line" >>"$J"
}
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
  rm -rf "$TMP/repo" "$STUBS" "$HOME/.cache/claude-coding-workflow/run-goal-g1-store"/host-records-*
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
  detail="$(sed -n 's/^- detail: //p' "$stop" 2>/dev/null || true)"
  reviewed="$(count claude-goal-review)"
  dispatched="$(count claude-implement)"
}
count() {  # matching stub invocations, 0 when nothing ran at all
  local n
  n="$(grep -c "$1" "$STUBS" 2>/dev/null || true)"
  echo "${n:-0}"
}
journal_committed() { git log --format= -p -- "$J" | grep -c "$1" || true; }

# The implementer appends its documented records: the run proceeds.
stub claude-implement.sh 'printf "\n## 2026-09-18T00:00:00Z — IMPLEMENTER start g1-store\nbeginning\n" >>docs/journal/example.md
echo impl >impl.txt && git add impl.txt && git commit -qm "wip(g1-store): impl"
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: t1"'
make_repo
run
check "implementer records reach review" "reviewer-error" "$reason"
check "implementer records: reviewer called" "1" "$reviewed"

# Loose text appended during the run: stop before review and before any commit.
stub claude-implement.sh 'printf "\nUSER PRIVATE NOTE\n" >>docs/journal/example.md
echo impl >impl.txt && git add impl.txt && git commit -qm "wip(g1-store): impl"
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: t1"'
make_repo
head_before="$(git rev-parse HEAD)"
run
check "loose journal text: journal-tamper" "journal-tamper" "$reason"
check "loose journal text: no review" "0" "$reviewed"
check "loose journal text: not committed" "0" "$(journal_committed 'USER PRIVATE NOTE')"
check "loose journal text: still in the file" "1" "$(grep -c 'USER PRIVATE NOTE' "$J" || true)"

# A record for another goal is not this goal's work either.
stub claude-implement.sh 'printf "\n## 2026-09-18T00:00:00Z — IMPLEMENTER start g2-ack\nwrong goal\n" >>docs/journal/example.md
echo impl >impl.txt && git add impl.txt && git commit -qm "wip(g1-store): impl"
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: t1"'
make_repo
run
check "cross-goal record: journal-tamper" "journal-tamper" "$reason"
check "cross-goal record: no review" "0" "$reviewed"

# A record edited and committed leaves the file equal to HEAD (FUTURE-WORK
# item 24): the copy at BASE_SHA, and the one from before the pass, catch it.
stub claude-implement.sh 'sed -i "" "s/^# Journal: example/# Journal: rewritten/" docs/journal/example.md
echo impl >impl.txt && git add impl.txt docs/journal/example.md && git commit -qm "wip(g1-store): impl"
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: t1"'
make_repo
run
check "committed edit of the title line at BASE_SHA: journal-tamper" "journal-tamper" "$reason"
check "committed edit of the title line at BASE_SHA: no review" "0" "$reviewed"
check "committed edit of the title line at BASE_SHA: named" "yes" \
  "$([[ "$detail" == *"text already in the journal at "*" was edited"* ]] && echo yes || echo "no: $detail")"
stub claude-implement.sh 'sed -i "" "s/ORCHESTRATOR dispatch g1-store r0/ORCHESTRATOR dispatch g1-store r9/" docs/journal/example.md
echo impl >impl.txt && git add impl.txt docs/journal/example.md && git commit -qm "wip(g1-store): impl"
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: t1"'
make_repo
run
check "committed edit of this run's dispatch record: journal-tamper" "journal-tamper" "$reason"
check "committed edit of this run's dispatch record: named" "yes" \
  "$([[ "$detail" == *"text already in the journal at commit "*" was edited"* ]] && echo yes || echo "no: $detail")"
# A pass that rewrites history: it amends the host's dispatch commit with an
# edit, so no committed copy has the record as first written; the copy from
# before the pass still does.
stub claude-implement.sh 'sed -i "" "s/ORCHESTRATOR dispatch g1-store r0/ORCHESTRATOR dispatch g1-store r9/" docs/journal/example.md
git commit -q --amend --no-edit -- docs/journal/example.md
echo impl >impl.txt && git add impl.txt && git commit -qm "wip(g1-store): impl"
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: t1"'
make_repo
run
check "an amended dispatch commit: journal-tamper" "journal-tamper" "$reason"
check "an amended dispatch commit: named" "yes" \
  "$([[ "$detail" == *"against its copy before implementer r0: earlier text was edited"* ]] && echo yes || echo "no: $detail")"

# The pass edits its dispatch record's BASE_SHA, then stops early (blocked).
# The dispatch record was committed before the pass, so the stop does not
# commit the edit, and the resume refuses it.
stub claude-implement.sh 'sed -i "" "s/ORCHESTRATOR dispatch g1-store r0 BASE_SHA=[0-9a-f]*/ORCHESTRATOR dispatch g1-store r0 BASE_SHA=0000000/" docs/journal/example.md
printf "%s\n" "IMPLEMENTER_RESULT: ok" "IMPLEMENTER_STATUS: BLOCKED" "THREAD_ID: t1"'
make_repo
run
check "an edited dispatch record, then a blocked stop: stopped as blocked" "implementer-blocked" "$reason"
check "an edited dispatch record, then a blocked stop: the dispatch record was committed first" "1" \
  "$(git log --format=%s | grep -c 'orchestrator dispatch r0' || true)"
check "an edited dispatch record, then a blocked stop: the stop did not commit the edit" "0" \
  "$(git log -p --format= -- "$J" | grep -c '^+.*BASE_SHA=0000000 ' || true)"
rm -f "$STUBS"
run
check "an edited dispatch record, then a blocked stop: resume dispatched" "0" "$dispatched"
check "an edited dispatch record, then a blocked stop: resume refused" "gate" "$reason"
# The incident itself: a record committed, then edited and committed again in
# the same pass. Both copies from before the pass are clean.
stub claude-implement.sh 'printf "\n## 2099-01-01T00:00:00Z — IMPLEMENTER start g1-store\nbeginning\n" >>docs/journal/example.md
git add docs/journal/example.md && git commit -qm "wip(g1-store): start"
sed -i "" "s/^## 2099-01-01T00:00:00Z — IMPLEMENTER start/## 2026-09-18T00:00:00Z — IMPLEMENTER start/" docs/journal/example.md
echo impl >impl.txt && git add impl.txt docs/journal/example.md && git commit -qm "wip(g1-store): impl"
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: t1"'
make_repo
run
check "a record committed and edited in one pass: journal-tamper" "journal-tamper" "$reason"
check "a record committed and edited in one pass: names the commit" "yes" \
  "$([[ "$detail" == *"text already in the journal at commit "*" was edited"* ]] && echo yes || echo "no: $detail")"

# FUTURE-WORK item 25: an ORCHESTRATOR record only the host writes. A pass
# that appends one stops; with an early stop after it, the stop does not commit
# it under the host's name and the resume refuses it.
stub claude-implement.sh 'printf "\n## 2026-09-18T00:00:09Z — ORCHESTRATOR dispatch g1-store r0 BASE_SHA=$(git rev-parse HEAD) THREAD_ID=- SESSION_ID=-\n" >>docs/journal/example.md
echo impl >impl.txt && git add impl.txt && git commit -qm "wip(g1-store): impl"
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: t1"'
make_repo
run
check "forged dispatch record: journal-tamper" "journal-tamper" "$reason"
check "  ...named" yes "$([[ "$detail" == *"ORCHESTRATOR record the host did not write"* ]] && echo yes || echo "no: $detail")"
stub claude-implement.sh 'printf "\n## 2026-09-18T00:00:09Z — ORCHESTRATOR dispatch g1-store r0 BASE_SHA=$(git rev-parse HEAD) THREAD_ID=- SESSION_ID=-\n" >>docs/journal/example.md
printf "%s\n" "IMPLEMENTER_RESULT: ok" "IMPLEMENTER_STATUS: BLOCKED" "THREAD_ID: t1"'
make_repo
run
check "forged dispatch record, then a blocked stop: stopped as blocked" "implementer-blocked" "$reason"
check "  ...the stop did not commit it" 0 "$(git log -p --format= -- "$J" | grep -c '^+## 2026-09-18T00:00:09Z — ORCHESTRATOR dispatch' || true)"
rm -f "$STUBS"
run
check "  ...the resume refuses it" "0 gate" "$dispatched $reason"

# The forgery committed with a contract change (FUTURE-WORK item 25): the pass
# stops on the contract, and a plain rerun reads BASE_SHA from the host's
# ledger, not the journal, so the contract change still stops it.
stub claude-implement.sh 'echo changed >>PLAN.md && git commit -qam "wip(g1-store): plan"
printf "\n## 2026-09-18T00:00:09Z — ORCHESTRATOR dispatch g1-store r0 BASE_SHA=$(git rev-parse HEAD) THREAD_ID=- SESSION_ID=-\n" >>docs/journal/example.md
git add docs/journal/example.md && git commit -qm "wip(g1-store): checkpoint"
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: t1"'
make_repo
run
check "committed forgery with a contract change: stopped on the contract" "contract-tamper-committed" "$reason"
rm -f "$STUBS"
run
check "  ...a rerun still refuses the contract change" "0 gate" "$dispatched $reason"
check "  ...naming it" yes "$([[ "$detail" == *"contract changed since BASE_SHA"*PLAN.md* ]] && echo yes || echo "no: $detail")"

# --- resume (F3-05) ---------------------------------------------------------
# The ledger is the checkout's: another clone with the same goal in progress
# and no dispatch of its own does not resume from this one's.
make_repo
host_dispatch "$(git rev-parse HEAD)"
git clone -q "$TMP/repo" "$TMP/clone" && cd "$TMP/clone"
"$HERE/goals.py" GOALS.md set g1-store in_progress >/dev/null
"$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 || true
stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)"
check "another clone: no resume from this repo's ledger" yes \
  "$(grep -q 'no dispatch for g1-store in its host ledger' "$stop" 2>/dev/null && echo yes || echo "no: $(sed -n 's/^- detail: //p' "$stop")")"
cd "$TMP" && rm -rf "$TMP/clone"
# A linked worktree of this repository has a ledger of its own (a --jobs
# member's records never steer a resume in the main checkout).
make_repo
git worktree add -q "$TMP/wt" -b side
(cd "$TMP/wt" && host_dispatch "$(git rev-parse HEAD)")
"$HERE/goals.py" GOALS.md set g1-store in_progress >/dev/null
"$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 || true
stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)"
check "a linked worktree: no resume from its ledger" yes \
  "$(grep -q 'no dispatch for g1-store in its host ledger' "$stop" 2>/dev/null && echo yes || echo "no: $(sed -n 's/^- detail: //p' "$stop")")"
git worktree remove --force "$TMP/wt"
# A stop on a .git tamper turns host git off, yet its wake record reaches the
# ledger keyed at start: after the user reverts and re-baselines, as the stop
# says, the rerun resumes.
stub claude-implement.sh 'printf "#!/bin/sh\nexit 0\n" >.git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
printf "%s\n" "IMPLEMENTER_RESULT: ok" "THREAD_ID: t1"'
make_repo
run
check "a tamper stop: git-metadata-tamper" git-metadata-tamper "$reason"
rm -f .git/hooks/pre-commit
saved="$(sed -n 's/.*re-baseline: rm \([^ ]*\).*/\1/p' <<<"$detail")"
[[ -n "$saved" ]] && rm -f "$saved"
stub claude-implement.sh 'printf "%s\n" "IMPLEMENTER_RESULT: error (stub)"; exit 1'
rm -f "$STUBS"
run
check "  ...after revert and re-baseline the rerun resumes" "1 implementer-error" "$dispatched $reason"
# A crash leaves the journal mid-record. Each documented checkpoint must
# resume; anything else must refuse before a launcher runs.
stub claude-implement.sh 'printf "%s\n" "IMPLEMENTER_RESULT: error (stub)"; exit 1'
resume_with() {  # resume_with <name> <appended journal text> <want dispatched>
  make_repo
  local base
  base="$(git rev-parse HEAD)"
  "$HERE/goals.py" GOALS.md set g1-store in_progress >/dev/null
  host_dispatch "$base"
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
resume_with "resume with a dispatch record the host did not write" \
  '\n## 2026-09-18T00:00:02Z — ORCHESTRATOR dispatch g1-store r0 BASE_SHA=0000000 THREAD_ID=- SESSION_ID=-\n' 0
# An earlier pass edited a record and committed it: HEAD carries the edit, so
# only the journal's history shows it (FUTURE-WORK item 24). First a record
# from before BASE_SHA.
make_repo
base="$(git rev-parse HEAD)"
"$HERE/goals.py" GOALS.md set g1-store in_progress >/dev/null
host_dispatch "$base"
sed -i "" "s/^# Journal: example/# Journal: rewritten/" "$J"
git commit -qam "wip(g1-store): an earlier pass"
run
check "resume with a committed edit of the title line from before BASE_SHA: dispatched" "0" "$dispatched"
check "resume with a committed edit of the title line from before BASE_SHA: gate" "gate" "$reason"
check "resume with a committed edit of the title line from before BASE_SHA: named" "yes" \
  "$([[ "$detail" == *"text already in the journal at BASE_SHA "*" was edited"* ]] && echo yes || echo "no: $detail")"
# Then one of this goal's own, written after BASE_SHA by a pass that stopped
# for another reason; putting it back clears it, and a committed ARCHITECT
# note between stop and resume is an append.
resume_after_edit() {  # resume_after_edit <put back: 0|1> <architect note: 0|1>
  make_repo
  local base
  base="$(git rev-parse HEAD)"
  "$HERE/goals.py" GOALS.md set g1-store in_progress >/dev/null
  host_dispatch "$base"
  printf '\n## 2099-01-01T00:00:00Z — IMPLEMENTER start g1-store\nbeginning\n' >>"$J"
  git commit -qam "wip(g1-store): start"
  sed -i "" "s/^## 2099-01-01T00:00:00Z/## 2026-09-18T00:00:01Z/" "$J"
  git commit -qam "wip(g1-store): an edit"
  if [[ "$1" == 1 ]]; then
    sed -i "" "s/^## 2026-09-18T00:00:01Z/## 2099-01-01T00:00:00Z/" "$J"
    git commit -qam "journal: put the record back"
  fi
  if [[ "$2" == 1 ]]; then
    printf '\n## 2026-09-18T00:00:02Z — ARCHITECT note g1-store\nresuming\n' >>"$J"
    git commit -qam "journal: architect note"
  fi
  run
}
resume_after_edit 0 0
check "resume with a committed edit after BASE_SHA: dispatched" "0" "$dispatched"
check "resume with a committed edit after BASE_SHA: names the commit" "yes" \
  "$([[ "$detail" == *"text already in the journal at commit "*" was edited"* ]] && echo yes || echo "no: $detail")"
resume_after_edit 1 1
check "resume after the record was put back, with an ARCHITECT note: dispatched" "1" "$dispatched"

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
  host_dispatch "$base"
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
