# Plan: rust-toolchain-gates (FUTURE-WORK items 39 and 40)
_Locked via crucible — by Claude + the owner, 2026-11-05; revised after Grok round 1 (Q3 re-decided by the owner)_

## Goal

Every process a goal runs sees the target's pinned tools first on `PATH`: the implementer and its commands, the
host proof, proof-fix rounds, mutation runs, the reviewer, `worktree_setup` and wave integration proofs. The host's
own orchestration commands do not.

A Rust plan may also opt into a lint and format step in its proofs:
- `cargo clippy --workspace --lib --bins --test <id> -- -D warnings`;
- `cargo fmt --all --check`.

The Architect's oracle files are held to that same gate in Tier 1, with the pinned tools and against the stubs.

**Evidence that this is needed:** in the Paladin M0 walk (`~/Paladin`, journal `docs/journal/m0-foundation.md`):
- Four implementer passes in a row (g3, g4, g5, g6) reported "`cargo clippy`/`cargo fmt` unavailable". Cargo looks
  for subcommands on `PATH` and in `$CARGO_HOME/bin`, not in its own folder, and the pinned toolchain was not on
  `PATH`.
- About 39 clippy errors and 137 rustfmt diffs reached `main` unseen.
- The cleanup goal g8 then blocked on 4 clippy findings in the Architect's own oracle. Tier 1 had missed them:
  the stub test failed first in the `&&` chain, and clippy never compiled the oracle once a library unit was red.

## Approach

1. **`goals.py`: a new top-level key, `tool_path:`.** It is optional, and holds a non-empty list of absolute directory
   paths.
   - It is written as a one-line flow list, `tool_path: [/abs/one, /abs/two]`, the only list form
     `parse_yaml_subset` reads. A block list fails with its existing `unexpected indent` error. GOAL-FORMAT.md
     documents the flow form, and a test pins both forms.
   - `validate` rejects:
     - a value that is not a list, or an empty list;
     - an entry that is not a string;
     - a relative path;
     - a path outside `SAFE` (`[A-Za-z0-9._/@+-]`, so no `:` and no spaces);
     - a path that is not an existing directory;
     - a directory holding an executable named `bash`, `sh`, `env`, `git`, `python3` or `shasum`, which the proof
       and the host rely on.
   - `meta` prints it, or `null` when absent.
