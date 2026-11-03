# Evidence: Rust rules for Tier 1 and Tier 2

Measured 2026-11-02/03 on an Apple M1 (`machdep.cpu.brand_string`), macOS
27.0.1. The toolchain was rustc 1.99.1 (`rustc 1.99.1 (58cf8f9c3 2026-10-13)`)
and cargo 1.99.1 (`5f94df478 2026-08-27`), aarch64-apple-darwin, isolated in
`~/.local/rust` (rustup from Homebrew, keg-only).

Crates (fixture `Cargo.lock`, sha256 `7861209f1aca…`):

| Crate | Version | Checksum |
|---|---|---|
| insta | 1.49.0 | `b67d3d2e287e4b86c10b3f3b641033d1f89b74bdb39d05f34952e2b9a6fe21cd` |
| mockall | 0.15.0 | `1a6ceddfe3ce334925e96bf420fdb2dcee5bed6c632a168ece622676dadeaf8a` |
| proptest | 1.12.0 | `b8530004ccb15eae51c7e40009fbe317f341f804db54dc033eec1c50be28cfa0` |
| tokio | 1.54.1 | `b52fd3255258d26fac7264ab5a76b53c13367136dc011d3d6ad4f8ed070396a3` |
| tokio-macros | 2.7.2 | `78773a2a397f451582ce068015985c33193cf6dea8b74d2a639fe457b2f07b0e` |

Every row below ran through `proof_exec` (`scripts/lib/proof.sh`) under the
proof sandbox, as the host runs a proof:
- the command was `cd <checkout> && <proof>`, the same shape as run-goal.sh and
  the merged proofs;
- `CARGO_HOME` was the walk's deps folder (read-only), except in the serial
  rows;
- `TMPDIR` was private, with no network;
- each row had a fresh git copy of `fixture/crate/` with one plant applied.

The caller's environment had `RUSTC`, `RUSTFLAGS`, `RUSTDOCFLAGS`,
`RUSTC_WRAPPER`, `RUSTC_WORKSPACE_WRAPPER`, `CI`, `RUST_TEST_THREADS`,
`RUST_BACKTRACE` and every `CARGO_*`, `RUSTUP_*`, `INSTA_*` and `PROPTEST_*`
variable unset. Each log opens with the ones the proof saw (`env:` lines): only
`CARGO_HOME`, plus `RUSTC` in row 33, which sets it on purpose. A row's own
`export` (row 19's `CI=1`) comes after that line.

`fixture/run-plants.sh all` reruns everything in about five minutes. A trap
counts only on the line after libtest's `thread '…' panicked at` line (PLAN
step 0). "Moved" is the host's `tree_snapshot` / `proof_moved`. Times are
cargo's own "Finished … in" time.

## Step 2b: Rust under the proof sandbox

- **Setup** (`--setup`, network): `cargo fetch --locked` into the deps folder,
  rc 0. It first failed: the sandbox refused to set file times on macOS 27.0.1,
  a defect fixed by `docs/features/sandbox-write-times` (75840a2) before this
  rerun.
- **Red proof on the stub:** rc 101, the trap on the panicked line; 6.2 s cold,
  0.4 s warm (a copied `target/`).
- **Green proof on the implementation:** rc 0.
- **Denials,** each run's window queried after `sleep 3` with proof.sh's own
  pipeline. The listing is complete, grouped by process name. The query is
  system-wide: one line from another process's sandbox
  (`spotlightknowledged.importer`, a `PowerManagement.control` lookup) is
  not the proof's.
  - the known harmless set from the proof-sandbox evidence:
    `com.apple.bsd.dirhelper`, `opendirectoryd.membership`/`libinfo`,
    `notification_center`, `logd`, `analyticsd` (from `cc`, `ld`, cargo);
  - **new, harmless** (nothing failed, cargo printed nothing, every verdict
    right):
    - in the red and green proofs, cargo's `file-write-data` on
      `deps/cargo/.package-cache`, `.package-cache-mutate` and
      `.global-cache` (cargo goes on without its package-cache lock when
      `CARGO_HOME` is read-only);
    - a `file-write-xattr` of `com.apple.fileprovider.ignore#P` on
      `deps/cargo/registry`;
    - mach lookups of `DiskArbitration`, `coreservicesd`,
      `SystemConfiguration.configd`, `distributed_notifications` and
      `com.apple.metadata.mds`;
    - in the fetch, `system-info net.link.addr` and `system-socket`.
  - Cargo does not need a writable `CARGO_HOME` in a proof, so no profile
    change follows. The plan required no new denial before Rust joins the
    proved list; the user judged these harmless (2026-11-03), and SKILL.md §4
    step 0b lists "Rust with cargo" as proved.

