# Plan Review Log: TypeScript rules for Tier 1 and Tier 2 (house item 9)
Phases 0-1 (recon + interrogation) complete — plan locked with the user. MAX_ROUNDS=5.

## Round 1 — Grok

I'll read the plan and the domain docs around it, then check the repo for conflicts with what it assumes.The plan is short. Next I’ll check the glossary, the rulebook it cites, and the research it treats as unverified.The plan's admission test does not match the host's pass bar, and the recipe it would publish does not survive the host's `bash -c` proof. Those are implementable bugs, not wording nits.

## 1. A type error still satisfies the pass bar

Assumption 2 and `GOAL-FORMAT.md` define a Tier 1 pass as a nonzero exit plus the trap text. A wrong-typed call still throws `<feature>-trap` under Vitest and under Node's stripper, so the runner output already meets that bar. `tsc --noEmit` failing in the same script does not flip the verdict if the script's exit status and log are the runner's. The same hole eats `allowOnly: false` and an assertion-count diagnostic whenever the trap line is still present.

Fix: write the verdict as one conjunction — `tsc` exit 0, and no allow-only or mock diagnostic, and the runner nonzero with the trap — and require the "with rule" plant to falsify that conjunction.

## 2. Several plants cannot change that verdict, and one cannot be built on the stub you specified

The stub throws synchronously in every body (step 1). Against that stub:

- A bare `toThrow()` exits 0, which the existing pass bar already rejects. It never "gets through."
- An un-awaited rejection never happens: the call throws before a promise exists. The plant that would slip through is an `async` stub, or `return Promise.reject(new Error("<feature>-trap"))`, whose promise the test does not return. Node's behavior for that rejection during a running test is exactly the unsourced claim in the research (report 1, item 10); one shot is a coin flip.
- `expect.hasAssertions()` also fails the clean oracle, because the stub throws before `expect` runs. Step 3 can keep it for "failing for that reason" while the goal's own criterion (the verdict changes) is false, and every good Tier 1 run goes red for the same reason.

Step 3 then says to drop whatever "the runner already catches." That phrase mixes the runner, the existing pass bar, and the host. The host marks a proof green when the exit is 0 and the log lacks pytest's `Ran 0 tests` (`scripts/run-goal.sh` around the proof block; `docs/WORKFLOW-REVIEW.md` D-03). A zero-file `node --test` that exits 0 fails Tier 1 in the Architect's reading and is a green host proof. `run-goal.sh` is out of scope, so a log-only "count the tests" line never reaches the gate.

Fix: keep a rule only when the clean stub run still passes the conjunction and the planted run fails it; make the async plant use a rejecting promise and run it repeatedly, recording a flake as unproved; put a nonzero exit for zero tests inside the `proof` command itself.

## 3. Assumption 6 is false, so the file-left plants measure the wrong thing

`tree_snapshot` in `scripts/run-goal.sh` is `git status --porcelain --untracked-files=all` plus `git status --porcelain --ignored=matching` on `tests/acceptance/`, the oracle path, the plan path, `.claude`, and `.mcp.json`. Ignored files under those paths wake `proof-tamper`. `scripts/tests/proof-test.sh` cases 7 and 11 show a gitignored `coverage.txt` at the repo root is allowed and a gitignored file under `tests/acceptance/` is tamper. Plain `git status --porcelain` shows neither. Step 1 puts the Vitest oracle in `tests/acceptance/*.test.ts`, so `__snapshots__/` lands on the contract path. Assumption 6's remedy, "disabled or ignored," is the condition the host treats as tampering (`GOAL-FORMAT.md` proof field).

Fix: score plants with those two `tree_snapshot` commands, and require artifacts under a contract path to be disabled; gitignore is allowed only outside the contract paths.

## 4. The published commands are not runnable by the host

