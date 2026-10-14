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
