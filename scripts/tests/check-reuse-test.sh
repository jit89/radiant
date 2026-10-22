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
# a-test also records what run-all gave it: a caffeinate -i -w held for one
# of its ancestors (run-all.sh), and CW_PROOF_DENIALS. The walk stops at this
# test's pid ($$, written in): an outer run-all holds an assertion too.
cat >>"$H/scripts/tests/a-test.sh" <<SH
p=\$\$; found=no
for _ in 1 2 3 4 5 6 7 8; do
  p="\$(ps -o ppid= -p "\$p" | tr -d ' ')"; [[ -n "\$p" && "\$p" != 1 && "\$p" != $$ ]] || break
  if pgrep -f "^/usr/bin/caffeinate -i -w \$p\\\$" >/dev/null; then found="\$(ps -o command= -p "\$p" | grep -oE 'run-all\.sh' | head -n1)"; break; fi
done
echo "awake=\$found denials=\${CW_PROOF_DENIALS:-unset}" >"$TMP/env-seen"
SH
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
check "run-all keeps the host awake and turns the denial listing off" "awake=run-all.sh denials=off" "$(cat "$TMP/env-seen" 2>/dev/null)"

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

echo "== a doc-only edit keeps the run (FUTURE-WORK item 20)"
rm -f "$TMP/ran"
mkdir -p "$H/docs/features/x"
printf '# Journal\n' >"$H/docs/features/x/journal.md"
printf '# Readme\n' >"$H/README.md"
printf '# Plan\n' >"$H/PLAN.md"
check_out
check "reused after docs/, README.md and PLAN.md changed" yes "$(has 'tests: reused the full run of' "$(cat "$TMP/out")")"
check "no test ran" "" "$(runs)"
printf 'more\n' >>"$H/GOALS.example.md"
check_out
check "GOALS.example.md is not a doc: a tests-read file makes the run stale" yes "$(lacks 'tests: reused' "$(cat "$TMP/out")")"
check "GOALS.example.md: both tests ran" 2 "$(runs)"
git -C "$H" checkout -q -- GOALS.example.md
# A run for this exact tree first, so only the skill below can make it stale.
"$H/scripts/tests/run-all.sh" >/dev/null 2>&1
check_out
check "the restored tree is reused again" yes "$(has 'tests: reused the full run of' "$(cat "$TMP/out")")"
rm -f "$TMP/ran"
mkdir -p "$H/skills/x" && printf '# Skill\n' >"$H/skills/x/SKILL.md"
check_out
check "Markdown outside docs/ and the top level (a skill) makes the run stale" yes "$(lacks 'tests: reused' "$(cat "$TMP/out")")"
check "a skill: both tests ran" 2 "$(runs)"
rm -rf "$H/skills" "$H/docs" "$H/README.md" "$H/PLAN.md"
"$H/scripts/tests/run-all.sh" >/dev/null 2>&1

echo "== no test reads a path the key leaves out"
# Every house path a test script names through \$HERE/../ (the house's idiom
# for the house top) must be in the key: a test that starts reading a doc file
# that way makes this red until lib/tree-key.py keeps it (KEPT_TOP_MD for a
# top-level file, excluded() for one under docs/). Reads
# through another form, or inside the scripts the tests run, are not seen.
read_paths="$(grep -ohE '\$HERE/\.\./[A-Za-z0-9._/-]+' "$HERE"/tests/*.sh | sed 's|^\$HERE/\.\./||' | sort -u)"
check "the scan finds what tests read (GOALS.example.md)" yes "$(has GOALS.example.md "$read_paths")"
# shellcheck disable=SC2086
check "none of them is left out of the key" "" "$(python3 "$HERE/lib/tree-key.py" --excluded $read_paths)"
check "--excluded flags the docs folder itself" docs "$(python3 "$HERE/lib/tree-key.py" --excluded docs)"
check "--excluded keeps scripts and skills" "" "$(python3 "$HERE/lib/tree-key.py" --excluded scripts skills/run-goal/SKILL.md mods)"

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
