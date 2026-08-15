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

## 2026-08-15T09:59:19Z — ARCHITECT fix

Dogfood g1-hash: DeepSeek ok, host proof 6/6, Opus wrote last line `VERDICT: DONE — goal is met…` (the prompt's own example). verdict_of used a bash glob that required the line to end with DONE → MISSING. Tokenize after VERDICT:; keep last-line-only so body quotes still lose.

## 2026-08-15T11:02:13Z — ARCHITECT

Walker visibility: goals.py progress ([==>.] 2/4 + per-id status, ANSI unless GOALS_COLOR=0) printed after every refresh. goals.py todos JSON for /run-goals to seed/refresh todo_write. TUI badge stays stale mid-walk; stdout bar is the live view. run-goals.sh defaults GOALS_COLOR=1 because the TUI exports NO_COLOR=1.

## 2026-08-15T11:04:50Z — ARCHITECT

Added scripts/mock-walk.sh + fixtures/GOALS.mock.md. Fake 4-goal walk (no DeepSeek/Opus). install.sh --check runs --quick. Live demo: [-...] 0/4 → [====] 4/4.

## 2026-08-15T12:30:00Z — ARCHITECT

Host event index: JSONL in `~/.cache/grok-coding-workflow/logs/` (not git). `walk_id` reused until walk-end so a bounce restart is the same job; remint if the journal no longer mentions the id. Journal commit stays fail-closed; JSONL append is best-effort. One `ORCHESTRATOR wake <id> r<n> reason=` line (no findings, no stop dump). Query via `scripts/logs.sh` verbs — no generated SQL.
