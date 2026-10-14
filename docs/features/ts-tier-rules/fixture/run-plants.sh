#!/usr/bin/env bash
# run-plants.sh — prove the TypeScript tier rules (docs/features/ts-tier-rules).
#
#   NODE=/abs/node run-plants.sh all         every case in CASES, plus the Tier 2 reference check
#   NODE=/abs/node run-plants.sh tier2       the Tier 2 reference check alone
#   run-plants.sh diff <plant>               what a plant changes, against its fixture
#
# Each case copies a fixture to a fresh temporary git repository, lays a
# variant (the trap stub, the correct implementation, or a wrong one) over
# src/duration.ts, overlays the plant, and runs a recipe — the literal one-line
# `proof` string from <fixture>/recipes/, $NODE and $REPO filled in — the way
# the host runs a proof — `bash -c` — in its strictest environment: `env -i`,
# PATH=/usr/bin:/bin, no login shell, and a non-UTC zone (Asia/Kolkata), so only the recipe's own TZ=UTC can
# make a UTC expectation hold. It scores the exit code, the trap text, the
# host's tree_snapshot before and after, and an expected-output pattern.
# The env -i run is a worst case: the host keeps the walk's environment minus
# credentials, so Node may or may not be on its PATH.
# KEEP=1 keeps each temporary repository. Runs on macOS /bin/bash 3.2.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TRAP="duration-trap"
CACHE="${TS_TIER_CACHE:-${HOME}/.cache/claude-coding-workflow/ts-tier-fixture}"

need_node() { [[ -n "${NODE:-}" && -x "$NODE" ]] || { echo "set NODE to an absolute node binary" >&2; exit 2; }; }

# node_modules for a fixture, kept in MOD_<fixture>: its own when present (the
# throwaway), else one `npm ci` from its lockfile into a cache keyed on the
# lockfile's hash, installed into a staging directory and moved into place only
# on success. Resolved once, before any case, so a failed install stops here.
resolve_modules() {
  local fixture="$1" var key dir npm stage
  var="MOD_${fixture//-/_}"
  if [[ -d "$HERE/$fixture/node_modules" ]]; then printf -v "$var" '%s' "$HERE/$fixture/node_modules"; return 0; fi
  key="$(shasum -a 256 "$HERE/$fixture/package-lock.json" | cut -c1-16)"
  dir="$CACHE/$fixture-$key"
  if [[ ! -d "$dir/node_modules" ]]; then
    npm="$(dirname "$NODE")/../lib/node_modules/npm/bin/npm-cli.js"
    mkdir -p "$CACHE"
    stage="$(mktemp -d "$CACHE/.stage-XXXXXX")"
    cp "$HERE/$fixture/package.json" "$HERE/$fixture/package-lock.json" "$stage/"
    if ! ( cd "$stage" && PATH="$(dirname "$NODE"):/usr/bin:/bin" "$NODE" "$npm" ci --no-audit --no-fund >/dev/null 2>&1 ); then
      rm -rf "$stage"; echo "npm ci failed for $fixture (the first run needs network)" >&2; return 1
    fi
    rm -rf "$dir"; mv "$stage" "$dir"
  fi
  printf -v "$var" '%s' "$dir/node_modules"
}

snapshot() {
  git rev-parse HEAD
  git status --porcelain --untracked-files=all
  { git status --porcelain --ignored=matching -- tests/acceptance .claude .mcp.json || true; } |
    { grep '^!! ' || true; }
}

# run FIXTURE VARIANT PLANT RECIPE — prints: exit=<n> trap=<yes|no> tamper=<yes|no> out=<file> repo=<dir>
run() {
  local fixture="$1" variant="$2" plant="$3" recipe="$4" tmp meta cmd var
  var="MOD_${fixture//-/_}"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ts-plant-XXXXXX")"; meta="$tmp.meta"; mkdir -p "$meta"
  cp -Rc "$HERE/$fixture/." "$tmp/" 2>/dev/null || cp -R "$HERE/$fixture/." "$tmp/"
  [[ -d "$tmp/node_modules" ]] || cp -Rc "${!var}" "$tmp/node_modules" 2>/dev/null ||
    cp -R "${!var}" "$tmp/node_modules"
  cp "$tmp/variants/$variant.ts" "$tmp/src/duration.ts"
  [[ "$plant" == - ]] || cp -R "$HERE/plants/$plant/." "$tmp/"
  cmd="$(cat "$tmp/recipes/$recipe.txt")"
  cmd="${cmd//\$NODE/$NODE}"; cmd="${cmd//\$REPO/$tmp}"
  (
    cd "$tmp" || exit 1
    git init -q && git -c user.name=p -c user.email=p@p add -A >/dev/null &&
      git -c user.name=p -c user.email=p@p commit -qm base >/dev/null
    snapshot >"$meta/before"
    env -i HOME="$HOME" PATH=/usr/bin:/bin TZ=Asia/Kolkata bash -c "$cmd" >"$meta/out" 2>&1
    echo $? >"$meta/rc"
    snapshot >"$meta/after"
  )
  local trap=no tamper=no
  grep -q "$TRAP" "$meta/out" && trap=yes
  cmp -s "$meta/before" "$meta/after" || tamper=yes
  echo "exit=$(cat "$meta/rc") trap=$trap tamper=$tamper out=$meta/out repo=$tmp"
}

