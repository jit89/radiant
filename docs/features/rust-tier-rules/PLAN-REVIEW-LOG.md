# Plan Review Log: Rust rules for Tier 1 and Tier 2
Phases 0-1 (recon + interrogation) complete — plan locked with the user. MAX_ROUNDS=5.

## Round 1 — Grok

I'll read the plan and the domain docs around it, then check the repo assumptions it depends on.The plan is locked and cites specific files. I'll check those citations against the rulebook, sandbox, and the TypeScript precedent.The plan would lock in rules proved under a different environment than the host, and several of the recipes contradict the pass bar or each other. It is not ready to implement.

1. **The plant harness is not the host proof.** Assumption 3 cites `scripts/lib/proof.sh:88-95` for an `env -i` run. Those lines are an `env -u` list: they set `CARGO_HOME=$deps/cargo`, `TMPDIR`, and `XDG_CACHE_HOME`, and they leave `PATH` and the rest of the environment in place. Step 2's `env -i HOME PATH` drops `CARGO_HOME`, so Cargo reads `$HOME/.cargo` (user config and registry), and it also drops inherited `CARGO_TARGET_DIR`, `RUSTFLAGS`, and `CARGO_PROFILE_*` that `proof_exec` keeps. Step 7's `run-plants.sh` then describes a third `CARGO_HOME`.
   **Fix:** One environment for step 2, the plants, step 2b, and `run-plants.sh`: the `proof_exec` assignments, the absolute `1.99.1` cargo, and a version check that refuses any other `rustc --version`.

2. **Two pre-runner checks do not fail closed.** The recipe is `cd && <checks> && cargo`, and each check is `grep …; test $? -eq 1`. `;` binds looser than `&&`, so `cd && grep -q should_panic f.rs; test $? -eq 1 && grep -q mock! f.rs; test $? -eq 1 && cargo test` runs Cargo after a `should_panic` hit: the first `test` exits 1, and the next `test $? -eq 1` succeeds. A default `grep` also prints the matching line, so a line that quotes `duration-trap` is a nonzero exit that still carries the trap.
   **Fix:** One parenthesized check, as in `TYPESCRIPT.md`: `( grep -q -F -e should_panic -e … -- tests/acceptance; test $? -eq 1 ) && "$CARGO" test …`.

3. **The allowed panic pin is the pattern the check rejects.** The candidate grep rejects `catch_unwind`, and the legal form for a planned panic is `catch_unwind` plus payload equality. That form never reaches (a) or (b). `-- --include-ignored` cannot meet (d) either: the plant's sibling still panics with the trap, so the exit stays 101 and the trap stays in the output.
   **Fix:** Match `should_panic`, `#[ignore]`, and `catch_unwind(…).is_err()` only; plant the payload-equality form with `assert_eq!` so the stub's message is what fails the assertion, and drop the `include-ignored` arm.

4. **`#![deny(unused_must_use, unreachable_code)]` is overridable, and the Result hole is narrower than the future hole.** `#[allow(unused_must_use)]` or `#[allow(unused)]` on the test overrides a crate-level `deny`. The plan plants `let _ = fut` and a bare `parse_duration("1x");`, and skips `let _ = parse_duration("1x")`, which silences `unused_must_use` the same way.
   **Fix:** Use `#![forbid(unused_must_use, unreachable_code)]`, and plant `#[allow(unused)]` plus `let _ = parse_duration(…)` so a bypass is either caught or written up as a gap.

5. **`[[test]]` is a shared registration list, and nothing measures a second target.** `tests/acceptance/<id>.rs` is not auto-discovered, so every goal's block goes in one `Cargo.toml`. That is the rbtree failure (`GOAL-FORMAT.md`, "Registration points"): parallel goals each appending one block stop on `merge-conflict`. The fixture has a single test, so no plant shows whether `cargo test --test g1` still builds a later `[[test]]` that does not compile.
   **Fix:** `RUST.md` says every `[[test]]` is committed in Phase 3 and no goal edits that table; add a second target that does not compile and keep the rule only if `--test` of the first still prints the trap.

6. **Overflow checks are two profiles, and the pass bar will mis-score a compile failure.** Cargo builds the integration-test binary with `test` and the library it links with `dev`. An explicit `[profile.test] overflow-checks = false` wins over a value inherited from `dev`. The hostile plant sets only `[profile.dev]`. Separately, step 0 treats the trap string anywhere in the output as a pass, so a `RUSTFLAGS="-D warnings"` diagnostic that quotes `panic!("duration-trap")` satisfies Tier 1 without running a test. The Q3 "one existing warning" measurement can therefore look like (a) held.
   **Fix:** Plant `+` in the library and in the oracle under `[profile.dev]`, `[profile.test]`, and both; force both with the flag that measurement keeps (`RUSTFLAGS=-C overflow-checks=on`, or both `CARGO_PROFILE_{DEV,TEST}_OVERFLOW_CHECKS`). Score a trap only on libtest's `thread '…' panicked at` line, which the Architect verification already recorded.

