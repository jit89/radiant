---
name: run-goals
description: Walk the GOALS.md DAG — refresh the frontier, run each ready goal via run-goal, honor blocked_by, stop on bounce or quota. Use when the user says /run-goals, "run the dag", "implement all goals", "walk the goals", or after a signed-off DAG when they want more than one goal. Not for a single named goal (/run-goal), not for planning (/crucible), not for cutting the DAG (/to-goals).
---

# Run Goals — walk the DAG

Phase 5. Sequential. The Architect stays in this session and calls
`run-goal` once per frontier goal until the frontier is empty or
something stops the walk.

`~/grok-coding-workflow/scripts/goals.py` is the DAG reader. Trust it
over hand-parsing YAML.

Parallel worktrees are **not** in this slice. Independent ready goals
still run one at a time, in file order. `conflicts_with` is recorded
and logged; it does not change v1 scheduling.

## 1. Gate

- `GOALS.md` exists at the target root.
- `goals.py validate` exits 0. If not, stop and fix the file (do not
  invent edges).
- `DEEPSEEK_API_KEY` is available the same way as `run-goal`. Missing
  → stop. Do not ask the user to paste it.

```bash
~/grok-coding-workflow/scripts/goals.py GOALS.md validate
~/grok-coding-workflow/scripts/goals.py GOALS.md refresh
~/grok-coding-workflow/scripts/goals.py GOALS.md graph
~/grok-coding-workflow/scripts/goals.py GOALS.md frontier
```

Show the graph. Confirm with the user that the walk should start
(one line). Then go.

Done when validate+refresh have run and the user has confirmed.

## 2. Loop

Until stop:

1. `refresh` then `frontier`.
2. Empty frontier → Resolution (all done, or only `bounced`/`blocked`
   remain).
3. Pick the **first** frontier id (file order). If it is
   `in_progress`, treat it as a resume of that goal, not a new start.
4. Journal `ARCHITECT walk <id>`.
5. Run the **`run-goal` skill** on that id — the whole Phase 4
   procedure, including assess, Claude review, and recovery. Do not
   fork it.
6. After `run-goal` returns:
   - goal is `done` → loop
   - goal is `bounced` → stop the walk (spec defect). Do not start
     another goal.
   - implementer `rate_limited` / quota death → stop the walk. Keep
     the resume handoff. Do not start another goal.
   - user stops you → stop.

Never dispatch a goal whose `blocked_by` still has unfinished ids.
`refresh` is what flips `blocked` → `ready` after a parent lands.

## 3. Resolution

Print the graph again. Summarize: done / bounced / still blocked /
not started. Append a journal `ARCHITECT walk-end`.

If every goal is `done`, the feature is implemented. Phase 5 ends.
There is no further house phase.

If anything is `bounced` or leftover `blocked` with unfinished
parents, say so. The user decides whether to re-cut (`/to-goals`) or
resume (`/run-goals` again).

## Hard rules

- Sequential. One `run-goal` at a time. Shared working tree.
- `goals.py` owns the YAML. Do not hand-edit statuses when the tool
  can `set` / `refresh`.
- Recovery stays inside `run-goal`. This skill only decides whether
  the walk continues after that.
- Do not start a new goal while one is `in_progress`.
- Do not fall back to another implementer on quota death.
- Do not invent parallel worktrees in v1.
