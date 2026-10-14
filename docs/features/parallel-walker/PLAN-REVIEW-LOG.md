# Plan Review Log: Parallel walker, fork-join waves in worktrees (house item 6)
Phases 0-1 (recon + interrogation) complete — plan locked with the user. MAX_ROUNDS=5.

## Round 1 — Grok

I'll review the parallel-walker plan against the domain docs and the code it depends on, looking for concrete breaks rather than style notes.The plan is locked and specific. I'll check it against the walker, journal, events, and worktree code it claims to extend.The plan is not safe to implement. The first wave dies on the current resume gate, the journal check misses the merge that actually happens, and the walker's own commit guards reject the new commits.

1. A fresh wave member is dispatched as a resume, then can never be resumed. Step 3.4 commits every member `in_progress` before `run-goal.sh` starts. `run-goal.sh` treats `in_progress` as resume and `resume-state.py` exits with no output when the journal has no `dispatch` line, so the gate is `in_progress but no journaled BASE_SHA` (`scripts/run-goal.sh:686-731`, `scripts/lib/resume-state.py:46-48`). That commit is also before `worktree_setup`. A setup failure, timeout, or crash leaves `in_progress` plus a worktree and no `BASE_SHA`. Step 8 only wakes `worktree-missing` when the worktree is gone, so the next walk hits the same gate.
   Fix: in worktree mode, `in_progress` with no journaled attempt is a fresh start (`BASE_SHA=HEAD`, no status write); on re-attach, rerun `worktree_setup` when there is no attempt, and leave the goal `ready` if setup fails before dispatch.

2. The pure-append check does not run on the merge that needs it. Step 7 calls `journal-merge.py` only when git reports a conflict in the journal and nowhere else. The first goal of a wave is the only side that touched the journal since the wave base, so git takes that blob with no conflict and no resolver. A rewritten earlier line, or a suffix that is not records, is committed. Inside the goal, `orch-files.py` only compares the worktree to `HEAD`, so a rewrite already committed is invisible there too. The planted non-append test, as written, only covers a conflict.
   Fix: for every integration, require the goal's journal blob to be a byte suffix of the merge-base journal, require that suffix to pass `orch-files.py --records <goal>`, and require the merged file to equal base + walk suffix + goal suffix.

3. Today's fail-closed commits reject every new walker commit. `commit_goals` allows only `blocked↔ready` plus one inflight goal (`scripts/run-goals.sh:105-110`). `commit_journal` refuses the file unless it equals `JOURNAL_EXPECT`, which only `journal_line` updates (`:124-129`). That refuses the wave commit (`ready→in_progress` for several ids), the integrate commit (`in_progress→done`), the bounce commit (`in_progress→bounced`), and any journal that gained a goal's records by merge. Those two helpers also make two commits, so neither SHA is the single wave base that step 4 passes to `git worktree add`.
   Fix: give wave, integrate, and bounce their own allow lists, replace `JOURNAL_EXPECT` with the post-merge journal before appending the walker's line, and put `GOALS.md` and the journal in one wave-base commit.

4. Merged proofs run in a tree that never had `worktree_setup`. Per-goal proofs run in the worktree after `npm ci` or `uv sync`. Step 7 runs the merged proofs on the merged tip in the main checkout. Ignored `node_modules` and `.venv` are invisible to the clean check, so the main tree has either no install (`integration-red` resets a good merge) or a stale one (the proof passes against the wrong deps). That is the item 9 case this plan says `worktree_setup` closes. Separately, N host proofs run at once during the wave and share `/tmp` and fixed ports.
   Fix: after each merge, run the preamble `worktree_setup` in the main checkout with its own timeout, then the merged proofs; give each in-wave proof a private `TMPDIR` and a port offset.

