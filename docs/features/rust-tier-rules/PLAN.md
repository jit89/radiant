# Plan: Rust rules for Tier 1 and Tier 2
_Locked via crucible — by Claude + cobalt, 2026-11-02._

## Goal

The to-goals rulebook proves an oracle cheaply before it is committed. Tier 1
runs the goal's `proof` against trap stubs of the planned API. Tier 2 checks
computed expectations against a reference or a brute-force model. TypeScript
has a proved rulebook (`skills/to-goals/TYPESCRIPT.md`,
`docs/features/ts-tier-rules/`). Rust has one table row shared with Go
(`skills/to-goals/GOAL-FORMAT.md:177`).

This item writes the Rust rules for **`cargo test` (libtest)**. Each rule is
admitted only when a planted oracle defect, on a throwaway Rust crate, shows
the rule changes the Tier 1 or Tier 2 verdict. It also proves that Rust runs
under the proof sandbox (SKILL.md §4 step 0b), which no Rust project has done
yet.

The purpose is the same as for TypeScript: catch the errors that really break
an oracle in this language, so Tier 3 is never needed, not every Rust pitfall.
The research is `docs/features/rust-tier-rules/RESEARCH.md`. Its "Architect
verification" section was run on the installed toolchain and wins wherever
the agent's text differs from it.

## Approach

