# Plan: TypeScript rules for Tier 1 and Tier 2 (house item 9)
_Locked via crucible — by Claude + cobalt, 2026-10-14._

## Goal

The to-goals rulebook proves an oracle cheaply before it is committed: Tier 1
runs the goal's `proof` against trap stubs of the planned API; Tier 2 checks
computed expectations against a reference or a brute-force model. C and
Python have rules learned on dogfoods; TypeScript has one table row
(`GOAL-FORMAT.md:122`). Before the TypeScript dogfood's Phase 3, write the
TypeScript rules for **Vitest and node:test**, each one admitted only when a
planted oracle defect on a throwaway TypeScript repo shows it changes the
Tier 1 or Tier 2 verdict. The purpose (user): catch the errors that really
break an oracle in this language, so Tier 3 is never needed — not every
JavaScript pitfall.

## Approach

0. **The verdict is the existing pass bar on the `proof` command.** Tier 1
   passes when the `proof` exits nonzero and its output carries the trap
   message (or this goal's assertion); a zero exit, a build or collection
   error, or any other failure fails it (`GOAL-FORMAT.md`). Every TypeScript
   rule is written so that this bar, applied to the whole `proof` command,
   gives the right verdict: the `proof` chains `tsc` before the run
   (`tsc … && runner …`), so a type error exits nonzero *without* the trap
   and fails Tier 1; a run that collects zero tests exits nonzero inside the
   `proof` itself, because the host reads exit 0 as green. Checks that must
   stop a run that would still print the trap (a mock of the feature module,
   a `.only`, a snapshot matcher, an unreturned async call if step 3 shows it
   passes) run **before** the runner in the same `&&` chain, so a hit
   exits nonzero with no trap. The runner clause that also guards zero tests
   is `( <runner>; status=$?; <tests counted > 0> || exit 1; exit "$status" )`
   — a check after `&&` never runs when the runner exits 0, and one after
   `;` would replace the runner's exit status.
   **Tier 1 keep rule:** a rule is kept only when, with it in the full
   `proof`, (a) the clean oracle still passes Tier 1 against the stub,
   (b) the same `proof` exits 0 against the correct implementation, (c) the
   tree snapshot (step 3) is unchanged by both runs, and (d) the planted
   oracle passes Tier 1 under the baseline minus the rule and fails it with
   the rule. "The existing pass bar already rejects it" means the planted
   oracle fails Tier 1 under the baseline; such a candidate is dropped,
   logged.
   **Tier 2 keep rule** (Tier 2 plants never reach an assertion against the
   stub, so the Tier 1 bar cannot judge them): the clean expectation must
   match the reference run on the proof's `$NODE` and `TZ`, and the plausible
   hand-computed one the rule names must differ from it. Then, by kind:
   classified by the planted oracle's result against the correct
   implementation, not by topic:
   - **red** — an unsatisfiable pin: the walk would stop on an oracle
     defect; kept (the rule is "compute it with the reference");
   - **green** — a loose pin: the matcher accepts the wrong value, so the
     oracle pins nothing there; kept only when the strict matcher
     (`toStrictEqual` / `assert.deepStrictEqual`) is red on the same values
     (the rule is "use the strict matcher"), otherwise dropped.
   A plausible hand computation that comes out right is dropped.

1. **Two fixtures, no shared module, each its own git repository** under
   `~/dogfood/ts-tiers/` (deleted after the commit; its sources are kept,
   step 7), with `tests/acceptance/` at each repository's root and
   `node_modules/` gitignored, so the host's snapshot pathspecs match as on a
   real target. Node 24 via `fnm`. One fixture per runner:
   - **Vitest:** `vitest-fixture/` with its own `tsconfig.json`
     (`strict: true`, bundler resolution, `include` = its oracle plus its
     stub), a project `vitest.config.ts` (the project's own, which the plants
     may make hostile), and a separate **recipe config**
     `tier.vitest.config.ts` that sets the kept flags and does not import or
     extend the project's config; the recipe names the recipe config;
   - **node:test:** `node-test-fixture/` with its own `tsconfig.json`
     (`strict: true`, `module`/`moduleResolution: nodenext`,
     `allowImportingTsExtensions`, `erasableSyntaxOnly`, `include` = its
     oracle plus its stub), imports with explicit `.ts` extensions.
   Each has a small planned API (`parseDuration(s): Duration`; one async
   function `loadDuration(s): Promise<Duration>` for the async plants; and
   one function whose correct result contains each value the loose-equality
   plants need — a `-0` (a negated zero component), an `undefined`-valued
   optional key, and an instance of a `Duration` class — so those plants have
   a reference result to be green or red against; the type-only name the
   import plant needs is a separate export, an interface `DurationShape`, so
   one export is never both a class and a type), its
   stub (every sync body `throw new Error("<feature>-trap")`; every async body
   `return Promise.reject(new Error("<feature>-trap"))`), an oracle under
   `tests/acceptance/`, and a correct implementation written for the
   fixture.

2. **The baseline recipe per runner, as the host runs it**: a single
   `proof` string run by `env -i HOME="$HOME" PATH=/usr/bin:/bin bash -c
   "<proof>"` — no `fnm`, no `node_modules/.bin` on `PATH`, no login shell —
   with Node and every tool called by absolute path:
   - Vitest: `TZ=UTC CI=1 "$NODE" "$REPO/node_modules/typescript/lib/tsc.js"
     --noEmit --incremental false -p <fixture>/tsconfig.json && TZ=UTC CI=1
     "$NODE" "$REPO/node_modules/vitest/vitest.mjs" run --config
     tier.vitest.config.ts <oracle> <flags measured in step 3>`, with the
     pre-runner checks and the zero-test clause of step 0;
   - node:test: the same `tsc` step and pre-runner checks, then
     `TZ=UTC "$NODE" --test --test-reporter=spec <oracle>` inside the
     zero-test subshell of step 0, its count read from the spec reporter's
     summary.
   `$NODE` and `$REPO` are written literally in the recipe as the absolute
   paths of the target; TYPESCRIPT.md shows them as placeholders the
   TypeScript project fills (how Node gets there is that project's choice,
   Q3). The baseline must fail Tier 1 correctly against the stub (nonzero,
   trap in the output) and exit 0 against the correct implementation.

3. **Plants, one per candidate**, each a defect an Architect plausibly
   writes in an oracle (named against GOAL-FORMAT's failure classes in the
   evidence). Each planted oracle runs under the baseline minus the
   candidate rule and under the full recipe; the verdict rule of step 0
   decides keep or drop. Candidates, per runner where they differ:
   - **type check:** a wrong-typed call into the planned API; an invented
     symbol only `tsc` rejects;
   - **syntax Node's stripping refuses** (node:test): an `enum`, a parameter
     property, a runtime `namespace`, each planted with `erasableSyntaxOnly`
     **off** so the run, not `tsc`, meets it and the
     `ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX` behaviour is observed; then with it
     on, to show `tsc` names it first. The kept form is a precondition in the
     node:test recipe (`erasableSyntaxOnly: true` in the tier tsconfig), not
     a failed correct oracle;
   - **a value import of a type-only name** (node:test): `import {
     parseDuration, DurationShape }` where `DurationShape` is an interface
     (never the `Duration` class), planted
     with `verbatimModuleSyntax` **off** so the run meets it. If collection
     fails before the trap, the kept form is a precondition — the tier
     tsconfig turns `verbatimModuleSyntax` on, so `tsc` names the import
     first — and `TYPESCRIPT.md` requires `import type` or an inline `type`
     modifier for type-only names, so a correct oracle passes;
   - **async:** a `loadDuration(s).then(…)` the test neither returns nor
     awaits, run against **both** the immediate-reject stub the recipe ships
     (step 1) and a stub whose rejection is delayed until after the test
     returns (`setImmediate` / a timer — the case where an
     `unhandledRejection` arrives after the test completed); each run 5
     times, a result that differs between runs recorded **unproved**. If
     either still passes Tier 1, the rule is a silent pre-runner check in the
     `&&` chain, if a cheap one catches it reliably (measured); if none does,
     the rule is a written oracle rule (await or return every call into the
     planned async API) and the plant is recorded as a **gap**. (A
     floating `expect(…).rejects` is not planted: the research says Vitest
     already fails it; if the baseline confirms, it is logged as dropped.)
   - **mocks:** a `vi.mock` of the feature module (Vitest), and
     `mock.module` where the installed Node supports it (node:test), whose
     factory **rethrows the trap** — the shape that still prints
     `<feature>-trap` and passes Tier 1; the candidate rule is a pre-runner
     check in the `&&` chain;
   - **vacuous runs:** a `.only` left in a file; zero tests collected (a path
     or filter typo); a snapshot oracle (`toMatchSnapshot`,
     `toMatchInlineSnapshot`, `toThrowErrorMatchingSnapshot` — the stub throws
     before the matcher, so it passes Tier 1 and later reds the host proof on
     a missing snapshot under `tests/acceptance/`; the candidate rule is a
     silent pre-runner check, the clean oracle having no matcher);
   - **hostile project config:** the project's `vitest.config.ts` and a
     `vite.config.ts` setting `allowOnly: true`, `coverage.enabled: true`, a
     cache directory under `tests/acceptance/`, `passWithNoTests: true`, and
     a **canary** the recipe config does not set — a `setupFiles` module that
     throws its own message, `canary-config-merged` (never the trap text,
     which the pass bar cannot tell apart from the stub) — so a partial merge
     (the recipe wins the four keys it sets, the hostile file's others still
     apply) is visible. The recipe config must win against both: the baseline
     log must not contain `canary-config-merged` and must show the trap thrown
     from the stub's frame. If the canary message appears, stop and do not
     publish the recipe;
   - **files the proof leaves**, scored the way the host scores them — the
     whole of `tree_snapshot` in `scripts/run-goal.sh` (`git rev-parse HEAD`,
     `git status --porcelain --untracked-files=all`, and `git status
     --porcelain --ignored=matching` on `tests/acceptance`, `.claude`,
     `.mcp.json`, the oracle and the plan), from the fixture repository's
     root, before and after: coverage, `.tsbuildinfo`, the Vitest/Vite cache,
     `__snapshots__`. An artifact under a contract path must be **disabled**
     (gitignore there is tampering to the host); one outside may be
     gitignored.
   - **Tier 2, per runner's equality API** (two lists): Vitest `toEqual` /
     `toStrictEqual`; node:test `assert.deepEqual` / `assert.deepStrictEqual`
     — `-0`, `undefined`-valued keys, class instances; default string-order
     `sort()`; UTF-16 `length`; date-only strings (run with and without
     `TZ=UTC` in the `proof`, to show the pin is what makes it stable). The
     Tier 2 reference is written **before** the correct implementation, lives
     outside the fixture, and does not import it; the evidence shows its
     import list.
   Dropped up front unless a plant shows otherwise: `0.1 + 0.2`, Turkish
   `i`, `Map` key order, a bare `toThrow()` (exits 0 against the stub, so the
   pass bar already rejects it), `expect.hasAssertions()` (it reddens the
   clean oracle too, because the stub throws before `expect` runs).

4. **Sources only for what a run cannot show**: version thresholds (Node's
   type-stripping default and stability; the Vitest defaults the hostile
   config overrides), each checked against the primary doc the research
   cites. A claim neither planted nor cited is dropped, logged.

5. **Evidence** `docs/features/ts-tier-rules/EVIDENCE.md`: per candidate and
   runner, the plant (a diff), the baseline-minus-rule result, the
   full-recipe result, the verdict (kept / dropped / unproved / gap, and
   why), the
   exact versions (Node, Vitest, TypeScript, with the lockfile's integrity
   hashes).

6. **The rulebook text.**
   - `skills/to-goals/TYPESCRIPT.md` (new, one level below the skill): the
     two `proof` recipes as proved (with `$NODE` / `$REPO` placeholders), why
     `tsc` is chained inside the `proof`, the kept rules with one line of
     reason each, the two Tier 2 lists, every **gap** as a look-for for the
     self-review and the oracle review (not a proof step), the versions, and
     how to rerun the plants (step 7) after an upgrade.
   - `skills/to-goals/GOAL-FORMAT.md`: the TypeScript table row links to it;
     one line: a TypeScript `proof` calls Node and every tool by absolute
     path (the host runs `bash -c` with no login shell) and needs no
     network.
   - `skills/to-goals/SKILL.md` §4: at most 3 lines; the file stays at or
     under 228 lines.
   - Another runner (Jest, Bun, Deno): proved the same way before its first
     oracle; the doc says so.

7. **Keep what reruns the proof.** Before deleting the throwaway, commit
   `docs/features/ts-tier-rules/fixture/`: both fixtures' sources, the
   reference, `package.json`, the lockfile, every plant as a patch, and
   `run-plants.sh`, which copies each fixture to a fresh temporary git
   repository before installing from the lockfile or applying a plant (so the
   house clone is never dirtied and the snapshot is the fixture's own), runs
   both recipes as the host would, and prints the verdict table EVIDENCE.md
   records.
   It is not part of `scripts/tests/run-all.sh` (it needs Node and one
   network install); TYPESCRIPT.md says how to run it. Its own sanity check,
   run before the commit: reverting each kept Tier 1 rule in the recipe turns
   that plant's row from "caught" to "through"; for each kept Tier 2 rule,
   the row is "caught" with the reference comparison run and "through" when
   it is skipped (the hand-computed value is what would be committed).

8. **Carried inputs** (Q3): the two hazards — the host proof's `bash -c`
   does not find an `fnm` Node; the implementer's sandbox has no network for
   `npm install` — go into `docs/FUTURE-WORK.md` addressed to the TypeScript
   project's Phase 1 recon, with what worked here (absolute paths in the
   `proof`; dependencies installed once from the lockfile before any run).

9. **Review and commit** per the FUTURE-WORK execution-plan recipe: a fresh
   Opus review of the diff (the doc text against EVIDENCE.md and the
   fixture), each finding taken or rejected with a reason; the full suite;
   `test -f ~/.claude/skills/to-goals/TYPESCRIPT.md` after `install.sh`
   (its `--check` does not list files inside a linked skill); commit on the
   user's OK; delete `~/dogfood/ts-tiers/`.

## Key decisions & tradeoffs

- **Vitest and node:test only (Q1, user).** Jest, Bun and Deno are out: Jest
  is mostly legacy for new projects; Bun and Deno are not installed, so their
  rules could not be proved. Cost: a TypeScript project on another runner
  needs a small item 9 of its own first.
- **A rule needs a plant it catches (Q2, user).** Evidence over citations;
  docs only for version facts. Cost: claims nobody can plant are dropped even
  if true, and the rules are proved on one Node, Vitest and TypeScript
  version (recorded, so a later upgrade knows what to recheck).
- **Hazards carried, not fixed (Q3, user).** How `node` reaches the proof
  and how dependencies arrive offline are target choices; the house records
  the hazard and the evidence, the TypeScript project's crucible decides.
- **`tsc` chained inside the `proof`** (`tsc … && runner …`), not a separate
  Architect step and not a runner's typecheck mode: then the existing pass
  bar, applied to the whole `proof`, rejects a type error (nonzero without
  the trap), the host type-checks every goal, and no second verdict exists
  to forget. Vitest's typecheck mode only covers `*.test-d.ts` files and
  Node's stripping never checks types (research, verified by plant).
- **Two fixtures, two tsconfigs.** Node's stripping and Vitest's bundler
  resolution disagree on extensions and syntax; one fixture would hide one
  runner's failures.

## Assumptions

1. TypeScript has one tier-table row; C and Python have learned rules —
   `skills/to-goals/GOAL-FORMAT.md:122`.
2. Tier 1 runs the real `proof` against trap stubs; pass bar: nonzero exit
   plus the trap message or this goal's assertion; "never compile-only"
   forbids compiling instead of running, not as well —
   `skills/to-goals/SKILL.md` §4.2, `GOAL-FORMAT.md:125`.
3. The research (`docs/research/2026-10-12-typescript-tier-rules.md`) is
   unverified; ~8 claims are marked unsourced; two fetches failed.
4. Node v24.21.0 is installed via `fnm` and not on `PATH`; no global `tsc`,
   `bun` or `deno`; Vitest and TypeScript come from npm into the throwaway
   repo (network needed once).
5. No TypeScript target exists yet; the TypeScript dogfood runs in another
   session and has not chosen a runner — `~/dogfood`, `FUTURE-WORK.md:76-78`.
6. The host proof wakes `proof-tamper` on any new unignored file anywhere,
   and on any new file — ignored or not — under `tests/acceptance/`, the
   oracle or the plan (`tree_snapshot`, `scripts/run-goal.sh`;
   `scripts/tests/proof-test.sh` cases 7 and 11). So an artifact outside the
   contract paths may be gitignored; one under them must be disabled —
   `GOAL-FORMAT.md:74`.
7. `skills/to-goals/SKILL.md` is 201 lines; the house keeps skills at or
   under 228 lines — `FUTURE-WORK.md` item 3.
8. Plan files in `docs/features/ts-tier-rules/`; build, Opus review, suite
   and commit per the FUTURE-WORK execution-plan recipe.

## Risks / open questions

- **Version drift.** Vitest changes defaults across majors (`allowOnly`,
  snapshot writing, cache paths). The rules are pinned to the versions
  measured; TYPESCRIPT.md names them and says to re-run the plants on an
  upgrade.
- **A plant can be unrealistic.** A defect nobody would write proves little.
  Each plant is a defect an Architect plausibly writes in an oracle (the
  oracle failure classes in GOAL-FORMAT.md), named as such in EVIDENCE.md.
- **Network for the throwaway repo.** One `npm install` with network; if the
  registry is unreachable, stop and tell the user rather than guess.

## Out of scope

- Jest, Bun, Deno, and type-checking runner modes beyond the one measured.
- Fixing how a TypeScript target finds `node` or installs dependencies
  offline (carried to the TypeScript project, Q3).
- Changes to `run-goal.sh` or the launchers.
- The TypeScript dogfood itself.