5. `--jobs 1` cannot stay byte-for-byte and also resume a parallel stop. Step 2 both relaxes the start baseline to one `in_progress` per worktree and says `--jobs 1` is today's loop unchanged. Today two `in_progress` goals stop the walk (`scripts/run-goals.sh:89-90`). A parallel stop leaves several, and their commits are on `cw/<goal>`, not the walk branch. The default command either refuses or, if the baseline is shared and the old loop runs, implements that goal in the main checkout and ignores the worktree.
   Fix: keep the single-`in_progress` refusal for `--jobs 1`, and if any `in_progress` goal has a `cw/<goal>` worktree, stop with a message to rerun `--jobs N`.

6. A bounce cannot be retried, and its journal never reaches the walk branch. Exit 3 sets `bounced` and does not merge. Step 4 keeps the worktree on any stop. The Architect's unstick is `goals.py set <id> ready`. The next wave treats the goal as fresh, finds `cw/<goal>` or the cache path, and stops `worktree-exists` with no remove commands. The `bounced` record stays on the goal branch.
   Fix: on exit 3, append that goal's checked journal suffix onto the walk journal, put `git worktree remove` and `git branch -D` in the stop file, and let a fresh start reuse the path only when status is `ready` and the branch journal ends in `bounced <id>`.

7. A healthy join is shown as a pause, and the event log can tear. `done` is terminal (`scripts/events.py:466`). `walk_graph` marks `in_progress` and not-live as `paused` (`:907-914`), and the task reconcile prints `PAUSED: stopped`. The goal writes `done` and exits 0 at the start of `join_wait`, while `GOALS.md` stays `in_progress` until integration. `append_event` appends one jsonl with no lock (`:257-258`); N goals and the walker write it together, and a torn line is dropped (`:516-517`), which can erase a wake or the walker `walk` row that `walks.live` depends on.
   Fix: have the goal emit a non-terminal `phase: integrate`, have the walker emit `done` only when it sets status, and flock the jsonl so each line is one `os.write`.

8. Ref protection misses a linked main checkout, and a failed measurement still runs the wave. Step 0(a) names `.git/HEAD`, `.git/index`, and `refs/heads/<walk>`. On a linked checkout those files live under `git rev-parse --absolute-git-dir` (`worktrees/<name>/`), which the recon says the sandbox can write. The deny list is a file a fallback can read again on a second pass. If 0(a) fails, step 6 still runs `--jobs N` and trusts the post-wave tip check, which does not see `cw/<other>` rewritten and then merged.
   Fix: resolve every deny path with `git rev-parse --git-path` and `--git-common-dir` from the main checkout, build the sandbox settings once and reuse them for the DeepSeek fallback, and refuse `--jobs` above 1 when lock-and-rename bypasses `denyWrite`.

9. Three recovery states the plan creates have no working next step. `integration-tamper` leaves the merge commit and a dirty main tree, so step 8's re-integrate fails the clean check; a proof that is both red and dirty has no precedence. A crash after the merge commit and before `done` makes `cw/<goal>` an ancestor of the walk tip, and `git merge --no-ff` then reports "Already up to date" and makes no commit for step 7 to continue from. During a long wave a clean `git switch` in the main checkout leaves the walk-branch tip check green while `git merge` writes whatever is checked out now. `run-goals.sh` is `set -e`, so a bare `wait` on the first nonzero pid exits before clean siblings integrate. The byte-equality rule also has to replace all five `status-only-id` allowances (`scripts/run-goal.sh:379`, `:384`, `:388`, `:701`, `:922`), or a status-only edit still passes the dirty-tree gate.
   Fix: on tamper, stop the join immediately and name the cleanup in the stop file; if the goal branch is already an ancestor, skip the merge and go to proofs and `done`; require `symbolic-ref HEAD` to be the branch the walker started on; collect every `wait` status with `set +e`.

VERDICT: REVISE

### Architect's response

All nine taken; 1, 4 and 6 in modified form.

