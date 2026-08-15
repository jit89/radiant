---
name: run-goals
description: Walk the GOALS.md DAG via the host script. Use when the user says /run-goals, "run the dag", "implement all goals", or "walk the goals". Not for a single named goal (/run-goal), not for planning (/crucible), not for cutting the DAG (/to-goals).
---

# Run Goals

Phase 5 lives in code. Do not re-read a walk procedure from this file.

From the **target** repo:

```bash
~/grok-coding-workflow/scripts/run-goals.sh
```

The slash command **is** the confirm. Do not ask "start the walk?".

Foreground timeout: long enough for every remaining goal (N × ~40 minutes, more if fix rounds).

## After the script exits

- **0** — frontier empty. Report the graph. Stop.
- **nonzero** — a **wake**. Read `STOP_FILE:` (the walker reprints the child's). Tell the user. Do not start the next goal yourself. Do not swap implementer.

`scripts/run-goals.sh` calls `scripts/run-goal.sh` as a subprocess and keys on exit code only.
