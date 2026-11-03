#!/usr/bin/env bash
# run-plants.sh [all | ROW...] — rerun the Rust Tier 1 / Tier 2 plants
# (docs/features/rust-tier-rules/PLAN.md) the way the host runs a proof: every
# run goes through proof_exec (scripts/lib/proof.sh) under the proof sandbox,
# on a fresh git copy of crate/ with one plant applied. Prints one line per run
# and a verdict per row; EVIDENCE.md records the table.
#
# Needs the pinned toolchain (RUST_TC, default the rustup toolchain
# 1.99.1-aarch64-apple-darwin under ~/.local/rust) and, once, network for
# `cargo fetch --locked` (a setup run into a deps folder kept by the lockfile's
# hash). Work, logs and deps go under RUST_TIERS_WORK (default
# ~/dogfood/rust-tiers): never under /tmp or ~/.claude, which the sandbox
# denies. Not part of scripts/tests/run-all.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOUSE="$(cd "$HERE/../../../.." && pwd)"
TC="${RUST_TC:-$HOME/.local/rust/rustup/toolchains/1.99.1-aarch64-apple-darwin/bin}"
TC_CARGO="$TC/cargo"
TC_RUSTC="$TC/rustc"
VERSION_LINE='rustc 1.99.1 (58cf8f9c3 2026-10-13)'
WORK="${RUST_TIERS_WORK:-$HOME/dogfood/rust-tiers}"
TRAP=duration-trap

# The caller's environment, minus anything that would steer cargo unless a row
# sets it on purpose (PLAN step 2).
unset RUSTC RUSTFLAGS RUSTDOCFLAGS RUSTC_WRAPPER RUSTC_WORKSPACE_WRAPPER CI RUST_TEST_THREADS RUST_BACKTRACE
for v in $(compgen -e); do
  case "$v" in CARGO_*|RUSTUP_*|INSTA_*|PROPTEST_*) unset "$v" ;; esac
done
# What each proof saw of these, printed at the top of its log (names and values).
ENVSHOW="env | grep -E '^(RUSTC|RUSTFLAGS|RUSTDOCFLAGS|RUSTC_WRAPPER|RUSTC_WORKSPACE_WRAPPER|CARGO_[A-Z0-9_]*|RUSTUP_[A-Z0-9_]*|CI|INSTA_[A-Z0-9_]*|PROPTEST_[A-Z0-9_]*|RUST_TEST_THREADS|RUST_BACKTRACE)=' | sort | sed 's/^/env: /'"
export CW_PROOF_DENIALS=off   # proof_exec's own listing; 2b runs its own query

# shellcheck disable=SC1091
source "$HOUSE/scripts/lib/proof.sh"
git() { command git "$@"; }

[[ -x "$TC_CARGO" && -x "$TC_RUSTC" ]] || { echo "no toolchain at $TC" >&2; exit 2; }
mkdir -p "$WORK/runs" "$WORK/tmp" "$WORK/logs"
RESULTS="$WORK/results.tsv"
LOCKHASH="$(shasum -a 256 "$HERE/crate/Cargo.lock" | cut -c1-12)"
DEPS="$WORK/deps-$LOCKHASH"
WARM="$WORK/warm-target"

# Candidate rules. FULL is every candidate; a row's "minus" run drops one.
FULL="V B C_sp C_ig C_cu C_mock C_insta C_prop2 C_hook F L T O"
# The check's patterns, one per candidate (bash 3.2: no associative arrays).
pat() {
  case "$1" in
    C_sp) echo 'should_panic' ;;
    C_ig) echo '#\[ignore' ;;
    C_cu) echo 'catch_unwind\(.*\)\.is_(err|ok)\(\)' ;;
    C_mock) echo 'mockall|mock!|automock' ;;
    C_insta) echo 'insta::|assert_[a-z_]*snapshot!' ;;
    C_prop) echo 'proptest' ;;
    C_hook) echo 'set_hook' ;;
  esac
}
has() { [[ " $1 " == *" $2 "* ]]; }
minus() { local r out=""; for r in $1; do [[ "$r" == "$2" ]] || out+="$r "; done; echo "${out% }"; }

