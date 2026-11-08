# Rust: Tier 1 and Tier 2

The Rust rules for proving an oracle (SKILL.md §4, GOAL-FORMAT.md "the
tiers"), for **`cargo test`** (libtest). They were measured on rustc and cargo
1.99.1 with insta 1.49.0, mockall 0.15.0, proptest 1.12.0 and tokio 1.54.1,
against planted oracle defects run through the host's own proof sandbox
(`docs/features/rust-tier-rules/EVIDENCE.md` on the house's main branch).

Each rule marked *kept* did one of three things: it turned a planted defect
that passed Tier 1 into a Tier 1 failure, turned a tampering run clean, or
turned a red run of the correct implementation green (the overflow rule).
`RUSTC="$RUSTC"` is the exception: it makes the compiler cargo uses the one the
version check read. Another runner (nextest) is proved the same way before its
first oracle. A project on Axum and SQLx also follows
[RUST-AXUM-SQLX.md](RUST-AXUM-SQLX.md).

## The `proof`, as the host runs it

The host runs a `proof` from the goal's checkout (`cd <checkout> && <proof>`,
in each merged worktree too), with `bash -c`, the walk's environment minus
credential variables, no login shell, and no network. So:
- call cargo and rustc by the toolchain's absolute path, not the rustup proxy;
- keep every path in the proof relative to the checkout;
- **vendor the crates into the checkout.** Commit `vendor/` (`cargo vendor`) and
  a `.cargo/config.toml` that replaces crates.io with it:

  ```toml
  [source.crates-io]
  replace-with = "vendored-sources"

  [source.vendored-sources]
  directory = "vendor"
  ```

  Measured: with no deps folder (a serial run has none, so `CARGO_HOME` is the
  proof's own empty temp folder), the proof fails on the first missing crate
  without `vendor/` and passes with it. A parallel walk's `worktree_setup` of
  `"$CARGO" fetch --locked` also fills the walk's deps folder for the host's
  proofs, but not for a serial run, and never for the implementer: its sandbox
  has no network, and nothing points its `CARGO_HOME` at that folder.
  Vendoring covers all three. Every crate a goal needs goes into `Cargo.toml`,
  `Cargo.lock` and `vendor/` in Phase 3.

  `vendor/` and `.cargo/config.toml` now steer every proof: an edited vendored
  crate (its `.cargo-checksum.json` updated to match) still passes `--locked`,
  and the checks only search `tests/acceptance/`. So the Architect commits
  both in Phase 3, with the `[[test]]` blocks, and no goal edits them. The
  rule reaches the implementer and the goal reviewer through the goal itself:
  every Rust goal's **Out of scope** names `vendor/` and `.cargo/` (the
  reviewer reads that goal's entry in GOALS.md, not this file).

The rules were measured with `RUSTC`, `RUSTFLAGS`, `RUSTDOCFLAGS`,
`RUSTC_WRAPPER`, `RUSTC_WORKSPACE_WRAPPER`, `CI`, `RUST_TEST_THREADS`,
`RUST_BACKTRACE` and every
`CARGO_*`, `RUSTUP_*`, `INSTA_*` and `PROPTEST_*` variable unset. The host
passes the walk's environment through. If the user's shell exports any of them,
unset them in the walk's environment. For example, an exported
`RUSTFLAGS=-C overflow-checks=off` defeats the overflow rule, `-D warnings`
breaks a clean oracle on a target with one warning, and `RUSTC_WRAPPER=sccache`
writes its cache outside the trees a proof may write.

`$CARGO` and `$RUSTC` are the pinned toolchain's own binaries, written into the
`proof` literally, for example
`~/.local/rust/rustup/toolchains/1.99.1-aarch64-apple-darwin/bin/cargo` with an
absolute home. The recipe is one line in GOALS.md (shown wrapped). It starts
with `(`: goals.py reads its own subset of YAML (the value runs from the first
`:` to the end of the line), and a leading `!` or `"` would read as a tag or a
quoted scalar.

```bash
( "$RUSTC" --version | grep -qx 'rustc 1.99.1 (58cf8f9c3 2026-10-13)' ) &&
( grep -rqE 'should_panic|#\[ignore|catch_unwind\(.*\)\.is_(err|ok)\(\)|mockall|mock!|automock|insta::|assert_[a-z_]*snapshot!|set_hook' tests/acceptance; test $? -eq 1 ) &&
( f=$(grep -rl proptest tests/acceptance); test -z "$f" || ! grep -L 'failure_persistence: None' $f | grep -q . ) &&
CARGO_TARGET_DIR="$PWD/target" CARGO_PROFILE_DEV_OVERFLOW_CHECKS=true CARGO_PROFILE_TEST_OVERFLOW_CHECKS=true RUSTC="$RUSTC" "$CARGO" test --offline --locked --test <id>
```

**Every oracle file** is a single integration-test file
`tests/acceptance/<id>.rs`. It opens with:

```rust
#![forbid(unused_must_use, unreachable_code)]
```

and is declared in `Cargo.toml`:

```toml
[[test]]
name = "<id>"
path = "tests/acceptance/<id>.rs"
```

Cargo only auto-discovers `tests/*.rs` and `tests/*/main.rs`. Without the
declaration, `--test <id>` finds no target. The `[[test]]` table is a shared
registration point (GOAL-FORMAT.md, "Registration points"), so the Architect
commits every goal's block in Phase 3, with the red oracles, and no goal edits
it. `--test <id>` builds only its own target: another goal's oracle that does
not compile yet does not reach this proof (measured).

`Cargo.lock` is committed and `/target` is gitignored.

**The trap.** Every stub body is `panic!("<feature>-trap")`, with parameters
named `_x` so the stub raises no warning. Not `todo!()`, `unimplemented!()` or
`unreachable!()`: their messages are fixed and shared.

**Reading the trap.** The trap counts only on the line after libtest's
`thread '<test>' (<tid>) panicked at <file>:<line>:<col>:` line. The trap
string anywhere else, such as a compiler error quoting the stub's source, is
not a pass.

The pass bar is GOAL-FORMAT's, applied to the whole `proof`.

**`tool_path`.** When the pinned toolchain is not on the host's `PATH`, set
GOALS.md's `tool_path: [<dirname "$CARGO">]` (GOAL-FORMAT.md). The proof gets
`CARGO_HOME` pointed at an empty folder, so `$CARGO` finds `cargo-clippy` and
`cargo-fmt` through `PATH` only. Without the key, `"$CARGO" clippy` fails
"no such command" in the proof (Paladin M0, measured). The folder leads `PATH`
for the implementer, the proof and the reviewer, and never for the host. It
must sit outside the target repo (the implementer could plant a tool there)
and somewhere the proof sandbox can read (not `/tmp`, `/var/folders`, a
secret path or the house cache); `validate` rejects both.

## Opt-in: the lint gate

A plan opts in in its PLAN.md (house feature `rust-toolchain-gates`). Its
lint table, `[workspace.lints]`, decides what is a warning, and every
workspace package carries `[lints] workspace = true`. Tier 1 checks that each
member has the line; without it the table does nothing. The proof appends,
after the test step (one line in GOALS.md, shown wrapped):

```bash
&& <envs> "$CARGO" clippy --offline --locked --workspace --lib --bins --test <id> -- -D warnings
&& <envs> "$CARGO" fmt --all --check
&& ( grep -rnE '#!?\[(cfg_attr\([^]]*)?(allow|expect)\((warnings|clippy::(all|pedantic|restriction|style|correctness|suspicious|complexity|perf|nursery|cargo))' --include='*.rs' <source roots>; test $? -eq 1 )
```

`<envs>` is the recipe's environment prefix (`CARGO_TARGET_DIR`, the overflow
variables, `RUSTC="$RUSTC"`). `<source roots>` are the plan's crate source
folders, never `tests/acceptance/`.

- **Not `--all-targets`.** It type-checks every `[[test]]`, later goals'
  oracles too, which do not compile yet; every early goal would go red (Paladin
  g1). The gate covers all library and binary code in the workspace plus this
  goal's own oracle. `#[cfg(test)]` unit-test modules are not linted: an
  accepted gap.
- **`fmt --all` is safe:** rustfmt parses and does not type-check, and every
  oracle is committed rustfmt-clean.
- **Opting in partway** through a project needs a cleanup goal first (Paladin
  g8).
- **Out of scope, in every opted-in goal body** (the reviewer reads the body,
  not this file): `clippy.toml`, `.clippy.toml`, `rustfmt.toml`,
  `.rustfmt.toml`, every `Cargo.toml`'s `[lints]` and `[workspace.lints]`
  tables, `Cargo.lock`, `vendor/` and `.cargo/`. Next to it, the body says:
  "No `#[allow]` or `#[expect]` of a lint the plan denies in crate source,
  outside a `#[cfg(test)]` item." The proof's grep catches only blanket and
  group allows; this line is how the goal reviewer learns to look for the
  rest.
- **Timeout.** `PROOF_TIMEOUT` (default 600 s) must cover a cold clippy run
  of the workspace libraries plus the goal's test target; mutation runs repeat
  it warm. A plan near the limit raises `PROOF_TIMEOUT` in its walk
  instructions.

**Tier 1 with the lint tail.** The proof's `&&` chain stops at the red test
step, so it never lints the oracle against the stubs. Lint separately:

1. Each stubbed crate root carries
   `#![allow(warnings, clippy::all, clippy::pedantic, clippy::restriction, clippy::panic, clippy::unwrap_used, clippy::expect_used, clippy::todo, clippy::unimplemented, missing_docs, unreachable_pub)]`.
   The individual names beat a plan's named `deny`, which a group allow would
   not. Stubs never use `unsafe` (`forbid` cannot be allowed).
2. `<envs> "$CARGO" clippy --offline --locked --workspace --lib --bins -- -D warnings`
   exits 0 against the stubs. If not, fix the stubs first.
3. For **every** oracle, with `tool_path` on `PATH`:
   `<envs> "$CARGO" clippy --offline --locked --test <id> --message-format=json -- -D warnings`.
   Any diagnostic whose primary span is under `tests/acceptance/` fails
   Tier 1 (Paladin g8 blocked on four).
4. The blanket-allow grep above, run on `tests/acceptance/`: any hit fails
   Tier 1. An oracle may allow one named lint (`clippy::panic` for its trap
   assertions), never a group.
5. `<envs> "$CARGO" fmt -- --check <every oracle file>`.
6. Where a reference implementation exists (a prior attempt, a scratch), the
   full proof exits 0 against it.

## Mutation proofs

A `mutation_proof` (GOAL-FORMAT.md) runs in a copy of the checkout at another
path, with the checkout's `target/` copied along. Cargo fingerprints a
vendored crate by its **absolute** source path, so in the copy every vendored
crate rebuilds (`cargo build -v`: `Dirty serde vX: the path to the source
changed`), and every workspace crate after them. Workspace crates alone would
stay fresh: their paths are hashed relative to the workspace. Paladin g39: the
mutation step rebuilt the vendored graph and took 20 minutes.

The host gives the mutation proof `CW_MUT_CHECKOUT`, the checkout's physical
path. Point the vendored source back at the checkout's own `vendor/`, in each
cargo call of the `mutation_proof` (after the subcommand):

```bash
"$CARGO" test --offline --locked --config "source.vendored-sources.directory='$CW_MUT_CHECKOUT/vendor'" ...
```

The name is the `[source.<name>]` table of `.cargo/config.toml`. The
mutation proof keeps the proof's build flags (the same features and profile
env), so its fingerprints match the copied ones. A probe (1.99.1; cfg-if,
memchr, serde with its build script and derive, a different `CARGO_HOME`)
rebuilt nothing. Only `--config` works: `CARGO_SOURCE_VENDORED_SOURCES_DIRECTORY`
is ignored, and a `vendor` symlink in the copy still rebuilds (Cargo uses
the path it was given). The proof reads the checkout's `vendor/` and writes
only in the copy. A checkout under a temp area (`/tmp`, `/var/folders`) is
unreadable to the proof, so the baseline goes red and every mutation is
skipped.