cleanup() { [[ -n "${KEEP:-}" ]] || rm -rf "$1" "$1.meta"; }

# The cases: fixture variant plant recipe want[*N] pattern  — `#` starts a comment.
#   through  the defect gets through: nonzero, the trap, no tamper (Tier 1 passes a broken oracle)
#   caught   nonzero and no trap (Tier 1 fails)      green  exit 0, no tamper
#   red      nonzero                                 zero   exit 0 (Tier 1 fails on a zero exit)
#   tamper   the host's tree_snapshot changed        canary the hostile config's canary ran
#   clean    Tier 1 passes on the stub: through, no canary, the trap from src/duration.ts
#   *N       repeat N times; any differing result is a mismatch (timing-dependent rows)
#   pattern  an ERE the output must contain (`-` for none; `.` matches a space)
CASES='
v stub - proof clean -                                        # baselines
v impl - proof green -
n stub - proof clean -
n impl - proof green -
v stub v-typed minus-tsc through -                            # KEEP tsc: a wrong-typed call
v stub v-typed proof caught TS2345
n stub n-typed minus-tsc through -
n stub n-typed proof caught TS2345
v stub v-invented minus-tsc through -                         # KEEP tsc: an invented symbol (Vitest)
v stub v-invented proof caught TS2305
n stub n-invented minus-tsc caught does.not.provide.an.export # node:test: module linking already rejects it
v stub v-only minus-recipe-config through -                   # KEEP the recipe config (allowOnly false): .only
v impl v-only minus-recipe-config green -
v stub v-only proof caught Unexpected.\.only.modifier
v stub v-only ci-only caught Unexpected.\.only.modifier                           #   CI=1 alone also catches it (dropped as redundant)
n stub n-only proof clean -                                   # DROP for node:test: .only is ignored without --test-only
n impl n-only proof green -
v stub v-hostile-nocov minus-recipe-config canary -           # KEEP a recipe config that does not extend the project config
v stub v-hostile-nocov minus-recipe-config tamper -
v stub v-hostile proof clean -
v impl v-hostile proof green -
v stub v-hostile-only proof caught Unexpected.\.only.modifier
v stub v-mock minus-check through -                           # KEEP check: a partial mock of the feature module
v impl v-mock minus-check green -                             #   ... green on the implementation, loadDuration untested
v stub v-mock proof caught ^tests/acceptance/duration\.test\.ts$
v stub v-mock-nested proof caught ^tests/acceptance/nested/helper\.ts$   # the check searches subdirectories
v stub v-snapshot minus-check through -                       # KEEP check: a snapshot matcher
v impl v-snapshot minus-check tamper -                        #   ... the implementation writes the snapshot under tests/acceptance/ (the host stops it)
v stub v-snapshot proof caught ^tests/acceptance/duration\.test\.ts$
n stub n-snapshot minus-check through -                       # KEEP check: t.assert.snapshot (node:test)
n impl n-snapshot minus-check red Missing.snapshots
n stub n-snapshot proof caught ^tests/acceptance/duration\.test\.ts$
v stub v-async-then minus-check through*5 -                   # KEEP check (Vitest): an unreturned .then
v stub-late v-async-then minus-check through*5 -
v wrongload-late v-async-then minus-check green*5 -           #   ... a late wrong value goes green
v stub v-async-then proof caught ^tests/acceptance/duration\.test\.ts$
n wrongload-late n-async-then proof red*5 generated.asynchronous.activity.after.the.test.ended   # DROP for node:test
n stub n-mock-module proof caught mock.module.is.not.a.function   # DROP: mock.module needs a flag in Node 24
v impl v-tsbuildinfo minus-incremental tamper -               # KEEP --incremental false
v impl v-tsbuildinfo proof green -
n impl n-tsbuildinfo minus-incremental tamper -
n impl n-tsbuildinfo proof green -
v impl - minus-tz red (FAIL.*>|✖).starts.a.day                  # KEEP TZ=UTC: the reference value is UTC midnight
n impl - minus-tz red (FAIL.*>|✖).starts.a.day
v impl v-t2-date minus-tz red (FAIL.*>|✖).starts.a.day
n impl n-t2-date minus-tz red (FAIL.*>|✖).starts.a.day
v impl v-t2-date proof green -
n impl n-t2-date proof green -
n impl n-enum-off proof red ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX  # PRECONDITION erasableSyntaxOnly: off, Node fails at load
n impl n-enum-on proof red TS1294                             #   on, tsc names the line
n impl n-paramprop-off proof red ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX
n impl n-paramprop-on proof red TS1294
n impl n-namespace-off proof red ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX
n impl n-namespace-on proof red TS1294
n impl n-typeimport proof red does.not.provide.an.export.named   # PRECONDITION verbatimModuleSyntax: off, Node fails to link
n impl n-typeimport-vms proof red TS1484                      #   on, tsc names the import
n impl n-typeimport-fixed proof green -                       #   with import type, a correct oracle is green
n stub n-typeimport-fixed proof clean -
v impl v-t2-sort proof red (FAIL.*>|✖).sorts.total.minutes      # KEEP Tier 2 reference: a string-order sort slip
n impl n-t2-sort proof red (FAIL.*>|✖).sorts.total.minutes
v impl v-t2-length proof red (FAIL.*>|✖).counts.a.label         # KEEP Tier 2 reference: a UTF-16 length slip
n impl n-t2-length proof red (FAIL.*>|✖).counts.a.label
v impl v-t2-loose proof red (FAIL.*>|✖).scales.each.field       # KEEP Tier 2 reference: +0 for -0, a missing undefined key
n impl n-t2-loose proof red (FAIL.*>|✖).scales.each.field
v impl v-t2-loosepin proof green -                            # KEEP strict matcher: toEqual accepts the wrong value
v impl v-t2-loosepin-strict proof red (FAIL.*>|✖).scales.each.field
n impl n-t2-loosepin proof green -                            # KEEP strict matcher: loose deepEqual accepts it
n impl n-t2-loosepin-strict proof red (FAIL.*>|✖).scales.each.field
v stub v-zero-filter proof zero -                             # DROP zero-test guard: Tier 1 already fails a zero exit
n stub n-zero-filter proof zero -
v stub v-zero-path proof caught No.test.files.found           # DROP: a path typo already fails without the trap
n stub n-zero-path proof caught Could.not.find
'

