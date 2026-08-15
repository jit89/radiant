---
name: run-goals
description: Walk the GOALS.md DAG via the host script. Use when the user says /run-goals, "run the dag", "implement all goals", or "walk the goals". Not for a single named goal (/run-goal), not for planning (/crucible), not for cutting the DAG (/to-goals).
---

# Run Goals

Phase 5 lives in code. Do not re-read a walk procedure from this file.

From the **target** repo:

1. Seed the TUI todo list from the DAG (badge only; it will not tick mid-walk):

```bash
~/grok-coding-workflow/scripts/goals.py GOALS.md todos
```

`todo_write` one item per JSON object: `id` as given, `content` as given, `status` as given (`pending` / `in_progress` / `completed` / `cancelled`). Then:

```bash
~/grok-coding-workflow/scripts/run-goals.sh
```

The slash command **is** the confirm. Do not ask "start the walk?".

Foreground timeout: long enough for every remaining goal (N × ~40 minutes, more if fix rounds).

The walker reprints `goals.py progress` (`[==> ] 2/4` plus per-id status) after every refresh. That stream is the live view. Do not re-enter between goals to repaint todos.

## After the script exits

Re-run `goals.py todos` and `todo_write` merge so the badge matches HEAD.

- **0** — frontier empty. Report the graph (and the last progress block). Stop.
- **nonzero** — a **wake**. Read `STOP_FILE:` (the walker reprints the child's). Tell the user. `scripts/logs.sh errors --last 20` (or `since walk`) for the machine index; do not invent SQL. Do not start the next goal yourself. Do not swap implementer.

`scripts/run-goals.sh` calls `scripts/run-goal.sh` as a subprocess and keys on exit code only.
