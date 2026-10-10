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

Run it with the Bash tool's `run_in_background: true`: a walk takes N × ~40 minutes, far past the 10-minute ceiling on a foreground call. The harness re-invokes you when the walk exits: do not poll or sleep. Then read the tail of its output file for the exit status and the last `STOP_FILE:` line.

Do not re-enter between goals to repaint todos. The badge stays stale until the walk exits.

## After the script exits

Re-run `goals.py todos` and `TodoWrite` again so the list matches HEAD.

- **0** — every goal is `done`. Report the graph. Stop.
- **nonzero** — a **wake**. Read `STOP_FILE:` (the walker reprints the child's). Tell the user. `reason: walk-stuck` means nothing is left to run but goals are bounced or blocked behind one; the stop file lists each and why. `reason: orchestration-files-dirty` / `orchestration-files-changed` means GOALS.md or the journal held edits the workflow did not make; nothing was committed — ask the user to commit or restore them. `scripts/logs.sh errors --last 20` (or `since walk`) for the machine index; do not invent SQL. Do not start the next goal yourself. Do not swap implementer by hand.

- **A wake the Architect (this session) diagnosed by hand:** ask whether a measurable check would have caught it. If so, the Architect adds that check before resuming, and journals it. A defect in the house: a test under `scripts/tests/` (house work is in-session). A defect in the target: an acceptance case under `tests/acceptance/`, committed before resuming and listed under the goal's **Acceptance edits** (a new goal if this one is done) — never a file in the target's `tests/regression/`, which is the implementer's.

`scripts/run-goals.sh` calls `scripts/run-goal.sh` as a subprocess and keys on exit code only.