# recipe DIR RULES TEST EXTRA — the proof string for these rules, as a goal's
# `proof` field: run from the checkout (run() prefixes the host's
# `cd <checkout> &&`), so paths are relative and the target dir is $PWD's.
recipe() {
  local dir="$1" rules="$2" test="$3" extra="$4" joined="" p rf="" envp="" cmd
  cmd=":"
  has "$rules" V && cmd+=" && ( '$TC_RUSTC' --version | grep -qx '$VERSION_LINE' )"
  for p in C_sp C_ig C_cu C_mock C_insta C_prop C_hook; do
    has "$rules" "$p" && joined+="${joined:+|}$(pat "$p")"
  done
  [[ -z "$joined" ]] || cmd+=" && ( grep -rqE '$joined' tests/acceptance; test \$? -eq 1 )"
  # C_prop2: every oracle file that uses proptest turns its failure
  # persistence off (else a failing case writes *.proptest-regressions there).
  has "$rules" C_prop2 && cmd+=" && ( f=\$(grep -rl proptest tests/acceptance); test -z \"\$f\" || ! grep -L 'failure_persistence: None' \$f | grep -q . )"
  has "$rules" T && envp+="CARGO_TARGET_DIR=\"\$PWD/target\" "
  has "$rules" O && envp+="CARGO_PROFILE_DEV_OVERFLOW_CHECKS=true CARGO_PROFILE_TEST_OVERFLOW_CHECKS=true "
  has "$rules" O2 && rf+="-C overflow-checks=on "
  has "$rules" W && rf+="-D warnings "
  [[ -z "$rf" ]] || envp+="RUSTFLAGS='${rf% }' "
  has "$rules" B && envp+="RUSTC='$TC_RUSTC' "
  cmd+=" && ${envp}'$TC_CARGO' test --offline"
  has "$rules" L && cmd+=" --locked"
  cmd+=" --test $test${extra:+ $extra}"
  printf '%s' "$cmd"
}

# make_copy NAME LIB PLANT RULES [nolock] — a fresh git repository: crate/,
# LIB (stub|impl), the plant, the oracle header for F/F_deny, committed.
make_copy() {
  local dir="$WORK/runs/$1" lib="$2" plant="$3" rules="$4" nolock="${5:-}" f
  rm -rf "$dir" && cp -R "$HERE/crate" "$dir"
  [[ "$lib" == impl ]] && cp "$HERE/impl/lib.rs" "$dir/src/lib.rs"
  (cd "$dir" && command git init -q && command git config user.name plant &&
    command git config user.email plant@localhost && command git config commit.gpgsign false)
  if [[ -n "$plant" ]]; then
    (cd "$dir" && command git apply "$HERE/plants/$plant.patch") || { echo "plant $plant does not apply" >&2; return 1; }
  fi
  for f in "$dir"/tests/acceptance/*.rs; do
    if has "$rules" F; then
      sed -i '' '1a\
#![forbid(unused_must_use, unreachable_code)]
' "$f"
    elif has "$rules" F_deny; then
      sed -i '' '1a\
#![deny(unused_must_use, unreachable_code)]
' "$f"
    fi
  done
  [[ "$nolock" != nolock ]] || rm -f "$dir/Cargo.lock"
  (cd "$dir" && command git add -A && command git commit -qm "row $1")
  [[ ! -d "$WARM" ]] || cp -Rc "$WARM" "$dir/target"
  echo "$dir"
}

# tier1 LOG — the Rust reading of the pass bar: the trap on the line after
# libtest's "thread '…' panicked at" line.
tier1() {
  awk -v t="$TRAP" 'prev ~ /^thread .* panicked at / && index($0, t) {f=1} {prev=$0} END {exit !f}' "$1"
}

# denials START — proof.sh's own query, after the unified log catches up.
denials() {
  sleep 3
  /usr/bin/log show --start "$1" --predicate 'sender == "Sandbox"' --style compact 2>/dev/null |
    grep 'deny(' | grep -v 'vfs\.disk-space' | sed 's/.*Sandbox: //; s/([0-9]*)//' | sort | uniq -c | sort -rn || true
}

LAST_RC=0 LAST_T1=no LAST_MOVED="" LAST_LOG=""
# run NAME DIR CMD [setup] [deny] [nodeps] — one proof through proof_exec;
# nodeps: no deps folder, as in a serial run (CARGO_HOME is then the proof's
# own empty TMPDIR/cargo).
run() {
  local name="$1" dir="$2" cmd="$3" setup="${4:-}" deny="${5:-}" nodeps="${6:-}" log="$WORK/logs/$1.log" t0 start secs deps="$DEPS"
  [[ "$nodeps" != nodeps ]] || deps=""
  local before="$WORK/tmp/$name.before" after="$WORK/tmp/$name.after"
  (cd "$dir" && tree_snapshot) >"$before"
  start="$(date '+%Y-%m-%d %H:%M:%S')"; t0=$SECONDS
  LAST_RC=0
  PROOF_ROOT="$dir" PROOF_DEPS="$deps" PROOF_NETWORK=none PROOF_SETUP="${setup:-0}" \
    proof_exec 600 "$log" "$WORK/tmp/$name" "$ENVSHOW; cd '$dir' && $cmd" || LAST_RC=$?
  secs=$((SECONDS - t0))
  (cd "$dir" && tree_snapshot) >"$after"
  LAST_MOVED="$(cd "$dir" && proof_moved "$before" "$after" | paste -sd ';' -)"
  if tier1 "$log"; then LAST_T1=yes; else LAST_T1=no; fi
  if [[ "$deny" == deny ]]; then
    { echo; echo "--- denials logged during this run ---"; denials "$start"; } >>"$log"
  fi
  LAST_LOG="$log"
  # A run that did not run is flagged whatever row kind reads it next.
  if broken; then printf 'ERROR\t%s\tdid not run (rc %s: timeout or sandbox stop)\n' "$name" "$LAST_RC" | tee -a "$RESULTS"; fi
  # secs: the whole proof_exec call; cargo: cargo's own "Finished … in" time.
  printf '%s\trc=%s\ttrap=%s\tsecs=%s\tcargo=%s\tmoved=%s\n' "$name" "$LAST_RC" "$LAST_T1" "$secs" \
    "$(sed -n 's/.*Finished .* in \([0-9.]*s\).*/\1/p' "$log" | head -1)" "${LAST_MOVED:-none}" | tee -a "$RESULTS"
}
# A Tier 1 pass: nonzero exit and the trap read as above.
t1pass() { [[ "$LAST_RC" -ne 0 && "$LAST_T1" == yes ]]; }
# A run that did not run: timed out (124) or the sandbox stopped it (126).
broken() { [[ "$LAST_RC" -eq 124 || "$LAST_RC" -eq 126 ]]; }
# (not libtest's own closing "error: test failed, to rerun pass …")
compile_error() { grep -qE '^error\[E[0-9]+\]|could not compile' "$LAST_LOG"; }
verdict() { printf 'VERDICT\t%s\t%s\n' "$1" "$2" | tee -a "$RESULTS"; }

