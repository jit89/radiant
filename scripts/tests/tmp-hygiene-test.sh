#!/usr/bin/env bash
# Self-test: temp-file hygiene (docs/features/temp-hygiene/PLAN.md). Launchers
# write into a caller-owned CW_OUT_DIR and delete nothing there; standalone they
# write under ~/.cache/claude-coding-workflow and drop raw output after an `ok`
# result; files are private without changing the umask the implementer gets;
# run-goal.sh keeps its run folder under ~/.cache, removes it on success and
# keeps it on a wake; cw_prune ages out runs/ and grok/ and touches nothing
# else. Nothing calls a model.
set -euo pipefail
# Mutation checks off here (docs/features/mutation-checks; mutation-test.sh turns them on).
export CW_MUTATIONS=0

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cw-tmp-hygiene-XXXXXX")" && pwd)"
export TMPDIR="$TMP" HOME="$TMP/home" CW_IMPL_TMP_ROOT="$TMP/impl-tmp"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$HOME"
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost EVENTS_CACHE="$TMP/events"
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
unset ANTHROPIC_API_KEY DEEPSEEK_API_KEY CW_OUT_DIR CW_KEEP_RAW CW_PRUNE_DAYS \
  GROK_REVIEW_OUT CLAUDE_REVIEW_OUT IMPLEMENTER_FALLBACK
# Its fallback scenarios are written for Haiku first (the default is DeepSeek).
export IMPLEMENTER_PRIMARY=haiku
umask 022
fails=0
CACHE="$HOME/.cache/claude-coding-workflow"

check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    echo "  ok   $name"
  else
    echo "  FAIL $name: want [$want] got [$got]"
    fails=$((fails + 1))
  fi
}
mode() { stat -f '%Lp' "$1" 2>/dev/null || echo missing; }
count() { find "$1" -mindepth 1 -maxdepth 1 -name "$2" 2>/dev/null | wc -l | tr -d ' '; }
line() { sed -n "s/^$1: //p" "$TMP/out" | head -n1; }

# A house of its own, so the real ~/claude-coding-workflow/.env never loads.
HOUSE="$TMP/house"
mkdir -p "$HOUSE/scripts"
cp -R "$HERE/." "$HOUSE/scripts/"
REPO="$TMP/repo"
mkdir -p "$REPO" && (cd "$REPO" && git init -q && git commit -q --allow-empty -m base)
printf '# Plan\n' >"$REPO/PLAN.md"