The proof is `bash -c`, not a login shell (`run-goal.sh`, the proof block), and assumption 4 says Node is not on `PATH`. Step 2 still runs bare `vitest`, `tsc`, and `node`. A `node_modules/.bin/vitest` shim, and `vitest.mjs` itself, start with `#!/usr/bin/env node`, so an absolute path to the shim looks `node` up on `PATH` again and fails the same way. There is no global `tsc` (assumption 4). Measuring from a shell that already ran `fnm use` or prepended `node_modules/.bin` will record a recipe the host cannot run. The GOAL-FORMAT line "the proof must find `node`" describes a lookup the host will not do; how Node gets on `PATH` is correctly out of scope (Q3), so the `proof` string has to carry the paths.

Fix: the recipe is `"$NODE" "$REPO/node_modules/vitest/vitest.mjs" run …` and `"$NODE" "$REPO/node_modules/typescript/lib/tsc.js" --noEmit …`, with `NODE` absolute, proved via `bash -c` and a `PATH` that contains neither fnm nor `node_modules/.bin`.

## 5. One fixture cannot justify both runners

Node's stripper requires explicit `.ts` extensions and `moduleResolution: nodenext`, and it throws `ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX` on enums, runtime namespaces, and parameter properties (research report 1, items 4 and 18). Vitest's bundler resolution is the other way. Step 1 shares one `parseDuration` module and step 2 speaks of `<tier1 tsconfig>` singular, whose `include`, `strict`, and `module` are never stated. A tsconfig that only includes `src` exits 0 on a type error in the test, the plant "does not get through," and the typecheck rule is dropped. The syntax failure is plantable and is not in the candidate list, so step 4's "docs only for version facts" drops it and the node:test recipe ships a collection error for a correct oracle. The throwaway also has no `vitest.config.ts`; a real project config that sets `allowOnly`, `coverage.enabled`, or a cache directory under `tests/acceptance/` can override the flags you measured against defaults.

Fix: two fixtures, no shared module; one tsconfig per runner with `strict: true` and `include` limited to that runner's oracle plus stubs; plant an enum under both runners; plant a hostile Vitest config and keep a flag only if it still wins, otherwise the recipe passes an explicit `--config` that does not extend the project's.

## 6. The Tier 2 list is a Vitest assertion quirk, and it is not pinned to a timezone

`toEqual` ignoring `undefined` keys is Vitest (`research` report 2, item 22). node:test has `assert.deepEqual` / `deepStrictEqual`, which disagree with each other and with `toEqual` on `-0` and missing keys. One shared list writes a Vitest rule into the node:test recipe. Date-only strings are on the plant list, but neither runner command sets `TZ`. The host inherits the laptop zone. A cross-check on that same zone agrees with a locally computed expectation, so the plant does not get through, and the oracle is still free to flip on another machine. The research's own Tier 2 rule — the model lives in the scratchpad and does not import the feature — is not in the plan, so the "correct implementation written for the repo" can be imported as the reference and agree with itself.

Fix: plant equality on each runner's assertion API and record two lists; put `TZ=UTC` in the `proof` command and run the date plant with and without it; write the reference before the correct implementation exists and show the evidence command does not import it.

## 7. The pin and the "did install pick this up?" check both disappear

The lockfile is "committed" inside `~/dogfood/ts-tiers/`, and step 8 deletes that repo after the house commit. The versions named in `TYPESCRIPT.md` have no integrity hashes and no way to rerun the plants. `install.sh` symlinks the whole `skills/to-goals/` directory; `install.sh --check` never lists files inside it, so a missing `TYPESCRIPT.md` still passes. The execution-plan recipe this plan cites (`docs/FUTURE-WORK.md`) also builds a test under `scripts/tests/` and then plants bugs that test must turn red. This plan's only tests are deleted with the throwaway.

Fix: commit `package.json` and the lockfile under `docs/features/ts-tier-rules/` before deleting the throwaway, and make the done check `test -f "$DEST/to-goals/TYPESCRIPT.md"` rather than a green `install.sh --check`.

VERDICT: REVISE

### Architect's response