1. Fresh member dispatched as a resume — taken, modified. In worktree mode the worktree's journal decides resume: a `dispatch <id> r0` attempt resumes, `in_progress` with no attempt starts fresh. A setup failure before dispatch leaves the goal `in_progress` with no attempt, and a rerun re-attaches, sets up again and starts fresh; resetting it to `ready` is not needed (step 6, step 5).
2. Pure-append check skipped without a conflict — taken. `journal-merge.py` runs on every integration: both sides must be byte suffixes of the merge-base journal, the goal's suffix passes `--records`, and the merged journal must equal its output (step 7). Test added for the first goal of a wave.
3. Fail-closed commit helpers refuse the new commits — taken. Allow lists per commit kind (wave, integrate, bounce), `JOURNAL_EXPECT` reset after each merge, `GOALS.md` and the journal in one commit so the wave base is one SHA (step 2).
4. Merged proofs without dependencies; shared `/tmp` and ports — taken, modified. `worktree_setup` also runs in the main checkout after each merge, before the merged proofs; each proof gets a private `TMPDIR`. Ports are not virtualised: `GOAL-FORMAT.md` will require `conflicts_with` for proofs binding a fixed port or path (steps 5, 6, 7).
5. `--jobs 1` against a parallel stop — taken. `--jobs 1` keeps today's single-`in_progress` refusal and stops with "rerun with --jobs N" when any `in_progress` goal has a `cw/` branch or worktree (step 2).
6. A bounce cannot be retried; its journal is stranded — taken, modified. The bounce appends the goal's checked journal suffix to the walk journal; the worktree is kept as evidence and the stop names the remove commands; a goal set back to `ready` whose branch ends its attempt with `bounced <id>` is recut by the walker (steps 4, 7a).
7. A joining goal shown as paused; torn event lines — taken. A goal's DONE is a non-terminal `phase integrate` event; the walker writes `done` when it sets status. `events.py append` takes an `flock` and writes each line with one `os.write` (step 6).
8. Deny paths on a linked main checkout; a failed measurement still ships — taken. Deny paths resolved with `git rev-parse --git-path` and `--git-common-dir`, passed as `--deny-write` arguments, settings built once and reused for the DeepSeek fallback. If step 0(a) fails, `--jobs` above 1 is not shipped and the plan returns to the user (steps 0, 6).
9. Recovery states — taken. Tamper ends the join at once with the cleanup in the stop file and is checked before red; an already-merged goal skips the merge; the walker checks `symbolic-ref HEAD` and its tip before every commit or merge; `wait` statuses collected under `set +e`; byte equality replaces all five `status-only-id` allowances (steps 2, 3, 6, 7, 8). Tests added for each.

## Round 2 — Grok

I'll re-read the revised plan and check each prior finding against the current walker code.The earlier holes in resume, journal conflicts, commit allow-lists, merged-proof installs, `--jobs 1`, bounce retry, `flock`, deny paths, and the `set +e` wait are specified now. A two-goal wave and the new recovery paths still break.

1. The walk-side journal check rejects every integration after the first. Step 7 requires the goal suffix to pass `orch-files.py --records <goal>`, then says the same holds for the walk side. `--records` fails when a heading names any other goal (`scripts/lib/orch-files.py:52-54`). After the first integrate, the walk suffix contains that goal's `done` and `integrated` lines, so the second goal of the wave wakes `journal-tamper`. A later resume whose branch point is older fails the same way. `git merge` on that normal journal conflict also returns 1, and under `set -e` the walker exits before the resolver runs. Overwriting the conflicted file leaves it unmerged, so the integrate commit is refused until it is staged.
   Fix: apply `--records <goal>` only to the goal suffix; require the walk side to be a byte suffix and the committed file to equal the resolver output; capture the merge status and `git add` the resolved journal before commit.

2. `integration-red` still cannot record its wake. Step 2 resets `JOURNAL_EXPECT` to the merged journal after the integrate commit. The red path then `git reset --hard` back to the pre-merge journal and commits a wake line. `commit_journal` refuses the file unless it matches `JOURNAL_EXPECT` (`scripts/run-goals.sh:127-129`), so this becomes `orchestration-files-changed`. The same reset is specified for a post-merge `worktree_setup` failure. On a rerun that skips the merge because `cw/<goal>` is already an ancestor, no pre-merge SHA was recorded this run, so a red proof has no commit to reset to.
   Fix: after every `reset --hard`, set `JOURNAL_EXPECT` from that tree before appending the wake; the reset target is the first parent of the integrate commit that has `cw/<goal>` as second parent, including when the merge is skipped.

