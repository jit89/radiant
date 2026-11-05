# Plan Review Log: rust-toolchain-gates
Phases 0-1 (recon + interrogation) complete — plan locked with the owner (Q1–Q3 recommendations accepted; cosmetic
defaults accepted). MAX_ROUNDS=5.

## Round 1 — Grok

I'll review the implementation plan skeptically against the repo and domain docs, looking for concrete breaks rather than style nits.The plan's PATH prepend is the right mechanism, and it is not safe to implement as written. Four of its own rules contradict the host's measured Rust and GOALS.md behavior, so a walk that opted in would stall on files the implementer is not allowed to edit.

1. **`clippy --workspace --all-targets` and `fmt --all` break oracle isolation.** GOAL-FORMAT.md's registration rule says no proof step may build, type-check, or collect a later goal's oracle, and RUST.md measured that `cargo test --test <id>` is what keeps a not-yet-compiling oracle out of earlier proofs. Both oracles are already committed in Phase 3. `--all-targets` type-checks every `[[test]]`, example, and bench; `fmt --all` checks every `.rs` file. An early goal then goes red on a later oracle and cannot edit `tests/acceptance/`. Q3's reason for `--all-targets` is wrong: `cargo clippy --test <id>` does lint that oracle. It does not skip it.
   **Fix:** Lint and format only `--lib` and `--test <id>` in each proof; run the workspace-wide gate once in Tier 1, while every oracle still compiles against the stubs.

2. **The Tier 1 command misses the g8 failure it is there to catch.** The proof is an `&&` chain, so a red stub test never reaches clippy or fmt. The separate command is bare `cargo` / `rustfmt`, which are not on `PATH` (the bug in item 39), and it omits `-D warnings`, so pedantic findings stay warnings and exit 0. `--keep-going` does not lint an integration test whose library unit failed. Cargo skips dependents of a failed unit, which is the g8 shape. The addendum's `similar_names` plant is absent, and `[workspace.lints]` does nothing unless every package has `[lints] workspace = true` (`docs/features/rust-tier-rules/RESEARCH.md`).
   **Fix:** Tier 1 runs the pinned `"$CARGO" clippy --offline --locked --test <id> --message-format=json -- -D warnings` and `"$CARGO" fmt -- --check <oracle>`, after stubs are clean under that same gate, and fails on any `tests/acceptance/` diagnostic. Require `[lints] workspace = true` in every package.

3. **The lint level is bypassed in source, and the reviewer never sees the config-file rule.** RUST.md already measured that `#[allow]` overrides `deny`. `-D warnings` is deny. `clippy.toml`, `rustfmt.toml`, and `[workspace.lints]` are "out of scope" only in RUST.md. The reviewer reads the goal body, not that file (the same sentence RUST.md uses for `vendor/` and `.cargo/`). An implementer can allow the lint in the crate or edit `Cargo.toml`, and the proof stays green.
   **Fix:** Put those paths and the lint tables in every opted-in goal's **Out of scope**, add the RUST.md look-for bullet, and add a proof grep for `allow(clippy` and `allow(warnings)` in the same style as the `should_panic` check.

4. **The handoff trigger does not match the recipe.** Step 3 looks for the substrings `cargo clippy` and `cargo fmt`. The recipe emits `"$CARGO" clippy` and `"$CARGO" fmt`, so the "run the lint steps before DONE" line is never added. The test in step 7 uses the same wrong substring, so it stays green while real handoffs omit the line.
   **Fix:** Trigger on the cargo subcommand tokens `clippy` and `fmt` in the proof, and assert that against a fixture proof that uses `"$CARGO" clippy`.

5. **The tests do not lock the failure that item 39 measured.** `cw-probe` in a stub `claude-implement.sh` shows that the launcher process inherited `PATH`. It does not show that `cargo` finds `cargo-clippy` on `PATH` when `proof_exec` has set `CARGO_HOME` to an empty deps dir (assumption 3), nor that Claude Code's Bash tool inherited `PATH`. The default implementer is `claude-implement.sh`. Only the legacy Codex launcher documents `inherit = all`. Item 39's "sandbox denies nothing new" and item 40's `scripts/tests/` `unwrap()` plant are replaced by an out-of-`run-all` plant that does not record denials. Marking 39, 40, and the addendum done overclaims what those tests show.
   **Fix:** Drive a fake `cargo` whose `clippy` subcommand succeeds only when `cargo-clippy` is found on `PATH` and not under `$CARGO_HOME/bin`, run that proof through `proof_exec`, and keep the real-toolchain plant as a denial diff plus a sibling oracle that does not compile.

