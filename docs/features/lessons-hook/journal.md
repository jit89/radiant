# Journal: lessons-hook

## 2026-10-11T18:34:00Z — ARCHITECT phase1
Plan locked after 3 load-bearing decisions (Q1 prompt.compose system-prompt section, rebuilt only when the approved set changes; Q2 every new lesson pending until approved via /lessons, recurrence only refreshes last_seen; Q3 two scopes, global and per-project under ~/.claude/lessons/, user confirms at approval) and cosmetic C1-C11 at defaults (C10 off switch became /lessons off: a mod is not assumed to read the env). Research tier: none (engine type docs, recon, transcript measurement). Next: Grok round 1.

## 2026-10-11T18:44:11Z — ARCHITECT phase2 r1
Grok REVISE: 7 findings. Taken: 3-7 in full; 1 and 2 in part. Rejected with evidence: --no-session-persistence and --tools "" are documented in claude --help 2.1.296; prompt.compose / session.compact / session.end are declared in the engine type file (claude-code.d.ts:8329, 4390, 4434) though absent from the changelog. Round 2 next.

## 2026-10-11T18:50:51Z — ARCHITECT phase2 r2
Grok REVISE: 7 findings (detach vs process.run pipes; throttle drops triggers; daily cap forgets evidence; prompt.compose must call next; fenced JSON; /clear; casefold + transcript shape). All 7 taken. Round 3 next.

## 2026-10-11T19:01:16Z — ARCHITECT phase2 r3
Grok REVISE: 4 findings (capped run loses corrections / no distilled mark; malformed-retry count not persisted; child closes its own release pipe; due marker never removed). All 4 taken; 1-2 by an evidence-queue redesign (extract owns the offset, distil drains a persisted queue). Round 4 next.

## 2026-10-11T19:06:51Z — ARCHITECT phase2 r4
Grok REVISE: 2 findings (test list contradicted the offset rule; re-send rule had no stored baseline, corrections had no key). Both taken. Round 5 (last under MAX_ROUNDS) next.

## 2026-10-11T19:12:03Z — ARCHITECT phase2 r5
Grok APPROVED. 5 rounds, 20 findings (18 taken in full, 2 in part, the rejected parts being claims checked false against claude --help and the engine types). Awaiting user sign-off.

## 2026-10-11T19:13:50Z — ARCHITECT signoff
User signed off the plan (Grok APPROVED r5). Next: commit plan + log, then build in-session.