# --- step 2b: deps, sandbox, cold and warm builds -------------------------
setup_deps() {
  [[ -f "$DEPS/.fetched" ]] && return 0
  rm -rf "$DEPS"; mkdir -p "$DEPS" && chmod 700 "$DEPS"
  local dir; dir="$(make_copy 2b-fetch stub "" "")"
  run 2b-fetch "$dir" "cd '$dir' && RUSTC='$TC_RUSTC' '$TC_CARGO' fetch --locked" 1 deny
  [[ "$LAST_RC" -eq 0 ]] || { echo "cargo fetch failed: see $LAST_LOG" >&2; rm -rf "$DEPS"; exit 1; }
  : >"$DEPS/.fetched"
}

row_2b() {
  rm -rf "$WARM"
  local dir
  dir="$(make_copy 2b-red-cold stub "" "$FULL")"
  run 2b-red-cold "$dir" "$(recipe "$dir" "$FULL" g1 "")" "" deny
  t1pass && verdict 2b "red proof on the stub passes Tier 1" || verdict 2b "red proof FAILED Tier 1"
  cp -Rc "$dir/target" "$WARM"
  dir="$(make_copy 2b-green impl "" "$FULL")"
  run 2b-green "$dir" "$(recipe "$dir" "$FULL" g1 "")" "" deny
  [[ "$LAST_RC" -eq 0 ]] && verdict 2b "green proof on the implementation exits 0" || verdict 2b "green proof FAILED"
  dir="$(make_copy 2b-red-warm stub "" "$FULL")"
  run 2b-red-warm "$dir" "$(recipe "$dir" "$FULL" g1 "")"
}

