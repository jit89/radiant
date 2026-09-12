---
name: run-goal
allowed-tools: Bash, Read
description: Run one ready goal from GOALS.md — host script dispatches DeepSeek then Claude Opus 5 as reviewer. Use when the user says /run-goal, "implement this goal", or "run the next goal". Not for planning (/crucible), not for cutting the DAG (/to-goals), not for walking the whole DAG (/run-goals).
---

# Run Goal

Phase 4 lives in code. Do not re-read a procedure from this file.

From the **target** repo (the directory that holds `GOALS.md`):

```bash
~/claude-coding-workflow/scripts/run-goal.sh <id>
```

No id → first `ready` from `goals.py GOALS.md frontier`; confirm the id in one line, then run the script.

Foreground timeout: **at least 40 minutes** per call (implementer 20 + reviewer 10, plus a fix round).

## After the script exits

- **0** — that goal is `done`. Tell the user. Stop (or the user asked `/run-goals` — that is the other skill).
- **nonzero** — a **wake**. Read the path on the last `STOP_FILE:` line. Tell the user the `reason` and the unstick commands. `scripts/logs.sh errors --last 20` for the machine index; do not invent SQL. Do not invent a retry loop. Do not paste keys. Do not swap implementer.

The script already ran the proof, checked the oracle, and routed Opus. Do not re-implement those steps in chat.

Rulebooks (do not fork): `scripts/run-goal.sh`, `scripts/deepseek-code.sh`, `scripts/claude-goal-review.sh`, `scripts/goals.py`.

The reviewer is a separate headless Opus session that sees only the brief, the diff and the proof output — never this conversation. You wrote the plan and the oracle; you did not write the diff it is judging.
