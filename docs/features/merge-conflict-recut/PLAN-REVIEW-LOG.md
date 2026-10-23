# Plan Review Log: the parallel walker recuts a goal after a merge conflict (house item 17)
Phases 0-1 (recon + interrogation) complete — plan locked with the user. MAX_ROUNDS=5.

## Round 1 — Grok

I'll read the plan and the domain docs first, then check the repo assumptions they depend on.The plan leans on `integrate()`, `recut()`, and the walk journal. I'll check those against the code they cite.The plan's once-per-walk recut is the right shape, and the journal budget matches how `walk_record` treats a later `recut` line. As written, the recovery path still drops the verified commit, and the wave stop undoes the "not a stop" rule on the path the tests require.

1. **`wave_stop` will list the recut goal as a real stop.** After the flush, `recut` has deleted `cw/<g>`, but the goal is still an exit-0 member of `RUNNING_IDS` and is not in `STOPS`. The scan at `scripts/lib/wave-walk.sh:332-349` then fails `check_result` and `add_stop`s `integration-unverified`. That is the test "conflict-recut and another stop": the stop file lists it under Stopped, and the remedy says to restore the branch. **Fix:** skip goals already conflict-recut this wave in that scan, and print them only under `## Recut`.

2. **The evidence ref and the journal copy trust the live branch, not the reviewed SHA.** `check_result` exists because `refs/heads/cw/<g>` can move after the result file (`scripts/tests/parallel-walk-trust-test.sh:63-70`). The queue stores `"<g>|<files>"` and step 4 runs `update-ref … refs/heads/cw/<g>` only after later integrations. `recut()` (`wave-walk.sh:296-304`) then appends whatever that branch's journal is now. A child that called `setsid` outlives the goal (`scripts/lib/run-timeout.py:21-22`) and can retarget the goal's own ref during that window; `deny_list` does not cover it (`wave-walk.sh:440-443`). **Fix:** store the verified SHA in the queue, point the evidence ref at that SHA, and merge the journal from that SHA.

3. **`n = 1 + count(refs/cw-conflict/<g>-*)` overwrites evidence.** `git update-ref` replaces an existing ref. The count collides when suffixes are not `{1..n}` (the plan tells the user to delete these refs) and when `<g>` is a prefix of another id (`g1-a-*` matches `refs/cw-conflict/g1-a-b-1`). The new namespace is not on `deny_list`, so a later goal can rewrite or pre-plant those refs. **Fix:** `n = 1 + max suffix`, create the ref only if it is absent, and deny `refs/cw-conflict` the same way as another goal's branch.

4. **`files=` is untrusted text inside a walker heading.** `git()` sets `core.quotePath=false` (`scripts/lib/git-guard.sh:46-47`), so `diff --name-only` can emit a raw newline. `journal_line` writes that into one `ORCHESTRATOR recut` record (`run-goals.sh:87-90`). `walk_record` (`wave-walk.sh:208-222`) will read a second physical line as `finished` or `recut` and can schedule that SHA for integration. **Fix:** keep the journal record to a single line with no raw path bytes (`\n`/`\r` rejected or encoded) and put the path list in the stop file or event payload.

5. **A refused journal suffix drops the budget token.** `recut` still deletes the branch when `journal-merge.py` fails, and today's line becomes `recut <g> abandoned-records-not-kept=(…)` with no `reason=merge-conflict` (`wave-walk.sh:303-311`). The next conflict in the same walk counts 0 and recuts again, which is the unbounded loop Q1 rejects. **Fix:** always append `reason=merge-conflict` on that record, including the abandoned-suffix line.

6. **The info `recut` event does not do what step 4 says.** `recut` is not in `EVENTS` (`scripts/events.py:42-58`); `append` rejects it and the walker continues. `walk_graph` marks every non-live `in_progress` goal `paused` (`events.py:965-966`) with reason `stopped` when there is no `wake`. The task list renders that as `PAUSED`. **Fix:** add `recut` to `EVENTS`, and treat an `in_progress` goal whose newest goal event is `recut` as waiting, ahead of the paused rule.

7. **Several exits never flush `CONFLICT_RECUTS`.** Return 2 (`wave-walk.sh:717-719`) and `walk_stop` on a failed fast-forward (`:722`) leave the loop before step 4, so the `finished` record stays and the rerun merges the same commit. A conflicted scratch rejects `git worktree remove` without `-f -f`; under `set -euo pipefail` that kills the walker with no stop file. Return code 3 is already the goal's bounce status (`:343-351`, `:1033-1034`). **Fix:** use a distinct integrate status, `merge --abort` then `worktree remove -f -f`, and run the same flush before every in-loop `wave_stop`.