6. **Prepending in the orchestrator shell shadows the host's own tools, and the timeout question is dropped.** The export is right after `goals-base.md` is written, in `run-goal.sh` and `wave-walk.sh`, so later `git`, `python3`, and `shasum` in the host resolve from `tool_path` first. Item 40's open question 3 (cold clippy versus `PROOF_TIMEOUT`, default 600s, and again on every mutation) is not in the risks, and item 38 is out of scope, so nothing warms that build.
   **Fix:** Pass the prepended `PATH` only on the `env` of `proof_exec`, the implementer, the reviewer, and `worktree_setup`, and state in RUST.md that the timeout must cover a cold lint of this goal's own test target.

VERDICT: REVISE

### Architect's response

Accepted, 6 of 6. PLAN.md is rewritten.

1. **`--all-targets` breaks oracle isolation.** Confirmed by Paladin's g1 END record ("`cargo test --tests` fails to
   compile g2–g7"). The owner re-decided Q3: the proof runs `--workspace --lib --bins --test <id>` and `fmt --all`,
   and Tier 1 lints every oracle.
   - `fmt --all` is kept: rustfmt only parses, and the Architect commits oracles rustfmt-clean.
   - The accepted gap is unit-test modules.
2. **Tier 1 command.**
   - The pinned `"$CARGO"`, with `-D warnings`, run outside the proof's `&&` chain, for every oracle, through
     `--message-format=json`. Any `tests/acceptance/` diagnostic fails.
   - Stubbed crate roots allow all lints, so a trap `panic!` cannot hide the oracle.
   - Every member must have `[lints] workspace = true`.
3. **Config files and escape hatches.**
   - The config files and lint tables go into every opted-in goal's Out of scope.
   - A RUST.md look-for bullet covers individual allows.
   - The proof gets a grep for blanket and group `allow`/`expect`, including `cfg_attr`.
4. **Handoff trigger.** It matches the cargo invocation forms (`cargo`, `"$CARGO"`, `$CARGO`, `${CARGO}`,
   `/…/cargo`) followed by `clippy` or `fmt`. The test uses a `"$CARGO" clippy` proof.
5. **Tests that lock the measured failure.**
   - A fake `cargo` resolves `cargo-<sub>` on `PATH` only, run through `proof_exec` with its `CARGO_HOME`.
   - Implementer and reviewer probes.
   - Real evidence for the Bash tool inheriting `PATH`, for both providers.
   - Real-toolchain plants, with a denial diff and a not-yet-compiling sibling oracle.
   - FUTURE-WORK is marked done only after these pass.
6. **Prefix scope and timeout.**
   - The prefix goes only on the implementer, the reviewer and `proof_exec` (including `worktree_setup` and
     integration proofs). A host-`git` resolution test checks the host is untouched.
   - `validate` refuses tool dirs holding `bash`, `sh`, `env`, `git`, `python3` or `shasum`.
   - The timeout note is in RUST.md and in Risks.

## Round 2 — Grok

I'll re-read the revised plan and check each prior finding against the host code, then flag only what still breaks.The round-1 holes in oracle isolation, Tier 1's separate pinned clippy invocation, goal-body out-of-scope, the handoff token match, and keeping the prefix off the orchestrator are fixed. The replacement lint command and two of the new checks still fail on this repo's own fixture and launchers.

1. **`--workspace --lib --bins --test <id>` is a hard cargo error on the crates this feature has to run.** Cargo applies those filters per package and exits if a package has no target of that kind. The rust-tier fixture (`docs/features/rust-tier-rules/fixture/crate/Cargo.toml`) is lib-only, with `[[test]]` entries `g1` and `g2` and no bins, so `--bins` fails the clean reference before the sibling-oracle plant runs. On a multi-package workspace, `--test <id>` fails in every member that does not define that test (`no test target named …`). Step 8 cannot show a green scoped run with the command as written.
   **Fix:** Split the tail into `clippy --workspace --lib --bins` only for packages that have those targets, plus a second `clippy --offline --locked --test <id>` from the package that owns the oracle, and point the step 8 fixture at those two commands.