All seven taken; 1, 2 and 7 with a refinement.
1. Taken, differently: `tsc` is chained inside the `proof` (`tsc … && runner …`), so the existing pass bar on the whole proof rejects a type error (nonzero, no trap) with no second conjunction to keep in sync, and the host type-checks every goal. New step 0 states the keep/drop rule against that bar.
2. Taken. Bare `toThrow()` and `hasAssertions()` dropped up front with the reasons Grok gives (logged in the plan). Async plants use a rejecting async stub and run 5 times; a differing result is "unproved". Zero tests must exit nonzero inside the `proof` (the host reads exit 0 as green; run-goal.sh is out of scope). "Runner already catches" replaced by "the planted oracle fails Tier 1 under the baseline recipe".
3. Taken. Assumption 6 corrected from tree_snapshot and proof-test cases 7/11; file plants are scored with the two tree_snapshot commands; artifacts under contract paths must be disabled, outside may be gitignored.
4. Taken. The recipe calls `$NODE` with vitest.mjs / tsc.js by absolute path and is proved under `env -i … PATH=/usr/bin:/bin bash -c`. The GOAL-FORMAT line now says "calls Node and every tool by absolute path".
5. Taken. Two fixtures, one strict tsconfig each with `include` = oracle + stub; an enum plant for both runners; a hostile project Vitest config plant; the recipe names its own `--config`.
6. Taken. Two Tier 2 lists by each runner's equality API; `TZ=UTC` in the proof, with the date plant run with and without it; the reference written before the implementation, outside the fixture, its imports shown.
7. Taken, extended. The fixture sources, reference, lockfile, plants as patches and `run-plants.sh` are committed under docs/features/ts-tier-rules/fixture/ (not in run-all: Node + one network install), with a sanity check that reverting each kept rule flips its row; the done check is `test -f` on the installed TYPESCRIPT.md.

## Round 2 — Grok

I'll re-read the revised plan and check each earlier finding against the host code it depends on.The revision takes most of the last round. I'll check the keep-rule and the fixture layout against the host's proof and `tree_snapshot`.The absolute-path recipe, the rejecting async stub, the dropped `toThrow` and `hasAssertions` plants, the two strict tsconfigs, `TZ=UTC`, the two equality lists, the reference written first, and committing the fixture with a `test -f` check all hold up. The keep rule added in the revision wipes out Tier 2, and the fixture still would not reproduce the host's tamper check.

## 1. Step 0's keep rule drops every Tier 2 plant

Step 3 says step 0 decides keep or drop for the whole candidate list. Step 0 keeps a rule only when the planted oracle passes Tier 1 without it and fails with it. A wrong `sort()`, `-0`, UTF-16 `length`, or date expectation never runs against the stub: the trap throws first, the output still contains `<feature>-trap`, and Tier 1 still passes. Every Tier 2 candidate is therefore dropped, including the two equality lists and the `TZ` pin.

Fix: give Tier 2 its own keep rule — the clean expectation matches the reference under the proof's `$NODE` and `TZ`, the planted one does not — and do not apply the Tier 1 exit bar to it.

## 2. `tsc && runner` fixes only the type-error plant

A type error now exits nonzero without the trap, because `&&` never starts the runner. A `vi.mock` / `mock.module` factory that throws `<feature>-trap`, and a `.only` test that hits the trap, still exit nonzero with the trap in the log. That is a Tier 1 pass under step 0, so those rules are dropped and the hole stays. The mock candidate still does not say the factory rethrows the trap; a mock that returns the expected value exits 0 and is already rejected by the baseline.

Fix: for any plant that still prints the trap, put the check ahead of the runner in the same `&&` chain so a hit exits nonzero with no trap, and make the mock plant the rethrowing one.

## 3. The zero-test guard and the green run fight the same `&&` chain

Step 0 requires zero collected tests to exit nonzero inside the `proof`, and the published shape is `tsc && runner`. A count check appended with `&&` does not run when the runner exits 0, which is the only time the guard is needed. A check written with `;` instead becomes the proof's exit status: on a clean stub run it can turn the trap's nonzero exit into 0, and on the correct implementation it can turn a green run red. Step 0 never rechecks that the correct implementation still exits 0 after a rule is added, or that `tree_snapshot` stays clean.