8. **The "first integration cannot conflict" claim is false.** It holds only when the goal commit's merge-base with the tip is `WAVE_BASE`. A goal that merged older history can conflict on the first slot, the wave integrates nobody, and the walk continues. The budget stops a repeat. It does not make the termination sentence true. **Fix:** state that case, and keep the once-per-walk stop as the bound.

VERDICT: REVISE


### Architect's response

All eight taken. (1) wave_stop's member scan skips goals recut this wave; they appear only under ## Recut. (2) The queue holds the verified SHA; the evidence ref and recut's journal suffix come from it, not the live cw/<g>. (3) refs/cw-conflict/<g>/<n> (a folder per goal), n = 1 + the highest, create-only, and refs/cw-conflict on every member's deny list. (4) No path names in the journal record; the file list goes to the event payload. (5) reason=merge-conflict on every form of the recut record. (6) recut added to events.py EVENTS; walk_graph reads an in_progress goal whose newest event is recut as ready. (7) integrate status 4; merge --abort then worktree remove -f -f; the flush also runs at the top of wave_stop, so every exit recuts queued goals first, and a recut that cannot finish is listed as a merge-conflict stop. (8) The termination claim is corrected: the budget is the bound. Tests added for 2, 3, 5, 7 and 6.

## Round 2 — Grok

I'll re-read the revised plan and check each earlier finding against the code it depends on.The SHA queue, the per-goal evidence ref, status 4, the `wave_stop` scan skip, the `recut` event, and the once-per-walk bound are in the plan. Four holes are still open.

1. **The journal injection fix is contradicted by the acceptance text.** Steps 3–4 keep paths out of the journal and put them only in the event payload. The test at line 97 still requires a record with `reason=merge-conflict files=…`, and the tradeoff at line 143 says the recut record names the files. A path with a raw newline (`core.quotePath=false` in `scripts/lib/git-guard.sh`) would again split a walker heading that `walk_record` trusts. **Fix:** drop `files=` from the test and from that tradeoff; assert the paths only in the `recut` event payload.

2. **A failed flush does not leave a `merge-conflict` stop.** `recut` commits through `wave_commit`, and `wave_commit` calls `walk_stop` (`scripts/lib/wave-walk.sh:156-167`). From the top of `wave_stop`, `WAVE_STOPPING` is already 1, so that `walk_stop` falls through to `walk_stop_single` (`:131-136`) and exits. The combined stop file is never written, the `finished` record stays the latest line, and the rerun merges the same SHA. If the flush runs before `WAVE_STOPPING=1`, the same failure calls `wave_stop` again and recurses. **Fix:** the flush commit must return on failure, `add_stop` that goal as `merge-conflict`, and continue the combined stop; snapshot the queued goals first, because start-of-walk goals are not in `RUNNING_IDS`.

3. **The conflict paths are discarded before they are saved.** Step 3 aborts the merge and removes the scratch tree, and the queue stores only `"<g> <sha>"`. `diff --diff-filter=U` is empty after `merge --abort`, so the step 4 payload has no files. That payload is now the only record of which paths conflicted. **Fix:** read the unmerged names before `merge --abort`, and keep them with the SHA until the event is written.

4. **Assumption 1 is still false.** It says a conflict can only come from an earlier sibling in the same wave. Step 6 (a `finished` goal integrated at the start of a rerun) and the termination bullet (a goal whose merge-base is older than `WAVE_BASE`) are both conflicts that rule does not cover. **Fix:** rewrite assumption 1 to those three sources.

VERDICT: REVISE


### Architect's response

All four taken. (1) files= removed from the test and the tradeoff; paths only in the recut event payload. (2) recut and wave_commit get a mode that returns 1 on a refused commit or branch removal instead of walk_stop; the flush works from a snapshot of the queue and add_stops a failed goal as merge-conflict, then continues the combined stop; a test for it. (3) The unmerged paths are saved (-z) to $WAVE_DIR/<g>.conflict-files before merge --abort and read for the event. (4) Assumption 1 rewritten to the three sources (same-wave sibling, a finished goal at a rerun's start, history older than the wave base), all under the budget.

## Round 3 — Grok

I'll re-read the revised plan and check the four open findings against the walker code.The four open findings are closed. The conflict paths are saved with `diff -z` before `merge --abort`, the journal record is `recut <g> reason=merge-conflict` with no paths, a failed flush returns instead of calling `walk_stop` and `add_stop`s `merge-conflict`, and assumption 1 lists all three conflict sources.

The return-mode commit, the queue snapshot for goals that are not wave members, the create-only evidence ref, and the `recut` event ahead of the paused rule match the walker as it is: `walk_record` still keys the goal id as the first token, status 4 is not the bounce exit, and a flush at the top of `wave_stop` covers return 2, a fast-forward `walk_stop`, and a signal in the join.

VERDICT: APPROVED


### Resolution

APPROVED in round 3 of 5. To the user for sign-off.