check() {
  local line="$1" want="$2" pattern="$3" out="${1##*out=}" canary=no frame=no clean_out
  out="${out%% repo=*}"
  clean_out="$(sed 's/\x1b\[[0-9;]*m//g' "$out")"
  grep -q canary-config-merged <<<"$clean_out" && canary=yes
  grep -q "src/duration.ts" <<<"$clean_out" && frame=yes
  if [[ "$pattern" != - ]] && ! grep -qE "$pattern" <<<"$clean_out"; then return 1; fi
  case "$want" in
    through) [[ "$line" != *"exit=0 "* && "$line" == *"trap=yes tamper=no"* ]] ;;
    caught)  [[ "$line" != *"exit=0 "* && "$line" == *"trap=no"* ]] ;;
    green)   [[ "$line" == *"exit=0 trap=no tamper=no"* ]] ;;
    red)     [[ "$line" != *"exit=0 "* ]] ;;
    zero)    [[ "$line" == *"exit=0 "* ]] ;;
    tamper)  [[ "$line" == *"tamper=yes"* ]] ;;
    canary)  [[ "$canary" == yes ]] ;;
    clean)   [[ "$line" != *"exit=0 "* && "$line" == *"trap=yes tamper=no"* && "$canary" == no && "$frame" == yes ]] ;;
    *) return 1 ;;
  esac
}