### The serial shape and vendored crates

A serial `run-goal.sh` has no deps folder (`run-goal.sh:1126-1127` clears it
outside a walk's worktrees), so the proof's `CARGO_HOME` is its own empty
`TMPDIR/cargo`. `claude-implement.sh` never sets `CARGO_HOME`.

| Row | Setup | Result |
|---|---|---|
| serial, no vendor | no deps folder | rc 101, no trap: `error: no matching package named 'insta' found` |
| serial, vendored, stub | `cargo vendor` + `.cargo/config.toml` source replacement, committed | rc 101 with the trap; 5.7 s cold; tree unchanged |
| serial, vendored, implementation | same | rc 0; tree unchanged |

The vendored run's denials are only the known harmless set and the cargo
lookups above. There are no `CARGO_HOME` writes at all: it writes in its own
temp folder. Vendoring is what RUST.md recommends. Its effect on the
implementer (Claude Code's sandbox) is not measured; FUTURE-WORK item 34
carries it.

## Tier 1 rows

Each row was run under the full recipe minus one rule ("minus"), then the full
recipe ("full"), on the stub. The verdict follows the keep rule (PLAN step 0).

| Row | Plant (failure class) | Minus | Full | Verdict |
|---|---|---|---|---|
| clean g1, g2 | none | — | stub rc 101 + trap, impl rc 0, tree unchanged | (a)(b)(c) hold |
| 01 | wrong-typed call into the planned API | rc 101, no trap (E0308) | — | dropped: the baseline rejects it |
| 02 | invented symbol | rc 101, no trap (E0425) | — | dropped |
| 03 | `async fn` under `#[test]` | rc 101, no trap (compile error) | — | dropped |
| 04 | bare `#[should_panic]` (passes on any panic) | through (rc 101 + trap) | rc 1, no trap | **kept**: check `should_panic` |
| 05 | `should_panic(expected = "duration")`, a substring of the trap | through | rc 1 | **kept** (same check) |
| 06 | `assert!(catch_unwind(…).is_err())` | through | rc 1 | **kept**: check `catch_unwind(…).is_err/is_ok()` |
| 07 | `#[ignore]` on the goal's case | through | rc 1 | **kept**: check `#[ignore` |
| 08 | `panic::set_hook` in an oracle | **nondeterministic**: through in 9 of 20 runs (runs 2 to 4b: 2, 3, 0, 4 of 5), no trap in the rest | rc 1 each time it got through | **kept**: check `set_hook` |
| 10 | dropped `Result` (`parse_duration("1x");`) | through | rc 101, no trap (compile error) | **kept**: `#![forbid(unused_must_use, unreachable_code)]` |
| 11 | `let _ = parse_duration("1x");` | through | through | **gap**: look-for |
| 12 | future never awaited (`load_duration("2m");`) | through | caught | **kept** (forbid) |
| 13 | `let _ = load_duration("2m");` | through | through | **gap**: look-for |
| 14 | assertion after `return;` | through | caught | **kept** (forbid) |
| 15 | row 10 under `#[allow(unused)]` | through | caught | **kept** (forbid) |
| 16 | row 12 under `#[allow(unused)]` | through | caught | **kept** (forbid) |
| 17 | row 14 under `#[allow(unreachable_code)]` | through | caught | **kept** (forbid) |
| 18 | `mockall::mock!` of the feature trait, the expectation calling the stub | through; impl rc 0 (green, tested the mock) | rc 1 | **kept**: check `mockall\|mock!\|automock` |
| 19 | `insta::assert_debug_snapshot!` | through | rc 1 | **kept**: check `insta::\|assert_*snapshot!` |
| 20 | `proptest!` without persistence off | through, **and** wrote `tests/acceptance/g1.proptest-regressions` (tamper) | rc 1 | **kept**: check that proptest files set `failure_persistence: None` |
| 21 | `proptest!` with `failure_persistence: None` | — | stub rc 101 + trap, impl rc 0, tree unchanged | the written form passes (a)(b)(c) |
| 22a | zero tests matched (`-- --exact nomatch`) | rc 0 | — | dropped: the pass bar rejects a zero exit |
| 22b | `--test g9` (no such target) | rc 101, no trap | — | dropped |
| 23 | `[[test]]` declaration missing | rc 101, no trap (`tests/acceptance/*.rs` is not auto-discovered) | — | dropped; RUST.md requires the declaration |
| 24 | `g2.rs` does not compile; proof `--test g1` | — | rc 101 + g1's trap | `--test` builds only its own target: one goal's broken oracle does not reach another's proof |
| 25 | `Cargo.lock` absent | through, **and** wrote `Cargo.lock` (tamper) | rc 101, no trap (`cannot create the lock file … because --locked was passed`) | **kept**: `--locked` |
| 26 | `.cargo/config.toml`: `build.target-dir = "tests/acceptance/target"` | through, **and** built under `tests/acceptance/target/` (tamper) | trap, tree unchanged | **kept**: `CARGO_TARGET_DIR="$PWD/target"` |
| 27 | `build.rs` printing a canary | — | trap; `warning: duration@0.1.0: canary-build-script` in the log | fact: a target's build script runs in every proof |
| 32 | the recipe's `rustc` reports another version (a fake reporting 1.98.0) | through, rebuilt on it | rc 1, no trap | **kept**: version check |
| 33 | the caller exports `RUSTC` (the fake) | cargo ran the caller's `RUSTC` (its marker written) | cargo ran the pinned rustc | **kept**: `RUSTC="$RUSTC"` on cargo (Tier 1 passes both ways; the rule makes the compiler cargo uses the one the version check read) |
| 34 | `panic = "abort"` in `[profile.dev]` and `[profile.test]` | — | stub rc 101 + trap, impl rc 0 | dropped: tests ignore it |

### Warnings as errors (Q3), per row

| Row | Narrow `forbid` | Narrow `deny` | Global `RUSTFLAGS="-D warnings"` |
|---|---|---|---|
| 10, 12, 14 | caught | caught | caught |
| 15, 16, 17 (`#[allow]` bypass) | caught | **through** | **through** |
| 11, 13 (`let _ =`) | through | through | through |
| 31: clean oracle, target with one warning (in its `build.rs`) | (a) and (b) hold | — | **(a) broken**: stub rc 101, no trap (`error: unused variable`); impl rc 101 |

So `forbid` is kept, `deny` is not enough, and the global flag is dropped: it
misses the bypasses and breaks every proof of a target that has a warning.

### Snapshots and property tests against the implementation

- **insta** (row 19, on the implementation, without the check): writes
  `tests/acceptance/snapshots/g1__parses_seconds_snapshot.snap.new` and exits
  101 (tamper). With `CI=1` or `INSTA_UPDATE=no` it writes nothing but still
  fails. The check is the rule. Whether either env changes the stub's Tier 1
  result was not run: it fails before insta's macro, so it cannot.
- **proptest** (row 20): the persisting form passes on the implementation
  (rc 0). A property failing during a FIX round would write the regressions
  file during the host proof, so the rule matters there too.

### Overflow checks across profiles (rows 28 to 30, implementation)

Two oracle cases: an overflowing `+` in the library (`total_secs`) and one in
the oracle, each asserting the panic.

| Row | Profile setting | Minus (no forcing) | `CARGO_PROFILE_{DEV,TEST}_OVERFLOW_CHECKS=true` | `RUSTFLAGS=-C overflow-checks=on` |
|---|---|---|---|---|
| 28 | `[profile.dev] overflow-checks = false` | both cases fail (no panic) | both pass, 0.4 s | both pass, 5.7 s (full rebuild) |
| 29 | `[profile.test] overflow-checks = false` | both fail | both pass | both pass |
| 30 | both | both fail | both pass | both pass |

Either profile setting turns checks off in the library **and** the oracle.
The env-var form is kept: it forces both profiles without overriding a
target's own `RUSTFLAGS`, and keeps the warm build. Not covered, so written
as look-fors in RUST.md: a per-package profile override, and
`-C overflow-checks=off` in a target's `RUSTFLAGS` or `build.rustflags`.

## Tier 2 rows

The reference is `fixture/reference/tier2.rs`: std only, importing nothing
from the fixture, built with the same `rustc 1.99.1` without `-O` (overflow
checks on), and written before `impl/lib.rs`. Its five runs are verbatim in
`fixture/reference/output.txt` (the harness's `ref` row). Run 1:

```
total_secs(3e9,2e9) = panic (overflow)
total_secs(1,2) = 3
wrapping 3e9+2e9 = 705032704
-7 % 3 = -1
(-7).rem_euclid(3) = 2
"go🚀".len() = 6
"go🚀".chars().count() = 3
hashmap keys = ["h", "ns", "s", "ms", "us", "m", "d", "w"]
-(0.0) = -0.0, bits 0x8000000000000000, == 0.0: true
mean([]) = NaN, == NAN: false, is_nan: true
Display 1.0 = 1, Debug 1.0 = 1.0
"İ".to_lowercase() = "i\u{307}", chars [105, 775]
```

The `hashmap keys` line differs in all five runs (5 distinct orders).

| Row | Hand value pinned | Reference | Against the implementation | Verdict |
|---|---|---|---|---|
| 40 | `total_secs(3e9, 2e9) == 705_032_704` (wrapped) | panics | red (the overflow panic) | **kept**: compute it with the reference, built as the proof builds |
| 41 | `bucket(-7, 3) == 2` | `-1` | red | **kept** |
| 42 | `label_width("go🚀") == 3` | `6` (bytes) | red | **kept** |
| 43 | `units()` pinned in insertion order | 5 orders in 5 runs | red, 5 of 5 | **kept**: sort, or a `BTreeMap`; never pin a `HashMap` order |
| 44 | `assert_eq!(negate(0.0), 0.0)` | `-0.0` | **green** (loose: `-0.0 == 0.0`) | **kept**: compare `to_bits()` |
| 45 | `to_bits()` against `0.0` (the strict form of 44) | — | red | (the strict form is red on the same values) |
| 46 | `assert_eq!(mean(&[]), f64::NAN)` | NaN | red | **kept**: `is_nan()` |
| 47 | `show(1.0) == "1.0"` | `"1"` (`Display`) | red | **kept** |
| 48 | `fold("İ") == "i"` | `"i\u{307}"` | red | **kept** |

Every red row is an assertion failure (or the overflow panic), never a compile
error: the harness reports a compile error separately.

## Sanity check (PLAN step 7)

Every kept Tier 1 rule's "minus" run above is the recipe with that rule
reverted, and each turns its row from caught to through. The exceptions are
08, nondeterministic and recorded as such, and the forbid rows, whose minus
run drops the header. Each kept Tier 2 row is caught when its value is
compared with the reference; skipping the comparison commits the hand value
in the second column.

## Departures from the plan

- The version check was planted with a fake `rustc` reporting another version,
  not with a `rust-toolchain.toml`. The recipe calls rustc by absolute path, so
  a toolchain file steers nothing.
- proptest's env-var route was not measured; the written config form was.
- Plant 31's warning is in the target's `build.rs`, not its library: the same
  "target code has a warning" case for `-D warnings`.
- `set_hook` was planted in the oracle, not in the target's code.
- Rows `ref` and `serial` were added after the Opus round-1 review.

## Runs

- **Run 1** (2026-11-02): found two harness defects. The insta env variants
  set the variable on `cd`, not cargo. The `RUSTC` marker was written outside
  the sandbox's trees. Row 08 also proved nondeterministic, and proptest's
  regressions file was noticed. All four were fixed, `C_hook` and the
  persistence check were added, and everything was rerun.
- **Run 2:** every row, with the fixes.
- **Run 3:** the harness in the host's exact shape (`cd <checkout> && <proof>`,
  `CARGO_TARGET_DIR="$PWD/target"`). Same verdicts as run 2, apart from
  row 08's split.
- **Run 4** (the evidence above), after the Opus round-1 review:
  - complete denial listings, grouped by process name, not cut at 40 lines;
  - cargo's own times;
  - the environment recorded;
  - timeouts, sandbox stops and compile errors reported as errors;
  - a fetch sentinel and the host's 600 s timeout;
  - the version check in parentheses;
  - the `ref` and `serial` rows.

  Same verdicts as run 3, apart from row 08's split. Its first pass found the
  new compile-error detector matching libtest's own closing line, `error: test
  failed`. Fixed, and rows 40-48 and 08 rerun (4b).
