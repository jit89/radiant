# Rust testing: research for the Tier 1 / Tier 2 rules

Date: 2026-11-02. Written by a Haiku 5.5 research agent.

Scope: primary sources only (doc.rust-lang.org, docs.rs, crate repos, crates.io API, nexte.st). Nothing was installed or run. Claims not confirmed in a primary source are marked UNVERIFIED. "Fetched" means the page was read through a web fetch on 2026-11-02, so page wording may have changed since.

## Key Takeaways

- `cargo test` exit 0 means success, 101 means "Cargo failed to complete" (test failure, compile error, or build error). The exit code alone cannot tell a compile error from a red test; the output must be checked. Sources: https://doc.rust-lang.org/cargo/commands/cargo-test.html , https://doc.rust-lang.org/cargo/commands/cargo-build.html
- A test binary's libtest harness exits 101 when any test fails and 0 otherwise (libtest source, `ERROR_EXIT_CODE = 101`). Source: https://raw.githubusercontent.com/rust-lang/rust/master/library/test/src/lib.rs
- The trap stub must be a panic, and it must be the trap text that appears. `todo!()` prints `not yet implemented`, `unimplemented!()` prints `not implemented`, and `todo!("msg")` / `unimplemented!("msg")` prepend `not yet implemented: ` / `not implemented: ` (core macro source). Use `panic!("feature-trap")` for a unique message.
- `#[should_panic]` makes a test PASS on ANY panic, including a trap stub. With `expected = "..."` it passes if the substring appears in the panic message. Any oracle test marked `should_panic` cannot be red-proven by a panic trap. Source: https://doc.rust-lang.org/reference/attributes/testing.html
- `#[ignore]` tests are compiled but not run. A proof whose only tests are ignored, or whose filter lands on ignored tests, exits 0 without running them. `--include-ignored` runs them. Source: same reference page.
- A test returning `Err(_)` fails; only `Ok(())` passes (Reference, Book ch11-01). `#[should_panic]` cannot be combined with a `Result`-returning test (Book ch11-01).
- `std::panic::catch_unwind` converts a panic into `Err`. An oracle that wraps the call in `catch_unwind(...).is_err()` will PASS on a trap stub. It only catches unwinding panics, not aborts. Source: https://doc.rust-lang.org/std/panic/fn.catch_unwind.html
- The test profile ignores `panic = "abort"`; the test harness requires `unwind` (Cargo profiles page). Abort-on-panic therefore cannot turn a trap into a pass; it does not help the proof either.
- Filter semantics are substring by default; `--exact` needs the full module path. A filter typo that matches zero tests is the main silent-pass risk for a green proof: cargo's sample output for an empty set is `running 0 tests` / `test result: ok` (Book ch11-01). cargo-nextest instead fails with exit 4 when no tests match (default `--no-tests=fail`). Sources: https://doc.rust-lang.org/rustc/tests/index.html , https://nexte.st/docs/running/
- rustc type-checks everything, so a wrong-typed or invented symbol in a test is a compile error (exit 101), which must count as a Tier 1 failure. `unused_must_use` (warn-by-default) flags an ignored `Result` or `#[must_use]` value, e.g. an un-awaited `Result`; it is a warning, not an error, unless `-D warnings` or `#![deny(unused_must_use)]` is set. Source: https://doc.rust-lang.org/rustc/lints/listing/warn-by-default.html
- `cargo test` builds and runs doc tests by default (Cargo book). Doc tests need a separate `--doc` run; nextest does not run doc tests at all (nexte.st). The proof must name each target explicitly.
- Writing snapshot and fixture crates is a real tamper risk: insta writes `.snap.new` pending files and `INSTA_UPDATE` modes (`CI` env selects `no`); expect-test rewrites the source file when `UPDATE_EXPECT` is set; trybuild writes `wip/` and overwrites under `TRYBUILD=overwrite`; proptest persists failures under `proptest-regressions/` (persistence page not fetched, see section 5).
- Cargo writes `Cargo.lock` on first build when it is missing (Cargo book, cargo-toml-vs-cargo-lock). `--locked` fails if the lock is missing or would change; `--frozen` = `--locked` + `--offline`; `--offline` / `net.offline` blocks network access. Sources: https://doc.rust-lang.org/cargo/commands/cargo-build.html , https://doc.rust-lang.org/cargo/reference/config.html
- Build scripts run arbitrary code "which may perform any number of tasks" before a package builds (Cargo book, build-scripts). Nothing in the fetched pages says they are sandboxed or network-free; the proof sandbox must assume they run with the sandbox's own limits.
- Rust integer overflow panics in debug builds; `i32::MIN / -1` panics even with overflow checks off; `%` takes the sign of the dividend (Reference, operator-expr). `str::len` is bytes; `HashMap` iteration order is arbitrary and randomly seeded (std docs).
- Toolchain isolation: rustup honours `RUSTUP_HOME`, `CARGO_HOME`, `RUSTUP_TOOLCHAIN`; `rust-toolchain.toml` supports `channel`, `components`, `targets`, `profile` (minimal/default/complete) (rustup docs). Use `profile = "minimal"` plus explicit `components`, and pin `channel`.
- nextest runs each test in its own process (no shared-process cancellation); libtest runs all tests in one binary and a crash cancels the rest; libtest has no per-test timeout (nexte.st, why-process-per-test).

## 1. The harness

**Commands and flags (libtest via `cargo test`)**