0. **The verdict is the existing pass bar on the `proof` command.** Tier 1
   passes when the `proof` exits nonzero and its output carries the trap
   message (or this goal's assertion). A zero exit, a build or compile error,
   or any other failure fails it (`GOAL-FORMAT.md`).

   Every Rust rule is written so that this bar, applied to the whole `proof`
   command, gives the right verdict:
   - rustc type-checks as part of `cargo test`, so an invented symbol or a
     wrong-typed call is a compile error (exit 101, no trap) and fails
     Tier 1 with no separate type-check step. The baseline confirms this by
     plant (step 3), and the old FUTURE-WORK row
     (`cargo test --no-run` as a build check, `docs/FUTURE-WORK.md:306`) is
     replaced, since the pass bar forbids a compile-only step;
   - checks that must stop a run which would still print the trap (a
     `#[should_panic]`, a `catch_unwind(…).is_err()`, an `#[ignore]`, a mock
     of the feature, a snapshot macro) run **before** cargo as **one
     parenthesized check**, as in `TYPESCRIPT.md`:
     `( grep -rqE '<kept patterns>' tests/acceptance; test $? -eq 1 ) && "$CARGO" test …`.
     A match or a grep error both fail the proof; `-q` prints nothing,
     because printing a matched line could print the trap text and pass
     Tier 1. Separate checks chained with `;` are never used: `;` binds
     looser than `&&`, so the second `test $? -eq 1` would succeed after the
     first check's hit and cargo would still run;
   - **reading the trap in Rust:** a trap counts only as libtest's
     `thread '<test>' (<tid>) panicked at <file>:<line>:<col>:` line followed
     by the trap message (Architect verification, RESEARCH.md). The trap
     string anywhere else (a compiler diagnostic quoting
     `panic!("duration-trap")` from the stub's source, for example) is not a
     pass. The plant harness scores on that line, and `RUST.md` states it as
     the Rust reading of the pass bar, as GOAL-FORMAT's C/C++ row names
     CTest's abort line.

   **Tier 1 keep rule.** A rule is kept only when, with it in the full
   `proof`:
   - (a) the clean oracle still passes Tier 1 against the stub;
   - (b) the same `proof` exits 0 against the correct implementation;
   - (c) the tree snapshot (step 3) is unchanged by both runs;
   - (d) the planted oracle passes Tier 1 under the baseline minus the rule,
     and fails it with the rule.

   "The existing pass bar already rejects it" means the planted oracle fails
   Tier 1 under the baseline. Such a candidate is dropped and logged.

   **Tier 2 keep rule.** Tier 2 plants never reach an assertion against the
   stub, so the Tier 1 bar cannot judge them. The clean expectation must match
   the reference (step 3, Tier 2), run on the proof's toolchain, and the
   plausible hand-computed value the rule names must differ from it. Then,
   classified by the planted oracle's result against the correct
   implementation:
   - **red**: an unsatisfiable pin, so the walk would stop on an oracle
     defect. Kept; the rule is "compute it with the reference".
   - **green**: a loose pin, so the assertion accepts the wrong value. Kept
     only when the strict form named in the plant (for example comparing
     `to_bits()`) is red on the same values; otherwise dropped.
   - **flaky**: the reference itself is run 5 times; when its output
     differs across runs, the value has no single pin and the rule names the
     deterministic form (sort, or use a `BTreeMap`), kept without the
     hand-value test. "Compute it with the reference" never applies to an
     order the reference does not fix. If all 5 runs agree, the input is
     enlarged and the runs repeated before the plant can be dropped.

   A plausible hand computation that comes out right is dropped.

1. **One fixture crate,** `duration`, its own git repository under
   `~/dogfood/rust-tiers/`. It is deleted after the commit; its sources are
   kept (step 7).
   - **Layout:** `tests/acceptance/` sits at the repository root as on a
     real target, with the oracle a single integration-test file
     `tests/acceptance/<id>.rs` declared as `[[test]] name = "<id>"`,
     `path = "tests/acceptance/<id>.rs"` in `Cargo.toml`. Cargo only
     auto-discovers `tests/*.rs` and `tests/*/main.rs`, so this declaration
     is what makes `--test <id>` find the file; the evidence shows the run
     without it. The `[[test]]` table is a shared registration point
     (GOAL-FORMAT.md, "Registration points": the rbtree `merge-conflict`
     stops). So `RUST.md` says every goal's `[[test]]` block is committed by
     the Architect in Phase 3, together with the red oracles, and no goal
     edits that table. The fixture has **two** targets, `g1` and `g2`, to
     measure whether `cargo test --test g1` still builds `g2`: a plant makes
     `g2` fail to compile. The rule is kept only if `--test g1` still prints
     `g1`'s trap. If `g2`'s compile error reaches `g1`'s proof instead, the
     rule changes to "each goal's oracle compiles on its own from Phase 3"
     and the evidence records why.
   - **Toolchain and build files:** edition 2024; `rust-toolchain.toml`
     pins `1.99.1`; `/target` gitignored; `Cargo.lock` committed.
   - **Dev-dependencies:** proptest, insta, mockall and tokio (`macros`,
     `rt`), at versions recorded with their lockfile checksums.
   - **Planned API:**
     - `parse_duration(s: &str) -> Result<Duration, ParseError>`;
     - `async fn load_duration(s: &str) -> Result<Duration, ParseError>` for
       the async plants;
     - a trait `DurationSource` with one method, the seam a mockall plant
       would mock;
     - functions whose correct results carry each value the Tier 2 plants
       need: a sum that overflows `u32`, a remainder of a negative number, a
       byte versus char length, a map collected to a `Vec`, an `f64` that is
       `-0.0` and one that is NaN, a float's `Display` versus `Debug`, a
       `to_lowercase` of `İ`.
   - **Stub:** every body `panic!("duration-trap")`, with parameters named
     `_s` so the stub itself raises no warning.
   - **Correct implementation:** written for the fixture after the Tier 2
     reference.

2. **The baseline recipe, as the host runs it.** Every run in this item goes
   through `proof_exec` itself (`scripts/lib/proof.sh`), sourced by the
   harness: the baseline, every plant, step 2b, and `run-plants.sh` (step 7).
   There is one environment, the host's: plain `bash -c`, the caller's
   environment minus `proof_env_unsets` (credentials and `CW_*`), plus
   `proof_exec`'s own assignments (`CARGO_HOME=$deps/cargo`, a private
   `TMPDIR`, `XDG_CACHE_HOME`), under the proof sandbox, with a deps folder
   filled once by a setup run (step 2b). No `env -i` harness is used: it
   would drop `CARGO_HOME`, so cargo would read `~/.cargo`, and it would hide
   inherited `RUSTFLAGS`, `CARGO_TARGET_DIR` or `CARGO_PROFILE_*` that a
   real host proof keeps.

   The harness starts each run from a caller environment with `RUSTC`,
   `RUSTFLAGS`, `CARGO_*` and `RUSTUP_*` unset unless the row sets them, and records the
   environment `proof_exec` passed (names only, values for the Rust ones). The
   recipe:

   ```
   cd "$REPO" && "$RUSTC" --version | grep -qx '<the exact line>' && ( grep -rqE '<kept patterns>' tests/acceptance; test $? -eq 1 ) && RUSTC="$RUSTC" "$CARGO" test --offline --locked --test <id> <flags measured in step 3>
   ```

   The version check is a candidate like the others. It refuses any other
   compiler, so the rules are never silently applied to a toolchain they
   were not proved on. Cargo is run with `RUSTC="$RUSTC"`, so the compiler
   checked is the compiler cargo uses even when the caller has `RUSTC` set
   (the harness also unsets `RUSTC` unless a row sets it). `<the exact line>`
   is copied from the first `"$RUSTC" --version` the harness prints and
   recorded in EVIDENCE.md (on this host today:
   `rustc 1.99.1 (58cf8f9c3 2026-10-13)`, RESEARCH.md). It is planted with a
   `rust-toolchain.toml` and a caller `RUSTC` pointing elsewhere.

   `$CARGO` is the toolchain's own binary
   (`~/.local/rust/rustup/toolchains/1.99.1-aarch64-apple-darwin/bin/cargo`),
   written literally, so `RUSTUP_HOME` is never needed; `$RUSTC` is the
   `rustc` beside it. `RUST.md` shows it
   as a placeholder the Rust project fills (how cargo gets there is that
   project's choice, step 8).

   The baseline must fail Tier 1 correctly against the stub (nonzero, trap in
   the output) and exit 0 against the correct implementation.

   **2b. Under the proof sandbox** (SKILL.md §4 step 0b). The same recipe also
   runs through `proof_exec` (`scripts/lib/proof.sh`), as the host calls it:
   `PROOF_ROOT` the fixture copy, `PROOF_DEPS` a fresh deps folder,
   `CARGO_HOME=$deps/cargo` set by the host. First a `worktree_setup` of
   `"$CARGO" fetch --locked` with `PROOF_SETUP=1` (network, deps writable),
   then the proof offline with the deps folder read-only.

   `proof_exec` lists the sandbox's denials only after a red run
   (`proof.sh` 134–140), so a green setup or a green proof shows none. The
   harness therefore runs the same query itself for the fetch, for the green
   proof on the implementation, and for the red proof on the stub: `--start`
   recorded before each run in `proof.sh`'s format
   (`date '+%Y-%m-%d %H:%M:%S'`), then `sleep 3` after it (the unified log
   lags), then `proof.sh`'s own `log show` pipeline, its `vfs.disk-space`
   filter included. It records all three.

   Recorded in EVIDENCE.md:
   - both pass;
   - the three listings, and whether any denial is new;
   - whether cargo tries to write under `CARGO_HOME` during a proof (a
     package-cache lock, an index cache).

   "Rust with cargo" joins step 0b's proved list (step 6) only when all
   three listings show no new denial and every kept row passed under
   `proof_exec`. If cargo needs a writable `CARGO_HOME` in a proof, stop:
   that is a sandbox profile change, reviewed before any Rust walk, not a
   rule. The record also notes that making `CARGO_HOME` writable would let
   `--jobs` proofs share one registry lock across goals.

   `target/` lands in the checkout, which the sandbox lets a proof write and
   `.gitignore` keeps out of the tree snapshot. The build time of a cold
   proof and a warm one is recorded, so a Rust project can judge
   `CARGO_TARGET_DIR` against its proof timeout.

3. **Plants, one per candidate.** Each is a defect an Architect plausibly
   writes in an oracle, named in the evidence against GOAL-FORMAT's failure
   classes. Each planted oracle runs under the baseline minus the candidate
   rule and under the full recipe; step 0's keep rule decides keep or drop.

   **Tier 1 candidates:**
   - **Compile-time checks** (expected dropped: the baseline rejects them):
     - a wrong-typed call into the planned API;
     - an invented symbol;
     - `async fn` under a plain `#[test]`.
   - **Tests that pass on the trap:**
     - a bare `#[should_panic]` on the goal's case;
     - `#[should_panic(expected = "duration")]`, a substring of the trap;
     - `assert!(catch_unwind(…).is_err())`;
     - an `#[ignore]` on the goal's case.

     Each sits beside a clean case that hits the trap, so the whole proof
     still exits 101 with the trap printed. The candidate rule is the
     pre-runner check matching `should_panic`, `#[ignore` and
     `catch_unwind(…).is_err()` / `.is_ok()` on one line under
     `tests/acceptance/`. A bare `catch_unwind` is not matched.
     (`-- --include-ignored` is not a candidate: the sibling's trap keeps the
     exit at 101 with the trap printed, so it cannot change the Tier 1
     verdict, keep rule (d).)

     An oracle that must pin a panic the plan specifies uses the written
     form: `let e = catch_unwind(…).unwrap_err();` then `assert_eq!` on
     the payload's message against the plan's message. Against the stub the
     trap is printed in libtest's panicked block and the assertion then fails
     on the trap's payload, so it passes Tier 1 for the right reason. This
     shape was measured on 1.99.1 (RESEARCH.md): the default panic hook runs
     before `catch_unwind` takes the payload, so the failing test's captured
     output shows `thread 'payload' (…) panicked at src/lib.rs:4:21:` with
     the trap on the next line, then a second panicked block for the
     `assert_eq!` with the trap as `left`. The scorer's rule therefore
     matches it unchanged. A target that installs its own panic hook
     (`std::panic::set_hook`) can silence that first block; that is planted
     as one more row. That
     form is itself planted and must pass (a) and (b) with the check in
     place. A multi-line spelling of `.is_err()` that the one-line pattern
     misses is a look-for, not a rule.
   - **Ignored results and dead assertions:**
     - `parse_duration("1x");` with its `Result` dropped, and
       `let _ = parse_duration("1x");`;
     - a `load_duration("1s")` future never awaited, both as a bare
       statement and as `let _ = …` (`let _` silences `unused_must_use`);
     - an assertion after an early `return`;
     - each of the above again under `#[allow(unused)]` on the test
       function, the bypass a `deny` permits.

     Each passes Tier 1 because a sibling case traps, then goes green on
     the implementation without checking anything. Candidates, per Q3:
     - **global:** `RUSTFLAGS="-D warnings"`, also run against a target
       whose library has one existing warning, to measure (a);
     - **narrow:** `#![forbid(unused_must_use, unreachable_code)]` at the
       top of the oracle file. `forbid`, not `deny`: an inner
       `#[allow(...)]` cannot override `forbid` (it becomes a compile
       error), while it does override `deny`. The `deny` form is planted
       too, to show the difference.

     A shape no candidate catches (expected: both `let _ =` forms) becomes a
     written look-for and is recorded as a **gap**.
   - **Mocks:** an oracle that defines `mock!` of `DurationSource` and whose
     expectation calls the stub, so it rethrows the trap and passes Tier 1,
     then on the implementation tests the mock. Candidate: a pre-runner check
     rejecting `mockall`, `mock!` and `automock` under `tests/acceptance/`.
   - **Snapshots:** an `insta::assert_snapshot!` / `assert_debug_snapshot!`
     on the planned API. The stub panics before the macro, so it passes
     Tier 1. On the implementation insta writes a `.snap.new` (or a
     `.pending-snap`) under `tests/acceptance/`, which the host calls
     tampering, or fails when it detects CI. Candidate: a pre-runner check
     rejecting insta's macros. Measured with and without `CI=1` and
     `INSTA_UPDATE=no`, to show what the env alone changes.
   - **Property tests:** a `proptest!` case on the planned API. Against the
     stub it fails, shrinks, and may persist a `proptest-regressions/` file
     next to the oracle. Measured:
     - whether that file is written, and where;
     - whether `ProptestConfig { failure_persistence: None, .. }` in the
       oracle, or an env var the crate honours, stops it.

     The kept form is whichever keeps (c), the tree snapshot, unchanged. If
     neither works, the rule is a pre-runner check rejecting `proptest`
     under `tests/acceptance/`.
   - **Vacuous runs:**
     - zero tests matched (a filter typo after `--`, `--exact` on a wrong
       name); expected dropped, since the stub run exits 0 too;
     - a `--test` naming no target (exit 101, no trap); expected dropped;
     - a missing `[[test]]` declaration.
   - **Files the proof leaves,** scored the way the host scores them. The
     whole of `tree_snapshot` in `scripts/run-goal.sh` runs from the fixture
     repository's root, before and after: `git rev-parse HEAD`,
     `git status --porcelain --untracked-files=all`, and
     `git status --porcelain --ignored=matching` on `tests/acceptance`,
     `.claude`, `.mcp.json`, the oracle and the plan. Measured:
     - `target/`;
     - `Cargo.lock` absent at the start (the first build writes it; the
       candidate is `--locked`, which fails without it, before any trap);
     - insta's and proptest's files (above).

     An artifact under a contract path must be **disabled**, since ignoring
     it there is tampering to the host. One outside may be gitignored.
   - **Hostile project config:** a `.cargo/config.toml` in the target
     setting `build.target-dir = "tests/acceptance/target"`, plus a
     `build.rs` canary that prints `canary-build-script` (never the trap
     text). Candidate: `CARGO_TARGET_DIR` set in the `proof` (an env var
     beats the config file).
   - **Overflow checks across profiles.** Cargo builds the integration-test
     binary with the `test` profile and the library it links with `dev`; an
     explicit `[profile.test]` value wins over one inherited from `dev`.
     The plant is an overflowing `+` in the library and in the oracle, under
     `overflow-checks = false` in `[profile.dev]`, in `[profile.test]`, and
     in both (three rows). Candidates, each forcing checks on in both
     binaries: `RUSTFLAGS="-C overflow-checks=on"`, and
     `CARGO_PROFILE_DEV_OVERFLOW_CHECKS=true` with
     `CARGO_PROFILE_TEST_OVERFLOW_CHECKS=true`. The one that restores the
     panic in all three rows, without breaking (a) to (c), is kept.

     The canary only records that a target's build script runs inside every
     proof (it already runs implementer code). It is a stated fact in
     RUST.md, not a rule.

   **Tier 2 candidates.** The reference is a standalone Rust file, outside
   the fixture, that imports nothing from it, compiled with the same
   `rustc 1.99.1` and written before the correct implementation. The
   evidence shows its imports. Plants:
   - overflow: a wrapped `u32` sum pinned where the debug build panics;
   - `-7 % 3` pinned as `2` (it is `-1`; `rem_euclid` is `2`);
   - `"go🚀".len()` pinned as `3` (it is 6 bytes; `chars().count()` is 3);
   - a `Vec` collected from a `HashMap`'s keys pinned in insertion order,
     with at least 8 keys so 5 runs of a random order almost never agree
     (the flaky rule of step 0);
   - `assert_eq!(f, 0.0)` where the correct value is `-0.0` (loose: it
     passes; the strict form compares `to_bits()`);
   - `assert_eq!(x, f64::NAN)` (always red; the rule is `is_nan()`);
   - `format!("{}", 1.0_f64)` pinned as `"1.0"` (`Display` prints `1`,
     `Debug` prints `1.0`);
   - `"İ".to_lowercase()` pinned as `"i"` (it is two chars, `i` plus a
     combining dot).

   **Dropped up front unless a plant shows otherwise:**
   - `sort_unstable` order on equal keys (deterministic for one input on
     one toolchain, so no plant can turn it red);
   - time zones (no date crate in the fixture);
   - test-thread races on env vars (nondeterministic; a written note at
     most);
   - `panic = "abort"` profiles (the research and the Cargo book say the
     test profile ignores them; one run confirms, then dropped).

4. **Sources only for what a run cannot show.** Version facts (insta's CI
   detection rule, proptest's persistence default, libtest's exit code) are
   each checked against the primary page RESEARCH.md cites. A claim neither
   planted nor cited is dropped and logged.

5. **Evidence:** `docs/features/rust-tier-rules/EVIDENCE.md`. It records the
   step 2b sandbox runs, then per candidate:
   - the plant, as a diff;
   - the baseline-minus-rule result;
   - the full-recipe result;
   - the verdict (kept / dropped / unproved / gap) and why;
   - the exact versions: rustc and cargo, each crate with its lockfile
     checksum.

6. **The rulebook text.**
   - **`skills/to-goals/RUST.md`** (new, beside `TYPESCRIPT.md`) holds:
     - the `proof` recipe as proved, with `$CARGO` / `$REPO` placeholders;
     - the `[[test]]` declaration;
     - why no separate type check is needed;
     - the kept rules, with one line of reason each;
     - the Tier 2 list;
     - every **gap**, as a look-for for the self-review and the oracle
       review (not a proof step);
     - the stated facts (a build script runs in every proof);
     - the versions, and how to rerun the plants after an upgrade (step 7).

     Another runner (nextest) is proved the same way before its first
     oracle; the doc says so.
   - **`skills/to-goals/GOAL-FORMAT.md`:** the Rust / Go row splits into a
     Rust row linking `RUST.md` and a Go row. The file is at the 228-line
     cap, so the added line is paid for by tightening another in the same
     table section; it stays at or under 228.
   - **`skills/to-goals/SKILL.md`:** §4 step 0b adds "Rust with cargo" to
     the proved list, and the Tier 1 and Tier 2 parentheticals name
     `RUST.md` beside `TYPESCRIPT.md`. The file stays at or under 228
     lines.
   - **`docs/FUTURE-WORK.md:306`:** the Rust cell is updated to point at
     `RUST.md`.

7. **Keep what reruns the proof.** Before deleting the throwaway, commit
   `docs/features/rust-tier-rules/fixture/`:
   - the crate's sources: stub, implementation, oracle, `Cargo.toml`,
     `Cargo.lock`, `rust-toolchain.toml`;
   - the Tier 2 reference;
   - every plant as `plants/NN-name.patch`;
   - `run-plants.sh`.

   `run-plants.sh` copies the crate to a fresh temporary git repository
   before applying a plant, so the house clone is never dirtied and the
   snapshot is the fixture's own. It fetches the crates once, with network,
   by a setup run of `cargo fetch --locked` through `proof_exec`
   (`PROOF_SETUP=1`) into a deps folder kept by the lockfile's hash (the
   same environment as step 2; no other `CARGO_HOME`). Then it runs every
   row offline through `proof_exec`, as the host would, and prints the
   verdict table EVIDENCE.md records. It is not part of `scripts/tests/run-all.sh` (it needs Rust and
   one network fetch); RUST.md says how to run it.

   Its own sanity check, run before the commit:
   - reverting each kept Tier 1 rule in the recipe turns that plant's row
     from "caught" to "through";
   - each kept Tier 2 row is "caught" with the reference comparison run and
     "through" when it is skipped.

8. **Carried inputs** go into `docs/FUTURE-WORK.md`, addressed to the first
   Rust project's Phase 1 recon, with what worked here:
   - the host proof's `bash -c` does not find a rustup proxy; call the
     toolchain's cargo by absolute path;
   - the implementer's sandbox has no network for crates; a
     `worktree_setup` of `cargo fetch --locked` fills the walk's deps
     folder;
   - the cold build time from step 2b.

9. **Review, commit and release,** per the house recipe:
   - a fresh Opus review of the diff (the doc text against EVIDENCE.md and
     the fixture), each finding taken or rejected with a reason;
   - the full suite after DONE;
   - `test -f ~/.claude/skills/to-goals/RUST.md` after `install.sh`;
   - one commit on the user's OK;
   - `scripts/make-release.sh`, then push `main` and `release` (no force);
   - delete `~/dogfood/rust-tiers/`.

## Key decisions & tradeoffs

- **`cargo test` only (Q1, user).**
  - Nextest is a separate binary a target would have to install into the
    proof's path.
  - Its main gain here (failing on zero tests) is already given by the pass
    bar at Tier 1.
  - Cost: a target on nextest needs a small item of its own first.
- **Four crates (Q2, user):** proptest, insta, mockall, tokio. Each can
  either pass on the trap or write into the repository. Left out, logged:
  - rstest and test-case (they generate plain tests and add no path);
  - trybuild (compile-fail tests are rare in acceptance oracles);
  - quickcheck (proptest covers the same shape);
  - expect-test (it rewrites source only when `UPDATE_EXPECT` is set; one
    line in RUST.md says not to set it).
- **Warnings-as-errors is a measured candidate in two forms (Q3, user).**
  - The global `RUSTFLAGS="-D warnings"` reaches the target's own code, so
    one existing warning would stop every goal's proof.
  - The narrow `#![forbid(unused_must_use, unreachable_code)]` in each
    oracle file confines it to files the Architect owns. It is `forbid`
    rather than the `deny` named in Q3, because an inner `#[allow]`
    overrides `deny` (Grok round 1); both are planted.
  - Expected: the narrow form is kept. It is planted, not assumed.
- **A rule needs a plant it catches** (the ts-tier-rules principle,
  confirmed in the ledger).
  - Evidence over citations; documents only for version facts.
  - Cost: true claims nobody can plant are dropped, and the rules are proved
    on one toolchain (1.99.1) and one set of crate versions, recorded.
- **Pre-runner checks over runner flags.** A banned pattern is caught by a
  fail-closed grep before cargo, not by trusting a flag the target's config
  could override. Cost: a grep is textual, so a pattern spelled another way
  (a macro hiding `should_panic`, a re-export of mockall) gets through. Those
  spellings become look-fors, not rules.
- **One fixture.** With one runner there is no second resolution mode to
  hide failures, unlike TypeScript's two.
- **Hazards carried, not fixed.** How cargo reaches the proof and how crates
  arrive offline are target choices; the house records them with the
  evidence (step 8).

## Assumptions

1. Rust shares one tier-table row with Go —
   `skills/to-goals/GOAL-FORMAT.md:177`.
2. Tier 1 runs the real `proof` against trap stubs. Pass bar: a nonzero exit
   plus the trap message or this goal's assertion; never a compile-only step
   — `skills/to-goals/SKILL.md` §4.2, `GOAL-FORMAT.md:179`.
3. The host proof runs plain `bash -c` in the caller's environment minus
   credential and `CW_*` variables (`env -u`, not `env -i`; `PATH` and the
   rest are kept), plus `CARGO_HOME=$deps/cargo` (read-only in a proof), a
   private `TMPDIR` and `XDG_CACHE_HOME` — `scripts/lib/proof.sh:47-60,
   88-95`. Denials are listed only after a red run — `proof.sh:134-140`.
4. The sandbox allows reads almost everywhere; it allows writes only to the
   checkout, the proof's temp folder and, under `--setup`, the deps folder
   — `scripts/lib/proof-sandbox.py:135-200`, proof-sandbox PLAN §D.
5. Rust has not been proved under the sandbox; step 0b lists C, TypeScript
   and Python only — `skills/to-goals/SKILL.md:68-75`.
6. Measured on 1.99.1 (RESEARCH.md, Architect section):
   - a zero-match filter exits 0;
   - `#[should_panic]` and `catch_unwind` pass on the trap;
   - `todo!()`, `unimplemented!()` and `unreachable!()` messages are fixed
     and not unique;
   - `--test <name>` runs neither doc tests nor unit tests;
   - the first run writes `Cargo.lock`;
   - stub parameters warn.
7. The host wakes `proof-tamper` on any new unignored file anywhere, and on
   any new file, ignored or not, under `tests/acceptance/`, the oracle or the
   plan — `tree_snapshot` in `scripts/run-goal.sh`; ts-tier-rules
   assumption 6.
8. Line counts: `SKILL.md` is 221 and `GOAL-FORMAT.md` 228, against the
   228 cap; `TYPESCRIPT.md` is 140.
9. Rust 1.99.1 is installed isolated in `~/.local/rust` (rustup from
   Homebrew, keg-only, not on `PATH`). No nextest. Crates come from
   crates.io into a fixture-only `CARGO_HOME`, with network needed once.
10. No Rust target exists yet. The rules are written before the first Rust
    project's Phase 3.
11. Plan files are in `docs/features/rust-tier-rules/`. Build, Opus review,
    suite, commit and release follow the house recipe; `skills/` ships on the
    release branch.

## Risks / open questions

- **The toolchain directory name.** Pinning `1.99.1` installs a toolchain
  directory named `1.99.1-aarch64-apple-darwin`. The installed default is
  `stable-…`. The fixture's `rust-toolchain.toml` only steers the rustup
  proxy, which the recipe does not use, so the recipe's absolute path names
  the pinned directory. The evidence shows `rustc --version` from inside the
  proof.
- **Version drift.** insta and proptest change defaults across majors (CI
  detection, persistence paths). The rules are pinned to the versions
  measured; RUST.md names them and says to rerun the plants on an upgrade.
- **A plant can be unrealistic.** A defect nobody would write proves
  little. Each plant is named against an oracle failure class in
  EVIDENCE.md.
- **Network for the crates.** One fetch. If crates.io is unreachable, stop
  and tell the user rather than guess.
- **The sandbox may deny cargo a write under `CARGO_HOME`.** That is a
  profile change and its own review, not something this item absorbs.

## Out of scope

- nextest, rstest, test-case, trybuild, quickcheck, expect-test and Go.
- Python and C/C++ rules (the next item the user named).
- Changes to `run-goal.sh`, the launchers, or the sandbox profile (a needed
  profile change stops this item and is raised).
- How a Rust target installs cargo or fetches crates (carried, step 8).
- A Rust dogfood project.