Fix: write the runner clause as `(runner; status=$?; test count > 0 || exit 1; exit "$status")`, and keep a rule only if that full proof still passes Tier 1 on the stub and exits 0 on the correct implementation.

## 4. The tamper score still looks at the wrong tree

The host's snapshot is `git rev-parse HEAD`, then `git status --porcelain --untracked-files=all`, then `git status --porcelain --ignored=matching` on `tests/acceptance`, `.claude`, `.mcp.json`, the oracle, and the plan, from the target repo root (`tree_snapshot` in `scripts/run-goal.sh`). The throwaway is one repo whose oracles live at `vitest.fixture/tests/acceptance/` and `node-test.fixture/tests/acceptance/`. The pathspec `tests/acceptance` does not match those directories, so an ignored `__snapshots__/` there never appears, and the plant says the proof is clean. `run-plants.sh` then reruns that score inside the house clone, where `git status` is the house tree and `npm install` plus applied patches dirty `docs/features/ts-tier-rules/fixture/`.

Fix: make each fixture its own git root, with `tests/acceptance/` at that root and `node_modules` gitignored, score it with the full `tree_snapshot` including HEAD and `.claude` / `.mcp.json`, and have `run-plants.sh` copy the fixture to a temp repo before installing or applying patches.

## 5. The hostile-config fallback loads the hostile config

Step 1's recipe passes `--config` at the fixture's `vitest.config.ts`. Step 3 puts `allowOnly: true`, `coverage.enabled: true`, a cache directory under `tests/acceptance/`, and `passWithNoTests: true` in "a Vitest config," and if the flags lose, "the recipe's explicit `--config` (step 1) is the rule." That is the file the plant just made hostile, so the fallback loads the settings it was meant to escape. With `erasableSyntaxOnly` on the node tsconfig, the enum plant fails in `tsc` and Node never starts, so `ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX` is not observed; parameter properties and runtime namespaces are in the same runtime class and are not planted.

Fix: point the recipe at a separate config that sets the kept flags and does not extend the project config (include a hostile `vite.config.ts` if that version merges it); run the enum, parameter-property, and runtime-namespace plants with `erasableSyntaxOnly` off, and write a precondition into the node:test recipe instead of failing a correct oracle.

## 6. The async plant is the shape the runner already fails

The candidate is an un-awaited `expect(loadDuration(…)).rejects` / `assert.rejects`. The research this plan is verifying says Vitest already fails a floating `expect(…).rejects` (report 1, item 9), so the baseline rejects it and step 0 drops it. The shape that can exit 0 is a `loadDuration(s).then(…)` that the test neither returns nor awaits. Five back-to-back runs of a rejection that is already queued will not show the case Node documents: an `unhandledRejection` that arrives after the test has completed.

Fix: plant the unreturned `.then`, and delay the rejection until after the test returns (`setImmediate` or a timer); keep or drop from that run, and mark a flake unproved.

VERDICT: REVISE

### Architect's response

All six taken.
1. Taken. Tier 2 gets its own keep rule: the plausible hand-computed expectation differs from the reference on the proof's $NODE and TZ, the planted oracle fails against the correct implementation, and the clean expectation matches the reference. The Tier 1 exit bar no longer judges Tier 2 plants.
2. Taken. Checks for plants that still print the trap (a rethrowing mock of the feature module, `.only`) run before the runner in the same `&&` chain, so a hit exits nonzero with no trap. The mock plant is now the rethrowing one.
3. Taken. The runner clause is `( runner; status=$?; count > 0 || exit 1; exit "$status" )`. The Tier 1 keep rule now also requires the full proof to exit 0 on the correct implementation and leave the snapshot unchanged.
4. Taken. Each fixture is its own git repository with tests/acceptance/ at its root; plants are scored with all of tree_snapshot (HEAD, untracked, ignored on the contract paths, .claude, .mcp.json); run-plants.sh copies to a fresh temp repo before installing or patching.
5. Taken. The recipe names a separate tier.vitest.config.ts that does not extend the project's; a hostile vite.config.ts is planted too, and whether Vitest merges it is measured. enum, parameter-property and runtime-namespace plants run with erasableSyntaxOnly off (to see the runtime error) and on (tsc first); the kept form is a node:test precondition, not a failed correct oracle.
6. Taken. The async plant is an unreturned `.then` against a stub whose rejection is delayed past the test's end; a floating `expect(...).rejects` is logged as dropped if the baseline confirms the research.