3. A goal waiting at the join still shows as `PAUSED`. `phase integrate` is not terminal, but `live_goals` also requires the event's pid to be alive (`scripts/events.py:532-556`). The goal writes that event and exits 0. `walk_graph` then labels `in_progress` and not-live as `paused` (`:913-914`), which the task list prints as `PAUSED: stopped`. The walker `done` event arrives only when status is set, which is after the wait the test cares about. `join_wait` is also absent from `EVENTS` (`:41-53`), and `events_append` swallows the rejection, so the timing row is dropped.
   Fix: while the walker's pid is alive, treat an `in_progress` goal whose latest event is `phase integrate` as running with that phase; add `join_wait` to `EVENTS`.

4. `worktree-setup-dirty` wedges the checkout the red path just learned how to undo. A nonzero setup after the merge is reset like `integration-red`. A dirty setup says nothing is reset, and the stop file does not name the cleanup that `integration-tamper` names. The merge stays, `done` is not set, and the tree is dirty. The next resume sees an ancestor, skips the merge and the clean check, and runs proofs on that tree. In the worktree, a dirty setup is left in place and the re-attach runs setup again on the same dirt, so it stops `worktree-setup-dirty` again.
   Fix: on a dirty setup after a merge, stop the join and name the same restore-and-`reset --hard` as tamper; on re-attach with no attempt, `git reset --hard` the worktree to its branch tip before running setup again.

5. `worktree-exists` is not sticky. The wave commit marks every fresh member `in_progress` before create. If the path or `cw/<goal>` is already there, that goal stops for inspection, still `in_progress`. Step 8 then sees a worktree at the expected path and no attempt, runs setup, and dispatches inside the tree it just refused to trust.
   Fix: on `worktree-exists`, commit that goal back to `ready` (allow `in_progress:ready`) so the next fresh start hits the same stop until the path is gone.

6. The last line of the plan contradicts the `--jobs 1` guard. Out of scope says the `--jobs 1` path changes only the atomic `GOALS.md` write. Step 2 and the tests add the `cw/<goal>` refusal. An implementer who follows the out-of-scope line drops that guard and resumes a parallel goal in the main checkout.
   Fix: delete that out-of-scope sentence; the `cw/<goal>` refusal is part of `--jobs 1`.

VERDICT: REVISE

### Architect's response

All six taken; 5 in modified form.

1. The walk-side `--records` check rejects every later integration; the merge's exit 1 under `set -e`; an unstaged resolution — taken. `--records <goal>` applies to the goal's suffix only; the walk side must be a byte suffix (its records are vouched for by `JOURNAL_EXPECT`). The merge runs under `set +e` with its status captured, and the resolved journal is staged before the remaining unmerged paths are checked (step 7).
2. `integration-red` cannot commit its wake; no reset target after a skipped merge — taken. The reset target is always the first parent of the integrate commit whose second parent is `cw/<goal>`'s tip, found the same way after a skipped merge. `JOURNAL_EXPECT` is reset from the tree after every `reset --hard`, before the wake line (step 7).
3. A goal waiting at the join still reads as paused; `join_wait` not in `EVENTS` — taken. While the walk is live, an `in_progress` goal whose latest event is `phase integrate` counts as running with phase `integrate`. `join_wait` and `integrate` are added to `EVENTS`, with a test that reads them back (step 6).
4. A dirty `worktree_setup` wedges the checkout — taken. After a merge it ends the join like `integration-tamper`, naming the restore and the reset. A worktree re-attached with no attempt is `reset --hard` and `git clean -fd` (not `-x`) before setup again (step 5).
5. `worktree-exists` is not sticky — taken, modified. The existence check runs while the wave is built, before the wave commit, so the goal is never set `in_progress`: it stays `ready`, is left out of the wave and listed in the combined stop. This avoids a new `in_progress:ready` transition (steps 3, 4).
6. The out-of-scope line contradicts the `--jobs 1` guard — taken. It now names the `cw/<goal>` refusal as part of `--jobs 1`.