2. **`run-goal.sh` and `lib/proof.sh` scope the prefix to child processes only.**
   - After `goals-base.md` is written (BASE_SHA's GOALS.md, where `PROOF` and `PLAN_PATH` are read), set
     `GOAL_TOOL_PATH` to the `:`-joined `tool_path`, and do not export it.
   - Three places prepend it, and only those: the implementer launch (`env PATH="$GOAL_TOOL_PATH:$PATH"
     "$IMPL_LAUNCHER" …`); the reviewer launch, the same way; and `proof_exec`, which adds `PATH=$prefix:$PATH` to
     its `envs`. `proof_exec` serves the host proof, fix rounds and mutation runs; `lib/proof.sh` reads the prefix
     from a `PROOF_TOOL_PATH` variable its callers set.
   - **The prefix is applied only when non-empty.** An empty `PATH` component means `.`, and a proof runs inside the
     checkout, so an unconditional `PATH="$prefix:$PATH"` would let a planted `./git` or `./cargo` run first.
     Without `tool_path`, the environment is exactly as today.
   - The host's own `git`, `python3` and `shasum` calls keep the host's `PATH`.
   - BASE_SHA's copy is the source, so a resume uses the same value. GOALS.md is already contract
     (`contract_drift`), so a mid-goal edit is a tamper stop.
3. **`run-goal.sh` tells the implementer.**
   - When `tool_path` is set, the handoff gains `- Tool path (first on PATH for you, the proof and the reviewer):
     \`<dirs>\``.
   - When the proof invokes cargo's `clippy` or `fmt` subcommand, the handoff gains "Run the proof's lint and format
     steps yourself before reporting DONE; they are part of the proof." The match is on the subcommand token after
     a cargo invocation: `cargo`, `"$CARGO"`, `$CARGO`, `${CARGO}`, or an absolute path ending in `/cargo`. It does
     not look for the substring `cargo clippy`.
4. **`lib/wave-walk.sh`** reads `tool_path` from the walk's GOALS.md at walk start. It sets `PROOF_TOOL_PATH` for the
   `worktree_setup` and integration proof runs it starts through `proof_exec`, and passes nothing else. Each goal's
   `run-goal.sh --worktree` reads its own frozen copy (step 2).
5. **`skills/to-goals/RUST.md`.**
   - **`tool_path`:** set it to `dirname "$CARGO"` whenever the pinned toolchain is not on the host's `PATH`.
     Without it, cargo cannot find `clippy` or `fmt`.
   - **The opt-in lint tail.** A plan opts in in its PLAN.md. The proof appends, after the test step:

     ```
     && <envs> "$CARGO" clippy --offline --locked --workspace --lib --bins --test <id> -- -D warnings
     && <envs> "$CARGO" fmt --all --check
     && ( grep -rnE '#!?\[(cfg_attr\([^]]*)?(allow|expect)\((warnings|clippy::(all|pedantic|restriction|style|correctness|suspicious|complexity|perf|nursery|cargo))' --include='*.rs' <source roots>; test $? -eq 1 )
     ```

     - `<envs>` is the recipe's existing environment prefix, and `<source roots>` are the plan's crate source
       folders, never `tests/acceptance/`.
     - **Why not `--all-targets`:** it type-checks every `[[test]]`, including later goals' oracles, which do not
       compile yet. The implementer cannot edit those, so every early goal would go red. That is GOAL-FORMAT.md's
       registration rule, and Paladin's g1 END record shows the failure.
     - **What it covers:** all library and binary code in the workspace, plus this goal's own oracle.
     - **What it does not cover:** `#[cfg(test)]` unit-test modules and other goals' oracles. Tier 1 covers the
       oracles. Unit-test modules are a known gap, accepted by the owner.
     - **`fmt --all` is safe:** rustfmt parses, it does not type-check, and the Architect commits every oracle
       rustfmt-clean.
   - **What counts as a warning** is the plan's lint table, `[workspace.lints]`, with every package carrying
     `[lints] workspace = true`. Tier 1 checks that each workspace member has it. Without it the table does nothing
     (`docs/features/rust-tier-rules/RESEARCH.md`).
   - **Opting in partway through** a project needs a cleanup goal first, as Paladin's g8 did.
   - **Out of scope in every opted-in goal body,** not just in RUST.md. The reviewer reads the goal body:
     `clippy.toml`, `.clippy.toml`, `rustfmt.toml`, `.rustfmt.toml`, every `Cargo.toml`'s `[lints]` and
     `[workspace.lints]` tables, `Cargo.lock`, `vendor/` and `.cargo/`.
   - **New "Look for" bullet,** scoped to crate source roots and never `tests/acceptance/`: an `#[allow]` or
     `#[expect]` of a lint the plan denies, outside a `#[cfg(test)]` item. The proof's grep covers blanket and group
     allows only; individual lints are a review finding. An oracle may allow one named lint, such as `clippy::panic`
     for its trap assertions. That is the Architect's file, and neither Tier 1 nor review fails it.
   - **Tier 1 with the lint tail.**
     - **Stub allows.** Stubs carry `#![allow(warnings, clippy::all, clippy::pedantic, clippy::restriction,
       clippy::panic, clippy::unwrap_used, clippy::expect_used, clippy::todo, clippy::unimplemented, missing_docs,
       unreachable_pub)]` at each stubbed crate root.
       - It names the trap-relevant lints individually as well as by group, so a plan's named `deny` cannot win over
         a group allow.
       - A trap stub's `panic!` must not fail the library unit and hide the oracle from clippy.
       - Stubs never use `unsafe`: `forbid` cannot be allowed.
     - **The stub library must lint clean first.** `<envs> "$CARGO" clippy --offline --locked --workspace --lib
       --bins -- -D warnings` exits 0 against the stubs before any oracle is judged. If it does not, fix the stubs
       first.
     - **Then lint every oracle,** separately from the proof's `&&` chain and under the proof's own `<envs>` prefix
       (`RUSTC="$RUSTC"`, `CARGO_TARGET_DIR`, the overflow-check variables), with `tool_path` on `PATH`. Run
       `<envs> "$CARGO" clippy --offline --locked --test <id> --message-format=json -- -D warnings` for **every**
       oracle. Any diagnostic whose primary span is under `tests/acceptance/` fails Tier 1.
     - Also run the proof's blanket-allow grep on `tests/acceptance/`; any hit fails Tier 1. Otherwise an oracle's
       own `#![allow(clippy::pedantic)]` would silence the check above. Individual lint allows in oracles, such as
       `clippy::panic`, are allowed.
     - Then run `<envs> "$CARGO" fmt -- --check <every oracle file>`.
     - Where a reference implementation exists (a prior attempt, a scratch), the full proof must exit 0 against it.
   - **Timeout:** the proof timeout (`PROOF_TIMEOUT`, default 600 s) must cover a cold clippy run of the workspace
     libraries plus this goal's test target. Mutation runs repeat it warm. A plan whose cold run comes near the
     limit raises `PROOF_TIMEOUT` in its walk instructions. Item 38, which warms caches, stays future work.
6. **`skills/to-goals/GOAL-FORMAT.md` and `SKILL.md`:**
   - Document `tool_path` in the YAML preamble section.
   - In step 4.2 (Tier 1), add one line pointing to RUST.md's oracle-lint rule for proofs with a lint step.
7. **Tests in `scripts/tests/`** (in `run-all.sh`, no Rust toolchain needed).
   - **`goals-contract-test.sh`:** each `validate` rejection in step 1, including a tool dir holding a fake `git`,
     plus a valid list and its `meta` output.
   - **`tool-path-test.sh`.** A fixture target whose `tool_path` holds a fake `cargo`. The fake `cargo <sub>` runs
     `cargo-<sub>`, found by searching `PATH` only, and fails "no such command" if it is found solely under
     `$CARGO_HOME/bin`. The same dir holds `cargo-clippy` and `cargo-fmt` stubs. Cases:
     - **Proof through `proof_exec`:** a proof of `"$CARGO" clippy && "$CARGO" fmt`, run through `proof_exec`
       (which sets `CARGO_HOME` to its empty deps dir), passes. Without `tool_path` it fails "no such command",
       the measured M0 failure.
     - **Implementer:** the fake implementer (the `implement-test.sh` pattern) records `command -v cargo-clippy`.
       The recorded path is the tool dir's.
     - **Reviewer:** the fake reviewer records the same, with the same result.
     - **Prefix scope, as two checks:**
       - **(a) At the `proof_exec` boundary.** `PROOF_TOOL_PATH` points at a dir holding a logging `git`. A proof
         running `git --version` hits it. The calling shell's own `git --version` does not.
       - **(b) Through a full `run-goal.sh` run** whose `tool_path` passes `validate`. The dir holds logging
         wrappers for `date` and `mktemp`, which `validate` allows and which the host calls on every run (`utc`,
         temp files). Each wrapper logs, then execs the real one.
         - The fake implementer, proof and reviewer never call them.
         - After a DONE run the log must be empty. Any entry means the prefix leaked into the host.
       - The `validate` rejection of a dir holding `git` is its own `goals-contract-test.sh` case.
     - **No `tool_path`:** the checkout holds an executable `./git` and `./cargo`, and neither runs, in a proof or
       for the implementer. This guards against the empty-prefix `.` component.
     - **Handoff lines:** the handoff has the tool-path line. It has the lint line for a proof using
       `"$CARGO" clippy`, and lacks it for a proof without clippy or fmt.
     - **Resume:** a resume after `tool_path` was edited mid-goal stops as contract drift.
   - **Parallel walk:** one case in the parallel-walk test pattern; `worktree_setup` runs the fake `cargo clippy`
     and succeeds.
8. **Real evidence, recorded in `EVIDENCE.md`.** These are run once, outside `run-all`.
   - **The implementer's Bash tool inherits `PATH`.** A one-shot pass through `claude-implement.sh`'s own launch
     path, once with each provider (DeepSeek and Haiku), with the tool list including `Bash` and the prompt "Run
     `command -v cargo-clippy` and reply with its output". `tool_path` is set, and the reply is recorded.
     - The existing `--smoke` cannot show this: it allows only `Read` and replies `PONG`.
     - The fake-implementer test cannot show it either, because Claude Code's Bash tool could reset `PATH`.
     - If the launcher has no way to run such a pass, the build adds a test-only flag for it.
   - **The rust-tier-rules fixture** (`docs/features/rust-tier-rules/fixture`) gains:
     - **New rows only.** `recipe()` and the existing rows and verdicts locked in rust-tier-rules' EVIDENCE.md stay
       unchanged.
     - **A new `lint_recipe()`:** the existing recipe plus the lint tail. It runs with `PROOF_TOOL_PATH` set to the
       toolchain bin (`$TC`). Without it cargo cannot find `cargo-clippy` under `proof_exec`'s `CARGO_HOME`, which
       is the item 39 failure itself.
     - **A lint table for the fixture,** used by the new rows only, through a copy of the crate:
       `[lints.clippy] unwrap_used = "warn"` (and `[lints] workspace = true` if it becomes a workspace member).
       `unwrap_used` is allow by default, and `-D warnings` promotes only warn-level lints, so without this the
       plant could not go red.
     - **A clean row:** the reference implementation plus `lint_recipe()` is green.
       - `-D warnings` also denies clippy's default warn-level lints. So the new rows' copy of the reference is
         first made clean under them: for example, `show`'s `format!("{}", x)` becomes `format!("{x}")`
         (`uninlined_format_args`).
       - The pinned clippy confirms the copy is clean before any row counts as evidence.
       - The shared `impl/lib.rs` and the locked rust-tier rows are untouched.
     - **An `unwrap()` row:** an `unwrap()` on a path whose test step still exits 0. It must be red at clippy only,
       with `clippy::unwrap_used` the sole diagnostic: no `dead_code`, and no earlier failing step.
     - **A sibling-oracle row:** a second `[[test]]` that the proof does not name. It parses and is rustfmt-clean,
       but does not type-check against the reference, for example by calling a function that does not exist. It
       must not turn the clean row red, which proves the `--test <id>` scoping without involving `fmt --all`.
     - `run-plants.sh` output is recorded, with the proof sandbox denials diffed against a run without the lint
       tail. No new denials is the bar.
9. **`docs/FUTURE-WORK.md`:** mark items 39 and 40, with the addendum, done only once steps 7 and 8 have passed, and
   point them at this feature's EVIDENCE.md.

## Key decisions & tradeoffs

- **Q1 (owner):** `tool_path` is a GOALS.md key, not `PATH=` inside each proof string. The proof-string form reaches
  neither the implementer's own commands nor the reviewer, and keeps the two in step only by convention, which is
  how M0 drifted.
- **Q2 (owner):** the gate denies every warning (`-D warnings`), and the plan's lint table decides what is a warning.
  A deny-list-only gate lets pedantic and style debt build up, and its list must be kept in step with the plan in
  two places.
- **Q3 (owner, re-decided after Grok round 1):** `--workspace --lib --bins --test <id>`, not `--all-targets`.
  - All production code is still gated workspace-wide. Of the oracles, the proof lints only this goal's own; the
    Architect lints every oracle in Tier 1.
  - The original `--all-targets` would compile later goals' not-yet-compiling oracles and make early goals
    unpassable.
  - Accepted gap: `#[cfg(test)]` unit-test modules are not linted by proofs.
- **Only goal processes get the prefix (Grok round 1).** The host keeps its own `PATH`. A tool dir can never shadow
  the orchestrator's `git` or `python3`, and `validate` refuses a dir that would shadow them in the proof.
- **Read from BASE_SHA's GOALS.md,** like `PROOF`.
- **No sandbox change.** Reads are allowed everywhere. The real-toolchain run diffs denials to confirm this.

## Assumptions

1. The pinned toolchain must not be put on the shell's `PATH` globally. Source: the owner's global CLAUDE.md, and
   this session's rustup under `~/.local/rust`.
2. `claude-implement.sh`, `claude-goal-review.sh` and `proof_exec` pass their caller's environment through.
   `PATH` survives into Claude Code's Bash tool; step 8 verifies this.
3. `proof_exec` sets `CARGO_HOME=$deps/cargo`, so cargo cannot find subcommands through `$CARGO_HOME/bin`. `PATH` is
   the only route. Source: `lib/proof.sh`.
4. The RUST.md anti-tamper rules stay as they are: `CARGO_TARGET_DIR`, `--locked`, the overflow-check variables and
   the unset list.
5. The lint gate stays opt-in. C, TypeScript, Python and existing Rust targets are unaffected.

## Risks / open questions

- **A toolchain upgrade under `-D warnings`.** A new lint in a newer clippy turns every goal red. RUST.md's "After
  an upgrade" section gains a line: re-run the lint tail on `main`, and land a cleanup goal before the next walk.
- **The blanket-allow grep is textual.** A macro-generated `allow` escapes it. The reviewer's look-for bullet is the
  backstop.
- **Cold clippy against the timeout** on large workspaces; see step 5.

## Out of scope

- FUTURE-WORK items 37 (`/walk-status`), 38 (warm Rust caches) and 41 (self-review gate).
- A per-crate lint gate.
- Linting unit-test modules in proofs.
- Changing Paladin. Its M1 cut adopts `tool_path` and the lint tail.