# --- row kinds -------------------------------------------------------------
# clean TEST — (a)(b)(c) for the full recipe: stub passes Tier 1, impl exits 0,
# neither moves the tree.
row_clean() {
  local t="$1" dir ok=1
  dir="$(make_copy "clean-$t-stub" stub "" "$FULL")"; run "clean-$t-stub" "$dir" "$(recipe "$dir" "$FULL" "$t" "")"
  t1pass && [[ -z "$LAST_MOVED" ]] || ok=0
  dir="$(make_copy "clean-$t-impl" impl "" "$FULL")"; run "clean-$t-impl" "$dir" "$(recipe "$dir" "$FULL" "$t" "")"
  [[ "$LAST_RC" -eq 0 && -z "$LAST_MOVED" ]] || ok=0
  ((ok)) && verdict "clean-$t" "(a)(b)(c) hold" || verdict "clean-$t" "(a)(b)(c) BROKEN"
}

# t1 NAME PLANT RULE [TEST] [EXTRA] — baseline minus RULE vs full, on the stub.
row_t1() {
  local name="$1" plant="$2" rule="$3" t="${4:-g1}" extra="${5:-}" dir m f
  m="$(minus "$FULL" "$rule")"
  dir="$(make_copy "$name-minus" stub "$plant" "$m")"; run "$name-minus" "$dir" "$(recipe "$dir" "$m" "$t" "$extra")"
  if broken; then verdict "$name" "ERROR: the minus run did not run (rc $LAST_RC)"; return; fi
  if ! t1pass; then verdict "$name" "dropped: the baseline already fails Tier 1"; return; fi
  local mv="${LAST_MOVED:+ (minus moved the tree)}"
  dir="$(make_copy "$name-full" stub "$plant" "$FULL")"; run "$name-full" "$dir" "$(recipe "$dir" "$FULL" "$t" "$extra")"
  if broken; then verdict "$name" "ERROR: the full run did not run (rc $LAST_RC)"; return; fi
  if t1pass; then verdict "$name" "GAP: passes Tier 1 under the full recipe$mv"
  else verdict "$name" "caught by $rule$mv${LAST_MOVED:+; FULL MOVED THE TREE}"; fi
}

# t1v NAME PLANT — the warnings rows: minus F, full (F), deny form, global -D warnings.
row_t1v() {
  local name="$1" plant="$2" dir m
  row_t1 "$name" "$plant" F
  m="$(minus "$FULL" F)"
  dir="$(make_copy "$name-deny" stub "$plant" "$m F_deny")"; run "$name-deny" "$dir" "$(recipe "$dir" "$m F_deny" g1 "")"
  t1pass && verdict "$name" "deny form: through" || verdict "$name" "deny form: caught"
  dir="$(make_copy "$name-W" stub "$plant" "$m W")"; run "$name-W" "$dir" "$(recipe "$dir" "$m W" g1 "")"
  t1pass && verdict "$name" "global -D warnings: through" || verdict "$name" "global -D warnings: caught"
}

# impl NAME PLANT RULES [TEST] [ENV] — the planted oracle against the implementation.
row_impl() {
  local name="$1" plant="$2" rules="$3" t="${4:-g1}" envp="${5:-}" dir
  dir="$(make_copy "$name" impl "$plant" "$rules")"
  run "$name" "$dir" "${envp:+export $envp; }$(recipe "$dir" "$rules" "$t" "")"
}

# t2 NAME PLANT — a Tier 2 pin against the implementation: red or green.
row_t2() {
  local name="$1" plant="$2"
  row_impl "$name" "$plant" "$FULL" g2
  if [[ "$LAST_RC" -eq 0 ]]; then verdict "$name" "green against the implementation"
  elif broken || compile_error; then verdict "$name" "ERROR: did not run its assertions (rc $LAST_RC)"
  else verdict "$name" "red against the implementation"; fi
}

ROWS=(2b ref serial clean-g1 clean-g2 01 02 03 04 05 06 07 08 10 11 12 13 14 15 16 17 18 19 20 21 zero notarget 23 24 lock 26 27 28 29 30 31 32 33 34 40 41 42 43 44 45 46 47 48)

