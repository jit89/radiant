# Evidence: TypeScript rules for Tier 1 and Tier 2 (house item 9)

Every rule in `skills/to-goals/TYPESCRIPT.md` is here with the plant that
proves it. `fixture/run-plants.sh all` reruns all of it: its `CASES` table is
this file's table (72 cases), followed by the Tier 2 reference check.
`fixture/run-plants.sh diff <plant>` shows what a plant changes.

## Versions

Node v24.21.0 (fnm); Vitest 5.0.4 (`sha512-z0WxZRV2Sg48wF0FSgMq3TFG8JS38/Qr9…`);
TypeScript 7.0.2 (`sha512-8FYau96o3NKOhbjKi/qNvG/W5jhzxkbdm…`); @types/node
26.6.5 (node:test fixture). Full hashes are in each fixture's
`package-lock.json`. The research (`docs/research/2026-10-12-typescript-tier-rules.md`)
assumed TypeScript 5; each of its claims a run could show was measured here
instead.

## How a case is run and scored

A case copies a fixture to a fresh temporary git repository (`tests/acceptance/`
at its root, `node_modules/` ignored) and lays a variant over
`src/duration.ts`: the stub (`variants/stub.ts`: every sync body throws
`duration-trap`, every async body returns a rejected promise), a stub whose
rejection arrives 200 ms late (`stub-late.ts`), the correct implementation
(`impl.ts`), or one whose async result is wrong and late (`wrongload-late.ts`).
It overlays the plant and runs a recipe: the literal one-line `proof` string
from `<fixture>/recipes/`, with `$NODE` and `$REPO` filled in, run by `bash -c`
under `env -i HOME=… PATH=/usr/bin:/bin TZ=Asia/Kolkata`. That is stricter
than the host, which keeps the walk's environment minus credential variables:
no Node on `PATH` is the worst case, and the non-UTC zone means only the
recipe's own `TZ=UTC` makes a UTC expectation hold. It scores the exit code, whether
`duration-trap` is in the output, whether the host's `tree_snapshot` (HEAD,
untracked files, ignored files under `tests/acceptance`, `.claude`,
`.mcp.json`) changed, and, where the row names one, an expected-output pattern
(`TS2345`, `TS1294`, `ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX`, …). Rows marked `*5`
run five times and must agree. Each `recipes/minus-<rule>.txt` removes exactly
one rule from `recipes/proof.txt`; every row must run (the harness counts
them).

**Tier 1 keep rule** (PLAN step 0): with the rule in the proof, the clean
oracle passes Tier 1 on the stub, the proof is green on the correct
implementation, and nothing is left behind; and the planted oracle passes
Tier 1 without the rule ("through": nonzero, the trap, no tamper) and fails it
with the rule. **Tier 2 keep rule**: the clean expectation matches the
reference (`fixture/reference/expected.mjs`, written before any
implementation, importing nothing, every value computed) and the
hand-computed slip does not — the `tier2` step pins the reference value at the
`sortMinutes`, `labelWidth` and `dayStartMs` calls of both clean oracles and
checks the sort and length plants carry the hand slip; the `-0` and
`undefined`-key values are checked in the reference itself, and the loose
plants by their CASES rows; a plant red against
the correct implementation is an unsatisfiable pin (rule: compute with the
reference), one green is a loose pin, kept only when the strict matcher is
red on it (rule: use the strict matcher).

## Baselines

| Case | Result |
|---|---|
| Vitest, clean oracle, stub | exit 1, trap from `src/duration.ts`, no tamper — Tier 1 passes |
| Vitest, clean oracle, correct implementation | exit 0, no tamper |
| node:test, clean oracle, stub | exit 1, trap from the stub's frame, no tamper — Tier 1 passes |
| node:test, clean oracle, correct implementation | exit 0, no tamper |

## Kept

| Rule | Runner | Plant | Without the rule | With it |
|---|---|---|---|---|
| `tsc --noEmit` before the runner | both | a wrong-typed call (`scale(d, "-1")`) | through | caught, `TS2345` |
| same | Vitest | an invented symbol (`formatDuration`) | through (the other tests still print the trap) | caught, `TS2305` |
| a recipe config with `allowOnly: false`, not extending the project's | Vitest | `.only` on one test | through on the stub (one test of seven runs); green on the implementation | caught |
| same | Vitest | a hostile project `vitest.config.ts` and `vite.config.ts` (allowOnly, `cacheDir` under `tests/acceptance/`, passWithNoTests, a `setupFiles` canary throwing `canary-config-merged`) | with the project config: the canary runs, the cache lands under `tests/acceptance/` (tamper) | canary absent, trap from the stub, no tamper; a `.only` in the hostile setup still caught |
| the check (Vitest): `vi.mock` / `vi.doMock`, snapshot matchers, `.then(` | Vitest | a partial `vi.mock(import(…), importOriginal)` stubbing `loadDuration` with a resolved value | through on the stub; green on the implementation (`loadDuration` never tested) | caught |
| same, recursive | Vitest | the mock in `tests/acceptance/nested/helper.ts` | — | caught (the check names the nested file) |
| same | Vitest | `toMatchSnapshot()` | through on the stub; on the implementation Vitest writes the snapshot under `tests/acceptance/` (tamper) | caught |
| same | Vitest | an unreturned `loadDuration(s).then(…)` | through on the stub and on the late stub (5/5 each); **green** on an implementation whose wrong value arrives 200 ms late (5/5) | caught |
| the check (node:test): `assert.snapshot` | node:test | `t.assert.snapshot(…)` | through on the stub; red on the implementation ("Missing snapshots") | caught |
| `--incremental false` | both | a tier tsconfig extending a project tsconfig with `incremental: true` | `.tsbuildinfo` written: tamper | no file |
| `TZ=UTC` on every command | both | none needed: the clean oracle's reference value is UTC midnight | the clean oracle is red on the correct implementation (`TZ=Asia/Kolkata`) | green |