2. **An empty `tool_path` prepends the current directory.** The key is optional, but step 2 always describes `PATH="$GOAL_TOOL_PATH:$PATH"` and `PATH=$prefix:$PATH` inside `proof_exec`. An empty component is `.`. The proof `cd`s into the checkout, so a `git` or `cargo` planted there runs first. The "without `tool_path`" test still passes if the fixture has no `./cargo`.
   **Fix:** Prepend only when `GOAL_TOOL_PATH` / `PROOF_TOOL_PATH` is non-empty, and add a fixture where `./git` exists and is not the one that runs.

3. **The host-`git` test cannot fail.** `validate` rejects a tool directory that contains `git`, so a full `run-goal.sh` run never has a tool-dir `git` to resolve. A mistaken `export PATH` in the orchestrator still finds the host `git` and the log stays green.
   **Fix:** Drive the prefix at the `proof_exec` boundary with a logging `git` inside the tool directory, and keep the `validate` rejection as its own `goals.py` case.

4. **`claude-implement.sh --smoke` cannot show that Bash inherited `PATH`.** The smoke branch calls `run_pass` with the tool list `Read` and the prompt `Reply with exactly: PONG` (`scripts/claude-implement.sh` around the smoke block). No shell runs, so `command -v cargo-clippy` is never executed for DeepSeek or Haiku.
   **Fix:** Record a one-shot pass whose tool list includes `Bash` and whose prompt is `command -v cargo-clippy`, for both providers.

5. **Blanket allows under `tests/acceptance/` still hide the g8 findings.** The new grep is only on crate source roots, because a hit there would red a goal that cannot edit the oracle. `#![allow(clippy::pedantic)]` in an oracle overrides `-D warnings`, Tier 1's clippy then exits 0, and the grep never sees the file.
   **Fix:** Run that same grep on `tests/acceptance/` during Tier 1 only, and fail Tier 1 on a hit.

6. **`tool_path` is specified as a YAML list, and `goals.py` only parses a one-line flow list.** A block list is the natural spelling for long toolchain paths. `parse_yaml_subset` raises `unexpected indent` and exits before `validate` (`scripts/goals.py`).
   **Fix:** Document and test `tool_path: [/abs/bin]` on one line, and reject a block list with that parse error.

VERDICT: REVISE

### Architect's response

Accepted, 5 of 6; point 1 rejected, with evidence.

1. **Rejected.** Cargo 1.99.1 does not error on these filters.
   - On a scratch library-only crate with one `[[test]] g1`, `cargo clippy --offline --workspace --lib --bins --test
     g1 -- -D warnings` finishes, exit 0.
   - On Paladin (5 packages; `paladin-ids` has no bin; only the root package has `g8-m0-hygiene`),
     `--workspace --lib --bins --test g8-m0-hygiene` finishes, exit 0.
   - Cargo errors only when no package has the named test (`--test nope`: "available test targets: g1"), which is
     the wanted behaviour.
   - The rust-tier fixture's failure in my probe was offline dependency resolution, unrelated to the filters.
     Step 8 runs it through its own `run-plants.sh` setup.
2. **Accepted.** The prefix is applied only when non-empty, and a test has a planted `./git` and `./cargo` that must
   not run.
3. **Accepted.** The host-`git` test moves to the `proof_exec` boundary with a logging `git` in the tool dir. The
   `validate` rejection is its own case.
4. **Accepted.** The Bash-inheritance evidence uses a one-shot pass with `Bash` in the tool list, per provider, plus
   a test-only launcher flag if one is needed.
5. **Accepted.** Tier 1 runs the blanket-allow grep on `tests/acceptance/`. Individual allows in oracles stay
   permitted.
6. **Accepted.** `tool_path` uses the one-line flow list form, and a test pins both forms.

## Round 3 — Grok