- `cargo test` by default compiles and runs unit, integration, and doc tests of the selected packages. Doc tests are run by rustdoc. Source: https://doc.rust-lang.org/cargo/commands/cargo-test.html (fetched).
- `--test <name>` runs one integration test target; the flag may repeat and supports Unix globs. Same page.
- `--doc` tests only the library doc tests and "cannot be mixed with other target options." Same page.
- `--no-fail-fast` runs all test executables even after one fails. Without it, cargo exits after the first failing executable. Same page.
- Everything after `--` goes to libtest; `cargo test foo -- --test-threads 3` is the cited example. Same page.
- Excluding doc tests from a run: the `--doc` page does not give an exclusion flag. Use an explicit target list (e.g. `--lib --bins --tests`). UNVERIFIED that this list is the exact exclusion form; the target-selection flags were not fetched.
- Filters: positional arguments are substring matches against the full test path (e.g. `works`, `utils::`). Source: https://doc.rust-lang.org/rustc/tests/index.html (fetched).
- `--exact`: the filter must equal the full path, e.g. `utils::paths::tests::it_works`. Same page.
- `--skip <FILTER>` skips tests whose name contains the string; repeatable. Same page.
- `--ignored` runs only `#[ignore]` tests; `--include-ignored` runs all. Same page.
- `--no-capture` (alias `--nocapture`, deprecated alias; env `RUST_TEST_NOCAPTURE` != `0`) lets tests print live. `--show-output` prints stdout/stderr of passing tests after the run. Same page.
- `--test-threads N`, default `available_parallelism`; env `RUST_TEST_THREADS` also works (deprecated per the page). Same page.

**Exit codes**

- Cargo: `0` succeeded, `101` failed to complete. Source: cargo-test page (fetched). This covers test failure and compile error alike.
- libtest binary: exits `101` on a failed run (`ERROR_EXIT_CODE`), `ExitCode::SUCCESS` otherwise. Source: libtest lib.rs (fetched; the `run_tests_console` body was not visible, so whether an empty run maps to success is only inferred).
- A filter matching zero tests: the Book's sample shows `running 0 tests` with `test result: ok. 0 passed` for an empty doc-test set (https://doc.rust-lang.org/book/ch11-01-writing-tests.html). The exit code for a filter that matches nothing was NOT confirmed in a primary source: UNVERIFIED (inferred 0 from the libtest exit logic and the Book sample).
- Test-level results: a test "passes" if it returns without panic, or returns a `Termination` value that is success; "fails" if it panics or returns a non-success `Termination` value (Reference, testing page).

**Panic output when captured**