The check fails closed by construction (`( grep -rlE … ; test $? -eq 1 )`: a
match or a grep error fails the proof; the error case is not planted) and
prints file names only. Printing the matched line is hygiene, not a measured
rule: a line can carry the trap text and pass Tier 1; no case plants that.

`.only` is also caught by `CI=1` alone (the `ci-only` row: the project
config, `CI=1`); with neither, it gets through. The recipe keeps the explicit key,
which does not depend on the environment, and drops `CI=1`.

## Preconditions (node:test)

These do not change a verdict: without them a correct oracle already fails
Tier 1, with no trap. They make `tsc` name the line instead of Node failing at
load.

| Precondition | Plant | Off | On |
|---|---|---|---|
| `erasableSyntaxOnly: true` | an `enum`; a parameter property; a runtime `namespace` | `ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX` at load, on the correct implementation too | `TS1294` from `tsc` |
| `verbatimModuleSyntax: true`, and `import type` / `{ type X }` | `import { …, DurationShape }` where `DurationShape` is an interface | "does not provide an export named", on the correct implementation too | `TS1484` from `tsc`; with `type DurationShape` the oracle passes Tier 1 and is green |

## Tier 2

| Rule | Plant | Result on the correct implementation |
|---|---|---|
| compute with the reference | string-order `sort()` (`[25, 60, 9]` for `[9, 25, 60]`); UTF-16 `length` (4 for `go🚀`, code points 3); `+0` for `-0` and no `undefined` key under `toEqual` / loose `deepEqual` | red (unsatisfiable pins); the reference gives the right values (`tier2` step) |
| use the strict matcher (`toStrictEqual`, `assert.deepStrictEqual`) | `toEqual({ hours: -0, minutes: -5 })` for a `Duration` with `label: undefined`; loose `deepEqual` with `{ hours: 0, … }` for `-0` | **green** with the loose matcher (loose pin); red with the strict one |
| `TZ=UTC` (above) | a date-only expectation | green under `TZ=UTC`, red under Asia/Kolkata |

## Dropped

| Candidate | Runner | Why |
|---|---|---|
| a zero-test guard | both | a filter that matches nothing exits 0 on the stub, and Tier 1 already fails a zero exit; a path typo fails without the trap |
| `.only` | node:test | Node runs every test unless `--test-only` is given |
| an invented symbol | node:test | module linking fails before any test ("does not provide an export"), without the trap |
| an unreturned `.then` | node:test | the runner fails the late assertion (red on the late wrong value, 5/5) |
| `mock.module` | node:test | "mock.module is not a function" in Node 24 without `--experimental-test-module-mocks` |
| `CI=1` | Vitest | redundant with `allowOnly: false` (above) |
| a bare `toThrow()`; `expect.hasAssertions()` | — | dropped in the plan: the first exits 0 against the stub, which Tier 1 rejects; the second reddens the clean oracle too |
| `0.1 + 0.2`, Turkish `i`, `Map` key order | — | general JavaScript facts a computed expectation rarely hits; not planted (PLAN step 3) |

## Gaps (look-fors in TYPESCRIPT.md)

The check matches only the shapes planted. Not covered, not planted: another
way to leave an async call neither awaited nor returned (a callback, a
`.catch(` chain, `void p`); a mock written another way (`vi.spyOn` on the
feature module); `.skip` or `.todo` on the goal's own case.

## Not measured

Jest, Bun and Deno (out of scope, Q1). Whether Vitest drops an unused value
import of a type-only name (not planted for Vitest). Coverage written by an
inherited config (the hostile-config runs used the project config directly,
with coverage removed, as `@vitest/coverage-v8` is not installed). Other Node,
Vitest or TypeScript versions — after an upgrade, bump the fixture's
`package.json`, regenerate its lockfile and rerun `fixture/run-plants.sh all`.
