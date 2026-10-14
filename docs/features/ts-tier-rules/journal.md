# Journal: ts-tier-rules

## 2026-10-14T15:37:32Z — ARCHITECT phase1
House item 9. Recon: GOAL-FORMAT has one TS row; research doc unverified; Node 24.21.0 via fnm (not on PATH), no tsc/bun/deno; no TS target yet. Decisions: Q1 Vitest + node:test only; Q2 a rule needs a planted oracle defect it catches (docs only for version facts); Q3 the node-on-PATH and offline-install hazards are carried to the TS project with evidence from the throwaway repo. Cosmetic defaults accepted (TYPESCRIPT.md reference file, ~/dogfood/ts-tiers, EVIDENCE.md, candidate list, MAX_ROUNDS=5). Next: Grok round 1.

## 2026-10-14T15:46:04Z — ARCHITECT phase2 r1
Grok REVISE: 7 findings, all taken (tsc chained inside the proof; plants re-scoped to the pass bar; tree_snapshot scoring; absolute-path recipe under bash -c; two fixtures; per-runner Tier 2 and TZ; fixture and plants committed). Round 2 next.

## 2026-10-14T15:53:25Z — ARCHITECT phase2 r2
Grok REVISE: 6 findings, all taken (Tier 2 keep rule; pre-runner checks in the && chain; subshell zero-test clause; fixtures as own git roots + full tree_snapshot; separate recipe config + hostile vite config; delayed-rejection async plant). Round 3 next.

## 2026-10-14T16:00:07Z — ARCHITECT phase2 r3
Grok REVISE: 3 findings, all taken (Tier 2 keep rule split strict/loose; snapshot matchers as pre-runner checks; async plant on both stubs, node:test zero-test subshell). Round 4 next.

## 2026-10-14T16:05:29Z — ARCHITECT phase2 r4
Grok REVISE: 4 findings, all taken (Tier 2 by result colour; Tier 2 sanity check; canary in hostile configs; type-only import plant and gap verdict into TYPESCRIPT.md). Round 5 (last) next.

## 2026-10-14T16:07:27Z — ARCHITECT phase2 r5
Grok REVISE: its four findings were round 4's, because the round-4 edit had failed silently (one wrapped anchor; edit, log and launch run in one command without &&). Applied now and verified present. MAX_ROUNDS reached; to the user: one confirming round, or sign-off.

## 2026-10-14T16:12:02Z — ARCHITECT phase2 r6
User: one confirming round 6 past MAX_ROUNDS=5, because the round-4 changes were never attacked.

## 2026-10-14T16:14:52Z — ARCHITECT phase2 r6
Grok REVISE: 2 findings (Duration as both class and type; canary message equal to the trap), both taken and verified present. To the user: sign-off or round 7.

## 2026-10-14T16:28:59Z — ARCHITECT phase2 r7
User: one more round (7) after round 6's two fixes.

## 2026-10-14T16:31:00Z — ARCHITECT phase2 r7
Grok APPROVED (round 7). Plan to the user for sign-off.

## 2026-10-14T16:32:25Z — ARCHITECT sign-off
User signed off the plan (Grok APPROVED r7). Next: commit plan and log, then build.

## 2026-10-14T16:46:03Z — ARCHITECT build
Built and measured on ~/dogfood/ts-tiers (Node 24.21.0, Vitest 5.0.4, TypeScript 7.0.2): two fixtures as own git repos, a reference, 29 plants plus variants; run-plants.sh all: 63 cases, 0 mismatches, also from the house copy (npm ci from the lockfiles). Kept: tsc chained first; Vitest recipe config (allowOnly false, CI=1, not extending the project config; canary proves it); a silent pre-runner grep (mocks of project modules, snapshot matchers, .then); --incremental false; TZ=UTC; node:test preconditions erasableSyntaxOnly and verbatimModuleSyntax; Tier 2 reference and strict matchers. Dropped: zero-test guard, node .only, node invented symbol, node async .then, mock.module. One gap (other unawaited async shapes) as a look-for. Two build fixes: harness wrote its own files into the measured repo; the first check printed the matched line (trap text) and fooled the pass bar, so it is grep -l. Wrote EVIDENCE.md, skills/to-goals/TYPESCRIPT.md, GOAL-FORMAT and SKILL lines, FUTURE-WORK carried inputs.

