---
name: run-goals
allowed-tools: Bash, Read
description: Walk the GOALS.md DAG via the host script. Use when the user says /run-goals, "run the dag", "implement all goals", or "walk the goals". Not for a single named goal (/run-goal), not for planning (/crucible), not for cutting the DAG (/to-goals).
---

# Run Goals

Phase 5 lives in code. Do not re-read a walk procedure from this file.

From the **target** repo:

The `walk` mod keeps the session's task list current: one task per goal of the walk this session launched, owned `walk:<id8>`, created and ticked by the mod as the walk runs. Write no walk tasks yourself (no `TodoWrite`, no `TaskCreate` for goals). Run:

```bash
~/claude-coding-workflow/scripts/run-goals.sh
```

With independent goals on the frontier, the user may ask for a parallel walk:
`run-goals.sh --jobs N` (N from 2 to 4). Use it only when asked, or when the
user agreed to it for this walk. It runs fork-join waves, each goal in its own
worktree under `~/.cache/claude-coding-workflow/worktrees/`, and integrates
each finished goal into the walk branch at the join. A target whose proofs
need installed dependencies (`node_modules`, a `.venv`) needs a
`worktree_setup:` key in GOALS.md (to-goals, `GOAL-FORMAT.md`). A walk that
stopped as a parallel walk is rerun with `--jobs` too: plain `run-goals.sh`
refuses it.

The slash command **is** the confirm. Do not ask "start the walk?".

Run it with the Bash tool's `run_in_background: true`: a walk takes N × ~40 minutes, far past the 10-minute ceiling on a foreground call. The harness re-invokes you when the walk exits: do not poll or sleep. Then read the tail of its output file for the exit status and the last `STOP_FILE:` line.

Do not re-enter between goals.

## After the script exits

- **0** — every goal is `done`. Report the graph, then read the walk's IMPLEMENTER END records in the journal. A note repeated across goals (the same caveat, defence or unanswered question) means the implementer prompt no longer fits: say so, and propose an implementer-prompt audit (`docs/features/prompt-audit/AUDIT.md` is the last one). Stop.
- **nonzero** — a **wake**. Read `STOP_FILE:` (the walker reprints the child's). Tell the user. `reason: walk-stuck` means nothing is left to run but goals are bounced or blocked behind one; the stop file lists each and why. `reason: orchestration-files-dirty` / `orchestration-files-changed` means GOALS.md or the journal held edits the workflow did not make; nothing was committed — ask the user to commit or restore them. `scripts/logs.sh errors --last 20` (or `since walk`) for the machine index; do not invent SQL. Do not start the next goal yourself. Do not swap implementer by hand.
- **nonzero, `--jobs`** — `reason: wave-stop` lists each stopped goal with its own reason and stop file; nothing is ever reset, and the walk branch moves only by a fast-forward to a fully proven integration. A goal listed `finished-not-integrated` passed review and is recorded `finished`: the rerun integrates it without dispatch. A goal that stopped any other way is recut on the rerun and implemented again from the next wave base (a parallel walk never resumes a half-done goal). The reasons, each with its remedy in its stop file: `merge-conflict`, `integration-red`, `integration-tamper`, `worktree-setup-failed` / `worktree-setup-dirty` (all in a scratch worktree kept as evidence; fix the walk branch and rerun to integrate the same reviewed commit again, or `goals.py set <id> ready` to recut it), `integration-unverified` (the branch is not the commit the goal reported after its review; a commit after the review is never merged), `head-moved-during-review` (a commit landed while Opus was reviewing), `integration-dirty` (the main checkout was dirty before the fast-forward: restore the tree to HEAD, never move HEAD), `journal-tamper`, `worktree-exists` (a `cw/<goal>` branch or folder this walk never made: inspect it), `walk-branch-moved`, `git-lock-stray`, `git-replace-ref`. Rerun with the same `--jobs`.

- **A wake the Architect (this session) diagnosed by hand:** ask whether a measurable check would have caught it. If so, the Architect adds that check before resuming, and journals it. A defect in the house: a test under `scripts/tests/` (house work is in-session). A defect in the target: an acceptance case under `tests/acceptance/`, committed before resuming and listed under the goal's **Acceptance edits** (a new goal if this one is done) — never a file in the target's `tests/regression/`, which is the implementer's.

`scripts/run-goals.sh` calls `scripts/run-goal.sh` as a subprocess and keys on exit code only.