# --- fakes ---------------------------------------------------------------------
# fake_grok <stopReason> <text>
fake_grok() {
  python3 - "$1" "$2" >"$TMP/envelope.json" <<'PY'
import json, sys
print(json.dumps({"text": sys.argv[2], "stopReason": sys.argv[1],
                  "sessionId": "11111111-2222-3333-4444-555555555555"}))
PY
  printf '#!/usr/bin/env bash\necho grok-stderr >&2\ncat %q\n' "$TMP/envelope.json" >"$TMP/grok"
  chmod +x "$TMP/grok"
}
# A claude that replays canned envelopes in order (resp.N), exit code rc.N, and
# creates a file in its working directory, as an implementer would.
FAKE_DIR="$TMP/fake"
cat >"$TMP/claude" <<'STUB'
#!/usr/bin/env bash
d="$FAKE_DIR"
n=$(( $(cat "$d/n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$d/n"
: >"made-by-child-$n.txt"
env | grep '^CW_' >"$d/cw-env.$n" || true
echo "child stderr $n" >&2
[[ -f "$d/err.$n" ]] && cat "$d/err.$n" >&2
cat "$d/resp.$n"
[[ -f "$d/rc.$n" ]] && exit "$(cat "$d/rc.$n")"
exit 0
STUB
chmod +x "$TMP/claude"
reset() {
  rm -rf "$FAKE_DIR"; mkdir -p "$FAKE_DIR"
  local i=1 body
  for body in "$@"; do printf '%s\n' "$body" >"$FAKE_DIR/resp.$i"; i=$((i + 1)); done
}
USAGE='"total_cost_usd":0.0125,"usage":{"input_tokens":100,"output_tokens":20}'
IMPL_DONE='{"type":"result","is_error":false,"stop_reason":"end_turn","result":"Implemented.\nIMPLEMENTER_STATUS: DONE","session_id":"s1",'"$USAGE"'}'
IMPL_DECLINED='{"type":"result","is_error":false,"stop_reason":"end_turn","result":"Not this one: reason R.\nIMPLEMENTER_STATUS: DECLINED","session_id":"s1",'"$USAGE"'}'
IMPL_BLOCKED='{"type":"result","is_error":false,"stop_reason":"end_turn","result":"Stuck.\nIMPLEMENTER_STATUS: BLOCKED","session_id":"s1",'"$USAGE"'}'
REFUSAL='{"type":"result","stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"},"result":"","session_id":"s1"}'
REVIEW_DONE='{"type":"result","is_error":false,"stop_reason":"end_turn","result":"Fine.\nVERDICT: DONE","session_id":"r1"}'
printf '# Handoff: g1\n' >"$TMP/handoff.md"
printf '# Brief\n' >"$TMP/brief.md"

grok() { (cd "$REPO" && env "$@" GROK_BIN="$TMP/grok" "$HOUSE/scripts/grok-review.sh" PLAN.md) >"$TMP/out" 2>&1 && rc=0 || rc=$?; }
impl() { (cd "$REPO" && env "$@" FAKE_DIR="$FAKE_DIR" CLAUDE_REAL_BIN="$TMP/claude" "$HOUSE/scripts/claude-implement.sh" "$TMP/handoff.md") >"$TMP/out" 2>&1 && rc=0 || rc=$?; }
review() { (cd "$REPO" && env "$@" FAKE_DIR="$FAKE_DIR" CLAUDE_REAL_BIN="$TMP/claude" "$HOUSE/scripts/claude-goal-review.sh" "$TMP/brief.md") >"$TMP/out" 2>&1 && rc=0 || rc=$?; }

echo "== 1. cache folders: created 0700, and tightened when they exist 0755 =="
fake_grok end_turn $'ok\nVERDICT: APPROVED'
grok X=1
check "fresh: exit 0" 0 "$rc"
check "fresh: cache root 0700" 700 "$(mode "$CACHE")"
check "fresh: runs/ 0700" 700 "$(mode "$CACHE/runs")"
check "fresh: grok/ 0700" 700 "$(mode "$CACHE/grok")"
chmod 755 "$CACHE" "$CACHE/runs" "$CACHE/grok"
grok X=1
check "existing 0755: root tightened" 700 "$(mode "$CACHE")"
check "existing 0755: runs/ tightened" 700 "$(mode "$CACHE/runs")"
check "existing 0755: grok/ tightened" 700 "$(mode "$CACHE/grok")"

echo "== 2. grok standalone: verdict kept 0600 under grok/, raw dropped on ok =="
rm -rf "$CACHE/grok"
fake_grok end_turn $'Findings.\nVERDICT: REVISE'
grok X=1
vf="$(line VERDICT_FILE)"
check "verdict under grok/" "$CACHE/grok" "$(dirname "$vf")"
check "verdict 0600" 600 "$(mode "$vf")"
check "ok: raw removed" 0 "$(count "$CACHE/grok" 'grok-review-raw-*')"
check "nothing in TMPDIR" 0 "$(count "$TMP" 'grok-review-*')"
rm -rf "$CACHE/grok"
grok CW_KEEP_RAW=1
check "CW_KEEP_RAW=1: raw and .err kept" 2 "$(count "$CACHE/grok" 'grok-review-raw-*')"
for f in "$CACHE"/grok/grok-review-raw-*; do check "kept $(basename "$f") 0600" 600 "$(mode "$f")"; done
rm -rf "$CACHE/grok"
fake_grok cancelled $'partial'
grok X=1
check "error: nonzero" 1 "$rc"
check "error: raw and .err kept" 2 "$(count "$CACHE/grok" 'grok-review-raw-*')"
check "error: .err holds grok's stderr" grok-stderr "$(cat "$CACHE"/grok/grok-review-raw-*.err)"
check "error: .err 0600" 600 "$(mode "$(echo "$CACHE"/grok/grok-review-raw-*.err)")"
# A round that fails before parsing (here grok exits 1) writes no verdict.
# (A cancelled turn, above, keeps its partial text there by design.)
rm -rf "$CACHE/grok"
printf '#!/usr/bin/env bash\necho boom >&2\nexit 1\n' >"$TMP/grok"
grok X=1
check "failed round: nonzero" 1 "$rc"
check "failed round: no empty verdict left in grok/" 0 "$(find "$CACHE/grok" -name 'grok-review-*.md' | wc -l | tr -d ' ')"
printf 'earlier verdict\nVERDICT: REVISE\n' >"$TMP/kept-verdict.md"
grok GROK_REVIEW_OUT="$TMP/kept-verdict.md"
check "error: an existing GROK_REVIEW_OUT verdict is not erased" "earlier verdict" "$(head -n1 "$TMP/kept-verdict.md")"

echo "== 3. grok under CW_OUT_DIR: everything there, nothing deleted =="
rm -rf "$CACHE/grok"
OD="$TMP/od-grok" && mkdir -p "$OD"
fake_grok end_turn $'ok\nVERDICT: APPROVED'
grok CW_OUT_DIR="$OD"
check "verdict in CW_OUT_DIR" "$OD" "$(dirname "$(line VERDICT_FILE)")"
check "raw and .err kept" 2 "$(count "$OD" 'grok-review-raw-*')"
check "grok/ unused" 0 "$(count "$CACHE/grok" '*')"
grok CW_OUT_DIR="$TMP/no-such-dir"
check "missing CW_OUT_DIR: refused" 1 "$rc"

echo "== 4. implementer standalone: ok drops every pass's raw, after the cost line =="
reset "$IMPL_DONE"
impl X=1
check "exit 0" 0 "$rc"
check "cost line survives deletion" 0.0125 "$(line IMPLEMENTER_COST_USD)"
check "LOG: removed" "(removed)" "$(line LOG)"
check "stderr: removed" "(removed)" "$(line stderr)"
rep="$(line REPORT)"
check "report kept, under runs/" "$CACHE/runs" "$(dirname "$(dirname "$rep")")"
check "report 0600" 600 "$(mode "$rep")"
check "no raw left beside it" 0 "$(count "$(dirname "$rep")" 'claude-implement-raw-??????')"
check "child's repo file keeps the caller umask" 644 "$(mode "$REPO/made-by-child-1.txt")"
check "nothing in TMPDIR" 0 "$(count "$TMP" 'claude-implement-*')"
rm -f "$REPO"/made-by-child-*
# Haiku flagged -> DeepSeek fallback: two passes, two pairs, none orphaned.
printf 'DEEPSEEK_API_KEY=fake-ds-key\n' >"$HOUSE/.env"
reset "$REFUSAL" "$IMPL_DONE"
impl X=1
check "fallback ran" "haiku -> deepseek (refusal)" "$(line IMPLEMENTER_FALLBACK)"
od="$(dirname "$(line REPORT)")"
check "fallback ok: only the final report left" "$(basename "$(line REPORT)")" "$(ls "$od")"
reset "$IMPL_DECLINED" "$IMPL_DONE"
impl X=1
check "decline fallback ran" "haiku -> deepseek (declined)" "$(line IMPLEMENTER_FALLBACK)"
od="$(dirname "$(line REPORT)")"
check "decline: Haiku's reason kept beside the final report" yes \
  "$(grep -l 'reason R' "$od"/*.md 2>/dev/null | grep -qv "$(line REPORT)" && echo yes || echo no)"
reset "$REFUSAL" "$IMPL_DONE"
impl CW_KEEP_RAW=1
od="$(dirname "$(line REPORT)")"
check "CW_KEEP_RAW=1: both pairs kept" 4 "$(find "$od" -name 'claude-implement-raw-*' ! -name '*.md' | wc -l | tr -d ' ')"
check "LOG names a real file" yes "$([[ -f "$(line LOG)" ]] && echo yes || echo no)"
rm -f "$HOUSE/.env" "$REPO"/made-by-child-*
# A resumed thread that was never saved: a fresh pass, a second pair, tracked.
reset "$IMPL_DONE" "$IMPL_DONE"
printf 'Error: No conversation found with session ID 22222222-3333-4444-5555-666666666666\n' >"$FAKE_DIR/err.1"
printf '1\n' >"$FAKE_DIR/rc.1"
(cd "$REPO" && FAKE_DIR="$FAKE_DIR" CLAUDE_REAL_BIN="$TMP/claude" "$HOUSE/scripts/claude-implement.sh" \
  --resume haiku:22222222-3333-4444-5555-666666666666 "$TMP/handoff.md") >"$TMP/out" 2>&1 && rc=0 || rc=$?
check "unsaved thread: retried fresh, ok" "0 ok" "$rc $(line IMPLEMENTER_RESULT)"
od="$(dirname "$(line REPORT)")"
check "unsaved thread: both pairs removed, only the report left" "$(basename "$(line REPORT)")" "$(ls "$od")"
rm -f "$REPO"/made-by-child-*
reset "$IMPL_DONE"; printf '1\n' >"$FAKE_DIR/rc.1"
impl X=1
od="$(dirname "$(line REPORT)")"
check "error: raw and .err kept" 2 "$(find "$od" -name 'claude-implement-raw-*' ! -name '*.md' | wc -l | tr -d ' ')"
check "error: LOG names a real file" yes "$([[ -f "$(line LOG)" ]] && echo yes || echo no)"
rm -f "$REPO"/made-by-child-*

echo "== 5. implementer under CW_OUT_DIR: an ok BLOCKED pass deletes nothing =="
OD="$TMP/od-impl" && mkdir -p "$OD"
before="$(count "$CACHE/runs" 'claude-implement-*')"; reset "$IMPL_BLOCKED"
impl CW_OUT_DIR="$OD" CW_PROOF_DEPS=/x CW_SOME_FUTURE_SETTING=1
check "result ok" ok "$(line IMPLEMENTER_RESULT)"
check "status BLOCKED" BLOCKED "$(line IMPLEMENTER_STATUS)"
check "LOG kept in CW_OUT_DIR" "$OD" "$(dirname "$(line LOG)")"
check "LOG exists" yes "$([[ -f "$(line LOG)" ]] && echo yes || echo no)"
check "stderr exists" yes "$([[ -f "$(line stderr)" ]] && echo yes || echo no)"
check "the model's shell sees no CW_ setting" "" "$(cat "$FAKE_DIR/cw-env.1")"
check "no folder under runs/" "$before" "$(count "$CACHE/runs" 'claude-implement-*')"
rm -f "$REPO"/made-by-child-*

echo "== 6. reviewer: flagged retry pair tracked; CW_OUT_DIR keeps all =="
rm -rf "$CACHE/runs"
reset "$REFUSAL" "$REVIEW_DONE"
review X=1
check "exit 0" 0 "$rc"
check "fallback named" yes "$(grep -q '^CLAUDE_REVIEW_FALLBACK:' "$TMP/out" && echo yes || echo no)"
vf="$(line VERDICT_FILE)"
check "verdict 0600 under runs/" "600 $CACHE/runs" "$(mode "$vf") $(dirname "$(dirname "$vf")")"
check "both pairs removed" 0 "$(count "$(dirname "$vf")" 'claude-goal-raw-*')"
OD="$TMP/od-review" && mkdir -p "$OD"
reset "$REFUSAL" "$REVIEW_DONE"
review CW_OUT_DIR="$OD"
check "CW_OUT_DIR: both pairs kept" 4 "$(count "$OD" 'claude-goal-raw-*')"
check "CW_OUT_DIR: verdict there" "$OD" "$(dirname "$(line VERDICT_FILE)")"
reset "$REVIEW_DONE"
(cd "$REPO" && CLAUDE_REVIEW_DRY_RUN=1 CLAUDE_REAL_BIN="$TMP/claude" "$HOUSE/scripts/claude-goal-review.sh" "$TMP/brief.md") >/dev/null 2>&1 || true
check "dry run makes no folder" 1 "$(count "$CACHE/runs" 'claude-goal-review-*')"
reset "$REVIEW_DONE"
review CLAUDE_REVIEW_OUT="$TMP/review-elsewhere.md"
check "CLAUDE_REVIEW_OUT: verdict there" "$TMP/review-elsewhere.md" "$(line VERDICT_FILE)"
check "CLAUDE_REVIEW_OUT: no empty folder left" 1 "$(count "$CACHE/runs" 'claude-goal-review-*')"
rm -f "$REPO"/made-by-child-*

echo "== 7. cw_prune: 15 days out, 13 days in, nothing else touched =="
P="$TMP/prune-home"
(
  export HOME="$P"
  # shellcheck disable=SC1091
  source "$HERE/lib/cache.sh"
  cw_prune && echo missing-ok >"$TMP/prune-missing"
  cw_cache_init
  old="$(date -v-15d +%Y%m%d%H%M)"; recent="$(date -v-13d +%Y%m%d%H%M)"
  mkdir -p "$CW_CACHE/runs/run-goal-old-x" "$CW_CACHE/runs/run-goal-new-x" "$CW_CACHE/keys" \
    "$CW_CACHE/run-goal-g1"
  : >"$CW_CACHE/grok/grok-review-old.md"; : >"$CW_CACHE/grok/grok-review-new.md"
  : >"$CW_CACHE/git-meta-abc.txt"; : >"$CW_CACHE/keys/k"; : >"$CW_CACHE/run-goal-g1/verdict-r0.md"
  for f in runs/run-goal-old-x grok/grok-review-old.md git-meta-abc.txt keys keys/k run-goal-g1 run-goal-g1/verdict-r0.md; do
    touch -t "$old" "$CW_CACHE/$f"
  done
  touch -t "$recent" "$CW_CACHE/runs/run-goal-new-x" "$CW_CACHE/grok/grok-review-new.md"
  cw_prune
  CW_PRUNE_DAYS=0 cw_prune
)
C="$P/.cache/claude-coding-workflow"
check "missing folders: success" missing-ok "$(cat "$TMP/prune-missing" 2>/dev/null)"
check "15-day run folder pruned" no "$([[ -e "$C/runs/run-goal-old-x" ]] && echo yes || echo no)"
check "15-day verdict pruned" no "$([[ -e "$C/grok/grok-review-old.md" ]] && echo yes || echo no)"
check "13-day run folder kept" yes "$([[ -e "$C/runs/run-goal-new-x" ]] && echo yes || echo no)"
check "13-day verdict kept" yes "$([[ -e "$C/grok/grok-review-new.md" ]] && echo yes || echo no)"
check "git-meta baseline untouched" yes "$([[ -e "$C/git-meta-abc.txt" ]] && echo yes || echo no)"
check "keys/ untouched" yes "$([[ -e "$C/keys/k" ]] && echo yes || echo no)"
check "ART_DIR untouched" yes "$([[ -e "$C/run-goal-g1/verdict-r0.md" ]] && echo yes || echo no)"

echo "== 8. run-goal.sh: success removes the run folder, a wake keeps it =="
# Launcher stubs that write into CW_OUT_DIR as the real ones do.
cat >"$HOUSE/scripts/claude-implement.sh" <<'SH'
#!/usr/bin/env bash
printf 'raw\n' >"$CW_OUT_DIR/stub-implement-raw"
echo "$RANDOM" >>impl.txt && git add impl.txt && git commit -qm "wip(g1-store): impl"
printf '%s\n' "IMPLEMENTER_RESULT: ok" "THREAD_ID: haiku:t1" "IMPLEMENTER_STATUS: DONE" \
  "REPORT: $CW_OUT_DIR/stub-implement-raw" "LOG: $CW_OUT_DIR/stub-implement-raw"
SH
cat >"$HOUSE/scripts/claude-goal-review.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$HOME/review-args"
printf 'Review.\nVERDICT: %s\n' "$STUB_VERDICT" >"$CW_OUT_DIR/stub-review.md"
printf '%s\n' "CLAUDE_REVIEW_RESULT: ok" "SESSION_ID: r1" "VERDICT: $STUB_VERDICT" \
  "VERDICT_FILE: $CW_OUT_DIR/stub-review.md"
SH
chmod +x "$HOUSE/scripts/claude-implement.sh" "$HOUSE/scripts/claude-goal-review.sh"
goal() {
  rm -rf "$TMP/grepo"
  mkdir -p "$TMP/grepo/docs/journal" && cd "$TMP/grepo"
  git init -q
  # A real proof command: the fixture's `true` counts as none, and PROOF: none
  # never auto-dones.
  # The proof also checks CW_OUT_DIR stays with the two launchers.
  awk '!d && /proof: true/ { sub(/proof: true/, "proof: test -s impl.txt \\&\\& test -z \"$CW_OUT_DIR\""); d = 1 } 1' \
    "$HERE/../GOALS.example.md" >GOALS.md
  printf '# Plan\n' >PLAN.md
  printf '# Journal: example\n' >docs/journal/example.md
  git add -- GOALS.md PLAN.md docs/journal/example.md
  git commit -q -m base
  STUB_VERDICT="$1" "$HOUSE/scripts/run-goal.sh" g1-store >"$TMP/out" 2>&1 && rc=0 || rc=$?
  cd "$TMP"
}
rm -rf "$CACHE/runs"
goal DONE
check "DONE: exit 0" 0 "$rc"
check "DONE: run folder removed with the launchers' files" 0 "$(count "$CACHE/runs" 'run-goal-g1-store-*')"
check "DONE: nothing in TMPDIR" 0 "$(count "$TMP" 'run-goal-*')"
goal BLOCKED
check "BLOCKED: wakes" 1 "$rc"
stop="$(sed -n 's/^STOP_FILE: //p' "$TMP/out" | tail -n1)"
rd="$(dirname "$stop")"
check "wake: stop file under runs/" "$CACHE/runs" "$(dirname "$rd")"
check "wake: run folder 0700" 700 "$(mode "$rd")"
check "wake: implementer file kept" yes "$([[ -f "$rd/stub-implement-raw" ]] && echo yes || echo no)"
check "wake: review kept" yes "$([[ -f "$rd/stub-review.md" ]] && echo yes || echo no)"
check "wake: reviewer --add-dir names the run folder" yes \
  "$(grep -qx -- "$rd" "$HOME/review-args" && grep -qx -- --add-dir "$HOME/review-args" && echo yes || echo no)"

echo "== 9. run-all.sh: parallel, ordered report, leaks and failures caught =="
RA="$TMP/ra/tests"
mkdir -p "$RA" "$TMP/ra/lib"
cp "$HERE/tests/run-all.sh" "$RA/"
# run-all.sh sources ../lib/cache.sh (cw_keep_awake): the house layout.
cp "$HERE/lib/cache.sh" "$TMP/ra/lib/"
fake_test() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$RA/$1-test.sh"; }
fake_test a-pass 'sleep 4; echo fine'
fake_test b-pass 'sleep 4; echo fine'
fake_test c-fail 'echo broke; exit 1'
fake_test d-leak 'echo x >"$TMPDIR/left-behind"'
fake_test e-roleak 'mkdir -p "$HOME/ro/sub" && chmod 500 "$HOME/ro"'
fake_test f-env 'test -z "${CW_OUT_DIR:-}${CW_KEEP_RAW:-}${CW_PRUNE_DAYS:-}"'
# SIGINT must reach a test: a background job starts with it ignored.
fake_test g-sigint 'yes | head -n1 >/dev/null; [[ "${PIPESTATUS[0]}" == 141 ]] || exit 1; trap "exit 0" INT; kill -INT $$; sleep 1; exit 1'
s="$(date +%s)"
CW_OUT_DIR=/nowhere CW_KEEP_RAW=1 CW_PRUNE_DAYS=3 \
  "$RA/run-all.sh" -j 6 --results "$TMP/ra/res" >"$TMP/out" 2>&1 && rc=0 || rc=$?
el=$(( $(date +%s) - s ))
check "nonzero on a failure or leak" 1 "$rc"
check "two 4s tests side by side under -j6" yes "$([[ "$el" -lt 8 ]] && echo yes || echo "no: ${el}s")"
check "report in name order" "a-pass b-pass c-fail d-leak e-roleak f-env g-sigint" \
  "$(sed -nE 's/^(ok|FAIL|LEAK) +([a-z-]+)-test\.sh.*/\2/p' "$TMP/out" | awk '!s[$0]++' | paste -sd ' ' -)"
check "failure reported with its output" yes "$(grep -q '^FAIL  c-fail-test.sh' "$TMP/out" && grep -q 'broke' "$TMP/out" && echo yes || echo no)"
check "leak reported" yes "$(grep -q '^LEAK  d-leak-test.sh' "$TMP/out" && grep -q 'tmp/left-behind' "$TMP/out" && echo yes || echo no)"
check "read-only leak reported, run finished" yes "$(grep -q '^LEAK  e-roleak-test.sh' "$TMP/out" && grep -q 'fails=3' "$TMP/out" && echo yes || echo no)"
check "CW_* settings stripped from the tests" yes "$(grep -q '^ok    f-env-test.sh' "$TMP/out" && echo yes || echo no)"
check "SIGINT reaches the test, SIGPIPE kills a writer" yes "$(grep -q '^ok    g-sigint-test.sh' "$TMP/out" && echo yes || echo no)"
check "--results: rc per test" "0 0 1 1 1 0 0" "$(for n in a-pass b-pass c-fail d-leak e-roleak f-env g-sigint; do cat "$TMP/ra/res/$n-test.sh.rc"; done | paste -sd ' ' -)"
check "--results: leak named in the .out" yes "$(grep -q 'LEAK: left in' "$TMP/ra/res/d-leak-test.sh.out" && echo yes || echo no)"
check "its own temp folder removed" 0 "$(count "$TMP" 'cw-run-all-*')"
s="$(date +%s)"
"$RA/run-all.sh" -j 1 a-pass-test.sh b-pass-test.sh a-pass-test.sh >"$TMP/out" 2>&1 && rc=0 || rc=$?
el=$(( $(date +%s) - s ))
check "-j 1 with names: those tests, a repeat dropped" "0 2" "$rc $(grep -c '^ok' "$TMP/out")"
check "-j 1 runs one at a time" yes "$([[ "$el" -ge 8 ]] && echo yes || echo "no: ${el}s")"
"$RA/run-all.sh" -j 0 >/dev/null 2>&1 && rc=0 || rc=$?
check "-j 0 refused" 2 "$rc"
# Interrupted: the tests go with the runner, not on writing into a deleted folder.
mark="cw-ra-orphan-$$"
rm -f "$RA"/*-test.sh
# The sleep is the test's child, not the test: a kill of the test's pid alone
# would leave it running.
fake_test z-slow "bash -c 'exec -a $mark sleep 30'; exit 1"
# Still writing after its TERM: the runner must wait for it before removing $G.
# It says when its trap is set, so the TERM cannot beat it, and ignores a
# repeated TERM while it writes, so its 1s delay holds.
late_ready="$TMP/ra-late-ready"
cat >"$RA/y-late-test.sh" <<SH
#!/usr/bin/env bash
trap 'trap "" TERM; sleep 1; mkdir -p "\$TMPDIR/late"; exit 1' TERM
: >"$late_ready"
sleep 30 & wait
SH
# Python starts the runner: its returncode tells death by a signal (-15) from
# a plain `exit 143`, which a shell's $? cannot.
rarc="$(python3 - "$RA/run-all.sh" "$mark" "$late_ready" <<'PY'
import os, subprocess, sys, time
p = subprocess.Popen([sys.argv[1], "-j", "3"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
def running():
    return subprocess.run(["pgrep", "-f", sys.argv[2]], stdout=subprocess.DEVNULL).returncode == 0
for _ in range(50):
    if running() and os.path.exists(sys.argv[3]):
        break
    time.sleep(0.3)
seen = running() and os.path.exists(sys.argv[3])
p.terminate()
print(f"{int(seen)} {p.wait()}")
PY
)"
check "TERM: the test's child was running, the late writer ready" 1 "${rarc%% *}"
rarc="${rarc#* }"
# Past the late writer's 1s: a folder it recreated would be back by now.
sleep 2
check "TERM: the test's child is killed with it" 0 "$(pgrep -f "$mark" | wc -l | tr -d ' ')"
check "TERM: runner folder removed" 0 "$(count "$TMP" 'cw-run-all-*')"
check "TERM: runner dies of TERM, not a plain exit" -15 "$rarc"
pkill -f "$mark" 2>/dev/null || true
chmod -R u+w "$TMP/ra"

echo
if [[ "$fails" -eq 0 ]]; then
  echo "tmp-hygiene-test: all passed"
else
  echo "tmp-hygiene-test: $fails failed"
  exit 1
fi