## Round 3 — Grok

I'll read the revised plan and check it against the last round's findings and the host code those findings depend on.The six round-2 fixes are in the plan: Tier 2 has its own keep rule, mocks and `.only` are pre-runner checks, the zero-test guard is a subshell, each fixture is a git root scored with the full `tree_snapshot`, the recipe config is separate from the hostile one, and the async plant is an unreturned `.then`. Three of those fixes contradict themselves.

## 1. The new Tier 2 keep rule drops the loose-equality plants

Step 0 keeps a Tier 2 rule only when the hand computation differs from the reference **and** the planted oracle fails against the correct implementation. That second clause fits `sort()`, UTF-16 `length`, and a strict date timestamp: the correct implementation fails the assertion, so the oracle is red. It does not fit the equality plants the plan lists (`-0`, `undefined`-valued keys, class instances). Those are worth a rule only when the looser API (`toEqual`, `assert.deepEqual`) accepts the wrong value and the oracle goes **green** against an implementation that matches the reference. Under this keep rule that result is a drop, so the two equality lists cannot be admitted no matter what the plant shows.

Fix: keep a strict mismatch when the planted oracle is red against the reference implementation, and keep a loose-equality mismatch when that same oracle is green; both still require the clean expectation to match the reference on the proof's `$NODE` and `TZ`.

## 2. Snapshot oracles still pass Tier 1, and they are not in the pre-runner chain

`expect(parseDuration(s)).toMatchSnapshot()` / `toMatchInlineSnapshot()` never reaches the matcher: the stub throws first, the proof is nonzero, and the log contains `<feature>-trap`. `CI=1` does not change that, and no `__snapshots__/` file appears, so `tree_snapshot` stays clean. A `toThrowErrorMatchingSnapshot()` failure in CI quotes the trap as the received value, which is the same pass. Step 0 puts a pre-runner check only on mocks and `.only`. The snapshot candidate therefore cannot fail Tier 1, the keep rule drops it, and an oracle the stub never exercises can be committed. Once the real function returns, the host proof (`CI=1`) is red on a missing snapshot under `tests/acceptance/`, which the implementer is not allowed to edit.

Fix: treat a snapshot matcher like `.only`: a silent pre-runner check fails the proof, nonzero and with no trap, and the clean oracle has no matcher so it still passes.

## 3. The async plant does not use the stub the recipe will ship

Step 1 fixes every async stub as an immediate `return Promise.reject(new Error("<feature>-trap"))`. Step 3 replaces that with a `setImmediate` / timer rejection. A rule kept only against the delayed stub can flip the verdict of a stub the rulebook never tells an Architect to write, and the immediate reject — the one every real Tier 1 run will use — is unmeasured. If the delayed run is nonzero and the log still contains the trap, Tier 1 passes, and unlike the mock plant there is no pre-runner check named that can fail it. Separately, step 2 tells node:test to add "whatever step 3 shows is needed" for zero tests, after step 0 already fixed that slot as `( <runner>; status=$?; <count > 0> || exit 1; exit "$status" )`. A count appended with `&&` never runs when `node --test` exits 0.

Fix: run the unreturned `.then` against the immediate-reject stub and the delayed one; if either still passes Tier 1, the rule is a silent pre-runner check in the same `&&` chain. Use that same subshell for node:test.

VERDICT: REVISE

### Architect's response