## Round 3 — Grok

I'll re-read the revised plan and check the six remaining findings against the walker code.The last round of findings is specified: the walk-side `--records` exception, the reset-target and `JOURNAL_EXPECT` rule on `integration-red`, the `phase integrate` liveness exception, the dirty-setup cleanup, the pre-commit `worktree-exists` check, and the `--jobs 1` out-of-scope line. Five holes remain.

1. A `worktree-exists` goal hangs the walk. Step 3.3 leaves it out of the wave and says skipped goals wait for a later wave. Step 4 says it is listed in the combined stop and every later walk hits that stop. Step 3.10 writes that stop only when a wave member stops or an integration fails, then loops otherwise. The left-out goal is not a member. Once it is the only frontier goal, the wave builds empty, nobody stops, and the loop never reaches walk-end or walk-stuck.
   Fix: a goal left out for `worktree-exists` counts as a stop for step 3.10, and a wave built with zero goals exits with that stop instead of looping.

2. The no-attempt cleanup runs in the main checkout. The walker `cd`s to the walk root (`scripts/run-goals.sh`). Step 5 then runs `git reset --hard` to the goal's branch tip and `git clean -fd` with no worktree path. That moves the walk branch to `cw/<goal>` and deletes untracked files in the main tree. The worktree's failed setup is left in place.
   Fix: both commands are `git -C <worktree-path>`, and the reset target is that worktree's own `HEAD`.

3. A bounce cannot be committed. Step 7a appends the goal's journal suffix onto the walk file and then commits through the fail-closed journal check. `commit_journal` refuses the file unless it matches `JOURNAL_EXPECT` (`scripts/run-goals.sh:127-129`). That expect is updated on merge and on `reset --hard`, and not when a bounce suffix is appended. A wave that contains an exit 3 stops `orchestration-files-changed` before later goals integrate.
   Fix: append those same bytes to `JOURNAL_EXPECT` before the bounce commit.

4. `join_wait` undoes the integrating state. It is recorded per goal after the goal has written `phase integrate` and exited, and before the join. That row is then the goal's latest event for the whole wait. The new liveness rule only matches `phase integrate`, so `live_goals` drops the goal (`scripts/events.py:552-556`) and the pane shows `PAUSED` for the interval the test calls integrating. A per-goal `join_wait` whose payload pid is the walker's stays "running" with the default phase, still not `integrate`.
   Fix: while the walk is live, an `in_progress` goal whose latest event is `phase integrate` or `join_wait` stays running with phase `integrate`.

5. A rerun after `integration-tamper` or a dirty post-merge setup skips the clean check. Neither stop resets. Both name a `reset --hard` for the human, then step 8 integrates again. `cw/<goal>` is already an ancestor, so step 7 goes straight to the merged proofs and can set `done` on the dirty tree. The pre-merge clean check never runs on that path, and a dirty tree there has no named stop.
   Fix: the ancestor path refuses a dirty tree with the same cleanup text, and does not run proofs or set `done` until the tree is clean.

6. The goal section still says `--jobs 1` is unchanged. Step 2 and the tests add the `cw/<goal>` refusal. The out-of-scope line was updated; the opening goal paragraph was not.
   Fix: say `--jobs 1` is today's path plus that refusal.

VERDICT: REVISE

### Architect's response

All six taken; 4 in modified form.