To check a new recipe: run its cargo step once in a copy of the checkout
(`cp -cRp`, with `target/`), with `CW_MUT_CHECKOUT` set to the checkout and
`-v`. No line says `Dirty` for a vendored crate.

## Why each piece is there

- **No type-check step.** rustc type-checks inside `cargo test`. A wrong-typed
  call (E0308), an invented symbol (E0425) or an `async fn` under `#[test]`
  exits 101 without the trap and fails Tier 1 already.
- **Kept: the version check.** The proof refuses any compiler but the one the
  rules were proved on. A recipe whose rustc reported another version passed
  Tier 1 without it.
- **Kept: `RUSTC="$RUSTC"` on cargo.** Without it, cargo compiled with a
  `RUSTC` the caller exported, while the version check had read the pinned one.
- **Kept: the check.** It searches every file under `tests/acceptance/` and
  fails closed: a match or a grep error both fail the proof. It prints
  nothing, because printing a matched line could print the trap text. It is
  one parenthesized check: `;`-chained checks would let cargo run after a hit.
  It rejects:
  - `should_panic`, bare or with an `expected =` that is a substring of the
    trap: either passes on the trap while a sibling case still prints it;
  - `catch_unwind(…).is_err()` / `.is_ok()` on one line: the same;
  - `#[ignore`: the case never runs;
  - `mockall`, `mock!`, `automock`: a mock of the feature passed Tier 1, then
    went green with the feature untested;
  - insta's `insta::` and `assert_*snapshot!`: the stub panics before the
    macro, so Tier 1 passes. Then the implementation run writes a `.snap.new`
    under `tests/acceptance/`, which the host calls tampering (with `CI=1` it
    fails without writing);
  - `set_hook`: a panic hook in an oracle makes Tier 1 depend on thread
    order. Over four runs of five, it passed in 9 of 20 and showed no trap in
    the other 11.