- Default panic output format, from the Book (ch09-01): `thread 'main' panicked at src/main.rs:2:5:` then the message on the next line, then `note: run with RUST_BACKTRACE=1 environment variable to display a backtrace` (https://doc.rust-lang.org/book/ch09-01-unrecoverable-errors-with-panic.html).
- Under libtest, captured stdout/stderr is shown in the failures section for a failing test; the Book describes a `failures:` section (ch11-01). The exact per-test heading format (e.g. `---- name stdout ----`) and the thread name used for test threads are UNVERIFIED in the fetched text.

**cargo-nextest**

- Runs each test in its own process; "the default execution model is now, and will always be, process-per-test." A segfault in one test does not take the others down. Source: https://nexte.st/docs/design/why-process-per-test/ (fetched).
- libtest "works by embedding a small runner into each test binary"; "if a test takes down the process, all of the other tests in the binary are effectively cancelled as well"; no per-test timeouts in `cargo test` (same page).
- Doctests: "Doctests are currently not supported because of limitations in stable Rust"; run `cargo test --doc` separately (https://nexte.st/docs/running/).
- `--no-tests` controls behaviour when no tests run: `auto` (default behaviour fails), `pass` (exit 0), `warn` (warning, exit 0), `fail` (error, exit 4). The default is `fail`; older versions defaulted to `pass` or `warn` (same page).
- Exit codes beyond 0 and 4 are not listed on the running page; UNVERIFIED for other nextest exit codes (test failure exit code not stated in fetched text).
- Version: crates.io reports cargo-nextest max_version 0.9.150 (https://crates.io/api/v1/crates/cargo-nextest, fetched 2026-11-02). The installation page refers to the 0.9 series. Install options include `cargo binstall cargo-nextest --secure` and GitHub release binaries (https://nexte.st/docs/installation/pre-built-binaries/).
- nextest docs say the commands "assume that your Rust installation is managed via rustup."

**Test layout and CI (see section 10 for layout detail)**

- Unit tests can test private items; integration tests use only the public interface (Book ch11-03).
- Each file in `tests/` is compiled as its own crate; `tests/common/mod.rs` is the convention for shared helpers so it is not treated as a test target (Book ch11-03).
- A binary-only crate (only `src/main.rs`) cannot be integration-tested by `use`; the project needs `src/lib.rs` (Book ch11-03).

## 2. Tests that pass on a panic

- `#[should_panic]` (no argument): the test passes if the body panics, for any reason. A stub `panic!("feature-trap")` or `todo!()` makes such a test PASS. Source: Reference testing page; Book ch11-01 ("The test passes if the code inside the function panics").
- `#[should_panic(expected = "...")]`: the expected string must appear somewhere in the panic message (substring). Source: Reference. A trap message that contains the expected substring also passes, so keep the expected string longer than a common trap word, or avoid `should_panic` in oracles.
- `should_panic` only has effect on the first use per function; later uses get a future-compatibility warning (Reference).
- Return type of a `should_panic` test must be `()` (Reference). The Book says `should_panic` cannot be used on a `Result`-returning test (ch11-01).
- Tests returning `Result<(), E>`: pass only on `Ok(())`; `Err` fails the test (Reference; Book ch11-01 shows the `Err` example). A `Result`-returning test does not pass on a panic stub: the panic propagates and the test fails (the trap text appears), unless the test body catches it (see `catch_unwind` above).
- `#[ignore]`: the test is compiled but not executed. A goal whose only oracle is ignored exits 0 with nothing run. `--include-ignored` runs them; `--ignored` runs only ignored tests. Source: Reference; rustc tests index.
- `std::panic::catch_unwind(f)`: returns `Ok` if `f` returns, `Err(payload)` if `f` panics. An oracle `assert!(catch_unwind(|| api()).is_err())` passes on a panic stub. It catches only unwinding panics; an abort is not caught. Source: https://doc.rust-lang.org/std/panic/fn.catch_unwind.html (fetched).
- `panic = "abort"` profile: "Tests, benchmarks, build scripts, and proc macros ignore the `panic` setting. The `rustc` test harness currently requires `unwind` behavior." The `panic-abort-tests` unstable flag enables abort. Source: https://doc.rust-lang.org/cargo/reference/profiles.html (fetched). So a panic in a test is always an unwind for the test profile; abort in a non-test profile does not affect test runs.
- Consequence for Tier 1: a trap stub makes a test PASS when the test is `should_panic` (with or without a matching substring), is wrapped in `catch_unwind`, or is `#[ignore]`d (then not run at all).

## 3. Panic macros and hooks

- `panic!`: default output is `thread '<name>' panicked at <file>:<line>:<col>:` then the message, then the RUST_BACKTRACE note (Book ch09-01). The message payload for `panic!("literal")` is `&str` (std::macro.panic page: "either a `&str` or `String`").
- `todo!()`: expands to `panic!("not yet implemented")`; `todo!("msg")`: `panic!("not yet implemented: {}", format_args!(...))`. Source: https://raw.githubusercontent.com/rust-lang/rust/master/library/core/src/macros/mod.rs (fetched; the `todo_default_msg` function is what the no-argument arm calls). The std docs say the message is "not yet implemented" (https://doc.rust-lang.org/std/macro.todo.html).
- `unimplemented!()`: `"not implemented"`; `unimplemented!("msg")`: `"not implemented: {}"` with the message appended (core macros source, and std docs https://doc.rust-lang.org/std/macro.unimplemented.html).
- `unreachable!`: builtin macro (`#[rustc_builtin_macro(unreachable)]`), so the core source does not show its format string. Std docs describe it as panicking if the determination proves wrong. The exact message text (`internal error: entered unreachable code`) is UNVERIFIED in a primary source. Do not use `unreachable!` as a trap; use `panic!` with a unique message.
- `panic!` with a unique text ("feature-trap") is the most reliable Tier 1 trap: the message is printed verbatim after the location line (Book ch09-01 format).
- RUST_BACKTRACE: `RUST_LIB_BACKTRACE` (if set and not `0`, enables capture); otherwise `RUST_BACKTRACE` with the same rule; if neither set, capture is disabled. Source: https://doc.rust-lang.org/std/backtrace/index.html (fetched). The Book says any value except `0` enables it. Setting it adds lines to output but does not change pass/fail.
- Panic hooks: `std::panic::set_hook` replaces the global hook; "The panic hook is a global resource"; it runs before the panic runtime; "Panics if called from a panicking thread." Source: https://doc.rust-lang.org/std/panic/fn.set_hook.html (fetched). Whether a custom hook changes libtest's failure reporting is UNVERIFIED. A test or helper that calls `set_hook` can silence the trap message from output; that breaks the "trap message appears" check. Forbid `set_hook` in oracle tests.

## 4. Compile-time checks

- rustc always type-checks test code; an invented symbol, a wrong type, or a missing method is a compile error (exit 101 from cargo). The Tier 1 rule (nonzero exit AND trap text) correctly fails on compile errors, but the trap-text check must not be the only evidence; a compile error will not print the trap either, so it fails the trap check. Good. Cargo exit mapping: https://doc.rust-lang.org/cargo/commands/cargo-test.html
- Warnings are not errors by default. `-D warnings` via `RUSTFLAGS` applies to all compiler invocations (Cargo env-var page; `RUSTFLAGS` "split by whitespace"). Cargo's CI page gives `build.warnings = "deny"` (config) and `CARGO_BUILD_WARNINGS: deny` as the CI-side equivalents (https://doc.rust-lang.org/cargo/guide/continuous-integration.html, fetched). `RUSTFLAGS` changes the build cache key; UNVERIFIED that RUSTFLAGS invalidates the cache (not stated in fetched text).
- Lint configuration: `[lints]` table in `Cargo.toml` (`[lints.rust]`, `[lints.clippy]`, `[lints.cargo]`), with `workspace = true` to inherit from `[workspace.lints]`. Inheritance is not implicit: "Many people mistakenly think that `workspace.lints` is implicitly inherited when it is not." (https://doc.rust-lang.org/cargo/reference/lints.html, fetched). The `priority` key is not described on that page (UNVERIFIED).
- `#![deny(...)]` / `#![warn(...)]` attributes at crate root work per crate.
- `unused_must_use`: "The `unused_must_use` lint detects unused result of a type flagged as `#[must_use]`." Default: warn (`#[warn(unused_must_use)]` on by default). Example output: `warning: unused `Result` that must be used`. Source: https://doc.rust-lang.org/rustc/lints/listing/warn-by-default.html (fetched, offset 170000).
- `dead_code`: warn-by-default; "The `dead_code` lint detects unused, unexported items." Source: same page. A stub that is never called causes dead_code warnings, not errors, unless denied.
- Clippy: `cargo clippy --all-targets --all-features --keep-going` is the CI command in the Cargo CI guide (https://doc.rust-lang.org/cargo/guide/continuous-integration.html). Whether clippy is "standard" in CI is not stated in a primary source; the Cargo guide shows it as a warnings job. The clippy site (https://clippy.rust-lang.org/master/index.html) redirect was fetched but the usage text was not visible; `-D warnings` on clippy: UNVERIFIED.
- An un-awaited future: the std `Future` trait is `#[must_use]` (std docs; the attribute text was NOT confirmed in fetched text, so UNVERIFIED). The compiler message is expected to be "unused implementer of `Future` that must be used" (UNVERIFIED wording). Futures are inert until polled (https://doc.rust-lang.org/std/future/trait.Future.html, fetched: "Futures alone are _inert_; they must be _actively_ `poll`ed").

## 5. Testing crates and what they write to disk

Download counts are from the crates.io API, fetched 2026-11-02. "total" is all-time; "recent" is the crates.io recent-downloads field.

| Crate | total downloads | recent | max_version | repo |
|---|---|---|---|---|
| insta | 121,513,235 | 36,478,877 | 1.49.0 | github.com/mitsuhiko/insta |
| proptest | 230,230,390 | 67,978,530 | 1.12.0 | github.com/proptest-rs/proptest |
| mockall | 186,660,285 | 33,474,535 | 0.15.0 | github.com/asomers/mockall |
| rstest | 141,890,589 | 35,521,100 | 0.28.0 | github.com/la10736/rstest |
| trybuild | 77,914,038 | 19,308,281 | 1.0.122 | github.com/dtolnay/trybuild |
| cargo-nextest | 13,584,525 | 1,844,521 | 0.9.150 | github.com/nextest-rs/nextest |

Not fetched (no numbers; UNVERIFIED for usage): quickcheck, test-case, expect-test, pretty_assertions, assert_cmd, assert_fs, serial_test.

- **insta** (snapshots). Snapshot files: "By default the new snapshots are stored next to the old ones with the extra `.new` extension." `INSTA_UPDATE` values: `auto` (default; `no` for CI, `new` otherwise), `always` (overwrite old snapshots), `unseen`, `new` (write `.snap.new`), `no` (do not update). "The `CI` environment variable" enables the CI behaviour, where insta "will not write new snapshot files." Source: https://insta.rs/docs/quickstart/ (fetched). `INSTA_FORCE_PASS`: not on fetched page (UNVERIFIED). That a snapshot mismatch fails the test: implied by the quickstart, not stated (UNVERIFIED as an explicit statement).
- **expect-test**. `UPDATE_EXPECT` set: "patch the file in-place"; not set: a mismatch "will produce a test failure", file unchanged. Source: https://docs.rs/expect-test/latest/expect_test/ (fetched). This writes into the repo under test, which is a tamper risk if the variable is set in the proof environment.
- **trybuild** (compile-fail tests). No matching `*.stderr`: the actual output is saved into `wip/` next to Cargo.toml. `TRYBUILD=overwrite` writes compiler output in place. A mismatch fails and shows expected vs actual. Source: https://docs.rs/trybuild/latest/trybuild/ (fetched). Note the `wip/` directory is a write-under-repo hazard.
- **proptest**. Regression files: the docs say failing cases are persisted to `proptest-regressions/`; the persistence page returned 404 and the source file fetch returned 404. UNVERIFIED: exact path, the `FileFailurePersistence::Off` setting, and the default. Treat proptest as writing under the repo unless persistence is disabled (to be checked against docs.rs/proptest in the implementation step).
- **mockall**. Automock mocks "most traits, or structs that only have a single `impl` block"; for a module it generates `mock_xxx`; `#[double]` swaps imports. "Module functions are static and so have the same caveats as static methods." For static methods, expectations are global and "you must provide your own synchronization" across tests. Source: https://docs.rs/mockall/latest/mockall/ (fetched). Mocking the module under test itself is not described: a mock of the feature module lets a test pass without exercising the real code (the TypeScript hazard). The Rust analogue is a `#[double]`/automock of the feature module, which the oracle must forbid.
- **rstest / test-case**: fixture and parameterised tests. Parameter expansion creates ordinary `#[test]` functions; no disk writes documented in fetched text (UNVERIFIED for disk behaviour; not fetched).
- **quickcheck**: UNVERIFIED (not fetched).
- **serial_test**: UNVERIFIED (not fetched). Its purpose (serialising tests that share global state) is a known workaround for env-var and global races; see section 6.
- **assert_cmd / assert_fs**: UNVERIFIED (not fetched). They run binaries and create temp dirs; any temp dir outside the repo should be checked against the sandbox rules.

## 6. Build artifacts and determinism

- Default target directory: "Defaults to `target` in the root of the workspace." `CARGO_TARGET_DIR` or `build.target-dir` config overrides it. Sources: https://doc.rust-lang.org/cargo/commands/cargo-clean.html ; https://doc.rust-lang.org/cargo/reference/environment-variables.html (fetched). Incremental-compilation subdirectory layout: UNVERIFIED (the build-cache reference was not fetched).
- `Cargo.lock`: "Cargo will take the latest commit and write that information out into your `Cargo.lock` when you build for the first time." `cargo update` rewrites it. Commit it: "When in doubt, check `Cargo.lock` into the version control system." Source: https://doc.rust-lang.org/cargo/guide/cargo-toml-vs-cargo-lock.html (fetched). So `cargo test` writes `Cargo.lock` if absent; a proof under the sandbox must have `Cargo.lock` committed and run with `--locked`.
- `--locked`: "Asserts that the exact same dependencies and versions are used as when the existing `Cargo.lock` file was originally generated. Cargo will exit with an error when either of the following scenarios arises: The lock file is missing. Cargo attempted to change the lock file due to a different dependency resolution." Source: https://doc.rust-lang.org/cargo/commands/cargo-build.html (fetched; same wording under cargo-test flags).
- `--frozen` = `--locked` + `--offline`. `--offline`: "Prevents Cargo from accessing the network for any reason." It uses only locally downloaded crates. Source: same page. `net.offline` / `CARGO_NET_OFFLINE`: "If this is `true`, then Cargo will avoid accessing the network, and attempt to proceed with locally cached data." Source: https://doc.rust-lang.org/cargo/reference/config.html (fetched).
- Vendoring: `cargo vendor` and `cargo fetch` were not fetched. UNVERIFIED for command details. `cargo fetch` is the documented way to download before going offline (cargo-build page: "See the cargo-fetch(1) command to download dependencies before going offline").
- `CARGO_HOME`: `$CARGO_HOME/config.toml`, default `$HOME/.cargo/config.toml` on Unix (cargo config page). The registry cache lives under CARGO_HOME; the config page says automatic cache deletion is disabled with `--offline`/`--frozen`.
- Build scripts: "Just before a package is built, Cargo will compile a build script into an executable (if it has not already been built). It will then run the script, which may perform any number of tasks." Scripts "should not modify any files outside of that directory" (OUT_DIR) — a recommendation, not a sandbox. `cfg!` in build scripts checks the host (build-scripts page, fetched). Whether build scripts run with network or full FS access: not stated (UNVERIFIED). Proc-macro compilation/execution on the host: not stated in fetched text (UNVERIFIED).
- Test parallelism and global state: libtest runs tests on threads (`--test-threads`, default available parallelism). Env-var races: `std::env::set_var` is `unsafe`; the docs say "In multi-threaded programs on other operating systems, the only sound option is to not use `set_var` or `remove_var` at all." and no thread may read the env concurrently (https://doc.rust-lang.org/std/env/fn.set_var.html, fetched). Edition-2024 linkage: UNVERIFIED (edition guide page 404).

## 7. Async tests

- `#[tokio::test]` (tokio-macros docs.rs page, fetched): each test gets a runtime built with `enable_all()` and `block_on` in a plain `#[test]`; the default runtime is single-threaded, "Each test gets a separate current-thread runtime"; `flavor = "multi_thread"` needs `rt-multi-thread`; `start_paused` needs `test-util`. Timeouts: not on the page (UNVERIFIED: no timeout option; use `tokio::time::timeout` in the test body).
- Source: https://docs.rs/tokio-macros/latest/tokio_macros/attr.test.html
- Un-awaited future: see section 4. The Future docs say futures "must be _actively_ `poll`ed"; the compiler warning is the only guard (UNVERIFIED wording).
- Trap stub in an async fn: a stub returning `todo!()` from an `async fn` panics only when polled. If the test forgets `.await`, the stub never runs and the test can pass. Forbid un-awaited calls in oracles; make the oracle `.await` every call.

## 8. Tier 2 slips (hand-computed expected values)

- Integer overflow: "Integer operators will panic when they overflow when compiled in debug mode. The `-C debug-assertions` and `-C overflow-checks` compiler flags can be used to control this more directly." "When `+`, `*` or binary `-` create a value greater than the maximum value, or less than the minimum value that can be stored." Source: https://doc.rust-lang.org/reference/expressions/operator-expr.html (fetched). Release-mode wrap-around: the Reference text does not say "wrap" in release; UNVERIFIED as quoted (the default for release is overflow-checks off per Cargo profile defaults, not fetched). `wrapping_*` / `checked_*` methods: the std page documents `checked_add` ("returning `None` if overflow occurred") and `unchecked_add` redirects to `wrapping_add` (https://doc.rust-lang.org/std/primitive.i32.html, fetched).
- Division by zero panics for integer types. `i32::MIN / -1` (and `%`) "These checks occur even when `-C overflow-checks` is disabled, for legacy reasons." (Reference.)
- Division and remainder: "Integer division rounds towards zero." "Rust uses a remainder defined with truncating division... the remainder will have the same sign as the dividend." Examples in Reference: `14 / 3 == 4`, `100 % 7 == 2`. So `-7 / 2 == -3` and `-7 % 2 == -1`. (Reference, operator-expr, fetched.) `rem_euclid` / `div_euclid`: the std docs describe `checked_rem_euclid` as computing `self.rem_euclid(rhs)`; the base `rem_euclid` text was NOT visible in the fetched portion. The Euclidean-remainder semantics (always non-negative) are UNVERIFIED in a fetched source. Compute expected values with a reference model for both `%` and `rem_euclid`.
- Float: `f64::min/max`: "If the inputs compare equal (such as for the case of `+0.0` and `-0.0`), either input may be returned non-deterministically." `minimum`/`maximum`: "`-0.0` is considered to be less than `+0.0`, making this function fully deterministic for non-NaN inputs." (https://doc.rust-lang.org/std/primitive.f64.html, fetched first 100k chars.) NaN != NaN and `-0.0 == 0.0` under `PartialEq`: UNVERIFIED (the PartialEq section was not reached in the fetched text; widely documented but not confirmed here). `total_cmp`: name confirmed in sidebar only.
- Float formatting: Display vs Debug (`{}` vs `{:?}`) and `f64` printing rules: UNVERIFIED (std::fmt not fetched).
- `str::len`: "Returns the length of this `String`, in bytes, not `char`s or graphemes. In other words, it might not be what a human considers the length of the string." Example: `"ƒoo".len() == 4`, `chars().count() == 3`. Source: https://doc.rust-lang.org/std/string/struct.String.html (fetched). Grapheme counting is not in std; UNVERIFIED for any crate.
- `HashMap` / `HashSet` iteration: "An iterator visiting all key-value pairs in arbitrary order." `retain` visits "in unsorted (and unspecified) order." Default hasher: "The algorithm is randomly seeded." (https://doc.rust-lang.org/std/collections/struct.HashMap.html, fetched). Any expected output that depends on iteration order must be sorted first.
- `sort` vs `sort_unstable`: stability guarantee wording NOT retrieved (fetched text truncated). UNVERIFIED in a primary source; the standard docs say `sort` is stable and `sort_unstable` is not, but this must be confirmed at https://doc.rust-lang.org/std/primitive.slice.html before an oracle relies on it.
- `to_lowercase` Unicode: UNVERIFIED (not reached in fetched text). Treat as: uses full Unicode case mapping; special cases (e.g. final sigma) must be brute-force-checked.
- `Debug` formatting of strings and structs (what `{:?}` prints, used in `assert_eq!` messages): UNVERIFIED (std::fmt not fetched). Do not pin exact `Debug` output in an oracle; compare values, not formatted text.
- Derived `PartialEq` / `Ord` field order: UNVERIFIED (the derive docs were not fetched). Derived `Ord` compares fields in declaration order (common knowledge; confirm at https://doc.rust-lang.org/std/cmp/trait.Ord.html before relying on it).
- Time zones: `chrono` / `time` local-time behaviour: UNVERIFIED (docs.rs not fetched). Pin UTC in oracles.

## 9. Toolchain isolation

- rustup env vars: `RUSTUP_HOME` (default `~/.rustup`): "Sets the root `rustup` folder, used for storing installed toolchains and configuration options." `RUSTUP_TOOLCHAIN`: "If set, will override the toolchain used for all rust tool invocations." Source: https://rust-lang.github.io/rustup/environment-variables.html (fetched).
- Installation: "setting the environment variables `CARGO_HOME` and `RUSTUP_HOME` before running the `rustup-init` executable"; "you will need to ensure these environment variables are always set." Source: https://rust-lang.github.io/rustup/installation/index.html (fetched).
- `--no-modify-path`: NOT found in the fetched install page (UNVERIFIED as a rustup-init flag from a primary source; the basics page was fetched and did not contain it either).
- `--profile minimal`: confirmed in a `rustup toolchain install` example on the rustup overrides/basics pages: `rustup toolchain install nightly --allow-downgrade --profile minimal --component clippy`.
- `rust-toolchain.toml`: `[toolchain]` section; keys `channel` (mutually exclusive with `path`), `components` (added to the profile), `targets`, `profile` (`minimal`, `default`, `complete`). "At least one property must be specified." Source: https://rust-lang.github.io/rustup/overrides.html (fetched).
- Precedence (rustup): `+toolchain` shorthand, then `RUSTUP_TOOLCHAIN`, then directory override, then `rust-toolchain.toml`, then default; proximity to the current directory matters for overrides and toolchain files. Same page.
- Editions: UNVERIFIED in this run (edition guide page 404). `edition` key in Cargo.toml: not fetched.
- Current stable version: the blog's `releases/latest` page did not state a version. Its link target `/2026/10/15/Rust-1.99.1/` suggests stable 1.99.1 dated 2026-10-15 as of 2026-11-02. This is inferred from a URL only: UNVERIFIED as a primary statement. Re-check https://blog.rust-lang.org/releases/latest/ before pinning.

## 10. Standard practice

- Book ch11 (https://doc.rust-lang.org/book/ch11-01-writing-tests.html, ch11-03): unit tests in `#[cfg(test)] mod tests` beside the code; integration tests in top-level `tests/`; each `tests/*.rs` is its own crate; `tests/common/mod.rs` for helpers; library crate needed for integration testing a binary's logic.
- `tests/*.rs` and `tests/*/main.rs` discovery: the Cargo targets page (fetched) says files under `tests/` "are integration tests" and that "Cargo will compile each of these files as a separate crate". The exact `tests/*/main.rs` rule is on the project-layout page, not fetched: UNVERIFIED for the `main.rs` form.
- Auto-discovery off: `autotests = false` in `[package]` (Cargo targets page).
- Conventional CI test command: `cargo test --verbose` (GitHub Actions, GitLab, CircleCI samples) and `cargo clippy --all-targets --all-features --keep-going` for warnings (Cargo CI guide, fetched). `--locked` is not in the Cargo CI guide; add it for deterministic lock use (per cargo-build page).
- Rust Book example for should_panic and Result tests: ch11-01.

## Candidate oracle hazards

| hazard | what happens in a test run (exit status, what output shows) | source URL | confidence |
|---|---|---|---|
| `#[should_panic]` on an oracle test | Trap panic is a pass; cargo/libtest exit 0; output `test x ... ok` | https://doc.rust-lang.org/reference/attributes/testing.html | confirmed |
| `#[should_panic(expected = "s")]` with `s` a substring of the trap text | Trap panic passes if `s` occurs in the message; exit 0 | https://doc.rust-lang.org/reference/attributes/testing.html | confirmed |
| `catch_unwind(...).is_err()` assertion | Trap panic is caught; `is_err()` true; test passes; exit 0 | https://doc.rust-lang.org/std/panic/fn.catch_unwind.html | confirmed |
| `#[ignore]` on the oracle | Test compiled, not run; exit 0 if no other failures; `N ignored` shown | https://doc.rust-lang.org/reference/attributes/testing.html | confirmed |
| Filter matching zero tests (typo or wrong module path) | cargo output `running 0 tests` / `test result: ok. 0 passed`; exit 0 (Book sample shows the output shape; the exit code for filters is inferred) | https://doc.rust-lang.org/book/ch11-01-writing-tests.html ; https://raw.githubusercontent.com/rust-lang/rust/master/library/test/src/lib.rs | exit code for zero-match filter: unverified; output shape confirmed |
| nextest with no matching tests | Default `--no-tests=fail`: error message, exit 4 | https://nexte.st/docs/running/ | confirmed |
| `cargo test` runs doc tests in addition to the proof target | Extra `Doc-tests` section; a failing doc example fails the run with exit 101 | https://doc.rust-lang.org/cargo/commands/cargo-test.html | confirmed (doc tests run by default); exact exit code for doc failure: UNVERIFIED |
| Async oracle without `.await` | Future never polled; stub body never runs; test passes; compiler warns about unused future | https://doc.rust-lang.org/std/future/trait.Future.html | inert-future behaviour confirmed; warning text UNVERIFIED |
| `unused_must_use` ignored `Result` in oracle | Warning only (warn-by-default); exit 0 unless `-D warnings`/`deny` set; output `warning: unused `Result` that must be used` | https://doc.rust-lang.org/rustc/lints/listing/warn-by-default.html | confirmed |
| Invented or wrong-typed symbol in an oracle | rustc error; cargo exit 101; no trap text printed, so the Tier 1 trap check fails | https://doc.rust-lang.org/cargo/commands/cargo-test.html | exit 101 confirmed; "always a compile error" follows from rustc type-checking (general knowledge; not in a fetched source) |
| `set_hook` in oracle or helper | Custom hook may replace the default message; trap text may not appear in output | https://doc.rust-lang.org/std/panic/fn.set_hook.html | effect on libtest output UNVERIFIED |
| Missing `Cargo.lock` under `cargo test` | Cargo writes `Cargo.lock` on first build; the file appears in the repo (tamper); with `--locked` it exits with an error instead | https://doc.rust-lang.org/cargo/guide/cargo-toml-vs-cargo-lock.html ; https://doc.rust-lang.org/cargo/commands/cargo-build.html | confirmed |
| `--offline` / no network | Cargo errors out if a crate is not cached; `--frozen` also forbids lock changes | https://doc.rust-lang.org/cargo/commands/cargo-build.html | confirmed |
| Build script (`build.rs`) run by proof | Runs arbitrary code before the package builds; can write files under OUT_DIR or elsewhere | https://doc.rust-lang.org/cargo/reference/build-scripts.html | arbitrary code confirmed; writes outside OUT_DIR not prevented by Cargo (recommendation only) |
| `insta` snapshot differs or is new | `.snap.new` written next to the snapshot (non-CI); in CI (`CI` env) new snapshots are not written; mismatch fails | https://insta.rs/docs/quickstart/ | `.snap.new` and CI behaviour confirmed; mismatch-fails implied, not stated |
| `expect-test` with `UPDATE_EXPECT` set | Source file rewritten in place; test passes; without the variable a mismatch fails and the file is unchanged | https://docs.rs/expect-test/latest/expect_test/ | confirmed |
| `trybuild` compile-fail case without `.stderr` | Actual output saved into `wip/` next to Cargo.toml; test fails | https://docs.rs/trybuild/latest/trybuild/ | confirmed |
| `TRYBUILD=overwrite` | Compiler output written into the test directory in place | https://docs.rs/trybuild/latest/trybuild/ | confirmed |
| `proptest` failure persistence | Failing seeds written to `proptest-regressions/` (path and disable switch not fetched) | https://proptest-rs.github.io/proptest/ | UNVERIFIED (docs page 404) |
| `mockall` automock of the feature module | Test runs against a mock; green without exercising the real code; expectations are global for statics | https://docs.rs/mockall/latest/mockall/ | confirmed for mechanism; "green untested" is the inference from the TypeScript precedent |
| `std::env::set_var` in a parallel test | Unsafe; races with other threads reading env; can cause flaky reads or UB | https://doc.rust-lang.org/std/env/fn.set_var.html | confirmed |
| `RUST_BACKTRACE` / `RUST_LIB_BACKTRACE` set in the proof env | Adds backtrace lines to panic output; no change to pass/fail; trap text still printed | https://doc.rust-lang.org/std/backtrace/index.html | confirmed |
| Integer overflow in a test expression (debug build) | Panic `attempt to add with overflow` (message text not fetched); test fails with exit 101 unless it is `should_panic` | https://doc.rust-lang.org/reference/expressions/operator-expr.html | panic confirmed; exact message text UNVERIFIED |
| `i32::MIN / -1` or `%` | Panics even with overflow checks disabled | https://doc.rust-lang.org/reference/expressions/operator-expr.html | confirmed |
| `%` on negative operands | Result takes the dividend's sign (`-7 % 2 == -1`); a hand-computed Euclidean value is wrong | https://doc.rust-lang.org/reference/expressions/operator-expr.html | confirmed |
| `HashMap` iteration in expected output | Order arbitrary and randomly seeded; output differs run to run | https://doc.rust-lang.org/std/collections/struct.HashMap.html | confirmed |
| `str::len` on non-ASCII text | Counts bytes; `chars().count()` differs | https://doc.rust-lang.org/std/string/struct.String.html | confirmed |
| `sort` vs `sort_unstable` on equal keys | `sort` stable; `sort_unstable` may reorder equal elements | https://doc.rust-lang.org/std/primitive.slice.html | UNVERIFIED (text not reached) |
| Float `-0.0` vs `0.0` and NaN in `==` | `-0.0 == 0.0`; `NaN != NaN` under PartialEq | https://doc.rust-lang.org/std/primitive.f64.html | UNVERIFIED (PartialEq section not reached); `minimum`/`maximum` ordering of -0.0 confirmed |
| `unreachable!` used as a trap | Message format not confirmed in a fetched source; use `panic!("feature-trap")` | https://doc.rust-lang.org/std/macro.unreachable.html | UNVERIFIED |
| `todo!()` / `unimplemented!()` as a trap | `not yet implemented` / `not implemented` in panic output; exit 101 for a red test; a should_panic would pass | https://raw.githubusercontent.com/rust-lang/rust/master/library/core/src/macros/mod.rs | confirmed |
| Test returns `Err` as its failure mode | Test fails; `should_panic` cannot be combined with a Result test | https://doc.rust-lang.org/book/ch11-01-writing-tests.html | confirmed |

## Architect verification on the installed toolchain (2026-11-02)

The Architect ran these on rustc and cargo 1.99.1 (aarch64-apple-darwin, isolated in `~/.local/rust`) under `env -i` with an absolute `cargo`, in a throwaway crate. Where they differ from the agent's text above, these runs take precedence.

| Claim | Result | Verdict |
|---|---|---|
| Filter matching zero tests (`cargo test --test acc -- --exact nomatch`) | **exit 0**, `running 0 tests`, `0 passed … 8 filtered out` | Confirmed: a silent pass. Tier 1 rejects it because the stub run also exits 0, but a proof whose filter drifts goes green on the implementation. |
| `--test <name>` naming no target | exit 101, `error: no test target named …` | A build-class error, which fails Tier 1 |
| `#[should_panic]` on a trap stub | **passes** | Confirmed. The proof still exits 101 when a sibling test hits the trap, so the whole-proof bar does not see it. |
| `catch_unwind(...).is_err()` on a trap stub | **passes** | Confirmed; same blind spot |
| `#[ignore]` | reported `ignored`, not run | Confirmed |
| `todo!()` / `unimplemented!()` / `unreachable!()` messages | `not yet implemented` / `not implemented` / `internal error: entered unreachable code` | All confirmed. None is unique, so use `panic!("<feature>-trap")`. |
| `panic!` output when captured | `thread '<test>' (<tid>) panicked at src/lib.rs:L:C:` followed by the message on the next line | Confirmed: the trap appears in default (captured) output |
| `tests/<dir>/main.rs` discovery | Built as target `<dir>`, runnable with `--test <dir>` | Confirmed |
| Doc tests | `cargo test --doc` runs them, and a doc example calling the stub fails with the trap (exit 101). They are not run under `--test <name>`. | Confirmed |
| `Cargo.lock` | Written into the crate root by the first `cargo test` when missing; `--locked` passes once it exists | Confirmed. A tree-snapshot concern if the target does not commit it. |
| `NaN != NaN`, `-0.0 == 0.0` under `assert_eq!` | Both hold | Confirmed |
| Unused parameters in a trap stub | `unused variable` warnings | Matters if `-D warnings` is adopted: name stub parameters `_x` |
| `--no-modify-path` | Not needed: installed via `brew install rustup` (keg-only) plus `rustup toolchain install` with `RUSTUP_HOME`/`CARGO_HOME` set; no profile edits | Superseded |
| Current stable | 1.99.1 (2026-10-13 per `rustc --version`; the agent's 2026-10-15 was a guess) | Corrected |

Still open for the plant runs: proptest persistence paths, insta behaviour under the sandbox, `sort` stability (documented as stable in std), `to_lowercase` edge cases, `Debug` formatting in `assert_eq!` messages, nextest's exit codes, and whether `-D warnings` changes a Tier 1 verdict.

**Added after Grok round 2 (same toolchain):**
- `rustc --version` prints exactly `rustc 1.99.1 (58cf8f9c3 2026-10-13)`.
- The `catch_unwind` payload form (`catch_unwind(|| stub()).unwrap_err()`, then `assert_eq!` on the message) fails against the stub. Its captured output holds two panicked blocks: first `thread 'payload' (…) panicked at src/lib.rs:4:21:` followed by `v-trap` (the default hook runs even though the panic is caught), then `panicked at tests/pay.rs:5:5:` with `assertion \`left == right\` failed`, `left: "v-trap"`.