1. A `worktree-exists` goal hangs the walk — taken. A goal left out for `worktree-exists` counts as a stop for step 3.10, and a wave that builds empty while the frontier is not empty exits with the combined stop (step 3).
2. The no-attempt cleanup runs in the main checkout — taken. Both commands are `git -C <worktree-path>`, resetting to that worktree's own `HEAD` (step 5).
3. A bounce cannot be committed — taken. The bounce suffix is appended to `JOURNAL_EXPECT` before the bounce commit (step 7a).
4. `join_wait` undoes the integrating state — taken, modified. Rather than widen the liveness rule again, `join_wait` becomes one walker-owned event per wave with no `goal` field (per-goal waits in its payload), so it is never a goal's latest event (steps 3, 6).
5. A rerun after tamper or a dirty setup skips the clean check — taken. The clean check runs on every integration path, the ancestor one included; a dirty tree stops `integration-dirty` with the tamper cleanup text, no proof and no `done` (step 7).
6. The goal paragraph still says `--jobs 1` is unchanged — taken. It now names the `cw/<goal>` refusal.

## Round 4 — Grok

I'll re-read the revised plan and check the last five findings against the walker.The last review left six open holes. I am re-reading the revised plan against those, and against the walker scripts, before judging anything new.The six earlier holes look closed in the text. I am checking the walker commit checks, event schema, and liveness rules for anything the new wording still breaks.The six earlier holes are closed. An empty wave or a `worktree-exists` goal now stops the walk (`PLAN.md:115-119`, test at `:382-383`), with the bounced-recut exception still in step 4 (`:139-142`). The bounce path appends the same bytes to `JOURNAL_EXPECT` (`:303-304`). Re-attach cleanup is `git -C <worktree-path> reset --hard HEAD` and `git -C <worktree-path> clean -fd` (`:174-176`). `join_wait` is one walker-owned event with no `goal` field (`:105-107`), and `live_goals` ignores rows with no `goal_id` (`scripts/events.py:544-546`), so the goal's latest event stays `phase integrate`. The ancestor path runs the clean check and a dirty tree is `integration-dirty` with no proof and no `done` (`:242-249`). `--jobs 1` includes the `cw/<goal>` refusal (`:16-17`, `:528-530`).

Three new holes:

1. `integration-dirty` reuses the tamper cleanup, `git reset --hard <pre-merge sha>` (`:244-245`, `:277-280`). That sha is defined as the first parent of the integrate commit whose second parent is `cw/<goal>`'s tip (`:282-284`). On the first integration the tree is dirty before any merge, so that commit does not exist. `run-goals.sh` is `set -euo pipefail` (`scripts/run-goals.sh:9`); a failed lookup while writing the stop ends the walker with no stop file, and the next run hits the same dirt. The new test covers only the ancestor rerun, where the commit already exists (`:388-389`). Fix: when this goal has no integrate commit yet, `integration-dirty` names `git status` and restoring the main checkout to the current walk tip; name `reset --hard` to that commit's first parent only after the merge has landed.

2. The wave commit marks every fresh member `in_progress` before any worktree is created (`:94-98`). A nonzero `worktree_setup` stops that goal (`:164-166`) and the plan never says the create/start loop continues. Today's `walk_stop` exits immediately (`scripts/run-goals.sh:42-51`). Later members stay committed `in_progress` with no branch and no worktree. Resume will not create them: a missing worktree wakes `worktree-missing` and waits for a hand unstick (`:311-314`), which also blocks re-attach of the members that were created. Fix: create every fresh member's worktree before any setup, treat a setup failure as a member stop, and start the members whose setup succeeded.

3. Step 0 says to prove the goal's own commits still work when `packed-refs` is denied, including `gc --auto` (`:29-31`). "(a) fails" is defined only as lock-and-rename getting past `denyWrite`, and only that case blocks `--jobs` above 1 (`:34-37`). A deny list that breaks the goal's commits still ships. Fix: any failed check in 0(a), including the goal's own commits or `gc --auto`, blocks `--jobs` above 1.

VERDICT: REVISE

### Architect's response

All three taken.