- **Kept: proptest without persistence.** A failing property writes
  `tests/acceptance/<id>.proptest-regressions` (tampering). So every oracle
  file that uses proptest sets persistence off:

  ```rust
  proptest! {
      #![proptest_config(ProptestConfig { failure_persistence: None, ..ProptestConfig::default() })]
      ...
  }
  ```

  The second check rejects a file that does not.
- **Kept: `#![forbid(unused_must_use, unreachable_code)]`.** A dropped
  `Result`, a future never awaited, or an assertion after `return` passed
  Tier 1 because a sibling case trapped, and then went green on the
  implementation without checking anything. `forbid`, not `deny`: an inner
  `#[allow(...)]` overrides `deny` (measured) and is a compile error under
  `forbid`. The global `RUSTFLAGS="-D warnings"` is not used: it misses the
  `#[allow]` bypasses, and it fails every proof of a target that already has
  one warning.
- **Kept: `--locked`.** Without a committed `Cargo.lock` the first proof writes
  one: tampering.
- **Kept: `CARGO_TARGET_DIR="$PWD/target"`.** A project `.cargo/config.toml`
  with `build.target-dir` under `tests/acceptance/` otherwise builds there:
  tampering. The env var wins over the config file.
- **Kept: both `CARGO_PROFILE_*_OVERFLOW_CHECKS=true`.**
  `overflow-checks = false` in either `[profile.dev]` or `[profile.test]` turns
  checks off in the library and the oracle alike. Then an overflow the plan
  says panics wraps silently. The env form keeps the target's own `RUSTFLAGS`.