7. **The HashMap rule copies a random order.** The red branch says "compute it with the reference". The reference is also a `HashMap`, so one run's order is not a pin. Five agreeing runs of a small map are easy (two keys agree about 1/16 of the time) and the plan then drops the plant because the hand value "came out right".
   **Fix:** Keep "sort or `BTreeMap`" whenever the reference order differs across five runs, and if the oracle's five runs agree, enlarge the map and rerun before dropping it.

8. **A green sandbox run has no denial listing.** `proof.sh` appends denials only when the exit is nonzero and not 124 (lines 134–140). Step 2b requires `worktree_setup` to pass, so that run's listing is empty, and step 6 still adds "Rust with cargo" to the proved list. Plants are not rerun under `proof_exec`. A follow-up that makes `CARGO_HOME` writable also lets `--jobs` proofs share one registry lock.
   **Fix:** Run `log show` for the fetch and for the green proof on the same window the red proof uses; rerun the kept recipe under `proof_exec`; add Rust to the proved list only when that listing has no new denials, and if the outcome is a writable `CARGO_HOME`, stop and record the parallel-lock conflict.

VERDICT: REVISE

### Architect's response
All eight points were taken; each was checked against the code first.
1. Taken. proof.sh uses `env -u` (credentials and CW_*), not `env -i`: PATH and the rest are kept, and CARGO_HOME, TMPDIR and XDG_CACHE_HOME are set. Every run (baseline, plants, 2b, run-plants.sh) now goes through proof_exec itself, so there is one environment. The harness unsets RUSTFLAGS, CARGO_* and RUSTUP_* in the caller unless a row sets them. A version check (`rustc --version` matched exactly) is a planted candidate. Assumption 3 corrected.
2. Taken. One parenthesized `( grep -rqE …; test $? -eq 1 ) &&` check, as in TYPESCRIPT.md, with `-q` so nothing is printed. Chaining with `;` is named as forbidden, with the reason.
3. Taken. The pattern matches `should_panic`, `#[ignore` and `catch_unwind(…).is_err()/.is_ok()` on one line; a bare catch_unwind is allowed. The payload form (`unwrap_err()` then assert_eq on the message) is planted and must pass (a) and (b). The `--include-ignored` arm was dropped: it cannot change the Tier 1 verdict.
4. Taken. The narrow form is now `#![forbid(...)]` (an inner #[allow] overrides deny, not forbid); deny is planted to show the difference. Plants added: `let _ = parse_duration(…)`, and each shape under `#[allow(unused)]`.
5. Taken. RUST.md will say every `[[test]]` block is committed in Phase 3 and no goal edits the table (the registration-point rule). The fixture has two targets; a plant makes g2 fail to compile, to measure whether `--test g1` is isolated from it.
6. Taken, both halves. Overflow is planted under [profile.dev], [profile.test] and both, against two forcing candidates (RUSTFLAGS `-C overflow-checks=on`, and both CARGO_PROFILE_*_OVERFLOW_CHECKS). A trap counts only on libtest's `thread '…' panicked at` line followed by the message, so a compiler diagnostic quoting the stub's source never reads as a pass; RUST.md states it as the Rust reading of the pass bar.
7. Taken. A HashMap order is never pinned from the reference: if the reference's 5 runs differ, the rule (sort or BTreeMap) is kept without the hand-value test; if they agree, the input is enlarged. The plant uses at least 8 keys.
8. Taken. The harness runs the `log show` denial query itself on each window (fetch, green proof, red proof), since proof_exec lists denials only after a red run. "Rust with cargo" joins step 0b's proved list only with no new denials and every kept row green under proof_exec. A writable CARGO_HOME stops the item, and the parallel registry-lock concern is recorded.

## Round 2 — Grok

I'll re-read the revised plan and check it against the earlier findings and the host code those findings depended on.The eight earlier findings are in the plan now. Two of the new mechanisms still record the wrong result, and the version pin is not the string the research measured.

1. **The version check does not bind the compiler Cargo runs.** The recipe checks `"$RUSTC" --version`, then invokes `"$CARGO" test` with no `RUSTC=` prefix. Cargo honors `RUSTC` from the environment, and the harness unset list is only `RUSTFLAGS`, `CARGO_*`, and `RUSTUP_*`. On a host that has `RUSTC` set, the check can print 1.99.1 from the pinned binary while Cargo compiles with the other one. The `-qx` line also pins `58cf8f9c3`, which is not in the Architect verification (that row is only `1.99.1 (2026-10-13 per rustc --version)`).
   **Fix:** Run Cargo as `RUSTC=<pinned rustc> "$CARGO" test …`, unset `RUSTC` in the harness unless the row sets it, and copy the `-qx` line from the first `rustc --version` the harness prints.

2. **A green denial listing is still empty if it is taken too soon.** `proof.sh` waits 3 seconds before `log show` (line 135) because the unified log lags; that append happens only when the exit is nonzero (lines 134–140). Step 2b runs the query itself for the fetch and the green proof, and does not wait. An empty listing then satisfies “no new denial”, and step 6 adds Rust to the proved list.
   **Fix:** For each of the three runs, record `--start` in `proof.sh`’s format, sleep 3, then run the same `log show` pipeline, including the `vfs.disk-space` filter.

3. **The payload form does not produce the panic line the new scorer requires.** The scorer counts a trap only when `thread '<test>' … panicked at <file>:<line>:<col>:` is followed by the trap message, which is the uncaught-panic shape in the Architect verification. `catch_unwind` swallows the stub, so libtest’s failure is the later `assert_eq!`, whose next line is the assertion text; `duration-trap` is inside the diff. `catch_unwind(…).is_err()` was measured as a passing test, which hides captured output, so this shape has never been recorded. A next-line scorer rejects the only legal panic pin, and the easy repair is to widen the scorer until a compiler quote matches again.
   **Fix:** Score the payload plant from its actual output: the trap is the `assert_eq!` actual value under that test’s `panicked at` block, and write that block into the scorer before any other plant is judged.

VERDICT: REVISE

### Architect's response
1. Taken. Cargo now runs as `RUSTC="$RUSTC" "$CARGO" test …`, and the harness unsets RUSTC unless a row sets it. On the hash: `58cf8f9c3` was measured (it is the line rustc printed at install, and again on 2026-11-02). It was missing from RESEARCH.md, which now records the exact line. The plan's recipe takes `<the exact line>` from the harness's first print and records it in EVIDENCE.md.
2. Taken. For each of the three runs: `--start` in proof.sh's format, `sleep 3`, then proof.sh's own log show pipeline with the vfs.disk-space filter.
3. Rejected, on measurement. The premise is that catch_unwind swallows the stub's panic line. On rustc 1.99.1, the default panic hook prints before catch_unwind takes the payload. The failing payload test's captured output shows `thread 'payload' (…) panicked at src/lib.rs:4:21:` then `v-trap`, followed by a second block for the assert_eq! with `left: "v-trap"` (RESEARCH.md, added section). The scorer's rule matches this shape unchanged, so it is not widened. Taken from the point: the shape is now recorded in the plan, and a target-installed panic hook (`set_hook`) that would silence the first block is planted as an extra row.

## Round 3 — Grok

I'll re-read the revised plan and check the last round's findings against the host proof code.Round 2 is addressed, and the earlier keep rules are still intact. The plan is sound enough to implement.

The Cargo invocation is now `RUSTC="$RUSTC" "$CARGO" test`, the harness unsets `RUSTC` unless a row sets it, and `<the exact line>` is taken from the first `rustc --version` the harness prints. `RESEARCH.md` records that line as `rustc 1.99.1 (58cf8f9c3 2026-10-13)`.

Step 2b records `--start` in `proof.sh`'s format, waits `sleep 3` because the unified log lags, then runs `proof.sh`'s `log show` pipeline including the `vfs.disk-space` filter, for the fetch, the green proof, and the red proof. Rust joins the proved list only when all three listings are clean.

The payload-form rejection matches a recorded run. `RESEARCH.md` shows the default hook prints `thread 'payload' (…) panicked at src/lib.rs:4:21:` with the trap on the next line, then a second block for the `assert_eq!`. The scorer stays on that next-line shape. The `set_hook` row is an extra plant under the same keep rule: if the baseline already fails Tier 1, it is dropped and logged.

`RUSTC_WRAPPER` and `RUSTC_WORKSPACE_WRAPPER` are still inherited, same as on the host. A wrapper that writes outside the checkout shows up in those denial listings, which blocks the proved-list edit, so it does not ship a bad rule.

VERDICT: APPROVED

### Architect's response
Converged: APPROVED in 3 rounds. The note on RUSTC_WRAPPER / RUSTC_WORKSPACE_WRAPPER is logged as a known inherited variable, the same as on the host; it is caught by the denial listings and is no plan change.