## 2026-10-14T18:37:47Z — REVIEWER review r1
Opus (fresh, read-only; the first launch hit the session limit, the second stalled ~56 min and was stopped, the third ran with stream-json): VERDICT FIX, 23 findings — the check failed open and missed subdirectories; recipes not run as literal bash -c strings; a minus recipe removed two rules (config and CI=1); an unrealistic mock plant; no delayed stub or repeats; the npm cache not keyed or atomic; modules failure not fatal; red/caught rows without reasons; TZ depended on the machine zone; Tier 2 reference never run; a tautological -0; temp copies left; unused files and cases; mock.module drop unbacked; doc overclaims (preconditions, coverage inheritance, unplanted claims); tsconfigs incomplete; no upgrade step; node snapshot unlisted; SKILL.md wording.

## 2026-10-14T18:37:47Z — ARCHITECT review r1 response
All 23 taken. Fixture and harness reworked: literal one-line recipes run by bash -c; one rule removed per minus recipe; tier.tsconfig.json per fixture; CI=1 dropped (allowOnly false kept; either alone catches .only); realistic partial-mock plant; stub-late; n-snapshot (node gets an assert.snapshot check); n-mock-module; pattern column; *5 repeats; cache keyed by lockfile hash, staged; non-UTC zone in env -i; tier2 step; cleanup; diff command. Rerun: 70 cases, 0 mismatches, tier 2 0. Docs rewritten to what was measured.

## 2026-10-14T18:37:47Z — REVIEWER review r2
Opus (fresh, user-requested second round, stream-json): VERDICT FIX, 16 findings — tier2 could not fail for labelWidth and never compared the plants; most red/caught rows still without reasons (v-hostile-only would pass with the recipe reverted); the recursive check and the CI=1 claim had no row; an alias-path look-for left over; node stub-late unused; the host environment misdescribed (the host keeps the walk env minus credentials; no network is the sandbox); the kept-rule sentence, TZ and extends wording overclaimed; the -off plants removed two rules; run inherited the CASES stdin and total was unchecked; EVIDENCE wording; FUTURE-WORK count; this journal lacked the review records; a 220-char line.

## 2026-10-14T18:37:47Z — ARCHITECT review r2 response
All 16 taken: tier2 pins each value at its call and checks the plants carry the hand slip (proved to fail on a toBe(4) copy), Node for JSON; a pattern on every red/caught row (TS codes, Unexpected .only modifier, the failure title, Missing snapshots, generated asynchronous activity after the test ended, No test files found, Could not find, the check file names); v-mock-nested and ci-only rows; -off plants keep verbatimModuleSyntax; node stub-late deleted; run </dev/null and a row count; docs reworded. 72 cases; rerun pending.

## 2026-10-14T18:41:24Z — ARCHITECT verify
After the r2 fixes: run-plants.sh all on ~/dogfood/ts-tiers 72 cases, 0 mismatches, tier 2 0; the house copy (docs/features/ts-tier-rules/fixture, 95 files) from a fresh npm ci of its lockfiles: 72 cases, 0 mismatches, tier 2 0. run-all -j 8 23/23 earlier (no house script changed). Neither review round changed a kept or dropped rule. Ready to commit on the user OK.

## 2026-10-14T18:42:15Z — ARCHITECT review r3 dispatch
User: a third Opus round. Fresh read-only session, seeded with r2 findings and the r2 response.

## 2026-10-14T18:46:56Z — REVIEWER review r3
Opus (fresh, user-requested third round, stream-json; read-only, ran nothing): VERDICT FIX, 3 findings — all 16 round-2 fixes confirmed by tracing (tier2 pin regex fails on toBe(4)); the FUTURE-WORK carried input still misdescribed the host environment; EVIDENCE and the run-plants comment overclaimed what tier2 checks; the verify record above was wrong to say neither review round changed a rule.

## 2026-10-14T18:46:56Z — ARCHITECT review r3 response
All three taken. FUTURE-WORK item 1 reworded (the host keeps the walk env minus credentials; Node on PATH only if the walk has it; item 1 stops every goal when PATH lacks Node, item 2 any goal needing an install). EVIDENCE and the run-plants comment now name the three pinned calls and the two plants. Correction to the verify record above: review round 1 did change rules — it dropped CI=1 (kept at the build), added the node:test assert.snapshot check, and widened the Vitest mock check to any vi.mock / vi.doMock; round 2 changed no rule. Comment and wording changes only: no evidence rerun needed.

## 2026-10-14T18:48:20Z — ARCHITECT end
Committed on the user OK; ~/dogfood/ts-tiers deleted (its sources are in fixture/). Item 9 done.
