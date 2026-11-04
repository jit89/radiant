#!/usr/bin/env bash
# run-plants.sh [all | ROW...] — rerun the Axum + SQLx (SQLite) plants
# (docs/features/rust-axum-sqlx-rules/PLAN.md), extended from the core Rust
# item's harness (docs/features/rust-tier-rules/fixture/run-plants.sh): every
# run goes through proof_exec (scripts/lib/proof.sh) under the proof sandbox,
# on a fresh git copy of notes-sqlite/ with one plant applied. Prints one line
# per run and a verdict per row; EVIDENCE.md records the table.
#
# Needs the pinned toolchain (RUST_TC) and, once, network for `cargo fetch
# --locked` into a deps folder kept by the lockfile's hash. Work, logs and deps
# go under AXS_WORK (default ~/dogfood/axum-sqlx): never under /tmp or
# ~/.claude, which the sandbox denies. Not part of scripts/tests/run-all.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOUSE="$(cd "$HERE/../../../.." && pwd)"
CRATE="$HERE/notes-sqlite"
IMPL="$HERE/impl/lib.rs"
TC="${RUST_TC:-$HOME/.local/rust/rustup/toolchains/1.99.1-aarch64-apple-darwin/bin}"
TC_CARGO="$TC/cargo"
TC_RUSTC="$TC/rustc"
VERSION_LINE='rustc 1.99.1 (58cf8f9c3 2026-10-13)'
WORK="${AXS_WORK:-$HOME/dogfood/axum-sqlx}"
TRAP=notes-trap

# The caller's environment, minus anything that would steer cargo or sqlx
# unless a row sets it on purpose.
unset RUSTC RUSTFLAGS RUSTDOCFLAGS RUSTC_WRAPPER RUSTC_WORKSPACE_WRAPPER CI RUST_TEST_THREADS RUST_BACKTRACE \
  DATABASE_URL SQLX_OFFLINE SQLX_OFFLINE_DIR CLANG_MODULE_CACHE_PATH SDKROOT
for v in $(compgen -e); do
  case "$v" in CARGO_*|RUSTUP_*|INSTA_*|PROPTEST_*|PG*) unset "$v" ;; esac
done
ENVSHOW="env | grep -E '^(RUSTC|RUSTFLAGS|RUSTDOCFLAGS|RUSTC_WRAPPER|RUSTC_WORKSPACE_WRAPPER|CARGO_[A-Z0-9_]*|RUSTUP_[A-Z0-9_]*|CI|RUST_TEST_THREADS|RUST_BACKTRACE|DATABASE_URL|SQLX_[A-Z_]*|CLANG_MODULE_CACHE_PATH|SDKROOT|PG[A-Z]*)=' | sort | sed 's/^/env: /'"
export CW_PROOF_DENIALS=off

# shellcheck disable=SC1091
source "$HOUSE/scripts/lib/proof.sh"
git() { command git "$@"; }

[[ -x "$TC_CARGO" && -x "$TC_RUSTC" ]] || { echo "no toolchain at $TC" >&2; exit 2; }
mkdir -p "$WORK/runs" "$WORK/tmp" "$WORK/logs"
RESULTS="$WORK/results.tsv"
LOCKHASH="$(shasum -a 256 "$CRATE/Cargo.lock" | cut -c1-12)"
DEPS="$WORK/deps-$LOCKHASH"
# The warm target is keyed by the lockfile and the migrations (Grok round 2).
WARM="$WORK/warm-$LOCKHASH-$(cat "$CRATE"/migrations/* | shasum -a 256 | cut -c1-12)"