do_row() {
  local dir m
  case "$1" in
    2b) row_2b ;;
    ref) row_ref ;;
    serial) row_serial ;;
    clean-g1) row_clean g1 ;;
    clean-g2) row_clean g2 ;;
    01) row_t1 01-wrong-type 01-wrong-type - ;;
    02) row_t1 02-invented-symbol 02-invented-symbol - ;;
    03) row_t1 03-async-plain-test 03-async-plain-test - ;;
    04) row_t1 04-should-panic-bare 04-should-panic-bare C_sp ;;
    05) row_t1 05-should-panic-substring 05-should-panic-substring C_sp ;;
    06) row_t1 06-catch-unwind-is-err 06-catch-unwind-is-err C_cu ;;
    07) row_t1 07-ignore 07-ignore C_ig ;;
    08) local i; for i in 1 2 3 4 5; do row_t1 "08-set-hook-$i" 08-set-hook C_hook; done ;;
    10) row_t1v 10-dropped-result 10-dropped-result ;;
    11) row_t1v 11-let-underscore-result 11-let-underscore-result ;;
    12) row_t1v 12-unawaited-future 12-unawaited-future ;;
    13) row_t1v 13-let-underscore-future 13-let-underscore-future ;;
    14) row_t1v 14-assert-after-return 14-assert-after-return ;;
    15) row_t1v 15-allow-dropped-result 15-allow-dropped-result ;;
    16) row_t1v 16-allow-unawaited-future 16-allow-unawaited-future ;;
    17) row_t1v 17-allow-assert-after-return 17-allow-assert-after-return ;;
    18) row_t1 18-mock-feature 18-mock-feature C_mock
        row_impl 18-mock-feature-impl 18-mock-feature "$(minus "$FULL" C_mock)" ;;
    19) row_t1 19-insta-snapshot 19-insta-snapshot C_insta
        m="$(minus "$FULL" C_insta)"
        row_impl 19-insta-impl 19-insta-snapshot "$m"
        row_impl 19-insta-impl-ci 19-insta-snapshot "$m" g1 "CI=1"
        row_impl 19-insta-impl-noupdate 19-insta-snapshot "$m" g1 "INSTA_UPDATE=no" ;;
    20) row_t1 20-proptest 20-proptest C_prop2
        row_impl 20-proptest-impl 20-proptest "$(minus "$FULL" C_prop2)" ;;
    21) m="$FULL"
        dir="$(make_copy 21-proptest-no-persist-stub stub 21-proptest-no-persist "$m")"
        run 21-proptest-no-persist-stub "$dir" "$(recipe "$dir" "$m" g1 "")"
        row_impl 21-proptest-no-persist-impl 21-proptest-no-persist "$m" ;;
    zero) row_t1 22-zero-tests "" - g1 "-- --exact nomatch" ;;
    notarget) row_t1 22-no-target "" - g9 ;;
    23) row_t1 23-missing-test-decl 23-missing-test-decl - ;;
    24) dir="$(make_copy 24-g2-broken stub 24-g2-broken "$FULL")"
        run 24-g2-broken "$dir" "$(recipe "$dir" "$FULL" g1 "")"
        t1pass && verdict 24-g2-broken "--test g1 is not reached by g2's compile error" || verdict 24-g2-broken "g2's compile error BREAKS g1's proof" ;;
    lock) m="$(minus "$FULL" L)"
        dir="$(make_copy 25-lock-missing-minus stub "" "$m" nolock)"; run 25-lock-missing-minus "$dir" "$(recipe "$dir" "$m" g1 "")"
        dir="$(make_copy 25-lock-missing-full stub "" "$FULL" nolock)"; run 25-lock-missing-full "$dir" "$(recipe "$dir" "$FULL" g1 "")" ;;
    26) m="$(minus "$FULL" T)"
        dir="$(make_copy 26-hostile-target-dir-minus stub 26-hostile-target-dir "$m")"; run 26-hostile-target-dir-minus "$dir" "$(recipe "$dir" "$m" g1 "")"
        dir="$(make_copy 26-hostile-target-dir-full stub 26-hostile-target-dir "$FULL")"; run 26-hostile-target-dir-full "$dir" "$(recipe "$dir" "$FULL" g1 "")" ;;
    27) dir="$(make_copy 27-build-script stub 27-build-script "$FULL")"; run 27-build-script "$dir" "$(recipe "$dir" "$FULL" g1 "")"
        grep -q canary-build-script "$LAST_LOG" && verdict 27-build-script "build.rs ran inside the proof" || verdict 27-build-script "build.rs output not seen" ;;
    28|29|30)
        local p; p="$(cd "$HERE/plants" && ls "$1"-*.patch)"; p="${p%.patch}"
        m="$(minus "$FULL" O)"
        row_impl "$p-minus" "$p" "$m" g2
        row_impl "$p-full" "$p" "$FULL" g2
        row_impl "$p-rustflags" "$p" "$m O2" g2 ;;
    31) dir="$(make_copy 31-lib-warning-stub stub 31-lib-warning "$FULL")"; run 31-lib-warning-stub "$dir" "$(recipe "$dir" "$FULL" g1 "")"
        dir="$(make_copy 31-lib-warning-impl impl 31-lib-warning "$FULL")"; run 31-lib-warning-impl "$dir" "$(recipe "$dir" "$FULL" g1 "")"
        dir="$(make_copy 31-lib-warning-W-stub stub 31-lib-warning "$FULL W")"; run 31-lib-warning-W-stub "$dir" "$(recipe "$dir" "$FULL W" g1 "")"
        dir="$(make_copy 31-lib-warning-W-impl impl 31-lib-warning "$FULL W")"; run 31-lib-warning-W-impl "$dir" "$(recipe "$dir" "$FULL W" g1 "")" ;;
    32|33) fake_rustc; row_version "$1" ;;
    34) dir="$(make_copy 34-panic-abort-stub stub 34-panic-abort "$FULL")"; run 34-panic-abort-stub "$dir" "$(recipe "$dir" "$FULL" g1 "")"
        dir="$(make_copy 34-panic-abort-impl impl 34-panic-abort "$FULL")"; run 34-panic-abort-impl "$dir" "$(recipe "$dir" "$FULL" g1 "")" ;;
    40) row_t2 40-t2-overflow-wrapped 40-t2-overflow-wrapped ;;
    41) row_t2 41-t2-rem-negative 41-t2-rem-negative ;;
    42) row_t2 42-t2-len-bytes 42-t2-len-bytes ;;
    43) local i; for i in 1 2 3 4 5; do row_t2 "43-t2-hashmap-order-$i" 43-t2-hashmap-order; done ;;
    44) row_t2 44-t2-negzero-loose 44-t2-negzero-loose ;;
    45) row_t2 45-t2-negzero-strict 45-t2-negzero-strict ;;
    46) row_t2 46-t2-nan-eq 46-t2-nan-eq ;;
    47) row_t2 47-t2-display-float 47-t2-display-float ;;
    48) row_t2 48-t2-lowercase 48-t2-lowercase ;;
    *) echo "unknown row $1" >&2; return 2 ;;
  esac
}

