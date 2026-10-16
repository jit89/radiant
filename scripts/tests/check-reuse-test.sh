#!/usr/bin/env bash
# Self-test: a full run-all.sh run of a house checkout leaves keyed results in
# ~/.cache/claude-coding-workflow/tests/last/, and install.sh --check reuses
# them while the tree is the one they tested (FUTURE-WORK item 19). A copy of
# the house with two fake tests; nothing calls a model.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cw-check-reuse-XXXXXX")" && pwd)"
export TMPDIR="$TMP" HOME="$TMP/home"
mkdir -p "$HOME"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=mock GIT_AUTHOR_EMAIL=mock@localhost
export GIT_COMMITTER_NAME=mock GIT_COMMITTER_EMAIL=mock@localhost
unset CW_CHECK_RERUN CLAUDE_CONFIG_DIR
# --check's tool steps get stubs, never the real claude, grok or codex.
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\necho stub 0.0\n' >"$TMP/bin/stub"
chmod +x "$TMP/bin/stub"
export CLAUDE_REAL_BIN="$TMP/bin/stub" GROK_BIN="$TMP/bin/stub" CODEX_BIN="$TMP/bin/stub"
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
has() { [[ "$2" == *"$1"* ]] && echo yes || echo "no: $2"; }
lacks() { [[ "$2" != *"$1"* ]] && echo yes || echo "present: $1"; }

# The house, its tests replaced by two fakes, committed so tree-key.py sees it.
H="$TMP/house"
mkdir -p "$H"
cp -R "$HERE" "$H/scripts"
rm -f "$H/scripts/tests/"*-test.sh
printf '#!/usr/bin/env bash\necho a ran >>"%s/ran"\n' "$TMP" >"$H/scripts/tests/a-test.sh"
printf '#!/usr/bin/env bash\necho b ran >>"%s/ran"\n' "$TMP" >"$H/scripts/tests/b-test.sh"
printf 'x\n' >"$H/tracked.txt"
cp "$HERE/../GOALS.example.md" "$HERE/../.gitignore" "$H/"
git -C "$H" init -q && git -C "$H" add -A && git -C "$H" commit -qm house
LAST="$HOME/.cache/claude-coding-workflow/tests/last"
key() { python3 "$H/scripts/lib/tree-key.py" "$H"; }
check_out() { "$H/scripts/install.sh" --check >"$TMP/out" 2>&1 || true; }
runs() { { wc -l <"$TMP/ran"; } 2>/dev/null | tr -d ' '; }

echo "== a full run publishes keyed results"
"$H/scripts/tests/run-all.sh" >/dev/null 2>&1
check "results kept" yes "$([[ -f "$LAST/a-test.sh.rc" && -f "$LAST/b-test.sh.out" ]] && echo yes || echo no)"
check "keyed by this tree, with its fail count" "$(key) 0" "$(cat "$LAST/key" 2>/dev/null)"
check "summary kept" yes "$(has 'fails=0' "$(tail -n1 "$LAST/summary" 2>/dev/null)")"
check "private" 700 "$(stat -f %Lp "$(dirname "$LAST")")"

echo "== --check on the same tree reuses it"
rm -f "$TMP/ran"
check_out
check "reused" yes "$(has 'tests: reused the full run of' "$(cat "$TMP/out")")"
check "tests: OK" yes "$(has 'tests: OK (test scripts: 2' "$(cat "$TMP/out")")"
check "no test ran" "" "$(runs)"
check "the reused run is kept" yes "$([[ -f "$LAST/key" ]] && echo yes || echo no)"

echo "== CW_CHECK_RERUN=1 runs the suite"
CW_CHECK_RERUN=1 check_out
check "not reused" yes "$(lacks 'tests: reused' "$(cat "$TMP/out")")"
check "both tests ran" 2 "$(runs)"

echo "== an edit makes the run stale"
rm -f "$TMP/ran"
printf 'y\n' >>"$H/tracked.txt"
check_out
check "not reused" yes "$(lacks 'tests: reused' "$(cat "$TMP/out")")"
check "both tests ran" 2 "$(runs)"
check "--check's own run is kept for the new tree" "$(key) 0" "$(cat "$LAST/key" 2>/dev/null)"

echo "== a run whose tree changed under it is not kept"
before="$(cat "$LAST/key")"
printf '#!/usr/bin/env bash\necho changed >>"%s/tracked.txt"\n' "$H" >"$H/scripts/tests/b-test.sh"
"$H/scripts/tests/run-all.sh" >/dev/null 2>&1 || true
check "last left as it was" "$before" "$(cat "$LAST/key")"

echo "== a subset run is not kept"
git -C "$H" checkout -q -- tracked.txt
printf '#!/usr/bin/env bash\necho b ran >>"%s/ran"\n' "$TMP" >"$H/scripts/tests/b-test.sh"
"$H/scripts/tests/run-all.sh" a-test.sh >/dev/null 2>&1
check "last left as it was" "$before" "$(cat "$LAST/key")"

echo "== a failed run is reused as a failure"
printf '#!/usr/bin/env bash\nexit 1\n' >"$H/scripts/tests/b-test.sh"
"$H/scripts/tests/run-all.sh" >/dev/null 2>&1 || true
check_out
check "reused" yes "$(has 'tests: reused' "$(cat "$TMP/out")")"
check "tests: FAIL" yes "$(has 'tests: FAIL' "$(cat "$TMP/out")")"
check "names the failed test" yes "$(has 'FAIL  b-test.sh' "$(cat "$TMP/out")")"

echo "== a failed test whose output ends in fails=0 is still a failure"
printf '#!/usr/bin/env bash\necho "inner: fails=0"\nexit 1\n' >"$H/scripts/tests/b-test.sh"
"$H/scripts/tests/run-all.sh" >/dev/null 2>&1 || true
check_out
check "reused" yes "$(has 'tests: reused' "$(cat "$TMP/out")")"
check "tests: FAIL" yes "$(has 'tests: FAIL' "$(cat "$TMP/out")")"

echo "== a publish that cannot finish leaves the run's status alone"
printf '#!/usr/bin/env bash\necho b ran >>"%s/ran"\n' "$TMP" >"$H/scripts/tests/b-test.sh"
fresh="$(dirname "$LAST")/.new-other-run"
mkdir -p "$fresh"
"$H/scripts/tests/run-all.sh" >/dev/null 2>&1 && rc=0 || rc=$?
check "all pass: exit 0" 0 "$rc"
check "another run's fresh .new-* folder is left alone" yes "$([[ -d "$fresh" ]] && echo yes || echo no)"
# A file where the cache folder should be: the publish cannot even start.
mv "$(dirname "$LAST")" "$TMP/tests-aside" && : >"$(dirname "$LAST")"
printf '#!/usr/bin/env bash\ntrue\n' >"$H/scripts/tests/b-test.sh"
"$H/scripts/tests/run-all.sh" >/dev/null 2>&1 && rc=0 || rc=$?
rm -f "$(dirname "$LAST")" && mv "$TMP/tests-aside" "$(dirname "$LAST")"
check "a publish that fails, all pass: exit 0" 0 "$rc"

if [[ "$fails" -eq 0 ]]; then
  echo "check-reuse-test: all passed"
else
  echo "check-reuse-test: $fails failed" >&2
  exit 1
fi