I'll re-read the revised plan and check the last round's findings against the host code.The cargo target filter is the one prior finding that still looks open. I'll check it against the fixture and how Cargo selects targets.The cargo-filter objection from last round is withdrawn. The review log's cargo 1.99.1 runs (a lib-only crate, and Paladin with `paladin-ids` bin-less and the named test only on the root) show `--workspace --lib --bins --test <id>` exits 0, and errors only when no package has that test. The empty-prefix rule, the flow-list form, the Bash one-shot, and the Tier 1 acceptance grep are in the plan. Three holes remain.

1. **The `unwrap()` plant stays green on the fixture that is supposed to prove it.** `clippy::unwrap_used` is allow by default, and `-D warnings` does not promote allow-level lints. `docs/features/rust-tier-rules/fixture/crate/Cargo.toml` has no `[lints]` table, so step 8's clean reference and the planted `unwrap()` both pass the tail. The red bar never fires.
   **Fix:** Give that crate `[lints.clippy] unwrap_used = "warn"` (and `[lints] workspace = true` if it becomes a workspace member) before treating a red run as evidence.

2. **The stub allow does not cover the lints that hide the oracle.** Paladin's `[workspace.lints.clippy]` sets `panic = "deny"` (and `missing_docs = "warn"`) by name. A named deny beats a group `allow(clippy::restriction)`, and `allow(warnings)` does not touch a lint whose level is already deny. The trap is `panic!` in a public stub, so the library unit still fails clippy and the oracle is never linted — the g8 miss again. `unsafe_code = "forbid"` cannot be allowed; stubs must simply not use it.
   **Fix:** Put `clippy::panic`, `clippy::unwrap_used`, `clippy::expect_used`, and `missing_docs` on the stub allow itself, and require a Tier 1 clippy of the stub library to exit 0 before any oracle is judged.

3. **Tier 1 clippy omits the proof's environment, and the host-`git` test is specified as one run that `validate` will refuse.** The Tier 1 command is `"$CARGO" clippy --offline --locked --test <id> …` with no `RUSTC="$RUSTC"` and no `<envs>`. RUST.md's measured rule is that an exported `RUSTC` makes cargo use a different compiler than the version check. Separately, step 7 puts a logging `git` in the tool directory and then requires the host `git` calls of that same `run-goal.sh` to miss it, while also saying the probe is not run through `run-goal.sh` because `validate` rejects a tool directory that contains `git`.
   **Fix:** Run Tier 1 clippy and fmt under the same `<envs>` prefix as the proof, and split the `git` check into a `proof_exec` probe (`PROOF_TOOL_PATH` points at the logging `git`, the parent `git` does not) plus a `run-goal.sh` run whose `tool_path` still passes `validate`.

VERDICT: REVISE

### Architect's response

Accepted, 3 of 3.

1. **The `unwrap()` plant.** The fixture crate gains `[lints.clippy] unwrap_used = "warn"`, so `-D warnings` can turn
   the plant red. Without it the evidence is vacuous.
2. **Stub allows.** They now name `clippy::panic`, `unwrap_used`, `expect_used`, `todo`, `unimplemented`,
   `missing_docs` and `unreachable_pub` individually, beside the groups.
   - Tier 1 requires `clippy --workspace --lib --bins -D warnings` to exit 0 on the stubs before any oracle is
     judged.
   - Stubs never use `unsafe`.
3. **Tier 1 environment and the host-`git` test.**
   - Tier 1 clippy and fmt run under the proof's own `<envs>` prefix.
   - The host-scope test is split in two:
     - (a) a `proof_exec`-boundary probe with a logging `git`;
     - (b) a full `run-goal.sh` run whose `tool_path` passes `validate`. It holds logging `date` and `mktemp`
       wrappers, which the host calls on every run, and the log must stay empty.

## Round 4 — Grok

I'll re-read the revised plan and check the last round's three findings against the fixture and the lint rules.The three earlier fixes are in the text. I'll check whether the new host-`PATH` test can actually see a leak, and whether the stub allow still loses to a named deny.Round 3's three fixes are in the plan. I'll re-read the revised plan and the fixture proof builder to see whether the new evidence steps can still fail for the wrong reason.Step 8 still plants a non-compiling sibling and adds the lint tail to “its proof.” I’ll check whether that proof is the shared fixture recipe.Round 3's three fixes are in the plan, and the cargo 1.99.1 filter objection stays withdrawn. The stub allow names the trap lints, the stub library must exit 0 under `clippy --lib --bins -- -D warnings` before any oracle is judged, Tier 1 runs under the proof `<envs>` prefix, the host-scope check is split into a `proof_exec` logging `git` and a `validate`-clean `run-goal.sh` with logging `date` and `mktemp`, and the fixture is supposed to set `unwrap_used = "warn"`.