# Candidate rules. The core RUST.md rules (V B C_* F L T O) stay in every
# recipe; this item's candidates are C_layer, C_pool, C_macro and X_db
# (X_clang was measured and dropped; it is not in the published recipe, so
# not in FULL either). F is not toggled here: the oracle files carry the
# forbid header themselves.
FULL="V B C_sp C_ig C_cu C_mock C_insta C_prop2 C_hook C_layer C_pool C_macro L T O X_db"
pat() {
  case "$1" in
    C_sp) echo 'should_panic' ;;
    C_ig) echo '#\[ignore' ;;
    C_cu) echo 'catch_unwind\(.*\)\.is_(err|ok)\(\)' ;;
    C_mock) echo 'mockall|mock!|automock' ;;
    C_insta) echo 'insta::|assert_[a-z_]*snapshot!' ;;
    C_hook) echo 'set_hook' ;;
    C_layer) echo 'CatchPanicLayer|(^|[^A-Za-z0-9_])app\(' ;;
    C_pool) echo 'SqlitePool::connect|PoolOptions|connect_with|sqlite:[^:]' ;;
  esac
}
# Anchored on the left like app\(, so a project's own build_query! passes.
MACRO_RE='(^|[^A-Za-z0-9_])query(_file)?(_as|_scalar)?(_unchecked)?!'
has() { [[ " $1 " == *" $2 "* ]]; }
minus() { local r out=""; for r in $1; do [[ "$r" == "$2" ]] || out+="$r "; done; echo "${out% }"; }

# recipe RULES TEST — the proof string, as a goal's `proof` field (run from
# the checkout; run() prefixes the host's `cd <checkout> &&`).
recipe() {
  local rules="$1" test="$2" joined="" p rf="" envp="" cmd
  cmd="unset DATABASE_URL PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE;"
  has "$rules" X_db && cmd+=" export DATABASE_URL=;"
  has "$rules" X_clang && cmd+=" export CLANG_MODULE_CACHE_PATH=\"\$TMPDIR/clang\";"
  cmd+=" :"
  has "$rules" V && cmd+=" && ( '$TC_RUSTC' --version | grep -qx '$VERSION_LINE' )"
  for p in C_sp C_ig C_cu C_mock C_insta C_hook C_layer C_pool; do
    has "$rules" "$p" && joined+="${joined:+|}$(pat "$p")"
  done
  [[ -z "$joined" ]] || cmd+=" && ( grep -rqE '$joined' tests/acceptance; test \$? -eq 1 )"
  has "$rules" C_prop2 && cmd+=" && ( f=\$(grep -rl proptest tests/acceptance); test -z \"\$f\" || ! grep -L 'failure_persistence: None' \$f | grep -q . )"
  has "$rules" C_macro && cmd+=" && ( grep -rqE '$MACRO_RE' src tests/acceptance; test \$? -eq 1 )"
  has "$rules" T && envp+="CARGO_TARGET_DIR=\"\$PWD/target\" "
  has "$rules" O && envp+="CARGO_PROFILE_DEV_OVERFLOW_CHECKS=true CARGO_PROFILE_TEST_OVERFLOW_CHECKS=true "
  has "$rules" B && envp+="RUSTC='$TC_RUSTC' "
  cmd+=" && ${envp}'$TC_CARGO' test --offline"
  has "$rules" L && cmd+=" --locked"
  cmd+=" --test $test"
  printf '%s' "$cmd"
}

# make_copy NAME LIB PLANT [cold] [PARENT] — a fresh git repository: the crate,
# LIB (stub|impl), the plant (a test-only plant applies to either lib),
# committed; the warm target copied in unless cold. PARENT puts the copy under
# another folder (the parent-.env rows).
make_copy() {
  local name="$1" lib="$2" plant="$3" cold="${4:-}" parent="${5:-$WORK/runs}" dir
  dir="$parent/$name"
  rm -rf "$dir" && mkdir -p "$parent" && cp -R "$CRATE" "$dir"
  [[ "$lib" == impl ]] && cp "$IMPL" "$dir/src/lib.rs"
  (cd "$dir" && command git init -q && command git config user.name plant &&
    command git config user.email plant@localhost && command git config commit.gpgsign false)
  if [[ -n "$plant" ]]; then
    (cd "$dir" && command git apply "$HERE/plants/$plant.patch") || { echo "plant $plant does not apply" >&2; return 1; }
  fi
  [[ -z "${EXTRA_FILES:-}" ]] || cp -R "$EXTRA_FILES" "$dir/"
  (cd "$dir" && command git add -A && command git commit -qm "row $name")
  [[ "$cold" == cold || ! -d "$WARM" ]] || cp -Rc "$WARM" "$dir/target"
  echo "$dir"
}

