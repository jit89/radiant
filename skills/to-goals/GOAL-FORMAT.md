# GOALS.md format

One file at the **target repo root**. YAML preamble is what Phase 5
will parse. Markdown bodies are for humans and for the implementer.

Do not publish to a tracker. Do not split into per-goal files.

## Shape

````md
# Goals: <task>
_Cut from PLAN.md — signed <date>_

```yaml
plan: PLAN.md
log: PLAN-REVIEW-LOG.md
journal: docs/journal/<slug>.md
goals:
  - id: g1-store
    title: Persist inbound mail
    blocked_by: []
    conflicts_with: []
    area: mailer/inbound
    proof: pnpm test tests/acceptance/g1-store.test.ts
    oracle: tests/acceptance/g1-store.test.ts
    status: ready
  - id: g2-ack
    title: Label-ack after enqueue
    blocked_by: [g1-store]
    conflicts_with: []
    area: mailer/inbound
    proof: pnpm test tests/acceptance/g2-ack.test.ts
    oracle: tests/acceptance/g2-ack.test.ts
    status: blocked
```

## g1-store — Persist inbound mail

**What it delivers:** <end-to-end behaviour, user-facing — not a file list>

**Blocked by:** None — can start immediately.

**Conflicts with:** None.

**Seams:** <pre-agreed TDD seams; the implementer must not wait to confirm these>

**Case table:**

| input | expected |
|-------|----------|
| <concrete> | <concrete> |

**Acceptance edits (applied, read-only):** <edits the Architect already made under `tests/acceptance/` for this goal — file:line, old → new — or None>

**Edits owned:** <files outside `tests/acceptance/` this goal must change because an acceptance assertion pins them (config, packaging, unit tests), or None>

**Out of scope:** <bounds + ceilings that need a ponytail comment>

**Oracle:** `tests/acceptance/g1-store.test.ts` (read-only to the implementer)
**Proof:** `pnpm test tests/acceptance/g1-store.test.ts`
````

If the target has no test harness, set `oracle: inline` and `proof: (case table)`.
The case table in the body *is* the oracle.

`worktree_setup:` (optional) is one shell command that makes a fresh checkout able to run the proofs: `npm ci`, `uv sync --frozen`. A parallel walk runs it in each goal's new worktree before dispatch (which has no ignored `node_modules` or `.venv`, and the implementer's sandbox has no network) and in the scratch worktree where each finished goal is merged and proved, on the host under the proof sandbox: with network, credential variables stripped, writing only that checkout and the walk's dependency folder (npm, uv, pip, pnpm, Cargo and Go caches point there; proofs may only read it). It must leave only ignored files behind. Omit it when a clean checkout already runs every proof (a C project built by the proof itself).

`proof_network:` (optional) is `loopback` or `true`. Every proof runs under the proof sandbox with **no network at all**, loopback included, unless this key says otherwise for the whole walk: `loopback` lets proofs bind and connect on 127.0.0.1 and ::1, which also lets them reach every loopback service on the machine and, if a server binds all interfaces, be reached from the LAN; `true` opens the full network. Leave it out unless a proof needs it, and say why in the plan. No live `.env` may sit in any checkout of the repo (a walk stops `secrets-in-checkout`): secrets live in `~/.config/cw-secrets/<project>/`.

`tool_path:` (optional) is a one-line flow list of absolute directories, `tool_path: [/abs/one, /abs/two]` (goals.py reads no block list). They lead `PATH` for the goal's own processes only: the implementer, every proof (host, fix rounds, mutations, `worktree_setup`, integration) and the reviewer; the host's own commands keep its `PATH`. Use it when a proof's tool finds helpers through `PATH` rather than by the absolute path the proof names: a pinned Rust toolchain off `PATH` needs its bin folder there for `cargo clippy` and `cargo fmt` (RUST.md). `validate` rejects a relative path, a character outside `[A-Za-z0-9._/@+-]`, a missing folder, a folder inside the target repo (the implementer could plant a tool there that every proof runs first), a folder the proof sandbox cannot read (`/tmp`, `/var/folders`, the secret paths, `~/.cache/claude-coding-workflow`; the list is `lib/proof-sandbox.py`'s `read_denied()`), and a folder holding an executable `bash`, `sh`, `env`, `git`, `python3` or `shasum`. A goal reads it from GOALS.md at its base commit, so changing it mid-goal is contract drift.