1. `integration-dirty` names a reset to a commit that may not exist — taken. The cleanup text depends on whether this goal's integrate commit exists: none yet → `git status` and restore to the current walk tip; landed → reset to its first parent. The lookup runs under `set +e` so the stop file is always written (step 7). Test added for a first integration.
2. One member's setup failure strands the rest of the wave — taken. Every fresh member's worktree is created first, then each is set up under `set +e`; a setup failure is that member's stop, and the members whose setup succeeded still start (step 3). Test added.
3. A deny list that breaks the goal's own commits still ships — taken. Any failed check in step 0(a) blocks `--jobs` above 1 and returns the plan to the user.

## Round 5 — Grok

The last review left three holes. I am re-reading the revised plan against those, and against the walker scripts, before judging anything new.The three earlier holes are in the new text. I am checking the start rule, the recut order, and the cleanup commands against the walker scripts.The three earlier holes are closed. Any failed step 0(a) check now blocks `--jobs` above 1, including the goal's own commits and `gc --auto` (`PLAN.md:34-39`). Worktrees are created before setup, setup runs under `set +e`, and a failure is one member's stop while the others are still set up and started (`:99-106`, test at `:406-408`). `integration-dirty` before any integrate commit names a restore to the walk tip, and the lookup is under `set +e` (`:250-257`, test at `:403-405`).

Four new holes:

1. Step 3.6 starts "each worktree whose setup succeeded (and each re-attached one)" (`:103-106`). With no `worktree_setup` key, nothing runs (`:186`), so a fresh wave has no successful setup and no re-attached member. The same step then goes straight to the combined stop. That is the normal DAG (the three-goal wave test has no setup key). The parenthesis also starts a re-attached goal whose setup failed, so `run-goal.sh` journals `dispatch` and the rerun is a resume. Setup runs only when there is no current attempt (`:164-166`, `:194-197`), so the broken tree is never set up again. Fix: start a fresh member when the key is absent or setup exited 0, and start a re-attached member only when it already has a current attempt or its setup exited 0.

2. The bounced-recut exception removes the old worktree and cuts a new one during the exists check (`:145-148`), and that check runs before the wave commit (`:139-140`). Creation is `git worktree add -b cw/<goal> <path> <wave-base>` (`:136`), but the wave base is the commit in step 3.4 (`:96-98`). Step 3.5 then creates every fresh member again (`:99`). The early cut has no wave base, and the second `git worktree add` fails because the branch and path already exist. `run-goals.sh` is `set -euo pipefail` (`scripts/run-goals.sh:9`), so the recut test dies there. Fix: the exception only removes the old worktree and branch and keeps the goal in the wave; step 3.5 is the only `git worktree add`, from the wave base.

3. The first-integration `integration-dirty` cleanup is `git restore`, plus deleting untracked files (`:252-255`). The clean check is the fresh-start gate's `git status --porcelain` (`scripts/run-goal.sh:708`), which still prints a staged index (`M `) and untracked files (`??`). `git restore` leaves both. The next run is `integration-dirty` again. Fix: name `git reset --hard HEAD` and `git clean -fd`. HEAD is already the walk tip, so this does not look up an integrate commit.

4. After setup, the tree must be clean or the goal stops with `worktree-setup-dirty` (`:175-177`). The walker `cd`s to the main checkout and stays there (`scripts/run-goals.sh:28`, `PLAN.md:184-185`). The reset and clean name `git -C <worktree-path>`; the clean check does not. A `git status` in the walker inspects the main checkout, so a dirty worktree is started anyway. Fix: the worktree check is `git -C <worktree-path> status --porcelain`, ignoring ignored paths.

VERDICT: REVISE

### Architect's response

All four taken. MAX_ROUNDS (5) reached without APPROVED; the plan goes to the user with these fixes unattacked.