tier1() {
  awk -v t="$TRAP" 'prev ~ /^thread .* panicked at / && index($0, t) {f=1} {prev=$0} END {exit !f}' "$1"
}
# case_result NAME — libtest's verdict for one case in the last log.
case_result() { sed -n "s/^test $1 \.\.\. \([a-zA-Z]*\).*/\1/p" "$LAST_LOG" | head -1; }

denials() {
  sleep 3
  /usr/bin/log show --start "$1" --predicate 'sender == "Sandbox"' --style compact 2>/dev/null |
    grep 'deny(' | grep -v 'vfs\.disk-space' | sed 's/.*Sandbox: //; s/([0-9]*)//' | sort | uniq -c | sort -rn || true
}

LAST_RC=0 LAST_T1=no LAST_MOVED="" LAST_LOG="" LAST_TMP=""
# run NAME DIR CMD [setup] [deny] [nodeps] [net] — one proof through proof_exec.
run() {
  local name="$1" dir="$2" cmd="$3" setup="${4:-}" deny="${5:-}" nodeps="${6:-}" net="${7:-none}"
  local log="$WORK/logs/$1.log" t0 start secs deps="$DEPS"
  local before="$WORK/tmp/$name.before" after="$WORK/tmp/$name.after"
  [[ "$nodeps" != nodeps ]] || deps=""
  LAST_TMP="$WORK/tmp/$name"
  rm -rf "$LAST_TMP"
  (cd "$dir" && tree_snapshot) >"$before"
  start="$(date '+%Y-%m-%d %H:%M:%S')"; t0=$SECONDS
  LAST_RC=0
  PROOF_ROOT="$dir" PROOF_DEPS="$deps" PROOF_NETWORK="$net" PROOF_SETUP="${setup:-0}" \
    proof_exec 600 "$log" "$LAST_TMP" "$ENVSHOW; cd '$dir' && $cmd" || LAST_RC=$?
  secs=$((SECONDS - t0))
  (cd "$dir" && tree_snapshot) >"$after"
  LAST_MOVED="$(cd "$dir" && proof_moved "$before" "$after" | paste -sd ';' -)"
  if tier1 "$log"; then LAST_T1=yes; else LAST_T1=no; fi
  if [[ "$deny" == deny ]]; then
    { echo; echo "--- denials logged during this run ---"; denials "$start"; } >>"$log"
  fi
  LAST_LOG="$log"
  if broken; then printf 'ERROR\t%s\tdid not run (rc %s: timeout or sandbox stop)\n' "$name" "$LAST_RC" | tee -a "$RESULTS"; fi
  printf '%s\trc=%s\ttrap=%s\tsecs=%s\tcargo=%s\tmoved=%s\n' "$name" "$LAST_RC" "$LAST_T1" "$secs" \
    "$(sed -n 's/.*Finished .* in \([0-9.]*s\).*/\1/p' "$log" | head -1)" "${LAST_MOVED:-none}" | tee -a "$RESULTS"
}
t1pass() { [[ "$LAST_RC" -ne 0 && "$LAST_T1" == yes ]]; }
broken() { [[ "$LAST_RC" -eq 124 || "$LAST_RC" -eq 126 ]]; }
compile_error() { grep -qE '^error\[E[0-9]+\]|^error: |could not compile' "$LAST_LOG" && ! grep -q '^error: test failed' "$LAST_LOG"; }
verdict() { printf 'VERDICT\t%s\t%s\n' "$1" "$2" | tee -a "$RESULTS"; }