`plan:` names the signed plan, committed. A goal's run freezes it at the goal's base commit: both agents read that copy, and a change to the live file during the run stops the goal as contract tampering, like an oracle edit.

## Field rules

- `id` — `g<n>-<slug>`, numbered in dependency order (blockers first). Stable once written.
- `blocked_by` — ids that must be **done** before this goal can start. A true gate: B is a lie until A exists.
- `conflicts_with` — ids that are not gates but share an area hard enough that Phase 5 must not merge them in parallel. Same-`area` is not automatic conflict; only declare it when a parallel merge would actually collide. A parallel walk (`run-goals.sh --jobs N`) never puts two goals in one wave when either names the other. Also declare it when two goals' proofs would collide running side by side: a fixed port, or a fixed path outside the repo (each proof gets its own `TMPDIR`, nothing else is separated).
- `area` — coarse module lock (`mailer/inbound`, not a file path). File paths go stale.
- `proof` — exact command that counts as done. Architect runs it, not the implementer's word. It must leave the repo as it found it: every file it writes (caches, reports, coverage) must match `.gitignore`, or the goal stops as `proof-tamper`. `.gitignore` does not excuse a path under `tests/acceptance/` or the plan: an ignored file there is tampering, because the reviewer's diff would never show it. Python bytecode is the common case: the host runs the implementer and the proof with `PYTHONDONTWRITEBYTECODE=1`, so run your own Phase 3 checks the same way (or delete `tests/acceptance/**/__pycache__` before committing), or the first goal wakes `contract-tamper-ignored`.
- `oracle` — path of the Architect-authored acceptance file, or `inline`.
- `status` — `ready` (no unfinished blockers) or `blocked` when first
  written. Phase 4 sets `in_progress`, then `done` or `bounced` (in a
  parallel walk the walker sets all three).

`blocked_by` and `conflicts_with` in the markdown body must match the YAML. The YAML wins if they drift.

### Registration points

A parallel walk merges each goal's branch into the walk branch at the join.
Goals that each add one line to the same list, or edit the same line, always
conflict in git, even when all their own code is in separate files. Seen on
the first live parallel walk (rbtree, 2026-10-16): three goals each appended
their source file to one `add_library(...)` line and registered their test at
the same place in `CMakeLists.txt`. The first goal merged; the other two
stopped `merge-conflict`.

For every shared registration point in the plan's harness (a build source
list, a test list, a module, export or route table), choose one:

- **The harness picks the files up itself**, so no goal edits the list.
  Prefer this: it keeps goals truly parallel.
  - **Sources:** glob them, e.g. `file(GLOB rbtree_src CONFIGURE_DEPENDS src/*.c)`;
    Python packages that import nothing by name in `__init__.py`.
  - **Oracles: no step of a goal's proof may build, type-check or collect a
    later goal's oracle.** The oracles are committed before any goal runs, red
    against an API that does not exist yet, so a later goal's oracle in an
    earlier goal's build fails every earlier goal's proof as a build or
    collection error. Two ways to meet it:
    - **A runner that finds test files itself** (pytest, Vitest, node:test) is
      fine when each proof names its own oracle files ("Proof composition"
      below); so is `cargo test --test <name>`. A bare `pytest`, `pnpm test`,
      `go test ./...` or `cargo test` stays red until the last goal lands: never
      use one as a proof.
    - **A build that compiles every oracle together** gets one unit per goal:
      - one Go package of oracles per goal (`tests/acceptance/<id>/`, selected
        by the proof) and one `tier.<id>.tsconfig.json` per goal, both the
        Architect's, committed with the oracles in Phase 3, never one shared
        package or `include` over every oracle;
      - for a harness that collects registrations by glob (CMake test targets),
        one registration file per goal, written by that goal and named in its
        body as its edit: e.g. `tests/register/<name>.cmake` holding its one
        `add_acceptance(<name>)` call. Committed up front it would land in every
        earlier goal's build. A Tier 1 run of a later goal writes it beside its
        stubs and deletes it with them.
    The rbtree plan was amended this way after the first parallel walk; on the
    re-run (2026-10-22) g4, g5 and g7 merged in one wave with no conflict
    (`docs/features/parallel-walker/EVIDENCE.md` step 12b, on the house's main branch).
- **The goals that edit it name each other in `conflicts_with`**, so they run
  in different waves. Correct, but those goals no longer run side by side.

The scaffold goal is the natural owner of a picking-up harness: it lands
before the goals that add files to it.

Each goal has exactly one `## <id> — <title>` section: the id, then a space or end of line (`## g1-store:` does not count). `goals.py validate` rejects duplicates, and a goal with no section, whatever its oracle: the section is the handoff's spec, and for `oracle: inline` its case table is the oracle.

## Slice rules

- Vertical: a narrow complete path (schema + API + tests, or the equivalent), demoable or verifiable alone. Not a horizontal layer ("just the types").
- Sized for **one implementer session** — tighter than a human ticket.
- Independence test: if two goals landed tomorrow in separate worktrees, would either be a lie without the other? If yes, they are not independent — add an edge or merge them.
- Cap ~8 goals. More than that → merge, or the plan is still too big (bounce to crucible).
- Wide mechanical change (rename, retype, blast radius that no vertical slice can land green): **expand → migrate batches → contract**. Each step is its own goal; migrate batches `blocked_by` the expand; contract `blocked_by` every migrate batch.

## Oracle rules

The Architect authors the oracle. The implementer makes it pass and does not edit it. A case that looks wrong is a blocker to bounce, not a license to change the test.

Each case is an example: concrete input → concrete output, plus the edges the plan named. Assertions are exact values, not "does not throw".

After a goal's DONE review, the reviewer mutates the implementer's code and the goal's proof must go red on each mutation (`docs/features/mutation-checks` on the house's main branch). A mutation the proof survives is an oracle gap, recorded in the journal with its diff kept: strengthen the oracle in a later goal or an acceptance edit. Some survivors are equivalent mutants no test can catch; judge them, do not chase them.

### Prove the oracle is satisfiable before committing it — the tiers

Red is not enough: a case can be red because the feature is missing, or because the case is
wrong. Before committing, prove each oracle with the cheapest evidence that suffices
(`skills/to-goals/SKILL.md` §4 has the order and the gate), then let Grok review it:

- **Tier 1 — every file oracle and swept edit: run the goal's `proof`.** The API the plan
  adds is stubbed, every body a trap with a unique message; existing API is the real code.
  Pass bar: a nonzero exit, and either the trap message in the output (stubbed — the test
  source must show this goal's assertion after the call) or this goal's new assertion in the
  failure (existing code). A zero exit, a build or collection error, or any other failure
  fails Tier 1. A swept file the `proof` skips runs through the same runner, filtered to
  this goal's case.
- **Tier 2 — computed expectations:** any expected value the plan does not state verbatim
  is checked against an existing reference with the same semantics, or a small brute-force
  model of the spec, in the scratchpad.
- **Tier 3 — last resort:** a full scratch implementation, only when neither exists; tell
  the user first, 30-minute box by default, never committed or shown to the implementer.

Where the trap and the failure show up, by language:

| Language | Stub trap | Pass bar in the `proof` output |
|---|---|---|
| C / C++ | print the message, `fflush(stdout)`, `fflush(stderr)`, `abort()` (CTest captures through a pipe; an unflushed message is lost) | the message, and CTest's abort/exception line for that test |
| Python | `raise NotImplementedError("<feature>-trap")` | a traceback ending in that message, or the goal's `AssertionError` |
| TypeScript | `throw new Error("<feature>-trap")`; an async body returns `Promise.reject(new Error("<feature>-trap"))` | the message in the runner's failure for that test; the `proof` runs a check and `tsc` before the runner ([TYPESCRIPT.md](TYPESCRIPT.md)) |
| Rust | `panic!("<feature>-trap")`, stub parameters named `_x` | the message on the line after libtest's `panicked at` line for that test; the `proof` runs a version check and checks before `cargo test` ([RUST.md](RUST.md); Axum + SQLx: [RUST-AXUM-SQLX.md](RUST-AXUM-SQLX.md)) |
| Go | `panic("<feature>-trap")` | the panic message for that test |

Another language: the analogous trap and run; never a compile-only or collect-only step.
A TypeScript or Rust `proof` calls its tools by absolute path (the host runs `bash -c`, no login
shell) and needs no network; TYPESCRIPT.md and RUST.md have the recipes, proved by planted defects.

The failure classes these catch, and that the self-review and the oracle review look for:

- **An invented symbol.** A seam that does not exist. Grep every name the oracle imports;
  Tier 1's build catches it.
- **A pin on a private signature.** Calling a helper with today's arguments freezes a shape
  the implementer must change to do the work. Pin what reaches the wire or the store.
- **A tautology.** Both sides of `==` derived from the same helper restates a definition —
  `broke() + nonce_on(ch) == on_channel(ch)` is `(A - B) + B == A`. One side must come from
  a run.
- **A differential that cancels its own term.** If the quantity under test is present in
  both arms, the case cannot fail for its own reason.
- **A maths claim asserted rather than run.** `rot13` and `reverse` commute, so an "order
  matters" case on that pair can never fail. Tier 2's brute force runs it.
- **A claim nowhere pinned.** Where the plan says "the shipped X is Y", something under
  `tests/acceptance/` must read X.
- **A test that passes against the stub.** A zero exit under Tier 1 means the oracle cannot
  fail; one that expects the stub's own exception is the usual cause.

Evidence: in one Week 6 goal a scratch run caught two of these in a single new oracle — an
invented seam, and a differential that cancelled the term it measured — both after the
oracle had been read twice. On uregex a ~550-line scratch caught only two harness defects
(a header failing `-Werror`; CTest `WILL_FAIL` not covering a signal abort), both of which a
Tier 1 run of the `proof` catches; the walk's one FIX round was an oracle gap, which the
oracle review targets.

### The whole directory is the Architect's

The host guards all of `tests/acceptance/`, not only a goal's own oracle: a change to any file there during a goal's run — an earlier goal's, an earlier week's — stops that goal as tampering, and a resume refuses one made while the goal was paused. So every edit under `tests/acceptance/` is the Architect's, applied in Phase 3 before dispatch and listed under **Acceptance edits (applied, read-only)**. **Edits owned** holds only paths outside the directory; `goals.py validate` rejects a `tests/acceptance/` path there.

### Pins

A **pin** is an existing assertion that fixes something the plan changes. When a plan changes behaviour an earlier oracle already covers, each pin owes an edit. The kinds that slipped through before:

- exact counts and totals — a whole-library count, `len(x) == 22`, `{"held": 1, "skipped": 22}`
- field, parameter, and signature lists, including argument order
- pinned lists and sets, including ones a test reads from config (a package list in `pyproject.toml`)
- single-row picks — `[0]`, `fetchone()`, a read of the first row where the plan adds rows of another kind
- example values whose width or format the plan changes
- docstrings and comments saying "until g<n>" or describing the old behaviour

A pin on a file outside the directory (the `pyproject.toml` list itself) is implementer work under that goal's **Edits owned**.

### Proof composition

Pre-applied edits stay red until their goal lands. A goal's `proof` runs only acceptance files that are green once that goal is done; a file carrying a later goal's red edit stays out of it.
