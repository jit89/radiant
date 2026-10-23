# Plan: the parallel walker recuts a goal after a merge conflict (house item 17)
_Locked via crucible — by Claude + the user, 2026-10-23_

## Goal

In a `--jobs N` walk, a goal that passed review but conflicts with a sibling
integrated earlier in the same wave stops the whole walk today
(`merge-conflict`), and keeps stopping on every rerun until the user hands it
back. Instead, on a plain merge conflict the walker recuts the goal once per
walk and the walk carries on: the goal runs fresh from the new walk tip in the
next wave. A second conflict for the same goal in the same walk stops as today.

## Approach

1. **Which stops qualify.** Only `integrate()`'s plain `merge-conflict`:
   the reviewed commit verified (`check_result`), the journal check passed
   (`journal-merge.py`), `git merge` exited 0 or 1 with `MERGE_HEAD` set, and
   files other than the journal are unmerged. `merge-failed`, `journal-tamper`,
   `integration-goals-edited`, `integration-tamper`, `integration-red`,
   `integration-dirty`, `integration-unverified` and the setup stops keep
   stopping the walk unchanged.

2. **The budget (Q1).** One automatic conflict-recut per goal per walk. The
   count is the goal's `## <utc> — ORCHESTRATOR recut <g> reason=merge-conflict`
   records in the walk journal at HEAD after the last
   `ORCHESTRATOR walk-start walk_id=<WALK_ID>` record of the current walk, read
   with anchored patterns (whole headings only). Budget left (count 0) → the
   recut path below. Budget used (count ≥ 1) → today's `integration_stop
   merge-conflict`, its detail adding "this goal's automatic recut for a merge
   conflict was already used in this walk".

3. **At the conflict.** `integrate()` first saves the unmerged paths
   (`diff --name-only --diff-filter=U`, NUL-separated with `-z`) to
   `$WAVE_DIR/<g>.conflict-files`, since `merge --abort` clears them; then it
   runs `merge --abort` in the scratch tree,
   removes it with `git worktree remove -f -f` (a conflicted tree refuses a
   plain remove), appends `"<g> <verified SHA>"` to a wave list
   `CONFLICT_RECUTS` (the goal and the SHA only; the paths stay in their
   file), writes nothing to GOALS.md or the journal, and returns a
   new status (4; 2 is "stop the wave now" and 3 is a goal's bounce) that the
   join treats as "not integrated, not a stop". The remaining goals of the wave
   still integrate, in order. The conflicted paths go to the event payload only
   (step 4), never into a journal record.

4. **The recut (`flush_conflict_recuts`, Q3: before any stop).** For each
   entry of `CONFLICT_RECUTS`, in order, all from the verified SHA, never from
   the live `cw/<g>` (a leftover process can move it after the result was
   checked):
   - keep the conflicted attempt as evidence at
     `refs/cw-conflict/<g>/<n>`: a folder per goal, so one id that prefixes
     another cannot collide; n = 1 + the highest existing n for that goal;
     created only if absent (`git update-ref <ref> <sha> ""`), never
     overwritten. `refs/cw-conflict` joins every member's deny list, as other
     goals' branches do, so no goal can write or pre-plant one;
   - `recut <g> <sha>` with the record `ORCHESTRATOR recut <g>
     reason=merge-conflict`: `recut()` takes the SHA to merge the journal suffix
     from, and the reason is written on every form of the record, the
     `abandoned-records-not-kept=(…)` one included, so the budget count never
     misses a recut. No path names in the record (a raw newline in a file name
     would split it into a forged second record). Its worktree and branch
     removal and result-file removal are unchanged. The recut record follows
     the goal's `finished` record, so `walk_record` reads it as `member` and
     nothing integrates the conflicting commit again;
   - an info event `recut` for the goal, its payload the conflicted paths read
     from `$WAVE_DIR/<g>.conflict-files` and the evidence ref (JSON-encoded by
     events.py, so no path byte reaches a journal or a heading). `events.py` gains `recut` in `EVENTS`, and
     `walk_graph` reads an `in_progress` goal whose newest goal event is `recut`
     as waiting to run (`ready`), ahead of its paused rule, so `/walk-status` and
     the task list do not show it as PAUSED.
   The goal stays `in_progress`; the frontier lists `in_progress` goals first,
   so it is in the next wave, cut fresh from the walk tip. The flush runs after
   the wave's integrations, and also at the top of `wave_stop`, so every way
   out of a wave (another stop, an integration's "stop the wave now" status,
   a walk-level stop or a signal during the join) recuts the queued goals first;
   a recut that cannot finish leaves the goal listed as a `merge-conflict`
   stop with the reason, so nothing is lost. For that the flush works from a
   snapshot of the queue (goals integrated at a rerun's start are not wave
   members), and its git writes return on failure instead of stopping:
   `recut` and `wave_commit` take a mode in which a refused commit or branch
   removal returns 1 rather than calling `walk_stop` (from inside `wave_stop`,
   `walk_stop` would exit without the combined stop file, and the
   `finished` record would stay the latest, so a rerun would merge the same
   commit). The flush then `add_stop`s that goal as `merge-conflict`, naming
   what failed, and goes on to the next.

5. **Then the wave ends as today (Q2).** No other stop: the walk goes on to the
   next wave. Another stop: `wave_stop` as today, except that its scan of the
   wave's members skips the goals recut this wave (their branch is gone, so
   `check_result` would call them `integration-unverified`), and its stop file
   gains a `## Recut` section listing each as `recut (merge-conflict): runs
   fresh on rerun`, not as a stop. On rerun the goal is `in_progress` with a
   `recut` record and runs fresh; its budget is used.

6. **The start-of-walk integration.** A rerun integrates `finished` goals
   before any wave (`wave-walk.sh` "Finished goals are integrated without
   dispatch"). A plain conflict there gets the same treatment: budget check,
   then the recut after those integrations and before the first wave.

7. **Walk end.** The `walk-end` output prints one line per conflict-recut goal
   of this walk (from the journal records), so the user sees them after a walk
   that never stopped.

8. **Docs.** `docs/features/parallel-walker/PLAN.md` gets an amendment naming
   this behaviour; README's parallel-walk paragraph and the run-goals skill
   mention it in one line each; FUTURE-WORK item 17 gets its DONE line.

9. **Tests** (`scripts/tests/parallel-walk*-test.sh`, stub implementers that
   edit one line of one file):
   - two goals in one wave edit the same line: the first integrates, the
     second is recut (the record `recut <g> reason=merge-conflict` with no path
     in it, the `refs/cw-conflict/<g>/1` ref at the verified SHA, an info
     `recut` event whose payload names the conflicted file, no stop), runs fresh in the
     next wave from the new tip and integrates; the walk ends 0, every goal done;
   - the same goal conflicts again in the same walk: the walk stops
     `merge-conflict`, the detail says the automatic recut was used;
   - a conflict-recut and another goal's stop in one wave: the stop file lists
     the recut goal under `## Recut`, not as a stop; a rerun runs it fresh and
     finishes;
   - the budget is per walk: a goal recut in one walk gets a recut in a new walk;
   - the recut uses the verified SHA: `cw/<g>` moved after the result check
     does not change the evidence ref or the journal suffix kept;
   - the evidence ref is never overwritten (an existing `<g>/<n>`, an id that
     prefixes another), and a member cannot write `refs/cw-conflict`;
   - a refused journal suffix still writes `reason=merge-conflict`, so a second
     conflict stops;
   - a conflict-recut queued when the wave stops another way (an
     integration's stop-now status, a signal in the join) is still recut;
   - a recut whose commit is refused inside `wave_stop` still writes the
     combined stop file, listing the goal as `merge-conflict` with the reason;
   - `/walk-status` shows a conflict-recut goal as waiting, not paused;
   - every other integration stop still stops (one existing test each is kept
     green);
   - each new branch planted red.

## Key decisions & tradeoffs

- **Q1 (user): once per goal per walk**, counted from the journal. Not "once
  ever" (a later walk's conflict would stop for no new reason) and not
  unbounded (two goals rewriting one line could recut each other every wave;
  the walk would still end, since each wave integrates one goal, but pay a pass
  and a review each time).
- **Q2 (user): carry on**, not "recut and still stop". A conflict no longer
  wakes the user; the journal record, the event and the walk-end summary carry
  it. The fresh attempt is reviewed like any other, so nothing unreviewed
  lands. Cost: one implementer pass and one review per conflicted goal.
- **Q3 (user): recut first, then stop** when the wave has another stop, so a
  rerun does not loop on the conflicting commit.
- **Termination.** Usually the wave's first integration merges onto the tip
  its goal was cut from and cannot conflict. Not always: a goal whose commit
  merged other history can conflict in the first slot, and then a wave may
  integrate nothing and go on. The bound is the budget: each goal is recut for
  a conflict at most once per walk, so a walk of G goals has at most G such
  recuts before a conflict stops it.
- **Evidence kept outside `refs/heads/cw/`** (`refs/cw-conflict/<g>/<n>`, at the
  verified SHA, create-only, denied to members) so the recut's branch removal
  and the next cut of `cw/<g>` are unaffected. They accumulate; the user
  deletes them.
- **No implementer handoff note.** The fresh attempt sees the sibling's code
  at the new tip. The conflicted paths are in the `recut` event's payload
  (`/walk-status`, `events.py`), not in the journal: a path is untrusted text.

## Assumptions

1. A plain conflict has three sources: a goal integrated earlier in the same
   wave (members are cut at `WAVE_BASE="$WALK_TIP"`; integration is serial);
   a `finished` goal integrated at a rerun's start, onto a tip that moved since
   it was cut; and a goal whose commit merged history older than its wave base.
   The budget covers all three. — `scripts/lib/wave-walk.sh`.
2. Today the stopped goal keeps its `finished` record and the next start
   integrates the same commit again, so it loops until handed back. —
   `wave-walk.sh` start-of-walk integration, `integration_stop`.
3. `recut()` keeps the goal's journal records, writes a `recut` record that
   overrides `finished` in `walk_record`, and removes worktree, branch and
   result file. — `wave-walk.sh` `recut`, `walk_record`.
4. A recut goal stays `in_progress` and the frontier lists `in_progress` first.
   — `scripts/goals.py` `frontier`.
5. The current walk's id is `WALK_ID` and its `walk-start` record is in the
   walk journal. — `scripts/lib/events.sh`.

## Risks / open questions

- A conflict whose cause is a planning mistake (two goals that should be one, a
  missing `conflicts_with`) is now read after the walk, not during it.
- Many `refs/cw-conflict/*` refs over many walks.

## Out of scope

- Dynamic dispatch (item 13) and an integration-red as a fix round (item 14).
- Learning `conflicts_with` from a conflict.
- Resolving conflicts automatically, or telling the implementer about them.
- The serial walker (`--jobs 1`), which cannot conflict.
