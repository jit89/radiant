# Evidence: rust-toolchain-gates

PLAN.md steps 7 and 8, run 2026-11-05 on rustc and cargo 1.99.1
(`58cf8f9c3 2026-10-13`), macOS, the house's own proof sandbox.

## Step 7: the house tests (no Rust toolchain)

`scripts/tests/run-all.sh -j 8`: 45 scripts, 0 failures. New or extended:

- `goals-contract-test.sh`: 14 `tool_path` cases. Each `validate` rejection in
  step 1, plus a folder inside the target repo, a temp area and the house
  cache (see "Deviation" below), a block list, two dirs, and `meta` with and
  without the key.
- `tool-path-test.sh`: 19 cases through `run-goal.sh` and `proof_exec`, under
  a fixed `PATH`. A fake `cargo` that finds `cargo-<sub>` on `PATH` only. The
  implementer, proof and reviewer each resolve into the tool folder; the
  host's `date` and `mktemp` never do; a planted `./git` and `./cargo` (the
  proof calls both bare) never run without the key; the handoff lines; resume
  drift; both `proof_exec` boundary checks (the empty-prefix one run from the
  folder holding the logging `./git`); the lint-line match over seven forms
  and five near misses.
- Test tool folders live in `<house>/.test-tools/` (gitignored): outside
  `scripts/`, which other tests copy while these run, and outside every
  folder the sandbox cannot read.
- `parallel-walk-test.sh`: `worktree_setup` under the sandbox runs
  `<tool>/cargo clippy`, which finds `cargo-clippy` through `tool_path` only,
  and the walk completes.

### Plants

Each plant was applied to the real house file, `tool-path-test.sh` and
`goals-contract-test.sh` run, the file restored (`cmp` checked each applied).
Second pass, after the Opus review's fixes:

| Plant | Failing checks |
|---|---|
| `export PATH="$GOAL_TOOL_PATH:$PATH"` in the host | 4 (the host's `date` logged; with an empty key, `.` led `PATH` and `./git` ran) |
| `proof_exec` adds no prefix | 4 |
| `proof_exec` adds the prefix unconditionally (empty → `.`) | 2 (planted `./git` ran; the boundary check logged) |
| implementer launch without `GOAL_PATH_ENV` | 1 |
| reviewer launch without `GOAL_PATH_ENV` | 1 |
| no `read_denied()` check in `validate` | 2 (temp area, house cache) |
| no repo-root check in `validate` | 1 |
| no shadowed-binary check in `validate` | 1 |
| lint-line regex never matches | 2 (handoff, form table) |
| `meta` drops `tool_path` | 6 |

All 10 caught. (The first pass, before the review, had 9 plants, all caught;
its empty-prefix plant failed only 1 check, which the review showed was the
only one that could.)

## Step 8: real evidence

### The implementer's Bash tool inherits `PATH`

`claude-implement.sh --probe-path` (new, evidence only: the `--smoke` pass with
`Read,Bash` and the prompt "Run `command -v cargo-clippy || echo none` with
the Bash tool and reply with its output only"), launched as `run-goal.sh`
launches it, `env PATH="<toolchain bin>:$PATH"`:

| Provider | `tool_path` | Reply |
|---|---|---|
| DeepSeek (deepseek-flash) | set | `/Users/hyde/.local/rust/rustup/toolchains/1.99.1-aarch64-apple-darwin/bin/cargo-clippy` |
| Haiku (claude-haiku-5-5) | set | `/Users/hyde/.local/rust/rustup/toolchains/1.99.1-aarch64-apple-darwin/bin/cargo-clippy` |
| DeepSeek | not set | `none` |

Claude Code's Bash tool, inside its own sandbox, keeps the `PATH` it was
started with. Cost: $0.0006 + $0.0020 + $0.0006.

### The rust-tier-rules fixture: `run-plants.sh lint`

New rows only (`row_lint`, not in `ROWS`, so `all` is unchanged). Each runs
through `proof_exec` under the sandbox, with `lint_recipe()` (the full recipe
plus RUST.md's lint tail) on a copy of the implementation with
`[lints.clippy] unwrap_used = "warn"`, rustfmt'd. `impl/lib.rs` and the locked
rows are untouched.

```
lint-no-tool-path  rc=101  VERDICT no tool_path: red, cargo finds no clippy
lint-baseline      rc=0    (the recipe without the tail; denials baseline)
lint-clean         rc=0    VERDICT clean: green, tree unchanged
lint-unwrap        rc=101  VERDICT unwrap: red at clippy only, unwrap_used the sole diagnostic
lint-sibling       rc=0    (g1's lint proof, with g3 in the crate)
lint-sibling-g3    rc=101  VERDICT sibling: g3 fails E0425 on its own, and g1's lint proof stays green
```

- **No `tool_path`:** "no such command", item 39's M0 failure, reproduced in
  the fixture (`PROOF_TOOL_PATH` unset; `CARGO_HOME` is the deps folder).
- **Clean:** green with `PROOF_TOOL_PATH` set to the toolchain bin. The
  reference was already clean under clippy's defaults at 1.99.1 (the plan's
  `format!("{}", x)` example did not apply); only rustfmt changed it.
- **The first clean run was red, rightly:** the fixture oracle's
  `catch_unwind(…).unwrap_err()` hit the lint table's `unwrap_used`. That is
  the failure the Tier 1 oracle lint exists for (Paladin g8). The lint copy
  then gives its oracles `#![allow(clippy::unwrap_used)]`, the one named lint
  RUST.md allows an oracle.
- **`unwrap`:** the test step passes (`test result: ok`), then clippy fails
  with `clippy::unwrap_used` as its only diagnostic.
- **Sibling:** a `[[test]] g3` calling a function that does not exist does
  not reach `--test g1`, and `fmt --all` passes over it. The control,
  `clippy --test g3` on the same copy, fails with `error[E0425]`, so the
  green is not an accident of g3 compiling.

**Denials**, `lint-clean` against `lint-baseline`: the same kinds from the
proof's own processes (`cargo`, `cc`, `ld`, `xcrun`; the tail repeats them).
The only line in the clean run and not the baseline is
`analyticsagent deny(1) mach-lookup com.apple.analyticsd.agent`, a system
daemon outside the proof caught by the time-windowed log query. No new
denials for the proof. (A first run overlapped `run-all.sh` and logged the
suite's own sandbox self-tests; it was rerun on a quiet machine.)

**Time.** On a quiet machine, warm: the recipe alone 4 s, with the lint tail
5–6 s. One run straight after `run-all.sh -j 8` took about 310 s for each
passing row, while cargo's own "Finished" stayed at 3–9 s. So the time went
outside cargo, inside `proof_exec`. It did not recur on the next run, and it
was not traced. If it shows up in a walk, it is a `proof_exec` issue, not a
lint-tail issue.

## Deviation from the plan

PLAN.md says "No sandbox change. Reads are allowed everywhere." Not quite:
`lib/proof-sandbox.py` denies reads under `/tmp`, `/private/tmp` and
`/private/var/folders`, the secret paths and the house cache, re-allowing only
the proof's own trees. A tool folder there fails every proof with "Operation
not permitted" (found when the first `tool-path-test.sh` kept its tool folder
under `$TMPDIR`). The sandbox stays unchanged. `lib/proof-sandbox.py` gains
`read_denied()`, the one list, and `validate` rejects a `tool_path` under any
of it (by real path).

Added after the Opus review: `validate` also rejects a folder inside the
target repo (GOALS.md's folder). The implementer can write there, and a
planted `cargo-clippy` or `grep` would run first in every proof, and a planted
`mktemp` in the host-side launchers. GOAL-FORMAT.md and RUST.md state both
rules. Journal: `ARCHITECT build: deviation from the signed plan`.

Also: the `validate` cases live in `goals-contract-test.sh` as the plan says;
`tool-path-test.sh` has the rest.