# A rustc that reports another version and records each use (rows 32, 33).
FAKE="$WORK/fake-tc"
fake_rustc() {
  mkdir -p "$FAKE"
  cat >"$FAKE/rustc" <<EOF
#!/bin/bash
echo used >>"\$TMPDIR/fake-used"
case " \$* " in
  *" -vV "*|*" --version "*|*" -V "*) "$TC_RUSTC" "\$@" | sed 's/1\.99\.1/1.98.0/' ;;
  *) exec "$TC_RUSTC" "\$@" ;;
esac
EOF
  chmod +x "$FAKE/rustc"
}

# 32: the recipe's own rustc is another version (an upgraded toolchain path).
# 33: the caller exports RUSTC; the recipe binds cargo to the pinned rustc (B).
row_version() {
  local dir m saved="$TC_RUSTC"
  if [[ "$1" == 32 ]]; then
    TC_RUSTC="$FAKE/rustc"
    m="$(minus "$FULL" V)"
    dir="$(make_copy 32-version-minus stub "" "$m")"; run 32-version-minus "$dir" "$(recipe "$dir" "$m" g1 "")"
    dir="$(make_copy 32-version-full stub "" "$FULL")"; run 32-version-full "$dir" "$(recipe "$dir" "$FULL" g1 "")"
    TC_RUSTC="$saved"
  else
    m="$(minus "$FULL" B)"
    # The fake marks each use in the proof's private TMPDIR (the sandbox lets
    # a proof write only there and in the checkout).
    rm -rf "$WORK/tmp/33-caller-rustc-minus" "$WORK/tmp/33-caller-rustc-full"
    dir="$(make_copy 33-caller-rustc-minus stub "" "$m")"
    (export RUSTC="$FAKE/rustc"; run 33-caller-rustc-minus "$dir" "$(recipe "$dir" "$m" g1 "")")
    [[ -f "$WORK/tmp/33-caller-rustc-minus/fake-used" ]] && verdict 33 "minus B: cargo ran the caller's RUSTC" || verdict 33 "minus B: caller's RUSTC not used"
    dir="$(make_copy 33-caller-rustc-full stub "" "$FULL")"
    (export RUSTC="$FAKE/rustc"; run 33-caller-rustc-full "$dir" "$(recipe "$dir" "$FULL" g1 "")")
    [[ -f "$WORK/tmp/33-caller-rustc-full/fake-used" ]] && verdict 33 "full: cargo STILL ran the caller's RUSTC" || verdict 33 "full: cargo ran the pinned rustc"
  fi
}

