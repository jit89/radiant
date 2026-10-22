---
name: run-goal
allowed-tools: Bash, Read
description: Run one ready goal from GOALS.md — host script dispatches the implementer (DeepSeek Flash, Haiku 5.5 on a refusal, or the other way round with IMPLEMENTER_PRIMARY=haiku) then Claude Opus 5.5 as reviewer. Use when the user says /run-goal, "implement this goal", or "run the next goal". Not for planning (/crucible), not for cutting the DAG (/to-goals), not for walking the whole DAG (/run-goals).
---

# Run Goal

Phase 4 lives in code. Do not re-read a procedure from this file.

From the **target** repo (the directory that holds `GOALS.md`):

```bash
~/claude-coding-workflow/scripts/run-goal.sh <id>
```

No id → first `ready` from `goals.py GOALS.md frontier`; confirm the id in one line, then run the script.

Run it with the Bash tool's `run_in_background: true`. A goal can take 40 minutes or more (implementer 20 + reviewer 10, plus fix rounds), past the 10-minute ceiling on a foreground call, which would kill it mid-goal. The harness re-invokes you when the script exits: do not poll or sleep. Then read the tail of its output file for the exit status and the last `STOP_FILE:` line.

## After the script exits

- **0** — that goal is `done`. Tell the user. Stop (or the user asked `/run-goals` — that is the other skill).
- **nonzero** — a **wake**. Read the path on the last `STOP_FILE:` line. Tell the user the `reason` and the unstick commands. `scripts/logs.sh errors --last 20` for the machine index; do not invent SQL. Do not invent a retry loop. Do not paste keys. Do not swap implementer by hand: the launcher's own fallback is the only switch. `reason: implementer-blocked` means the implementer stopped on a blocker (its question is in the journal END record and the return handoff); `implementer-declined` means the implementer refused, declined or was out of balance (DeepSeek 402) and no fallback was left (both models, the fallback off, or no DeepSeek key); `claude-config-tamper` means `.claude/` or `.mcp.json` changed during the pass. A red host proof is not a stop by itself: it becomes a proof fix round (ADR 0002). `proof-red` means a proof fix round changed nothing outside the journal, so the host and the implementer's sandbox may disagree; fix the host and resume (the resume proves first), or bounce. `max-fix-rounds` "after a red proof" means the shared budget ran out on proof fixes. `proof-excerpt-error` means the proof was red but its output could not be turned into a fix handoff (the excerpt failed or timed out); read the raw output the detail names, then resume or bounce.

- **A wake the Architect (this session) diagnosed by hand:** ask whether a measurable check would have caught it. If so, the Architect adds that check before resuming, and journals it. A defect in the house: a test under `scripts/tests/` (house work is in-session). A defect in the target: an acceptance case under `tests/acceptance/`, committed before resuming and listed under the goal's **Acceptance edits** (a new goal if this one is done) — never a file in the target's `tests/regression/`, which is the implementer's.

The script already ran the proof, checked the oracle, and routed Opus. Do not re-implement those steps in chat.

Rulebooks (do not fork): `scripts/run-goal.sh`, `scripts/claude-implement.sh`, `scripts/claude-goal-review.sh`, `scripts/goals.py`.

The reviewer is a separate headless Opus session that sees only the brief, the diff and the proof output — never this conversation. You wrote the plan and the oracle; you did not write the diff it is judging.