setup_deps() {
  [[ -f "$DEPS/.fetched" ]] && return 0
  rm -rf "$DEPS"; mkdir -p "$DEPS" && chmod 700 "$DEPS"
  local dir; dir="$(make_copy 2b-fetch stub "" cold)"
  run 2b-fetch "$dir" "RUSTC='$TC_RUSTC' '$TC_CARGO' fetch --locked" 1 deny
  [[ "$LAST_RC" -eq 0 ]] || { echo "cargo fetch failed: see $LAST_LOG" >&2; rm -rf "$DEPS"; exit 1; }
  : >"$DEPS/.fetched"
}

# --- step 2b ---------------------------------------------------------------
row_2b() {
  local dir
  rm -rf "$WARM"
  dir="$(make_copy 2b-red-cold stub "" cold)"
  run 2b-red-cold "$dir" "$(recipe "$FULL" g1)" "" deny
  t1pass && verdict 2b "red proof on the stub passes Tier 1" || verdict 2b "red proof FAILED Tier 1 (rc $LAST_RC)"
  cp -Rc "$dir/target" "$WARM"
  dir="$(make_copy 2b-green impl "")"
  run 2b-green "$dir" "$(recipe "$FULL" g1)" "" deny
  [[ "$LAST_RC" -eq 0 ]] && verdict 2b "green proof on the implementation exits 0" || verdict 2b "green proof FAILED (rc $LAST_RC)"
  dir="$(make_copy 2b-red-warm stub "")"
  run 2b-red-warm "$dir" "$(recipe "$FULL" g1)"
  # The bundled C build with the module-cache redirect (dropped candidate):
  # the comparison row. The published recipe (FULL) has no redirect.
  dir="$(make_copy 2b-clang-cold stub "" cold)"
  run 2b-clang-cold "$dir" "$(recipe "$FULL X_clang" g1)" "" deny
  t1pass && verdict 2b "with CLANG_MODULE_CACHE_PATH: passes Tier 1" || verdict 2b "with CLANG_MODULE_CACHE_PATH: FAILS (rc $LAST_RC)"
  # The serial shape: no deps folder, crates vendored into the checkout.
  dir="$(make_copy 2b-vendored stub "" cold)"
  (cd "$dir" && CARGO_HOME="$DEPS/cargo" RUSTC="$TC_RUSTC" "$TC_CARGO" vendor --offline --locked vendor >/dev/null 2>&1 &&
    mkdir -p .cargo && printf '[source.crates-io]\nreplace-with = "vendored-sources"\n\n[source.vendored-sources]\ndirectory = "vendor"\n' >.cargo/config.toml &&
    command git add -A && command git commit -qm vendored) || { verdict 2b "ERROR: cargo vendor failed"; return; }
  run 2b-vendored "$dir" "$(recipe "$FULL" g1)" "" deny nodeps
  t1pass && verdict 2b "vendored, no deps folder: passes Tier 1" || verdict 2b "vendored, no deps folder: FAILS (rc $LAST_RC)"
}

# ref — the Tier 2 reference (examples/tier2_ref.rs: sqlx and the bundled
# SQLite only, nothing from the crate), run inside a proof.
row_ref() {
  local dir; dir="$(make_copy ref stub "")"
  run ref "$dir" "unset DATABASE_URL; export DATABASE_URL=; CARGO_TARGET_DIR=\"\$PWD/target\" RUSTC='$TC_RUSTC' '$TC_CARGO' run -q --offline --locked --example tier2_ref"
  grep -vE '^env: ' "$LAST_LOG"
  [[ "$LAST_RC" -eq 0 ]] && verdict ref "reference ran" || verdict ref "ERROR: reference failed (rc $LAST_RC)"
}