# ref — the Tier 2 reference, built as the proof builds (no -O), run 5 times.
row_ref() {
  local bin="$WORK/tmp/tier2-ref" i
  "$TC_RUSTC" --edition 2024 -o "$bin" "$HERE/reference/tier2.rs" 2>/dev/null || { verdict ref "ERROR: the reference does not build"; return; }
  : >"$WORK/logs/ref.txt"
  for i in 1 2 3 4 5; do { echo "--- run $i"; "$bin" 2>/dev/null; } >>"$WORK/logs/ref.txt"; done
  cat "$WORK/logs/ref.txt"
  verdict ref "$(grep -c '^hashmap keys' "$WORK/logs/ref.txt") hashmap lines, $(grep '^hashmap keys' "$WORK/logs/ref.txt" | sort -u | wc -l | tr -d ' ') distinct"
}

# serial — a serial run has no deps folder (run-goal.sh clears it), so
# CARGO_HOME is the proof's own empty TMPDIR/cargo. Without crates in the
# checkout the proof cannot build; with them vendored (cargo vendor plus a
# source replacement, committed) it can, offline.
row_serial() {
  local dir
  dir="$(make_copy serial-no-vendor stub "" "$FULL")"
  run serial-no-vendor "$dir" "$(recipe "$dir" "$FULL" g1 "")" "" "" nodeps
  t1pass && verdict serial "no deps, no vendor: passes Tier 1" || verdict serial "no deps, no vendor: fails (rc $LAST_RC, trap $LAST_T1)"
  dir="$(make_copy serial-vendor stub "" "$FULL")"
  (cd "$dir" && CARGO_HOME="$DEPS/cargo" RUSTC="$TC_RUSTC" "$TC_CARGO" vendor --offline --locked vendor >/dev/null 2>"$WORK/logs/serial-vendor.vendor.err" &&
    mkdir -p .cargo && printf '[source.crates-io]\nreplace-with = "vendored-sources"\n\n[source.vendored-sources]\ndirectory = "vendor"\n' >.cargo/config.toml &&
    command git add -A && command git commit -qm vendored) || { verdict serial "ERROR: cargo vendor failed (see serial-vendor.vendor.err)"; return; }
  run serial-vendor "$dir" "$(recipe "$dir" "$FULL" g1 "")" "" deny nodeps
  t1pass && verdict serial "no deps, vendored: passes Tier 1" || verdict serial "no deps, vendored: FAILS (rc $LAST_RC)"
  dir="$(make_copy serial-vendor-impl impl "" "$FULL")"
  (cd "$dir" && CARGO_HOME="$DEPS/cargo" RUSTC="$TC_RUSTC" "$TC_CARGO" vendor --offline --locked vendor >/dev/null 2>&1 &&
    mkdir -p .cargo && printf '[source.crates-io]\nreplace-with = "vendored-sources"\n\n[source.vendored-sources]\ndirectory = "vendor"\n' >.cargo/config.toml &&
    command git add -A && command git commit -qm vendored)
  run serial-vendor-impl "$dir" "$(recipe "$dir" "$FULL" g1 "")" "" "" nodeps
  [[ "$LAST_RC" -eq 0 && -z "$LAST_MOVED" ]] && verdict serial "no deps, vendored: the implementation exits 0, tree unchanged" || verdict serial "no deps, vendored: implementation rc $LAST_RC, moved ${LAST_MOVED:-none}"
}

main() {
  local rows=("$@") r
  [[ ${#rows[@]} -gt 0 && "${rows[0]}" != all ]] || rows=("${ROWS[@]}")
  echo "# run-plants $(date -u +%FT%TZ) $("$TC_RUSTC" --version)" | tee -a "$RESULTS"
  setup_deps
  for r in "${rows[@]}"; do do_row "$r"; done
}
main "$@"