# tier2 — run the reference on the proof's own Node with TZ=UTC; each clean
# oracle must pin the reference value at the sortMinutes, labelWidth and
# dayStartMs calls, and the sort and length plants must carry the
# hand-computed slip there, which must differ from it. The -0 and
# undefined-key values are checked in the reference; the loose plants by
# their CASES rows.
tier2() {
  local ref fails=0 fx pre key want hand plant re
  ref="$(TZ=UTC "$NODE" "$HERE/reference/expected.mjs")" || { echo "reference failed" >&2; return 1; }
  val() { "$NODE" -e 'const v = JSON.parse(process.argv[1])[process.argv[2]]; console.log(Array.isArray(v) ? v.join(", ") : String(v))' "$ref" "$1"; }
  pin() { # pin FILE CALL VALUE — the value is the expectation at that call
    grep -qE "$2\(.*\)\)?(\.toBe\(|\.toStrictEqual\(\[?|, \[?)$3\]?\)" "$1"
  }
  for fx in vitest-fixture node-test-fixture; do
    pre="${fx:0:1}"
    for key in sortMinutes:sortMinutes:sortMinutesHand:t2-sort labelWidth:labelWidth:labelWidthHand:t2-length dayStartUtc:dayStartMs:-:-; do
      IFS=: read -r want call hand plant <<<"$key"
      re="$(val "$want" | sed 's/[][\.]/\\&/g')"
      if pin "$HERE/$fx/tests/acceptance/duration.test.ts" "$call" "$re"; then echo "ok       $fx clean oracle pins $call to the reference ($(val "$want"))"
      else echo "MISMATCH $fx clean oracle does not pin $call to the reference ($(val "$want"))"; fails=$((fails + 1)); fi
      [[ "$hand" != - ]] || continue
      if [[ "$(val "$hand")" == "$(val "$want")" ]]; then echo "MISMATCH hand-computed $hand equals the reference"; fails=$((fails + 1)); continue; fi
      re="$(val "$hand" | sed 's/[][\.]/\\&/g')"
      if pin "$HERE/plants/$pre-$plant/tests/acceptance/duration.test.ts" "$call" "$re"; then echo "ok       $pre-$plant carries the hand-computed $(val "$hand"), not the reference $(val "$want")"
      else echo "MISMATCH $pre-$plant does not carry the hand-computed $(val "$hand")"; fails=$((fails + 1)); fi
    done
  done
  if [[ "$(val scaledHoursIsNegZero)" == true ]]; then echo "ok       scale(0h5m, -1) computes -0 hours"; else echo "MISMATCH no -0"; fails=$((fails + 1)); fi
  if [[ "$(val hasLabelKey)" == true ]]; then echo "ok       the scaled value keeps an undefined label key"; else echo "MISMATCH no label key"; fails=$((fails + 1)); fi
  return "$fails"
}

all() {
  need_node
  resolve_modules vitest-fixture || exit 1
  resolve_modules node-test-fixture || exit 1
  local fails=0 total=0 fx variant plant recipe want pattern rest line n i first mark result
  while read -r fx variant plant recipe want pattern rest; do
    [[ -n "$fx" && "$fx" != \#* ]] || continue
    [[ "$fx" == v ]] && fx=vitest-fixture || fx=node-test-fixture
    n=1
    if [[ "$want" == *\** ]]; then n="${want##*\*}"; want="${want%%\**}"; fi
    mark=ok; first=""
    for ((i = 0; i < n; i++)); do
      line="$(run "$fx" "$variant" "$plant" "$recipe" </dev/null)"
      result="${line%% out=*}"
      check "$line" "$want" "$pattern" || mark=MISMATCH
      [[ -z "$first" ]] && first="$result"
      [[ "$result" == "$first" ]] || mark=MISMATCH
      cleanup "${line##*repo=}"
    done
    total=$((total + 1)); [[ "$mark" == ok ]] || fails=$((fails + 1))
    printf '%-8s %-10s %-14s %-22s %-20s want %-8s x%s %s\n' "$mark" "${fx%%-fixture}" "$variant" "$plant" "$recipe" "$want" "$n" "$first"
  done <<<"$CASES"
  local rows
  rows="$(grep -cvE '^[[:space:]]*($|#)' <<<"$CASES")"
  if [[ "$total" -ne "$rows" ]]; then echo "ran $total of $rows cases"; fails=$((fails + 1)); fi
  echo "cases: $total, mismatches: $fails"
  local t2=0
  tier2 || t2=$?
  echo "tier 2 reference mismatches: $t2"
  [[ "$fails" -eq 0 && "$t2" -eq 0 ]]
}

diff_plant() {
  local plant="$1" fx=vitest-fixture f
  [[ "$plant" == n-* ]] && fx=node-test-fixture
  ( cd "$HERE/plants/$plant" && find . -type f ) | while read -r f; do
    f="${f#./}"
    if [[ -f "$HERE/$fx/$f" ]]; then diff -u --label "$fx/$f" --label "plant/$f" "$HERE/$fx/$f" "$HERE/plants/$plant/$f"
    else echo "+++ new file: $f"; cat "$HERE/plants/$plant/$f"; fi
  done
}

case "${1:-}" in
  all) all ;;
  tier2) need_node; tier2 ;;
  diff) diff_plant "${2:?plant}" ;;
  *) sed -n '2,8p' "$0" >&2; exit 2 ;;
esac