Two evidence holes in step 8 are still open, plus one instruction conflict.

1. **The sibling oracle can redden the clean reference through `fmt --all`.** Step 8 says the sibling "does not compile yet" and must not turn the clean reference red, while the tail runs `cargo fmt --all --check`. The plan's own rule is that rustfmt only parses, and that `fmt --all` is safe only because every committed oracle parses and is rustfmt-clean. A sibling that does not parse fails `fmt --all` even when `--test <id>` never builds that file, so a red clean run does not disprove the scoping.
   **Fix:** Make the sibling a type error that still parses and is rustfmt-clean, registered as a `[[test]]` the proof does not name.

2. **The lint tail is attached to the shared fixture recipe, which cannot find `cargo-clippy`.** `recipe()` in `docs/features/rust-tier-rules/fixture/run-plants.sh` is the proof for every locked row (`row_2b`, `row_clean`, `row_t1`, …). That script never puts the toolchain bin on `PATH`, and `proof_exec` sets `CARGO_HOME` to the deps dir, so cargo looks for `cargo-clippy` on `PATH` and `$CARGO_HOME/bin` and finds neither (assumption 1: the pinned toolchain is not on the host `PATH`). Appending the tail there turns today's green rows red with "no such command" and rewrites the command `docs/features/rust-tier-rules/EVIDENCE.md` locked. The same row also fails to prove the plant: an `unwrap()` on a path the test step already fails never reaches clippy, and an unused helper goes red on `dead_code` under `-D warnings`.
   **Fix:** Add new plant rows only, and leave `recipe()` and the existing verdicts unchanged. The new row prepends `$TC` on `PATH` (or sets `PROOF_TOOL_PATH`), and the `unwrap()` sits on a path whose test step still exits 0, so only `clippy::unwrap_used` is red.

3. **The new look-for rejects the oracle allows Tier 1 permits.** The look-for says an individual `#[allow]` or `#[expect]` of a lint the plan denies, outside a `#[cfg(test)]` item, is a review finding. Tier 1 says individual oracle allows such as `clippy::panic` are allowed. Acceptance oracles are files under `tests/acceptance/`, not `#[cfg(test)]` modules, so a reviewer following the look-for fails an oracle the gate is specified to pass.
   **Fix:** Scope the look-for to crate source roots. An oracle may allow one named lint, and Tier 1 does not fail on that.

VERDICT: REVISE

### Architect's response

Accepted, 3 of 3.

1. **The sibling oracle.** It now parses and is rustfmt-clean but fails to type-check (it calls a missing function),
   so only `--test <id>` scoping is being tested, not `fmt --all`.
2. **The fixture recipe.**
   - New rows only. `recipe()` and the locked rust-tier-rules verdicts are unchanged.
   - A separate `lint_recipe()` runs with `PROOF_TOOL_PATH=$TC`.
   - The lint table lives in a copy of the crate used by the new rows.
   - The `unwrap()` row must be red at clippy only, with `unwrap_used` the sole diagnostic: no `dead_code`, and no
     earlier failing step.
3. **The look-for bullet.** It is scoped to crate source roots. A single named allow in an oracle (the Architect's
   file) is fine for both Tier 1 and review.

## Round 5 — Grok

Round 4 left three holes in the evidence steps. I'll re-read the revised plan and check those against the fixture proof builder.The three round-4 fixes are in the text. I'll check the new evidence rows against the fixture recipe and the sandbox exec rules so a green run can't pass for the wrong reason.Round 4's three fixes are in the plan. The sibling oracle parses and is rustfmt-clean, the lint tail is a new `lint_recipe()` with `PROOF_TOOL_PATH=$TC` and the lint table lives only on that row's crate copy, the `unwrap()` row must fail at clippy alone with `unwrap_used` as its only diagnostic, and the look-for bullet is limited to crate source roots. An oracle may allow one named lint.

