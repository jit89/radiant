# TypeScript rules for Tier 1 and Tier 2 oracle checks (research, 2026-10-12)

Two Haiku 5.5 research agents (high effort, web search and fetch, read-only) were
asked for the TypeScript-specific rules and pitfalls of the two cheap oracle
checks in `skills/to-goals/GOAL-FORMAT.md` ("Prove the oracle is satisfiable — the
tiers"), with a primary source for every rule. Their reports are below, lightly
formatted. **Not yet verified by the Architect**: every URL and claim is to be
checked before any of it becomes a rule (FUTURE-WORK item 9). Items the agents
could not source are marked *unsourced*; two fetches failed (tsx.is had a
certificate error; the Jest configuration page was truncated).

## Key Takeaways

- **Tier 1 needs a type check of its own.** Vitest (esbuild), Node's type
  stripping, Bun and Jest with babel/swc only strip types, so an oracle with a
  wrong-typed call or a missing type runs as plain JS and can still reach the
  trap: Tier 1 passes on an oracle `tsc` would reject. Add `tsc --noEmit
  --incremental false -p tsconfig.tier1.json` over the oracle and stub files, in
  addition to the run (GOAL-FORMAT's "never compile-only" forbids compiling
  *instead of* running, not as well as).
- **Async and mocks are the TypeScript ways to pass against the stub**: an
  un-awaited rejection, a bare `toThrow()`, or a `vi.mock`/`jest.mock` of the
  feature module that replaces the trap. Pin the trap text and require it in the
  output; grep oracles for mocks of new modules.
- **Vacuous runs**: `.only` is allowed locally in Vitest unless `CI` is set;
  snapshots auto-write (Vitest, locally) or auto-pass (Jest, CI); node:test's
  zero-file exit code is unsourced. Use `CI=1`, `allowOnly: false`, no snapshot
  oracles, and count the tests run.
- **The proof must leave no files**: coverage, `.tsbuildinfo`, the Vite/Vitest
  cache, Jest's cache, `__snapshots__`. Disable each and fail on any new path in
  `git status --porcelain` (the analogue of `PYTHONDONTWRITEBYTECODE`).
- **Tier 2's traps in JS are number, order, string and time semantics** that a
  hand-computed expectation gets wrong: IEEE doubles and `-0`, string-order
  `sort()`, UTF-16 `length`, date-only strings parsing as UTC, `toEqual`
  ignoring `undefined` keys. Cross-check in the scratchpad on the proof's own
  runtime, TZ and ICU, against a same-semantics reference, a brute-force model,
  or a fast-check property (keep the seed).

## Why it matters

Tier 1 and Tier 2 exist so that a cheap run, not a full scratch implementation
by the expensive model (Tier 3), shows an oracle can fail only for its own
reason and will pass once the feature is right. Planted bugs and these checks
are not meant to catch every possible error, only the ones that would really
break an oracle in this language. A TypeScript rule set that misses the
type-check gap or the async/mocking ways to pass against the stub would push
TypeScript goals back to Tier 3.

## Report 1 — Tier 1 (the trap-stub run of the goal's `proof`)

**Type checking**
1. Vitest transpiles with esbuild and does not type-check a normal run; `typecheck.enabled` defaults to `false`; `vitest --typecheck` runs `tsc` only on `*.test-d.ts` files, which are not executed. A wrong-typed call in `*.test.ts` runs as plain JS and only fails at run time. — https://vitest.dev/config/typecheck, https://vitest.dev/guide/testing-types
2. So Tier 1 needs a separate `tsc --noEmit -p <tier1 tsconfig>` whose `include` is the oracle files plus the stub files; Vitest's typecheck mode calls `tsc` itself, with no runner-level scoping. — same pages
3. Jest with ts-jest type-checks by default; with `isolatedModules` enabled it does not. Babel or swc Jest transforms do not type-check (*unsourced*). — https://kulshekhar.github.io/ts-jest/docs/getting-started/options/isolatedModules
4. node:test with Node's built-in type stripping does no type checking; enums, namespaces with runtime code and parameter properties throw `ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX`; import specifiers need explicit `.ts` extensions. Stripping is on by default from v23.6.0 and v22.18.0, stable from v25.2.0 and v24.12.0. — https://nodejs.org/api/typescript.html
5. Bun: `bun test` does not check types (`bun test --check` / `bun check` do). — https://bun.com/docs/test/writing-tests
6. Deno: `deno test` type-checks local modules by default; `--no-check` skips it. — https://docs.deno.com/runtime/reference/cli/test/
7. Whether a value import of a type-only name fails at run time under Node's stripping: *unsourced*.

**Async**
8. Vitest reports unhandled promise rejections as errors and fails the run even when every assertion passed. — https://vitest.dev/guide/learn/async
9. Vitest fails a test with an un-awaited `expect(...).resolves/.rejects`. — same page
10. node:test fails a test on `uncaughtException`/`unhandledRejection` only after it completed; behaviour during a running test is not confirmed. — https://nodejs.org/api/test.html
11. Whether a bare `toThrow()` matches any throw: *unsourced*. Rule: pin the trap text, `toThrow("<feature>-trap")`, and check the trap appears in the output.

**Vacuous passes**
12. Vitest `passWithNoTests` defaults to `false` (the exact exit code of "No test files found", 1, is community-observed). — https://vitest.dev/config/passwithnotests
13. Vitest `allowOnly` defaults to `!process.env.CI`: a `.only` is allowed locally. Set `allowOnly: false`. — https://vitest.dev/config/allowonly
14. node:test honours `only` only with `--test-only` or isolation off; `todo` tests do not affect the exit code. — https://nodejs.org/api/test.html
15. Deno: any `only` test makes the run fail; `--permit-no-files` controls the no-files exit. — https://docs.deno.com/runtime/fundamentals/testing/
16. Vitest `expect.hasAssertions()` / `expect.assertions(n)` guard against a test that asserts nothing. — https://vitest.dev/guide/learn/async
17. Snapshots: Vitest writes a missing snapshot on the first run unless `CI` is set, and fails missing snapshots in CI (https://vitest.dev/guide/snapshot); Jest does not write new snapshots in CI but they "automatically pass" (https://jestjs.io/docs/snapshot-testing). Rule: no snapshot oracles, or `CI=1` and check the snapshot file is unchanged.

**Module resolution**
18. Node stripping requires explicit extensions; recommended tsconfig: `module: nodenext`, `rewriteRelativeImportExtensions`, `erasableSyntaxOnly`, `verbatimModuleSyntax`. — https://nodejs.org/api/typescript.html
19. Vite 8+ has `resolve.tsconfigPaths` (off by default); earlier Vite needs `vite-tsconfig-paths` (second-hand: https://tanstack.com/start/latest/docs/framework/solid/guide/path-aliases.md). Whether Vitest reads it the same way: *unsourced*. Rule: resolve stubs through the runner and through `tsc`.
20. Jest ESM: `jest.mock` does not apply to ESM targets; use `jest.unstable_mockModule` with a dynamic import. — https://jestjs.io/docs/ecmascript-modules

**Mocking**
21. `vi.mock` is hoisted to the top of the file; its factory cannot use outer variables. — https://vitest.dev/api/vi.html
22. Mocks in a setup file do not apply to test files. — same page
23. Derived: a `vi.mock`/`jest.mock` of the feature module replaces the stub, so the trap never runs. Grep oracles for mocks of feature modules and require the trap text in the output.

**Files written into the repo**
24. Vitest coverage: `coverage.enabled` defaults to `false`, `reportsDirectory` is `./coverage`. Disable with `--coverage.enabled=false`. — https://vitest.dev/config/coverage
25. Vitest cache: `--cache=false` disables it; the directory follows Vite's `cacheDir` (default `node_modules/.vite`: *unsourced*). — https://vitest.dev/config/cache
26. TypeScript `incremental` writes `.tsbuildinfo`; redirect with `tsBuildInfoFile` or use `--incremental false` with `--noEmit`. — https://www.typescriptlang.org/tsconfig/incremental.html
27. Jest `cacheDirectory` defaults to `/tmp/<path>`; snapshots go in `__snapshots__`. — https://jestjs.io/docs/configuration, https://jestjs.io/docs/snapshot-testing
28. Practice: after Tier 1, fail on any new path in `git status --porcelain`.

**Exit codes and output**
29. `vitest run` (or `--run`) disables watch; plain `vitest` watches in an interactive terminal. — https://vitest.dev/guide/cli.html
30. `--reporter=verbose`, `--outputFile.<reporter>=<path>`; reporter truncation *unsourced*. — same page
31. node:test exits 1 if any test fails; zero matched files: exit code *unsourced*. — https://nodejs.org/api/test.html

**Recipe — Vitest**
- Stubs: each new export `throw new Error("<feature>-trap")`; existing API real.
- `CI=1 npx vitest run <oracle paths> --allowOnly=false --coverage.enabled=false --cache=false --reporter=verbose` (check each flag name against the CLI docs).
- `tsc --noEmit --incremental false -p tsconfig.tier1.json` (include: oracle + stubs).
- Pass bar: nonzero exit, and `<feature>-trap` or the oracle's own assertion message in the output; fail on zero exit, a collection error, or neither.
- `git status --porcelain`: fail on any new file.

**Recipe — node:test (+ tsx)**
- `node --test --test-reporter=spec --test-reporter-destination=stdout <oracle files>` (built-in stripping; `--import tsx` only for path aliases, *unsourced*).
- The same `tsc --noEmit` step; count the tests in the reporter output and fail on zero; pass bar and `git status` as above.

## Report 2 — Tier 2 (computed expected values)

**Numbers**
1. `0.1 + 0.2 !== 0.3`: compare with a tolerance or assert the exact printed value. — https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Number/toFixed
2. Integers are exact only up to `Number.MAX_SAFE_INTEGER` (9007199254740991); use BigInt beyond. — https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Number/MAX_SAFE_INTEGER
3. `Object.is(0, -0)` is false and `Object.is(NaN, NaN)` true; `-4 % 2` is `-0`. — https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Object/is
4. `%` takes the dividend's sign; a non-negative modulo is `((n % d) + d) % d`. — https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Operators/Remainder
5. Bitwise operators truncate to 32-bit integers. — https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Operators/Bitwise_OR
6. `toFixed` returns a string, rounds the exact binary value, and switches to exponent form at 1e21; it and `Math.round` disagree on ties and negatives. — MDN toFixed; ECMA-262 numbers-and-dates (from a search summary)

**Ordering**
7. `sort()` with no comparator compares strings: `[80, 9, 700]` → `[700, 80, 9]`. — https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Array/sort
8. `sort` is stable from ES2019; `toSorted` stability fixed in 2024 (https://github.com/tc39/ecma262/pull/3424).
9. A comparator must be consistent (anti-symmetric, transitive); `(a,b) => a > b ? 1 : 0` sorts differently across engines. — MDN sort
10. `localeCompare`/`Intl.Collator` depend on locale and the ICU build; only the sign is specified. Pin the locale, compare signs. — https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/String/localeCompare
11. Object keys: integer-like keys ascending first, then strings in insertion order; `JSON.stringify` follows it. — MDN Object.keys, JSON.stringify
12. Map iterates in insertion order with SameValueZero keys (NaN = NaN, 0 = -0); object keys match by identity. — https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Map

**Strings**
13. `length` counts UTF-16 code units (`'😄'.length` is 2); `[...s]` for code points, `Intl.Segmenter` for graphemes. — https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/String/length
14. Normalise (NFC) before comparing composed and decomposed text. — https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/String/normalize
15. Locale case mapping: Turkish `i`; `'Gesäß'.toLocaleUpperCase()` is `'GESÄSS'` (length changes). — https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/String/toLocaleUpperCase
16. Regex `u`/`v` flags: *unsourced* in this run.

**Dates and time**
17. Date-only ISO strings parse as UTC; date-time strings without an offset parse as local time. — https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Date/parse
18. `getMonth` is zero-based. — MDN getMonth
19. `Temporal` is "Limited availability"; do not assume it. — https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Temporal
20. Pin `TZ=UTC` on the command line (Node clears its TZ cache when `process.env.TZ` changes, from v13; Deno honours `TZ`; Bun has `jsc.setTimeZone`). — https://github.com/nodejs/node/pull/20026, https://docs.deno.com/examples/set_timezone/, https://bun.sh/reference/bun/jsc/setTimeZone

**JSON and equality**
21. `JSON.stringify` drops `undefined`/functions/symbols in objects (nulls in arrays), turns `NaN`/`Infinity` into `null`, throws on BigInt, serialises Map/Set as `{}`. — MDN JSON.stringify
22. Vitest `toEqual` ignores `undefined`-valued keys, sparseness and class type; `toStrictEqual` checks them. — https://vitest.dev/api/expect.html
23. Jest `toEqual` uses `Object.is` for primitives (`+0` ≠ `-0`); Vitest's behaviour and Map/Set content equality: *unsourced*. — https://jestjs.io/docs/expect

**Randomness and fast-check**
24. A fast-check failure prints `seed` and `path`; pass them back to `fc.assert` to replay. — https://fast-check.dev/docs/tutorials/quick-start/read-test-reports/
25. Default `numRuns` and seed stability across arbitrary changes: *unsourced*.

**Recipe — Tier 2**
- The cross-check lives in the scratchpad and never imports the code under test.
- Same runtime, TZ and ICU as the proof (`TZ=UTC node check.ts`); record the Node version and ICU mode (https://nodejs.org/api/intl.html).
- Per computed expectation, one of: a same-semantics reference (`Intl.Collator` with an explicit locale, `Intl.Segmenter`), a brute-force model of the spec, or a fast-check property comparing the oracle's formula to the model (keep the seed).
- Both sides from different sources; include one case that must fail, to show the check can.
- Keep the check's output with the oracle commit so the Grok oracle review sees it.