# clean TEST — (a)(b)(c) for the full recipe; also where #[sqlx::test] put files.
row_clean() {
  local t="$1" dir ok=1 f
  dir="$(make_copy "clean-$t-stub" stub "")"; run "clean-$t-stub" "$dir" "$(recipe "$FULL" "$t")"
  t1pass && [[ -z "$LAST_MOVED" ]] || ok=0
  f="$(find "$dir" "$LAST_TMP" -name '*.sqlite*' -not -path '*/vendor/*' 2>/dev/null | sed "s|$WORK/||" | paste -sd ' ' -)"
  echo "sqlite files after the failing run: ${f:-none}"
  dir="$(make_copy "clean-$t-impl" impl "")"; run "clean-$t-impl" "$dir" "$(recipe "$FULL" "$t")"
  [[ "$LAST_RC" -eq 0 && -z "$LAST_MOVED" ]] || ok=0
  ((ok)) && verdict "clean-$t" "(a)(b)(c) hold" || verdict "clean-$t" "(a)(b)(c) BROKEN"
}

# case NAME PLANT RULE TEST CASE — a plant beside a trapping sibling; minus =
# full without RULE. Scored on two separate grounds (Opus round 1):
#   per-case: minus is a Tier 1 pass with CASE `ok` on the stub (a hole);
#   tamper:   minus is a Tier 1 pass and moved the tree.
# Kept when either ground holds under minus and full is not a Tier 1 pass. A
# rule that newly creates a Tier 1 pass would be a launder and is never credited.
row_case() {
  local name="$1" plant="$2" rule="$3" t="$4" c="$5" dir m mc mv grounds=""
  m="$(minus "$FULL" "$rule")"
  dir="$(make_copy "$name-minus" stub "$plant")"; run "$name-minus" "$dir" "$(recipe "$m" "$t")"
  mc="$(case_result "$c")"; mv="$LAST_MOVED"
  if broken; then verdict "$name" "ERROR: minus did not run"; return; fi
  if ! t1pass; then verdict "$name" "dropped: the baseline already fails Tier 1 (case $c: ${mc:-absent})"; return; fi
  [[ "$mc" == ok ]] && grounds+="the case passes on the stub; "
  [[ -n "$mv" ]] && grounds+="minus moved the tree ($mv); "
  if [[ -z "$grounds" ]]; then verdict "$name" "no hole under minus (case $c: ${mc:-absent}, tree unchanged): nothing to catch"; return; fi
  dir="$(make_copy "$name-full" stub "$plant")"; run "$name-full" "$dir" "$(recipe "$FULL" "$t")"
  if broken; then verdict "$name" "ERROR: full did not run"; return; fi
  if t1pass; then verdict "$name" "GAP: passes Tier 1 under the full recipe (${grounds}case under full: $(case_result "$c"))"
  elif [[ "$mc" != ok && -n "$LAST_MOVED" ]]; then verdict "$name" "NOT credited: the tamper ground needs full to leave the tree unchanged (moved: $LAST_MOVED)"
  else verdict "$name" "caught by $rule (${grounds%; })"; fi
}

# t2 NAME PLANT — a Tier 2 pin against the implementation.
row_t2() {
  local name="$1" plant="$2" dir
  dir="$(make_copy "$name" impl "$plant")"; run "$name" "$dir" "$(recipe "$FULL" g3)"
  if [[ "$LAST_RC" -eq 0 ]]; then verdict "$name" "green against the implementation"
  elif broken || compile_error; then verdict "$name" "ERROR: did not run its assertions (rc $LAST_RC)"
  else verdict "$name" "red against the implementation"; fi
}