One new hole remains in that evidence bar.

1. **The clean row cannot go green on the reference implementation.** `lint_recipe()` runs `clippy -- -D warnings`, which denies every warn-level lint, including clippy's built-in default warns, not only `unwrap_used`. `docs/features/rust-tier-rules/fixture/impl/lib.rs` defines `show` as `format!("{}", x)`. That is `clippy::uninlined_format_args`, warn by default, so the clean row is red before any plant. The sibling row's "must not turn the clean row red" is then unmeasurable.
   **Fix:** On the new-row copy only, make the reference clean under clippy's default warns before treating a green run as evidence. `show` becomes `format!("{x}")`. Leave the shared `impl/lib.rs` and the locked rust-tier rows alone.

VERDICT: REVISE

### Architect's response

**Accepted.** The new rows' copy of the reference is made clean under clippy's default warn-level lints
(`format!("{x}")`) and confirmed with the pinned clippy before any row counts. The shared `impl/lib.rs` is untouched.

**MAX_ROUNDS (5) reached without APPROVED.**
- Every finding across the 5 rounds was accepted, except round 2's cargo-filter claim. That was rejected with
  cargo 1.99.1 evidence, and Grok withdrew it in round 3.
- Round 5's only point is fixed above, but Grok has not seen the fix.
- This goes to the owner: sign off, or one confirming round.

Owner decision (2026-11-05): sign off; build.

## Build review round 1 — Opus (fresh headless session, plan + full diff)

The 10 FIX lines, in short form; the full output is kept in the session scratchpad:

1. `goals.py` accepts a tool folder inside the target repo. The implementer can write there, so a planted `cargo-clippy`, `grep` or `mktemp` would run first, and on the host too.
2. `TOOL_PATH_UNREADABLE` copies only the temp areas, not the sandbox's secret-path or house-cache denials.
3. The test tool folders under `scripts/tests/` race the `cp -R "$HERE/."` that other tests run in parallel.
4. The "empty prefix adds nothing" check could never fail.
5. The planted `./cargo` half of the check was empty, because nothing called bare `cargo`.
6. The lint-line forms from step 3 were untested, and the check had no near-miss cases.
7. The "no tool_path" checks depend on the developer's own `PATH`.
8. The sibling row never confirms that g3 fails to type-check.
9. The rule against an `#[allow]` of a denied lint sits only in RUST.md, which the goal reviewer never reads.
10. The deviation is not logged as an Architect decision.

VERDICT: REVISE

### Architect's response

All 10 accepted and fixed:

1. `validate` rejects a folder inside GOALS.md's folder.
2. `read_denied()` in `lib/proof-sandbox.py` is now the one list; the most specific match names the folder.
3. Test tool folders live in `<house>/.test-tools/` (gitignored), outside `scripts/`.
4. The empty-prefix check runs from inside the folder that holds the logging `./git`.
5. The proof also runs bare `cargo --version`.
6. The lint-line check gains a seven-form table and five near misses.
7. The test sets a fixed `PATH`.
8. The sibling row gains a control that requires `error[E0425]`.
9. RUST.md now requires a line about this in every goal body under the gate.
10. Logged in the journal.

The plants were rerun with two new ones: removing the repo check, and removing the deny-list check.

## Build review round 2 — Opus (confirming; fresh headless session)

All 10 round-1 fixes were checked and none broke anything. Two FIX lines remain, both marked minor and non-blocking:

1. `.test-tools/toolpath-*` sits outside the per-test folders that `run-all.sh` checks for leaks, so a killed test's folder is never reported.
2. The fixed `PATH` keeps git's own folder. A Homebrew bin there may also hold `cargo-clippy`, and the test would then fail closed.

VERDICT: APPROVED

### Architect's response

Both fixed before commit:

1. `run-all.sh` gives each test its own `CW_TEST_TOOLS_ROOT` under `.test-tools/<run>/<test>`, reports anything left there as a leak, and removes it.
2. git and python3 now reach the test through links in a folder the test owns.

`run-all.sh -j 8`: 45 scripts, 0 failures, and `.test-tools/` is empty afterwards.