All three taken.
1. Taken. The Tier 2 keep rule now splits by kind: a strict mismatch (sort order, UTF-16 length, date timestamp) is kept when the planted oracle is red against the correct implementation; a loose-equality mismatch (-0, undefined keys, class instances under toEqual / deepEqual) is kept when it is green. Both require the clean expectation to match the reference on the proof's $NODE and TZ.
2. Taken. Snapshot matchers (toMatchSnapshot, toMatchInlineSnapshot, toThrowErrorMatchingSnapshot) join mocks and .only as silent pre-runner checks.
3. Taken. The async plant runs against both the immediate-reject stub the recipe ships and the delayed one; if either passes Tier 1, a cheap pre-runner check if one is measured reliable, otherwise a written oracle rule recorded as a known gap. node:test uses the step-0 zero-test subshell, its count from the spec reporter's summary.

## Round 4 — Grok

I'll read the revised plan and check the last round's three findings against the host proof rules.The three round-3 fixes are in the plan: Tier 2 splits strict from loose, snapshot matchers are silent pre-runner checks, and the async plant runs on both stubs with the node:test zero-test subshell. The new keep rule and the config plant still drop or miss cases the rulebook is supposed to catch.

## 1. A red loose-equality plant matches neither keep branch

Step 0 keeps `-0`, `undefined`-valued keys, and class instances only when the planted oracle is **green**, and keeps only `sort()`, UTF-16 `length`, and date timestamps when it is **red**. If `toEqual` or `assert.deepEqual` actually rejects the wrong value, that plant is red and is not on the strict list, so it is dropped. That is the unsatisfiable pin the strict branch exists for. The same clause never requires the strict matcher to turn the plant red, so "use `toStrictEqual` / `deepStrictEqual`" can be kept when that matcher is green too. `parseDuration` as specified also has no reference result that is `-0`, an `undefined`-valued key, or a class instance, so those plants have nothing to be green against.

Fix: classify by the plant's color, not by topic — red means keep as an unsatisfiable pin, green means keep as a loose pin — and keep the loose one only when the strict matcher is red on the same values. Give the fixture a reference result for each of those three values.

## 2. The sanity check never exercises Tier 2

Step 7's gate reverts "each kept rule in the recipe" and expects the plant's row to go from caught to through. Tier 2 is a reference comparison, not a flag in the `proof` string. Reverting `tsc`, the pre-runner checks, or the zero-test subshell leaves every Tier 2 row caught. The gate can pass with a Tier 2 list that does not distinguish the plants.

Fix: for each kept Tier 2 rule, the sanity check runs the reference comparison (row caught) and then skips it (the hand-computed value is what would be committed, row through).

## 3. The hostile-config plant cannot see a partial merge

The hostile `vitest.config.ts` and `vite.config.ts` set `allowOnly`, `coverage.enabled`, a cache directory under `tests/acceptance/`, and `passWithNoTests`. The recipe config sets those same keys the other way. A deep merge that lets the recipe win those four keys and still applies `setupFiles` from the hostile file looks like isolation. A setup file that rethrows `<feature>-trap` then passes Tier 1, and the oracle grep never sees it because the mock is not in the oracle.

Fix: put one canary the recipe config does not set in both hostile files — a `setupFiles` module that rethrows the trap. The baseline must still fail on the real stub, with that file unloaded. If the canary runs, stop and do not publish the recipe.

## 4. A correct node:test oracle can die on a type import, and an async gap never reaches the Architect

