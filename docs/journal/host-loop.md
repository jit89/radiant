# Journal: host-loop

## 2026-08-15T08:19:02Z — ARCHITECT start

Brownfield crucible on `~/grok-coding-workflow`. User: put the host-loop optimisation through crucible and report the outcome. No implementation this turn.

Research: `none` (house is familiar; failure modes measured in the consistent-hash dogfood).

Load-bearing locks (conversation + Architect defaults, no new interview):

- host Orchestrator, not DeepSeek↔Opus
- host assess before Opus
- host-authored DIFF/PROOF only
- dirty tree fail-closed
- FIX = numbered findings only (no Grok hop)
- launchers unforked; house work in-session

ADR `docs/adr/0001-host-loop.md`. CONTEXT: Orchestrator, Host assess.

Next: Opus 5 via `claude-review.sh`.

## 2026-08-15T08:36:00Z — ATTACKER end

5 rounds, last verdict REVISE. MAX_ROUNDS. Not APPROVED.

Taken across rounds: the assess gate cannot fire on its own journal/proof debris; contract from BASE_SHA; no auto-done without an executed proof; walker keys on exit code; resume state in the journal; artifacts stay outside the target tree.

Rejected: per-goal worktrees as the v1 vehicle.

Cap leftovers T1–T6 folded into PLAN.md as Architect takes. User breaks the tie.

## 2026-08-15T08:45:00Z — ARCHITECT sign-off

User treated the folded plan as signed. House git had **no commits**; baseline snapshot taken so the Grok-in-the-hop skills remain revertible after the host loop lands.

## 2026-08-15T09:50:47Z — ARCHITECT fix

Dogfood /run-goals woke immediately: run-goals.sh journal_line walk g1-hash, then run-goal.sh fresh-start clean-tree gate failed on docs/journal/consistent-hash.md. Same class as the refresh-must-commit rule. Walker now commit_journal after every walk line (and walk-end uses the helper).