1. Step 3.6 starts nothing when there is no setup key; a re-attached goal with failed setup is dispatched — taken. Start rules spelled out: a fresh member when the key is absent or setup exited 0 with a clean worktree; a re-attached member with a current attempt; a re-attached member with no attempt only after a clean setup. A member whose setup failed never journals a `dispatch` (step 3).
2. The bounced recut creates a worktree twice, before the wave base exists — taken. The check only removes the old worktree and branch and keeps the goal in the wave; step 3.5 is the only `git worktree add` (step 4).
3. The first-integration `integration-dirty` cleanup leaves a staged index and untracked files — taken. It names `git reset --hard HEAD` and `git clean -fd`; HEAD is the walk tip (step 7).
4. The post-setup clean check inspects the main checkout — taken. In a worktree it is `git -C <worktree-path> status --porcelain` (step 5).

Trend: 9, 6, 6, 3, 4 findings. Rounds 3-5 found ordering and command-level slips in the integration and setup paths, not design breaks; every earlier fix was confirmed closed.

## Round 6 — Grok (authorised past MAX_ROUNDS)

The last review left four holes. I am re-reading the revised plan against those, and against the walker scripts, before judging anything new.The four earlier holes are closed. The start rule now covers a missing `worktree_setup` key, a clean setup, and a re-attached goal, and a failed setup is never dispatched (`PLAN.md:103-114`, tests at `:422-424`). The bounced-recut path only removes the old worktree and branch during the check; the only `git worktree add` is step 3.5 from the wave base (`:153-158`, test at `:425-426`). The first-integration `integration-dirty` cleanup is `git reset --hard HEAD` and `git clean -fd` (`:263-268`, test at `:416-418`). The setup clean check in a worktree is `git -C <worktree-path> status --porcelain` (`:185-188`, test at `:427-428`).

One new hole:

A recut goal starts as a fresh member, then `run-goal.sh` resumes the dead attempt. Step 7a appends that goal's journal suffix, including its `dispatch <id> r0`, onto the walk journal (`:322-329`). The next wave base is that journal. Step 3.5 cuts the replacement branch from the wave base, so the new worktree has the old `dispatch` line and the `bounced` line, and it does not have the old code commits (those died with the deleted branch). Worktree mode treats "a current attempt (a `dispatch <id> r0` line)" as resume (`:206-209`). That is what `resume-state.py` does: it starts at the last `dispatch <id> r0` and never reads `done` or `bounced` (`scripts/lib/resume-state.py:29-49`). The old `BASE_SHA` is still an ancestor of the new tip, so the ancestor check passes (`scripts/run-goal.sh:724-727`), and the fresh-start `BASE_SHA=HEAD` path does not. The worktree's `GOALS.md` is the wave base, not that old `BASE_SHA`, so the byte-equality contract check fails. Status stays `in_progress`, the next run re-attaches the same journal, and the goal loops on contract drift. The same definition skips `worktree_setup` ("no current attempt", `:174-175`), so a repo that has the key also never installs deps on the new worktree. The recut test only checks that the branch is cut once.

Fix: a `dispatch <id> r0` is a current attempt only when that attempt does not already end with `done <id>` or `bounced <id>`; a recut goal then runs setup and starts fresh with `BASE_SHA` equal to the wave base.

VERDICT: REVISE

### Architect's response

Taken. "Current attempt" is now defined once: the last `dispatch <id> r0`, provided no `done <id>` or `bounced <id>` follows it. Resume, `worktree_setup`, the re-attach cleanup, the start rules and `resume-state.py` in worktree mode all use it. A goal recut after a bounce inherits its old records through the walk journal, so it has no current attempt, runs setup and starts fresh from the wave base (step 6). The recut test now checks the fresh start, not just the single cut.

All four round 5 fixes were confirmed closed. Trend: 9, 6, 6, 3, 4, 1.

Addendum (Architect, after logging round 6): steps 4 and 8 said "ends its current attempt with bounced/done", which contradicts the new definition (an attempt ending in done or bounced is not current). Both now say "last attempt (from its last dispatch <id> r0)". Wording only; no rule changed.

## Resolution
Signed off by the user after 6 Grok rounds (round 6 authorised past MAX_ROUNDS=5). Last verdict REVISE with 1 finding, taken; findings 9, 6, 6, 3, 4, 1. No point left unresolved between Grok and the Architect.