# prep_sqlx — a .sqlx/ matching the s2 plant's query!, prepared the way an
# Architect with a database would (outside any proof): an online build against
# a scratch database holding the migrations, with SQLX_OFFLINE_DIR set.
# Keyed by the lockfile, the plant and the migrations, like DEPS and WARM, so a
# rerun after an upgrade never reuses an old cache.
SQLX_KEY="$LOCKHASH-$(cat "$HERE/plants/s2-query-macro.impl.patch" "$CRATE"/migrations/* | shasum -a 256 | cut -c1-12)"
SQLX_DIR="$WORK/sqlx-prepared-$SQLX_KEY/.sqlx"
prep_sqlx() {
  [[ -d "$SQLX_DIR" && -n "$(ls "$SQLX_DIR" 2>/dev/null)" ]] && return 0
  local p="$WORK/sqlx-prep" db
  rm -rf "$p" "$(dirname "$SQLX_DIR")"; mkdir -p "$SQLX_DIR"   # sqlx writes into it; it must exist
  p="$(make_copy sqlx-prep impl s2-query-macro.impl cold "$WORK")"
  db="$(dirname "$SQLX_DIR")/prep.db"
  # Every migration, as the key covers. A reversible migration's .down.sql
  # would need excluding here; the fixture has none.
  cat "$CRATE"/migrations/*.sql | /usr/bin/sqlite3 "$db"
  (cd "$p" && CARGO_HOME="$DEPS/cargo" RUSTC="$TC_RUSTC" DATABASE_URL="sqlite://$db" SQLX_OFFLINE_DIR="$SQLX_DIR" \
    CARGO_TARGET_DIR="$p/target" "$TC_CARGO" build --offline --locked --tests >"$WORK/logs/sqlx-prep.log" 2>&1)
  ls "$SQLX_DIR" 2>/dev/null | head -3
  [[ -n "$(ls "$SQLX_DIR" 2>/dev/null)" ]] || { echo "prep_sqlx: no .sqlx written (see logs/sqlx-prep.log)" >&2; return 1; }
}

row_macro() {
  local dir m
  prep_sqlx || { verdict s2 "ERROR: could not prepare .sqlx"; return; }
  m="$(minus "$FULL" C_macro)"
  dir="$(EXTRA_FILES="$SQLX_DIR" make_copy s2-diag impl s2-query-macro.impl)"
  if (cd "$dir" && grep -rqE "$MACRO_RE" src tests/acceptance); then verdict s2 "diagnostic grep (outside the proof) matches the plant's query!"
  else verdict s2 "VOID: the diagnostic grep does not match the plant"; return; fi
  dir="$(EXTRA_FILES="$SQLX_DIR" make_copy s2-minus impl s2-query-macro.impl cold)"
  run s2-minus "$dir" "$(recipe "$m" g1)"
  verdict s2 "minus (DATABASE_URL empty, .sqlx present): rc $LAST_RC $(compile_error && echo '(compile error)')"
  dir="$(EXTRA_FILES="$SQLX_DIR" make_copy s2-minus-offline impl s2-query-macro.impl cold)"
  run s2-minus-offline "$dir" "export SQLX_OFFLINE=true; $(recipe "$m" g1)"
  verdict s2 "minus + SQLX_OFFLINE=true: rc $LAST_RC $(compile_error && echo '(compile error)')"
  dir="$(make_copy s2-nocache impl s2-query-macro.impl cold)"
  run s2-nocache "$dir" "$(recipe "$m" g1)"
  verdict s2 "minus, no .sqlx: rc $LAST_RC $(compile_error && echo '(compile error)')"
  dir="$(EXTRA_FILES="$SQLX_DIR" make_copy s2-full impl s2-query-macro.impl)"
  run s2-full "$dir" "$(recipe "$FULL" g1)"
  verdict s2 "full: rc $LAST_RC (the check)"
}

# A parent folder's .env with another DATABASE_URL (sqlx-macros reads every
# ancestor's .env). Cold builds: a changed env alone does not rebuild.
row_env() {
  local par="$WORK/envparent" dir
  mkdir -p "$par" && printf 'DATABASE_URL=sqlite:///nonexistent-dir/x.db\n' >"$par/.env"
  prep_sqlx || { verdict s3 "ERROR: could not prepare .sqlx"; rm -f "$par/.env"; return; }
  dir="$(make_copy env-clean-minus impl "" cold "$par")"
  run env-clean-minus "$dir" "$(recipe "$(minus "$FULL" X_db)" g1)"
  verdict s3 "clean oracle, parent .env, unset only: rc $LAST_RC"
  dir="$(make_copy env-clean-full impl "" cold "$par")"
  run env-clean-full "$dir" "$(recipe "$FULL" g1)"
  verdict s3 "clean oracle, parent .env, DATABASE_URL exported empty: rc $LAST_RC"
  dir="$(EXTRA_FILES="$SQLX_DIR" make_copy env-macro-minus impl s2-query-macro.impl cold "$par")"
  run env-macro-minus "$dir" "$(recipe "$(minus "$(minus "$FULL" X_db)" C_macro)" g1)"
  verdict s3 "macro plant + .sqlx, parent .env, unset only: rc $LAST_RC $(compile_error && echo '(compile error)')"
  dir="$(EXTRA_FILES="$SQLX_DIR" make_copy env-macro-xdb impl s2-query-macro.impl cold "$par")"
  run env-macro-xdb "$dir" "$(recipe "$(minus "$FULL" C_macro)" g1)"
  verdict s3 "macro plant + .sqlx, parent .env, exported empty: rc $LAST_RC $(compile_error && echo '(compile error)')"
  rm -f "$par/.env"
}

# Migration staleness: a warm build, then a new migration and a case needing it.
row_stale() {
  local with="$1" name="s4b-stale-$1" dir
  dir="$(make_copy "$name" impl "" cold)"
  if [[ "$with" == buildrs ]]; then
    printf 'fn main() {\n    println!("cargo:rerun-if-changed=migrations");\n}\n' >"$dir/build.rs"
    (cd "$dir" && command git add -A && command git commit -qm build.rs)
  fi
  run "$name-1" "$dir" "$(recipe "$FULL" g1)"
  printf 'ALTER TABLE notes ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;\n' >"$dir/migrations/0002_pinned.sql"
  cat >>"$dir/tests/acceptance/g1.rs" <<'EOF'

#[sqlx::test(migrations = "./migrations")]
async fn pinned_column_exists(pool: SqlitePool) {
    let n: i64 = sqlx::query_scalar("SELECT count(pinned) FROM notes").fetch_one(&pool).await.unwrap();
    assert_eq!(n, 0);
}
EOF
  (cd "$dir" && command git add -A && command git commit -qm "migration 0002")
  run "$name-2" "$dir" "$(recipe "$FULL" g1)"
  verdict s4b "$with: after a new migration on a warm build: rc $LAST_RC, case pinned_column_exists $(case_result pinned_column_exists)"
}

# s4c — the staleness that matters: the oracle needing a column is committed
# first (red: no such column), then only a migration is added, with no test
# file touched. Without a rerun-if-changed, does the warm build embed it?
row_stale2() {
  local with="$1" name="s4c-stale-$1" dir
  dir="$(make_copy "$name" impl "" cold)"
  if [[ "$with" == buildrs ]]; then
    printf 'fn main() {\n    println!("cargo:rerun-if-changed=migrations");\n}\n' >"$dir/build.rs"
  fi
  cat >>"$dir/tests/acceptance/g1.rs" <<'EOF2'

#[sqlx::test(migrations = "./migrations")]
async fn pinned_column_exists(pool: SqlitePool) {
    let n: i64 = sqlx::query_scalar("SELECT count(pinned) FROM notes").fetch_one(&pool).await.unwrap();
    assert_eq!(n, 0);
}
EOF2
  (cd "$dir" && command git add -A && command git commit -qm "case first")
  run "$name-1" "$dir" "$(recipe "$FULL" g1)"
  verdict s4c "$with: before the migration: rc $LAST_RC, case $(case_result pinned_column_exists)"
  printf 'ALTER TABLE notes ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;\n' >"$dir/migrations/0002_pinned.sql"
  (cd "$dir" && command git add -A && command git commit -qm "migration only")
  run "$name-2" "$dir" "$(recipe "$FULL" g1)"
  verdict s4c "$with: after adding only the migration (warm, test unchanged): rc $LAST_RC, case $(case_result pinned_column_exists)"
}

ROWS=(2b ref clean-g1 clean-g2 clean-g3 a1 a2 a3 a3b s2 s3 s4a s4b s4c s5 t2)

do_row() {
  local dir i m
  case "$1" in
    2b) row_2b ;;
    ref) row_ref ;;
    clean-g1|clean-g2|clean-g3) row_clean "${1#clean-}" ;;
    a1) row_case a1-5xx a1-5xx-via-app.stub C_layer g2 get_failure_is_500 ;;
    a2) dir="$(make_copy a2-none-stub stub a2-listener-timeout.stub)"; run a2-none-stub "$dir" "$(recipe "$FULL" g2)"
        verdict a2 "listener, no network, stub: rc $LAST_RC trap $LAST_T1, case served_get_is_404 $(case_result served_get_is_404)"
        dir="$(make_copy a2-none-impl impl a2-listener-timeout.stub)"; run a2-none-impl "$dir" "$(recipe "$FULL" g2)"
        verdict a2 "listener, no network, implementation: rc $LAST_RC, case $(case_result served_get_is_404)"
        dir="$(make_copy a2-loop-impl impl a2-listener-timeout.stub)"; run a2-loop-impl "$dir" "$(recipe "$FULL" g2)" "" "" "" loopback
        verdict a2 "listener, loopback, implementation: rc $LAST_RC, case $(case_result served_get_is_404)"
        dir="$(make_copy a2-loop-stub-notimeout stub a2-listener-no-timeout.stub)"; run a2-loop-stub-notimeout "$dir" "$(recipe "$FULL" g2)" "" "" "" loopback
        verdict a2 "listener, loopback, stub, no timeout: rc $LAST_RC (124 = hung), case $(case_result served_get_is_404)" ;;
    a3) row_case a3-fake a3-fake-repo.stub - g1 repo_returns_the_note ;;
    a3b) row_case a3b-extractor a3b-extractor-rejection.stub - g2 malformed_json_is_400 ;;
    s2) row_macro ;;
    s3) row_env ;;
    s4a) dir="$(make_copy s4a-dup impl s4a-dup-migration-version.stub)"; run s4a-dup "$dir" "$(recipe "$FULL" g1)"
         verdict s4a "two migrations with version 0002: rc $LAST_RC $(compile_error && echo '(compile error)') $(grep -m1 -oE 'UNIQUE constraint failed[^"]*' "$LAST_LOG")" ;;
    s4b) row_stale none; row_stale buildrs ;;
    s4c) row_stale2 none; row_stale2 buildrs ;;
    s5) row_case s5-filedb s5-file-db-in-checkout.stub C_pool g1 creates_in_a_file_db
        dir="$(make_copy s5-filedb-impl impl s5-file-db-in-checkout.stub)"; run s5-filedb-impl "$dir" "$(recipe "$(minus "$FULL" C_pool)" g1)"
        verdict s5 "file database in the checkout, implementation, no check: rc $LAST_RC, moved ${LAST_MOVED:-none}" ;;
    t2) row_t2 t2-like t2-like-case.stub; row_t2 t2-affinity t2-affinity.stub; row_t2 t2-division t2-division.stub
        row_t2 t2-dates t2-dates-as-text.stub; row_t2 t2-rowid t2-rowid-reuse.stub
        for i in 1 2 3 4 5; do row_t2 "t2-order-$i" t2-order-unsorted.stub; done ;;
    *) echo "unknown row $1" >&2; return 2 ;;
  esac
}

main() {
  local rows=("$@") r
  [[ ${#rows[@]} -gt 0 && "${rows[0]}" != all ]] || rows=("${ROWS[@]}")
  echo "# run-plants $(date -u +%FT%TZ) $("$TC_RUSTC" --version)" | tee -a "$RESULTS"
  setup_deps
  for r in "${rows[@]}"; do do_row "$r"; done
}
main "$@"