- **A stated fact:** a target's `build.rs` runs in every proof. It already runs
  implementer code, so this adds no kind of access, but read `build.rs` like
  any other implementer file.

A pinned panic the plan specifies is written by catching the panic and
comparing its payload:

```rust
let e = std::panic::catch_unwind(|| must_parse("")).unwrap_err();
assert_eq!(panic_message(e), "duration must not be empty"); // a downcast helper
```

Against the stub, the trap's panicked block prints first, then the assertion
fails on the trap's payload: Tier 1 passes for the right reason.

Measured and not needed:
- a zero-test guard (a filter matching nothing exits 0, which the pass bar
  rejects);
- `panic = "abort"` profiles (tests ignore them).

Not a candidate: `-- --include-ignored`. The sibling case's trap keeps the
exit at 101 with the trap printed, so it cannot change a Tier 1 verdict. The
check's `#[ignore` pattern is the rule.

## Tier 2: computed expectations

Compute every expected value the plan does not state verbatim with a
reference: a standalone Rust file importing nothing from the code under test,
built with the proof's own `rustc` without `-O` (overflow checks on, as the
proof builds). Record its output with the oracle. Slips it caught:

- an overflowing sum pinned at its wrapped value (`705_032_704`): the build
  panics instead;
- `-7 % 3` pinned as `2`: it is `-1` (`rem_euclid` gives `2`);
- `"go🚀".len()` pinned as `3`: it counts bytes, `6` (`chars().count()` is 3);
- `format!("{}", 1.0)` pinned as `"1.0"`: `Display` prints `1`, `Debug` prints
  `1.0`;
