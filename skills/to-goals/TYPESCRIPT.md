# TypeScript: Tier 1 and Tier 2

The TypeScript rules for proving an oracle (SKILL.md §4, GOAL-FORMAT.md "the
tiers"), for **Vitest** and **node:test**, measured on Node 24.21.0, Vitest
5.0.4 and TypeScript 7.0.2 against planted oracle defects
(`docs/features/ts-tier-rules/EVIDENCE.md` on the house's main branch). Each rule marked
*kept* either turned a planted defect that passed Tier 1 into a Tier 1
failure, or turned a red or tampering run of the correct implementation
green and clean; the *preconditions* do not change a verdict — without them
the oracle already fails, with no trap — they make `tsc` name the line
instead. Another runner
(Jest, Bun, Deno) gets its rules proved the same way before its first oracle.

## The `proof`, as the host runs it

The host runs a `proof` with `bash -c` in the walk's environment minus
credential variables: no login shell, so a version manager's Node may or may
not be on `PATH`; the implementer's sandbox, which runs the same command, has
no network. So call Node and every tool by absolute path, and install
dependencies from the lockfile before the first goal. The recipes were proved
in the strictest case: `env -i`, `PATH=/usr/bin:/bin`. `$NODE` and `$REPO` are
the target's absolute paths, written into the `proof` literally. Each recipe
is one line in GOALS.md (shown wrapped here). It starts with `(`, not `!`,
which YAML would read as a tag.

**Vitest:**

```bash
( grep -rlE 'vi\.(mock|doMock)\(|toMatch(Inline|File)?Snapshot|toThrowErrorMatching(Inline)?Snapshot|\.then\(' --include='*.ts' tests/acceptance; test $? -eq 1 ) &&
TZ=UTC "$NODE" "$REPO/node_modules/typescript/lib/tsc.js" --noEmit --incremental false -p tier.tsconfig.json &&
TZ=UTC "$NODE" "$REPO/node_modules/vitest/vitest.mjs" run --config tier.vitest.config.ts tests/acceptance/<id>.test.ts
```

`tier.vitest.config.ts` (never imports or extends the project's config):

```ts
import { defineConfig } from "vitest/config";
export default defineConfig({ test: { include: ["tests/acceptance/**/*.test.ts"], allowOnly: false } });
```

`tier.tsconfig.json`: `strict`, `target: es2022`, `module: esnext`,
`moduleResolution: bundler`, `noEmit`, `skipLibCheck`, `types: []`;
`include` = the oracle and the code it imports. With more than one goal, one
`tier.<id>.tsconfig.json` per goal, its `include` naming that goal's oracle
only, and the proof's `-p` names it: one shared file listing every oracle makes
`tsc` fail every earlier goal on a later goal's red oracle (GOAL-FORMAT.md,
"Registration points").

**node:test** (dev dependencies `typescript` and `@types/node`):

```bash
( grep -rlE 'assert\.snapshot\(' --include='*.ts' tests/acceptance; test $? -eq 1 ) &&
TZ=UTC "$NODE" "$REPO/node_modules/typescript/lib/tsc.js" --noEmit --incremental false -p tier.tsconfig.json &&
TZ=UTC "$NODE" --test --test-reporter=spec tests/acceptance/<id>.test.ts
```

`tier.tsconfig.json`: `strict`, `target: es2022`, `module` and
`moduleResolution: nodenext`, `allowImportingTsExtensions`,
`erasableSyntaxOnly`, `verbatimModuleSyntax`, `noEmit`, `skipLibCheck`,
`types: ["node"]`; `include` = the oracle and the code it imports; imports
written with their `.ts` extension.

The pass bar is GOAL-FORMAT's, applied to the whole `proof`.

## Why each piece is there

- **Kept: `tsc` before the runner.** Vitest and Node's type stripping never
  check types: a wrong-typed call (both runners) or an invented symbol
  (Vitest) still reaches the trap and passes Tier 1. Chained with `&&`, a type
  error exits nonzero without the trap.
- **Kept: the recipe config with `allowOnly: false` (Vitest).** With the
  project's config, a `.only` left in an oracle runs one test of seven and
  passes Tier 1. `CI=1` alone also stops it; the explicit key does not
  depend on the environment. With a hostile project config, a setup file ran
  and the cache landed under `tests/acceptance/` (tampering); a config that
  extends the project's would inherit both (not planted).
- **Kept: the check.** It searches every `.ts` under `tests/acceptance/`,
  subdirectories included, and fails closed by construction (`test $? -eq 1`:
  a match or a `grep` error fails the proof; the error case is not planted).
  It prints file names only: printing the matched line could print the trap
  text and pass Tier 1. It rejects:
  - any `vi.mock` / `vi.doMock` call (a partial mock of the feature module
    passed Tier 1 and went green with the mocked function never tested);
  - any snapshot matcher, and node:test's `assert.snapshot` (the stub throws
    before it, so Tier 1 passes; on the implementation Vitest then writes the
    snapshot under `tests/acceptance/`, which the host calls tampering, and
    node:test fails on the missing snapshot file — the walk cannot finish);
  - any `.then(` (Vitest: an unreturned `.then` passed Tier 1 and went green
    on a wrong value that arrived late) — oracles `await` instead.
- **Kept: `--incremental false`.** A tier tsconfig that extends a project
  tsconfig with `incremental` on wrote a `.tsbuildinfo` the host calls
  tampering.
- **Kept: `TZ=UTC`** on every command. The reference value for a calendar day
  is UTC midnight; under Asia/Kolkata (any zone off UTC on that date) the
  correct implementation failed.
- **Preconditions (node:test).** Node's stripping refuses `enum`, parameter
  properties and runtime `namespace`s at load, and a value import of a
  type-only name fails to link — the correct implementation fails too, with no
  trap. `erasableSyntaxOnly` and `verbatimModuleSyntax` make `tsc` name the
  line (`TS1294`, `TS1484`); write type-only imports as `import type` or
  `{ type X }`.

Measured and not needed: a zero-test guard (a run that collects nothing exits
0 or fails without the trap; Tier 1 already rejects both); `.only` on
node:test (ignored without `--test-only`); an invented symbol on node:test
(module linking fails); an unreturned `.then` on node:test (the runner fails
the late assertion); `mock.module` (absent in Node 24 without a flag).

## Tier 2: computed expectations

Compute every expected value the plan does not state verbatim with a
reference that imports nothing from the code under test, run on the proof's
own `$NODE` with `TZ=UTC`; record its output with the oracle. Slips it caught:

- default `sort()` orders numbers as strings (`[60, 25, 9]` → `[25, 60, 9]`);
- `length` counts UTF-16 units (`"go🚀".length` is 4; code points `[...s]` 3);
- a negated zero is `-0`, and a class instance carries its `undefined` keys.

Use the strict matcher: **Vitest** `toStrictEqual`, not `toEqual` (it ignores
`undefined`-valued keys and the class); **node:test** `assert.deepStrictEqual`
from `node:assert/strict`, not `assert.deepEqual` from `node:assert` (it
treats `-0` as `0` and ignores the prototype). The loose ones accepted a wrong
expected value on the correct implementation.

## Look for (self-review and oracle review)

Not covered by the check, not planted:
- a call into the planned async API neither awaited nor returned in another
  shape — a callback, a `.catch(` chain, `void p` (await or return each one);
- a mock written another way — `vi.spyOn` on the feature module;
- `.skip` or `.todo` on the goal's own case (it runs nothing and passes).

## After an upgrade

Bump the versions in each fixture's `package.json` under
`docs/features/ts-tier-rules/fixture/` (on the house's main branch), regenerate its lockfile, then run
`NODE=<abs node> docs/features/ts-tier-rules/fixture/run-plants.sh all` (one
`npm ci` with network, cached by lockfile hash). Every case should match; a
mismatch names the rule to recheck before these rules are trusted on the new
versions.
