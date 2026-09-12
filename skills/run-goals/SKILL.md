---
name: run-goals
allowed-tools: Bash, Read, TodoWrite
description: Walk the GOALS.md DAG via the host script. Use when the user says /run-goals, "run the dag", "implement all goals", or "walk the goals". Not for a single named goal (/run-goal), not for planning (/crucible), not for cutting the DAG (/to-goals).
---

# Run Goals

Phase 5 lives in code. Do not re-read a walk procedure from this file.

From the **target** repo:

1. Seed the todo list from the DAG (a badge only; it will not tick mid-walk):

```bash
~/claude-coding-workflow/scripts/goals.py GOALS.md todos
```

`TodoWrite` one item per JSON object: `content` as given, `status` as given (`pending` / `in_progress` / `completed` / `cancelled`), `activeForm` as the present-participle form of the content. Then:

```bash
~/claude-coding-workflow/scripts/run-goals.sh
```

The slash command **is** the confirm. Do not ask "start the walk?".

Foreground timeout: long enough for every remaining goal (N × ~40 minutes, more if fix rounds).

Do not re-enter between goals to repaint todos. The badge stays stale until the walk exits.

## After the script exits

Re-run `goals.py todos` and `TodoWrite` again so the list matches HEAD.

- **0** — frontier empty. Report the graph. Stop.
- **nonzero** — a **wake**. Read `STOP_FILE:` (the walker reprints the child's). Tell the user. `scripts/logs.sh errors --last 20` (or `since walk`) for the machine index; do not invent SQL. Do not start the next goal yourself. Do not swap implementer.

`scripts/run-goals.sh` calls `scripts/run-goal.sh` as a subprocess and keys on exit code only.