- `"İ".to_lowercase()` pinned as `"i"`: it is `"i\u{307}"`, two chars;
- `assert_eq!(x, f64::NAN)`: always red. Use `x.is_nan()`.

Two rules are about the comparison, not the value:
- **`-0.0`:** `assert_eq!(negate(0.0), 0.0)` passes against `-0.0`, because
  `-0.0 == 0.0`. Compare `to_bits()` when the sign matters.
- **`HashMap` and `HashSet` order:** different on every run. Never pin it.
  Sort, or use a `BTreeMap`.

## Look for (self-review and oracle review)

Not covered by the check or by `forbid`:
- **`let _ = <call into the planned API>`.** It silences `unused_must_use` for a
  `Result` and for a future alike, so the call is never checked (a future is
  never even run). Planted; nothing caught it. Bind and assert, or `.await`.
- **A banned pattern spelled differently.** A multi-line `catch_unwind(…)` then
  `.is_err()`, a macro that expands to `should_panic`, a re-export of mockall.
- **`expect-test`.** Never set `UPDATE_EXPECT`: it rewrites the oracle's own
  source.
- **A case that never runs:** one compiled out by `#[cfg(feature = …)]`, or a
  function missing `#[test]`. Both act like `#[ignore]`, and `dead_code` is not
  forbidden.
- **A mock from the library:** an `#[automock]` in the target's code generates
  `Mock*` types that an oracle can use with no banned word under
  `tests/acceptance/`.
- **Overflow checks turned off past the env vars:** a per-package
  `[profile.dev.package.<name>] overflow-checks = false`, or
  `-C overflow-checks=off` in the target's `RUSTFLAGS` or `build.rustflags`
  (it comes after the profile's flag and wins).
- **A Rust goal whose Out of scope does not name `vendor/` and `.cargo/`.**
  The Architect's `.cargo/config.toml` holds only the source replacement. A
  `target.*.runner`, a `build.rustc-wrapper`, an `[env]` table or an edited
  vendored crate each changes how the proof runs.
- **Two `proptest!` blocks in one file, one without persistence off:** the
  file-level check passes.
- **A macro crate that emits `#[allow(unreachable_code)]`** (async-trait does)
  fails to compile under `forbid`. That fails closed, but the walk stalls on
  it: name the crate in the plan, and keep its uses out of the oracle.
- **Under the lint gate: an `#[allow]` or `#[expect]` of a lint the plan
  denies,** in a crate source root, outside a `#[cfg(test)]` item. The proof's
  grep catches blanket and group allows only; a single named lint, or an
  allow a macro generates, is a review finding. Not under `tests/acceptance/`:
  the Architect's named allows there are by design.

## After an upgrade

Pin the new toolchain in `fixture/crate/rust-toolchain.toml` and in
`run-plants.sh` (`RUST_TC`, `VERSION_LINE`), bump the crates and regenerate the
lockfile. Then run `docs/features/rust-tier-rules/fixture/run-plants.sh all` (on
the house's main branch; one `cargo fetch` with network, cached by the
lockfile's hash). Every row should match `EVIDENCE.md`. A mismatch names the
rule to recheck before these rules are trusted on the new versions.

A target under the lint gate: a newer clippy brings new lints, and under
`-D warnings` each one turns every goal red. Re-run the lint tail on `main`
with the new toolchain, and land a cleanup goal before the next walk.