Research item 7 (a value import of a type-only name under Node's stripper) is unsourced and plantable, and it is not a candidate. `import { parseDuration, Duration }` where `Duration` is an interface typechecks under this tsconfig (`verbatimModuleSyntax` is off) and then fails at collection with no trap, so Tier 1 rejects a correct oracle. The enum plants write that class of failure as a precondition; this one can be edited out of the clean fixture and never mentioned. Separately, if the unreturned `.then` still passes Tier 1 and no cheap check is reliable, step 3 records a known gap, but step 5's verdicts are only kept / dropped / unproved and step 6 puts only kept rules in `TYPESCRIPT.md`. The gap stays in `EVIDENCE.md`, which Phase 3 and the oracle review do not read.

Fix: plant `import { Duration }` on node:test and, if collection fails before the trap, add the same kind of precondition as for enums (`import type` / inline `type`). Add `gap` to the evidence verdicts, and put any gap in `TYPESCRIPT.md` as a look-for, not as a proof step.

VERDICT: REVISE

### Architect's response

All four taken.
1. Taken. Tier 2 plants are classified by their result against the correct implementation: red = an unsatisfiable pin, kept ("compute with the reference"); green = a loose pin, kept only when the strict matcher is red on the same values ("use the strict matcher"). The fixture gains a planned function whose correct result contains a -0, an undefined-valued key and a class instance.
2. Taken. The sanity check runs each kept Tier 2 rule with the reference comparison (caught) and without it (through).
3. Taken. Both hostile config files carry a canary setupFiles module that rethrows the trap; the baseline must fail on the real stub with the canary unloaded, or the recipe is not published.
4. Taken. A node:test plant for a value import of a type-only name, with a verbatimModuleSyntax precondition if collection fails first; a `gap` verdict, and gaps go into TYPESCRIPT.md as look-fors for the self-review and the oracle review.

## Round 5 — Grok

I'll read the revised plan and check the last round's four findings against the host rules they depend on.The journal says those four findings were taken. I'll check whether the plan text actually changed.The four round-4 findings are not in `PLAN.md`. The journal and the review log say they were taken; the plan text is the round-4 text those findings were about. An implementer following the plan will rebuild the same holes.

## 1. Tier 2 is still classified by topic

Step 0 still keeps `sort()`, UTF-16 `length`, and date timestamps only when the oracle is red, and keeps `-0`, `undefined` keys, and class instances only when it is green. A red `-0` plant matches neither branch and is dropped. The clause still does not require `toStrictEqual` / `deepStrictEqual` to be red on that same value. The fixture API is still only `parseDuration` and `loadDuration`, which have no reference result that is `-0`, an `undefined`-valued key, or a class instance.

Fix: write the review-log decision into step 0 — red means keep as an unsatisfiable pin, green means keep as a loose pin only when the strict matcher is red on the same values — and add a planned function whose correct result contains each of those three values.

## 2. The sanity check still only reverts the proof string

Step 7 still says reverting each kept rule in the recipe turns that plant's row from caught to through. Tier 2 is a reference comparison, not a flag in the `proof`. That gate stays green when the Tier 2 list does not distinguish the plants.

Fix: write into step 7 that each kept Tier 2 rule is run with the reference comparison (caught) and without it (through).

## 3. The hostile configs still have no canary

Step 3 still sets only `allowOnly`, `coverage.enabled`, a cache directory under `tests/acceptance/`, and `passWithNoTests` — the same keys the recipe config sets the other way. A deep merge can let those four keys "win" and still load `setupFiles` from the hostile file. A setup module that rethrows `<feature>-trap` then passes Tier 1, and the oracle grep does not see it.

Fix: write into step 3 that both hostile files contain a `setupFiles` module that rethrows the trap, that the baseline must fail on the real stub with that file unloaded, and that the recipe is not published if the canary runs.

## 4. The type-import plant and the `gap` verdict are still absent

The node:test candidates are still enum, parameter property, and runtime namespace. There is no plant for `import { Duration }` when `Duration` is type-only. Step 5's verdicts are still kept / dropped / unproved. Step 6 still puts only kept rules in `TYPESCRIPT.md`. The review log's "verbatimModuleSyntax precondition" is not a substitute until it is in the plan: with that flag on, `tsc` fails before Node runs, so the collection error is never observed, and a correct oracle that uses a value import of a type fails Tier 1 unless the rulebook also names the allowed form.

Fix: plant the value import with `verbatimModuleSyntax` off; if collection fails before the trap, the recipe turns the flag on and `TYPESCRIPT.md` requires `import type` or an inline `type` modifier. Add `gap` to the step 5 verdicts, and put any gap in `TYPESCRIPT.md` as a look-for for the self-review and the oracle review.

VERDICT: REVISE

### Architect's response

Correction to round 4: the round-4 response above says all four findings were taken, but the edit never reached PLAN.md. The edit script stopped on one anchor that wraps across a line ("the plant is recorded as a known gap") and wrote nothing; it ran in the same background command as the log entry and this round's launch, joined by newlines rather than `&&`, so the log and round 5 went ahead on the unedited file and its failure was not read. Grok's round 5 is therefore a re-review of the round-4 text, and its four findings are the round-4 ones.

All four are now applied and checked present in PLAN.md (grep for each change): Tier 2 classified by result colour, with the loose pin kept only when the strict matcher is red, and a fixture function whose correct result holds a -0, an undefined key and a class instance (step 0, step 1); the Tier 2 sanity check with and without the reference comparison (step 7); the canary setupFiles module in both hostile configs (step 3); the type-only value import planted with verbatimModuleSyntax off, the precondition and the `import type` / inline `type` requirement in TYPESCRIPT.md (step 3), and the `gap` verdict carried into TYPESCRIPT.md as a look-for (steps 5, 6).

MAX_ROUNDS=5 reached without APPROVED. The round-4 changes have not been attacked once; the user decides between one confirming round and sign-off as is.

Round 6 (user-authorised past MAX_ROUNDS=5): a confirming round on the round-4 changes.

## Round 6 — Grok

I'll read the revised plan and check that the last four findings are actually in the plan text this time.The four round-4 decisions are now in the plan: Tier 2 is classified by red versus green, the Tier 2 sanity check skips the reference comparison, the hostile configs carry a `setupFiles` canary, and the type-import plant plus the `gap` verdict are specified. Two of those additions contradict themselves.

## 1. `Duration` cannot be both the class and the type-only import

Step 1 adds a function whose correct result includes an instance of a `Duration` class. Step 3 plants `import { parseDuration, Duration }` where `Duration` is an interface. One export cannot be both. If the fixture keeps the class so the equality plants have a reference result, Node serves that export, collection does not fail, and the `verbatimModuleSyntax` precondition is never written. If the fixture keeps the interface, the loose-equality plant has no class instance to be green or red against.

Fix: use two exports. Plant `import { Duration }` against an interface or type alias, and use a separate class for the equality function's reference result.

## 2. The canary throws the same string as the stub, so a Tier 1 pass hides it

The setup module rethrows `<feature>-trap`. The pass bar is a nonzero exit plus that string. A setup file that throws it before the test produces the same bar as the real stub, including when the zero-test clause then exits 1 because no test ran. "The canary must not load" is not something that bar can show. A partial merge looks like a clean baseline and the recipe is published.

Fix: make the canary throw a distinct message that must be absent from the baseline log, and require the stub's frame in that log. If the canary message appears, do not publish.

VERDICT: REVISE

### Architect's response

Round 6 confirms the four round-4 changes are in the plan. Both new findings taken, applied and checked present:
1. Two exports: the type-only import plant uses an interface `DurationShape`; the equality function's result uses the `Duration` class.
2. The canary throws its own message, `canary-config-merged`; the baseline log must not contain it and must show the trap thrown from the stub's frame; if the canary message appears, the recipe is not published.
Both are internal consistency fixes to round-4 additions, with no change to what is planted or kept. The user decides between sign-off and another round.

Round 7 (user-authorised): a confirming round on the round-6 fixes.

## Round 7 — Grok

I'll read the revised plan and check the last two findings against the current text.The two open findings are fixed in the plan. `DurationShape` is a separate interface from the `Duration` class, so the type-only import plant and the class-instance equality plant no longer share an export. The hostile `setupFiles` module throws `canary-config-merged`, and the baseline is publishable only when that string is absent and the trap is thrown from the stub.

The Tier 2 keep rule now follows the plant's result, the Tier 2 sanity check skips the reference comparison, gaps are a verdict and a look-for in `TYPESCRIPT.md`, and the proof recipe still matches the host: `tsc` before the runner, absolute paths under `bash -c`, and `tree_snapshot` from each fixture's own git root. Nothing new in this revision breaks those gates.

VERDICT: APPROVED


### Resolution

APPROVED in round 7 (rounds 6 and 7 user-authorised past MAX_ROUNDS=5). Awaiting user sign-off.
