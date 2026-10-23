# Plan: Parallel walker, fork-join waves in worktrees (house item 6, step 5)
_Locked via crucible — by Claude + cobalt, 2026-10-15._

## Goal

`scripts/run-goals.sh` walks the goal DAG one goal at a time. Independent
goals (rbtree: g4, g5, g7 after g3) wait for each other for no reason. Item 6
adds `run-goals.sh --jobs N`: the walker runs the frontier in **waves**
(fork-join). Each goal of a wave runs `run-goal.sh` in its own git worktree on
its own branch. The walker waits for the whole wave, then **integrates** each
finished goal into the walk branch one at a time: merge, journal resolve,
merged proofs. Then it marks the goal `done` and plans the next wave. The
walker is the single writer of `GOALS.md`, of the walk branch and of every
merge. Goal processes report through their exit code only. Nothing claims
work and nothing is locked, because only one process changes walk state.
`--jobs 1` (the default) is today's code path plus one refusal: a goal with a
`cw/<goal>` branch or worktree is never run there (step 2).

## Approach

0. **Measure first (throwaway repo, before any code).**
   - (a) Run an implementer pass in a worktree with `sandbox.filesystem.denyWrite`
     naming the walk branch's ref, `packed-refs`, the main checkout's `HEAD`
     and `index`, its `logs/HEAD` and `logs/refs/heads/<walk>`, and another
     worktree's `worktrees/<name>/`. Check that each of these is refused:
     `git branch -f <walk> HEAD`, `git update-ref refs/heads/<walk> HEAD`,
     `git pack-refs --all`, and writes to the main `HEAD` and `index`. Check
     that git's lock-file-and-rename (`<ref>.lock`, then rename) cannot
     replace a denied file. Check that the pass's own commits on `cw/<goal>`
     still succeed, and that a denied `packed-refs` does not break them
     (`gc --auto`).
   - (b) Run two worktree passes while the main checkout does a `git worktree add`
     and a `git merge`, and confirm the shared object store survives.
   - Record the results in `docs/features/parallel-walker/EVIDENCE.md`. If
     any check in (a) fails, `--jobs` above 1 is not shipped and the plan
     comes back to the user. That covers lock-and-rename getting past
     `denyWrite` (the walker's tip check cannot see a `cw/<other>` branch
     rewritten and then merged), and also a deny list that breaks the goal's
     own commits or `gc --auto`.
   - Recon already measured, 2026-10-15:
     - commits work from both a sibling worktree and one nested in the repo,
       two at once;
     - the sandbox blocks `.git/hooks`, `.git/config` and the main checkout's
       files;
     - it allows `.git/info`, `objects/`, `refs/heads/*` and other worktrees'
       admin folders;
     - `denyWrite` blocks a named file, a named folder and a path that does
       not exist yet.

1. **Atomic `GOALS.md` writes (every mode).** `goals.py`'s three in-place
   writes (`write_fence`, `cmd_refresh`, `cmd_set`) go through one helper:
   - a temp file in the same folder;
   - write, flush, `fsync`;
   - `os.replace`, keeping the file mode.

   A reader (the `/walk` pane, a goal starting) sees the old file or the new
   one, never half.

2. **`run-goals.sh --jobs N`.**
   - N is an integer from 1 to 4; anything else is refused with exit 2.
   - `--jobs 1`, or no flag, runs the existing loop, with one addition: if any
     `in_progress` goal has a `cw/<goal>` branch or worktree, the walk stops
     with `orchestration-files-dirty` and "a parallel walk stopped here;
     rerun with `--jobs N`". It never implements such a goal in the main
     checkout. Today's refusal of more than one `in_progress` goal stays for
     `--jobs 1`. Apart from that addition, a test diffs the commands and
     commits of a mock walk against today's.
   - For N > 1 the walker runs the wave loop below. Its start baseline allows
     one `in_progress` goal per worktree being re-attached (step 8).
   - **Walk-state commits (N > 1).** `commit_goals` and `commit_journal` keep
     their fail-closed checks, but each kind of commit gets its own allow
     list:
     - the wave commit: `<member>=ready:in_progress` for each fresh member;
     - the integrate commit: `<id>=in_progress:done`;
     - the bounce commit: `<id>=in_progress:bounced`;
     - today's `blocked↔ready`, unchanged.

     After each merge, `JOURNAL_EXPECT` is reset to the journal as committed
     (step 7), before the walker appends its own line. Wherever `GOALS.md` and
     the journal both change, they go in **one** commit, so the wave base is a
     single SHA.
   - **The walk branch.** At start the walker records `symbolic-ref HEAD` and
     its tip. Before every walker commit or merge, `HEAD` must still be that
     branch, at the tip the walker last wrote. Otherwise it wakes
     `walk-branch-moved`. A `git switch` in the main checkout during a wave is
     caught, not merged into.

3. **The wave loop (N > 1).** In order:
   1. `refresh`, then commit.
   2. Take the frontier in file order (`in_progress` first, as today).
   3. Build the wave: take goals greedily, skipping any goal that names, or is
      named by, a goal already in the wave in `conflicts_with` (symmetric),
      and leaving out a fresh goal whose branch or path already exists
      (`worktree-exists`, step 4).
      Stop at N. Skipped goals wait for a later wave.
   4. Journal `ORCHESTRATOR wave <n> <id,id,…>`. Set each fresh member
      `in_progress`. Commit `GOALS.md` and the journal in one commit
      (`chore: orchestrator wave <n>`). This commit is the **wave base**.
   5. Create every fresh member's worktree first (step 4), then run
      `worktree_setup` (step 5) in each, under `set +e`. A setup failure is
      that member's stop, collected for the combined stop like any other; it
      does not end the walker, and the other members are still set up.
   6. Start `run-goal.sh --worktree <main-root> <id>` in the background, each
      with its own stop pointer, for:
      - each fresh member, when there is no `worktree_setup` key or its
        setup exited 0 with a clean worktree;
      - each re-attached member that already has a current attempt (setup
        does not run for it);
      - each re-attached member with no attempt whose setup exited 0 with a
        clean worktree.

      A member whose setup failed is never started, so it never journals a
      `dispatch`, and the next rerun sets it up again. Record each pid. If no member started, go
      straight to the combined stop.
   7. Write a `walk` event row with the walker's pid, as today, so
      `walks.live` stays true.
   8. Under `set +e`, `wait` on every pid and collect each exit status. A
      sibling's nonzero exit must not end the walker before the clean goals
      are integrated. One walker-owned `join_wait` event per wave (no `goal`
      field, so it is never a goal's latest event and cannot change how a
      goal reads in the pane) records, per goal in its payload, the seconds
      between that goal's exit and the last exit of the wave.
   9. **Join**, in wave order:
      - exit 0: integrate the goal (step 7);
      - exit 3: bounce it (step 7a);
      - any other exit: keep its stop file for the combined stop.

      An `integration-tamper` ends the join at once (step 7).
   10. If any member stopped, any integration failed, or any goal was left
       out for `worktree-exists`, write one combined stop file and exit
       nonzero (step 9). Otherwise loop. A wave that builds with zero goals
       while the frontier is not empty (every candidate left out) exits with
       that combined stop, never loops.

   An empty frontier ends the walk as today: walk-end if everything is done,
   otherwise `walk-stuck`.

4. **Worktrees.**
   - Path: `~/.cache/claude-coding-workflow/worktrees/<repo_id>/<goal>`. The
     `repo_id` is the events hash of the main checkout's root. The folder is
     private (700).
   - `cw_prune` does not touch it. The walker creates worktrees and only it
     deletes them.
   - Creation: `git worktree add -b cw/<goal> <path> <wave-base>`.
   - If `cw/<goal>` or the path already exists for a goal starting fresh,
     that goal stops with `worktree-exists`, and the stop file names the
     commands to remove them. The check runs while the wave is being built,
     before the wave commit (step 3.3), so the goal is never set
     `in_progress`. It stays `ready`, it is left out of the wave, and it is
     listed in the combined stop. Every later walk hits the same stop until
     the path and branch are gone. An implementer could have planted it, or an old
     run left it, and either way it gets inspected.
   - One exception: a goal set back to `ready` whose branch journal ends its
     last attempt (from its last `dispatch <id> r0`) with `bounced <id>`
     (step 7a). The Architect has looked
     at it and reset it, so during the check the walker only removes the old
     worktree and branch (`git worktree remove --force`, `git branch -D`)
     and keeps the goal in the wave. Step 3.5's `git worktree add` from the
     wave base is the only place any worktree is created.
   - A worktree and its branch are removed (`git worktree remove`, then
     `git branch -D`) only after the goal is integrated and its `done` is
     committed. On any other stop they are kept as evidence and for resume.
   - At walk-end: `git worktree prune`, then list any `cw/*` worktree still
     registered, in the walk-end output and the journal. Delete nothing.

5. **`worktree_setup:` (an optional `GOALS.md` preamble key).**
   - One shell command, written by the Architect at to-goals, so it is part
     of the signed contract (for example `npm ci`, `uv sync --frozen`).
   - It runs on the host:
     - with network;
     - with credential-named variables stripped (`proof_env_unsets`);
     - with `PYTHONDONTWRITEBYTECODE=1`;
     - bounded by `PROOF_TIMEOUT`.
   - It runs in two places:
     - in each new or re-attached worktree before dispatch, when the goal has
       no current attempt;
     - in the main checkout after each merge, before the merged proofs
       (step 7). A merged goal may have changed the lockfile, and the main
       checkout's ignored `node_modules` or `.venv` would otherwise be
       missing or stale, unseen by the clean check.
   - A nonzero exit or a timeout stops with `worktree-setup-failed` (output
     in the run folder). In a worktree the goal stays `in_progress` with no
     attempt; a rerun of the walker re-attaches it, runs setup again and
     starts fresh (step 6). After a merge, it is an integration failure,
     handled like `integration-red`: the walker's merge is reset.
   - Afterwards the tree must still be clean apart from ignored files, the
     same rule as the fresh-start gate. In a worktree the check is
     `git -C <worktree-path> status --porcelain` (the walker's cwd is the
     main checkout); after a merge it is the main checkout's own status. Otherwise it stops with
     `worktree-setup-dirty`. After a merge, that ends the join at once,
     exactly like `integration-tamper` (step 7): nothing is reset, and the
     stop file names the restore and the `reset --hard <pre-merge sha>`. In a
     worktree, re-attaching a goal with no attempt first runs
     `git -C <worktree-path> reset --hard HEAD` and
     `git -C <worktree-path> clean -fd` (not `-x`: ignored dependency
     folders stay) before running setup again. Both name the worktree
     explicitly, since the walker's own cwd is the main checkout. With no attempt,
     nothing in that worktree is an implementer's work.
   - No key: nothing runs.
   - `goals.py validate` accepts the key and `goals.py meta` prints it. Its
     description goes into `GOAL-FORMAT.md`.

6. **`run-goal.sh --worktree <main-root> <id>` (worktree mode).** The flag is
   passed by the walker; nothing infers it from the folder.
   - **Status:** read from `<main-root>/GOALS.md`, read-only. Worktree mode
     writes no status. The walker sets `in_progress` before dispatch, so the
     **worktree's journal** decides resume:
     - a current attempt means resume, as today. A **current attempt** is
       the last `dispatch <id> r0` line, provided no `done <id>` or
       `bounced <id>` line follows it. This one definition is used
       everywhere the plan says "attempt" (resume, `worktree_setup`, the
       re-attach cleanup, the start rules) and by `resume-state.py` in
       worktree mode. A goal recut after a bounce inherits its old records
       through the walk journal; those end in `bounced <id>`, so it has no
       current attempt, runs setup and starts fresh with `BASE_SHA` equal to
       the wave base;
     - `in_progress` with no attempt is a fresh start (`BASE_SHA=HEAD`,
       round 0).
   - **`GOALS.md` in the worktree** must equal `BASE_SHA`'s byte for byte.
     Full equality replaces every `status-only-id` allowance, so a
     status-only edit counts as drift there too. The allowances it replaces
     are in the fresh-start gate, the three `contract_drift` comparisons
     (index, HEAD, worktree) and the dirty-tree loop.
   - **Outcomes:**
     - done: journal `done <id>`, commit the journal on `cw/<goal>`, exit 0;
     - bounced (reviewer BLOCKED, `blocked-oracle-edit`): journal
       `bounced <id>`, commit, write the stop, exit **3**;
     - every other wake: exit 1, as today.
   - **Events:** the index and the walk file are keyed on `<main-root>`
     (`CW_EVENTS_ROOT`, read by `events.py git_root()`). Worktree mode never
     mints a walk.
     - A goal's own DONE is a non-terminal `phase integrate` event, not
       `done`. The walker writes the `done` event when it sets the status
       (step 7). The goal's process exits right after, so `live_goals` (which
       needs the event's pid alive) would drop it. It is extended: while the
       walk is live (the walker's pid, `walk_liveness`), an `in_progress` goal
       whose latest event is `phase integrate` counts as running, with phase
       `integrate`. The `/walk` pane and the walk tasks therefore show a goal
       waiting at the join as integrating, not `PAUSED`. Once the walker is
       gone, the goal reads as paused, as today.
     - `join_wait` (walker-owned, no `goal` field) and `integrate` are added
       to `events.py`'s `EVENTS`.
       `events_append` swallows a rejected event, so without that the timing
       rows would be silently dropped. A test reads them back.
     - `events.py append` takes an `flock` on the jsonl and writes each line
       with one `os.write`, so N goals and the walker never tear a line.
   - **Proof isolation between goals:** the proof runs with
     `TMPDIR=$RUN_DIR/tmp`, private to each goal. Ports are not
     virtualised: `GOAL-FORMAT.md` says a proof that binds a fixed port, or a
     fixed path outside the repo, must name its sibling goals in
     `conflicts_with`.
   - **Ref protection:** the walker resolves every deny path from the main
     checkout:
     - with `git rev-parse --git-path`: its `HEAD`, `index` and `logs/HEAD`
       (these live under `worktrees/<name>/` when the main checkout is itself
       a linked worktree);
     - with `--git-common-dir`: `packed-refs`, the walk branch's ref and its
       log, and every other wave member's branch ref and `worktrees/<name>/`.

     It passes them to `claude-implement.sh` as repeated `--deny-write PATH`
     arguments. The launcher builds the sandbox settings once and reuses them
     for the DeepSeek fallback pass. The legacy `IMPLEMENTER=codex` launcher
     refuses worktree mode (gate).
   - **Unchanged:** the no-progress diff (it runs in the worktree), handoffs
     in `$RUN_DIR/implementer/`, `ART_DIR` (keyed by goal id), and the
     `.claude` baseline (keyed by root path).

7. **Integration, by the walker in the main checkout, one goal at a time.**
   - **Before merging:** the walk-branch check (step 2) must pass, and the
     main checkout's tree must be clean, on every path, including the
     ancestor one below. A dirty tree stops with `integration-dirty`: no
     proof runs and no `done` is set. Its cleanup text depends on whether
     this goal's integrate commit exists. If it does not (the dirt came
     before any merge), it names `git status`, then `git reset --hard HEAD`
     and `git clean -fd`. `HEAD` is already the walk tip, so no integrate
     commit is looked up, and both a staged index and untracked files are
     cleared, which `git restore` would leave behind. If it does, it names the tamper cleanup, `reset --hard` to that
     commit's first parent. The lookup runs under `set +e`, so a missing
     commit can never end the walker before the stop file is written. If `cw/<goal>` is already an ancestor of the walk tip (a
     crash after the merge commit, or a rerun after `integration-tamper` or
     a dirty post-merge setup, before `done`), the merge is skipped and the
     walker goes to the merged proofs, after that clean check.
   - **Journal check, on every integration** (conflict or not). The goal's
     journal must be the merge-base journal plus a byte-for-byte suffix, and
     that suffix must pass `orch-files.py --records <goal>`. The walk side's
     journal must also be the merge-base journal plus a byte-for-byte suffix,
     but `--records` is not applied to it: after the first integration it
     holds other goals' records by design, and the walker's own
     `JOURNAL_EXPECT` already vouches for it.
     `scripts/lib/journal-merge.py BASE OURS THEIRS` checks all of it and
     writes base, then the walk side's suffix, then the goal's suffix. After
     the merge, the committed journal must equal its output. Any check that
     fails aborts the merge and wakes `journal-tamper`.
   - **The merge:** `git merge --no-ff --no-commit cw/<goal>`, through the
     host git wrapper (hooks and fsmonitor off), under `set +e` with its
     exit status captured: a journal conflict is the normal case, and git
     returns 1 for it. The journal is set to `journal-merge.py`'s output and
     staged (`git add`) whether or not git reported a conflict there. Only
     then are the remaining unmerged paths checked.
   - **Merge conflict:** a conflict in any other path → `git merge --abort`,
     wake `merge-conflict`.
   - **Commit** `chore(<goal>): orchestrator integrate`.
   - **Merged proofs:** run `worktree_setup` in the main checkout (step 5).
     Then, on the merged tip, run the `proof` of the merged goal and of every
     goal done earlier in this walk. They run the same way as the host proof:
     credential variables stripped, `PYTHONDONTWRITEBYTECODE=1`, a private
     `TMPDIR`, `PROOF_TIMEOUT`, and a tree snapshot before and after. The
     snapshot and proof runner move from `run-goal.sh` into
     `scripts/lib/proof.sh`, shared by both rather than copied.
   - **A merged proof changes the tree** (checked first, whether it was red
     or green): wake `integration-tamper` at once and end the join. Nothing
     is reset. The stop file names the cleanup: `git status`, restore what
     the proof wrote, then `git reset --hard <pre-merge sha>`. A rerun then
     integrates the goal again (step 8).
   - **The reset target:** `<pre-merge sha>` is always the first parent of
     the integrate commit whose second parent is `cw/<goal>`'s tip. It is
     found the same way when a rerun skipped the merge (ancestor), so it is
     never the run's own memory. After every `reset --hard`, `JOURNAL_EXPECT`
     is reset from that tree's journal before the walker appends its wake
     line, so the commit of that line is not refused as
     `orchestration-files-changed`.
   - **A merged proof is red:** `git reset --hard <pre-merge sha>`. This
     undoes only the walker's own merge commit, since the tree was checked
     clean before the merge. Then journal and commit the wake line, and wake
     `integration-red` naming the red proofs. The goal stays `in_progress`
     with its branch and worktree.
   - **All green:** set `done`, journal `ORCHESTRATOR integrated <id>
     merge=<sha>`, write the `done` event, and commit `GOALS.md` and the
     journal in one commit. Then remove the worktree (step 4).

   **7a. Bounce (exit 3).**
   - The goal's journal suffix gets the same checks as at integration.
   - The walker appends that suffix to the walk journal, without merging any
     code, so the `bounced` record and the reviewer's ids reach the walk
     branch.
   - The same bytes are appended to `JOURNAL_EXPECT`, so the fail-closed
     journal check accepts the commit.
   - It sets `bounced` and commits `GOALS.md` and the journal in one commit.
   - The worktree and branch are kept. The goal's stop file, reprinted in
     the combined stop, adds the remove commands and the reset
     (`goals.py set <id> ready`, or let the walker recut it per step 4).

8. **Resume (the walker reruns after a stop).**
   - At start, each `in_progress` goal needs `cw/<goal>` and its worktree at
     the expected path. If either is missing, wake `worktree-missing`, naming
     the unstick commands: re-create it, or `goals.py set <id> ready` after
     removing the branch.
   - If the goal's journal on `cw/<goal>` ends its last attempt (from its
     last `dispatch <id> r0`) with `done <id>`, the goal itself finished. The walker integrates it again
     (step 7) without dispatching; the ancestor check covers a merge that
     already landed.
   - Otherwise the goal joins the first wave as a resume. With no current
     attempt, `worktree_setup` runs first.
   - Re-attached goals fill the first wave first, then fresh frontier goals
     up to N, under the same conflict rule. If the re-attached goals alone
     exceed N, the extras wait.

9. **Stops while a wave runs.**
   - **A member stops:** the others run to the end. The ones that finished
     cleanly are integrated. Then the walker writes
     `run-goals-wave-stop/stop.md`, listing each stopped goal, its reason
     and its own stop file, and prints it as the last `STOP_FILE:` line.
     Nothing new starts.
   - **INT/TERM to the walker:** TERM every running goal, wait for all of
     them, write the combined stop, exit 130/143. Each goal records its own
     stop, as today.
   - **A `.git` metadata change after the wave** (`meta_stop`) stops before
     any integration.

10. **Docs and skills.**
    - `CLAUDE.md`: drop "Parallel worktrees are not in this slice"; Phase 5
      names `--jobs`.
    - `skills/run-goals/SKILL.md`: `--jobs`, the combined stop, and the new
      reasons (`merge-conflict`, `integration-red`, `integration-tamper`,
      `walk-branch-moved`, `integration-dirty`, `worktree-exists`, `worktree-missing`,
      `worktree-setup-failed`, `worktree-setup-dirty`).
    - `GOAL-FORMAT.md`: `worktree_setup:`, and `conflicts_with` as the wave
      rule.
    - `GLOSSARY.md`: **wave**, **integration**, and an updated
      `conflicts_with`.
    - `FUTURE-WORK.md`:
      - item 6 marked done;
      - new notes for dynamic dispatch (gated on `join_wait` evidence) and
        for turning `integration-red` into a fix round;
      - item 9's carried input (`npm ci` before dispatch) closed by
        `worktree_setup`.

11. **Tests (`scripts/tests/parallel-walk-test.sh`, mock implementer and
    reviewer).**
    - **Waves:**
      - a three-goal wave;
      - a conflict split into two waves;
      - `--jobs 2` capping a three-goal frontier;
      - a single-goal wave still merged through a worktree.
    - **Integration:**
      - `--no-ff` keeps the reviewed SHAs;
      - the journal resolve keeps base, then walk additions, then goal
        additions;
      - a planted rewrite of an earlier journal line → `journal-tamper`, on
        the first goal of a wave too, where git reports no conflict;
      - a crash after the merge commit: the rerun skips the merge
        (ancestor) and goes to the merged proofs;
      - a `git switch` in the main checkout mid-wave → `walk-branch-moved`;
      - a two-goal wave where the second goal's journal conflicts with the
        first's integration: resolved, staged and committed, with no
        `journal-tamper` from the first goal's records;
      - `integration-red` after a merge, and after a rerun that skipped the
        merge: reset to the integrate commit's first parent, and the wake
        line committed (`JOURNAL_EXPECT` reset);
      - a dirty `worktree_setup` after a merge ends the join with the
        cleanup named; re-attaching a worktree with no attempt resets and
        cleans it before setup;
      - a planted `cw/<goal>` left `ready` and out of the wave, and still
        stopped on the next walk;
      - a planted `cw/<goal>` as the only frontier goal: the walk stops
        with the combined stop, it does not loop;
      - a bounce followed by a clean integration in the same wave (the
        journal expect grows by the bounce suffix);
      - the no-attempt cleanup touches only the worktree, never the main
        checkout;
      - a rerun after `integration-tamper` with the tree still dirty →
        `integration-dirty`, no proof, no `done`;
      - the pane during a join, after `join_wait` is written: still
        integrating;
      - `integration-dirty` on a goal's first integration (no integrate
        commit yet): the stop file is written and names `git reset --hard
        HEAD` and `git clean -fd`, with no integrate-commit lookup;
      - a wave where the second of three members fails `worktree_setup`:
        the other two are still created, set up and run, and the failure is
        in the combined stop;
      - a wave with no `worktree_setup` key starts every member;
      - a re-attached goal whose setup failed is not started, and is set up
        again on the next rerun;
      - a bounced goal set back to `ready` is removed during the check and
        cut once, from the wave base; its new worktree (which inherits the
        old `dispatch` and `bounced` records) runs setup and starts fresh with
        `BASE_SHA` equal to the wave base, not a resume;
      - a dirty worktree after setup is caught by the worktree's own status,
        not the main checkout's;
      - `worktree_setup` rerun in the main checkout after a merge, and its
        failure resetting the merge;
      - a planted conflicting edit → `merge-conflict`;
      - a merged proof red only together → `integration-red`, the walk
        branch reset to its pre-merge SHA, branch and worktree kept;
      - a merged proof that writes a file → `integration-tamper`.
    - **Stops:**
      - a member stopping mid-wave while the others integrate;
      - exit 3 → `bounced`, the goal's journal suffix on the walk branch, and
        a later `set ready` recutting the worktree;
      - a nonzero sibling while the others still integrate (`set +e` wait);
      - TERM to the walker mid-wave.
    - **Resume:**
      - a re-attach that resumes;
      - a re-attach whose goal is already done, which integrates without
        dispatch;
      - `worktree-missing`;
      - `worktree-exists`;
      - a fresh member with `in_progress` and no attempt starting fresh;
        a setup failure before dispatch re-attached and set up again;
      - `--jobs 1` with a `cw/<goal>` worktree present → the rerun-with-jobs
        stop.
    - **Worktree mode:** a status write refused, events landing in the main
      index, a `GOALS.md` edit in the worktree caught as contract drift.
    - **The rest:**
      - `worktree_setup` failing, timing out and dirtying the tree;
      - atomic replace (a reader never sees a torn file);
      - the `--jobs 1` equivalence;
      - walk tasks and `/walk` with three live goals, and a goal waiting at
        the join shown as integrating, not `PAUSED`;
      - N writers appending events at once, no torn line (`flock`);
      - deny paths resolved when the main checkout is a linked worktree.
    - Planted bugs, each shown red:
      - the walker skipping the tip check;
      - merged proofs covering only the merged goal;
      - the journal resolver accepting a non-append;
      - `conflicts_with` treated as one-way;
      - no `denyWrite` on the walk ref.
    - Then `run-all.sh -j 8` and `install.sh --check`.

12. **Live dogfood.** Replay the rbtree DAG in a throwaway copy with
    `--jobs 3`, from its committed `GOALS.md` and oracles: one walk with real
    Haiku and Opus. Record the waves, the `join_wait` times, the merges and
    the merged proofs in `EVIDENCE.md`, compared with the sequential walk's
    33 minutes.

## Key decisions & tradeoffs

- **Fork-join waves, not a worker pool or dynamic dispatch (user,
  2026-10-15).**
  - What it buys: one scheduler process and no shared queue. Bash 3.2 has no
    `wait -n`, and a plain `wait` per pid is enough. Merges happen only at the
    join, in a fixed order, and a mid-wave stop needs no drain policy.
  - What it costs: a fast goal idles until the slowest member of its wave
    finishes. `join_wait` events measure this, as the case for dynamic
    dispatch later.
- **One journal, resolved at merge, instead of a journal file per goal
  (user, 2026-10-15; reverses the 2026-10-10 lock).**
  - What it buys: every reader stays as it is (resume-state, orch-files, the
    events index keyed by the journal's stem, the walk-end END review, the
    implementer prompt).
  - What it costs: a resolver that must not drop or reorder records. It is
    checked by the pure-append rule and planted reorders.
- **Merge `--no-ff` and prove the merged tip, instead of rebasing.** The
  reviewed commits survive unchanged, so `BASE_SHA..HEAD` in the journal stays
  true. Merged proofs catch goals that are green alone and red together. A
  red merged proof is a wake in v1, not a fix round: a fix round would need a
  moved base, which pollutes the review diff (logged in FUTURE-WORK).
- **Worktrees outside the repo (`~/.cache/...`), dependencies through
  `worktree_setup:`.** A nested worktree would need an ignore entry
  (`.git/info/exclude` is fingerprinted, `.gitignore` is the target's). Tools
  that search upward would find the main checkout's `node_modules` and
  config by accident. Symlinked dependency folders show up as untracked
  files and would be shared and writable by every goal.
- **The walker is the single writer of `GOALS.md` and the walk branch.**
  `run-goal.sh` in worktree mode writes no status and exits 0, 3 or 1.
- **Cross-goal ref protection through the sandbox's `denyWrite`**, if step
  0(a) holds, plus the walker's own tip check either way.
- **Built in-session**, not through a bootstrap (user, Q1): the same review
  chain as items 1–10, plus the live dogfood.
- **Escape-hatch locks:** none. Every decision was answered.

## Assumptions

1. Today's `--jobs 1` behaviour is the contract: extend additively only
   (decisions memory; `journal/workflow-optimization.md:11`).
2. Commits from a worktree work under the implementer's sandbox, two at once
   (measured 2026-10-15, sibling and nested worktrees).
3. From a worktree, the sandbox blocks `.git/hooks`, `.git/config` and the
   main checkout's files, and allows the rest of the common gitdir.
   `denyWrite` blocks named files, named folders and paths that do not exist
   yet (measured 2026-10-15). Whether it holds against lock-and-rename is
   step 0(a).
4. `git_meta_init` already fingerprints the common gitdir as well as the
   per-worktree one (`scripts/lib/git-guard.sh:41`).
5. `events.py` keys the index by the cwd's path (`repo_id(git_root())`,
   `:73`, `:89`). The walk pane and walk tasks find a walk by its walk file's
   `root` and `session`, and treat a walk as live while the walker's pid
   lives (carried inputs from uregex and item 10).
6. `live_goals` and the walk-task reconcile already allow several goals
   `in_progress` at once (journal `workflow-optimization.md:70`, item 10).
7. The proof fix rounds of step 3 run inside the goal's own worktree
   unchanged: the no-progress diff uses that worktree, and the journal it
   excludes is that worktree's copy, which merges into the main journal
   (carried input from step 3).
8. `conflicts_with` is the declared merge hazard; same `area` is not a
   conflict (`GOAL-FORMAT.md:72`).
9. A fresh worktree has no ignored dependency folders, and the implementer's
   sandbox has no network (carried input from item 9).
10. `cw_prune` prunes only `runs/`, `grok/` and `lessons/logs/`
    (`scripts/lib/cache.sh`).

## Risks / open questions

- **The journal resolve is new code on the one file resume depends on.** It
  is guarded by the pure-append rule, `--records` on the goal's additions,
  and planted reorders.
- **Rate limits:** N Haiku and N Opus sessions share one account. A rate
  limit stops only that goal (`rate_limited`, as today), and the wave drains.
- **`integration-red` has no automatic recovery in v1.** The Architect fixes
  the walk branch or the goal and reruns, which integrates again.
- **The host proof and the merged proofs run unsandboxed**, with N goals'
  code on one machine at once (item 12, unchanged in kind).
- **An implementer may still write other parts of the common gitdir**
  (`objects/`, its own refs, `info/`, which `git-meta` catches).
  Cross-goal damage outside the deny list is a known limit.
- **Disk:** N worktrees with `node_modules` each. Bounded by N ≤ 4 and
  removed per goal.

## Out of scope

- Dynamic dispatch, or starting a goal before its wave has joined.
- Turning `integration-red` into a fix round.
- Sandboxing the host proof (item 12).
- Parallel walks across repos, or two walkers in one repo.
- Jest, Bun and Deno setup recipes (`worktree_setup` is a free-form command).
- Any change to the `--jobs 1` path beyond the atomic `GOALS.md` write and
  the refusal to run a goal that has a `cw/<goal>` branch or worktree
  (step 2).

## Amendment 1 — step 0 results (user-approved, 2026-10-15)

Step 0 passed (`EVIDENCE.md`): no bypass of the deny list, and the shared
object store is clean under concurrency. It found one denial-of-service gap,
and this amendment closes it. It changes step 6's deny list and adds one
walker check:

- **Lock paths:**
  - add `<path>.lock` to the deny list for every denied file except
    `packed-refs`: `HEAD.lock`, `index.lock`, `logs/HEAD.lock`, the walk
    branch's ref and reflog `.lock`, and each other member's ref and reflog
    `.lock`;
  - `packed-refs.lock` stays writable. In git 2.54, denying it makes every
    implementer commit print a false `error:`, although the commit
    succeeds.
- **Stray locks:** before each of its own git writes, the walker checks that
  no `packed-refs.lock`, and none of the denied `.lock` paths, exists. If
  one does, it wakes `git-lock-stray`, naming the file, and deletes nothing.
  `git-lock-stray` joins step 10's list of reasons. A test plants a
  `packed-refs.lock` and a `refs/heads/<walk>.lock`.

## Amendment 2 — the Opus review's trust findings (user-approved, 2026-10-15)

The first Opus review of the build found that the walker trusted state an
implementer can write. This amendment replaces those trust points:

1. **"Finished" comes from a host-written record.**
   - When the review passes, `run-goal.sh --worktree` commits its `done`
     journal line on `cw/<goal>`. It then writes a `phase integrate` event
     whose payload carries `head`, the reviewed tip SHA. The event goes into
     the events index under `~/.cache`, outside the implementer's sandbox.
   - At the join, the walker reads that SHA (`events.py finished`), refuses
     if `cw/<goal>` no longer equals it (`integration-unverified`), and
     merges the SHA, not the branch name.
   - On a rerun, an `in_progress` goal is integrated without dispatch only
     when such an event follows the goal's last `dispatch` and the branch
     still matches. If the event exists but the branch has moved, that is
     `integration-unverified`. The goal branch's journal is no longer read
     for this (step 8).
2. **A re-attached goal with no open attempt must have no commits of its own**
   past its merge base with the walk branch. Otherwise the walker stops
   `worktree-unreviewed-commits`, naming the recut: remove the worktree and
   branch, then `goals.py set <id> ready`.
3. **An integration must not change `GOALS.md`.** If the staged merge
   differs from HEAD in `GOALS.md`, the walker aborts the merge and stops
   `integration-goals-edited`.
4. **Replace refs.** The walker exports `GIT_NO_REPLACE_OBJECTS=1`, which
   every goal process inherits. `walk_check` stops `git-replace-ref` if any
   `refs/replace/` entry exists.

Also from that review, within the existing steps:
- the merge's exit status is checked (0 or 1, with `MERGE_HEAD` present,
  else `merge-failed`);
- a bounce reads the walk journal from HEAD, after checking it against the
  walker's expected copy;
- a reset happens only when the merge's commit is the sole first-parent
  commit since the pre-merge SHA; otherwise the walker stops without
  resetting and names the cleanup;
- `walk_check` runs before every reset;
- a walk-level stop raised during a wave goes into the combined stop file;
- a bounce's stop names the remove and recut commands;
- the `--jobs 1` refusal also checks for the worktree folder;
- before running git in a worktree, the walker checks that the worktree's
  `.git` file still names its own admin folder (`worktree-gitfile-changed`);
- a failed `git worktree add` is that goal's stop
  (`worktree-add-failed`).

Known limit, recorded with item 12: the deny list covers only the current
wave's members. The kept branches of goals outside the wave (a bounced goal,
an `integration-red` goal, a goal waiting for a slot) are writable by a
running implementer. An `in_progress` goal outside the wave is still checked
against its host-recorded reviewed SHA before it is merged. A bounced goal is
recut from the wave base.

## Amendment 3 — integration by construction (user-approved, 2026-10-15)

The second Opus review found five of its eight defects in fixes for the first
review's findings, all in the integration and recovery state. That state is
guarded after the fact today: branch refs, worktree HEADs, an events row,
and a reset after a merge. This amendment changes the structure instead. Where
it conflicts with steps 6–9, step 11's test list or Amendment 2, this
amendment wins: the resume, ancestor-path, reset and dirty-cleanup tests of
step 11 are replaced by tests of the scratch worktree, the `finished` record,
recut on no record, and the result file.

**A. The goal reports what was reviewed, through a file the walker owns.**
- `run-goal.sh --worktree` takes two more arguments from the walker:
  - `--base <wave-base>`: a fresh start requires HEAD == `cw/<goal>` == that
    SHA, with `symbolic-ref HEAD` == `refs/heads/cw/<goal>`. Otherwise it is a
    gate stop.
  - `--result <file>`: a path in the walker's private run folder.
- Worktree mode never resumes. It always starts fresh (C below), so it never
  reads `resume-state.py --open-attempt`; that flag and `lib/attempt-state.py`
  are removed.
- `REVIEWED_HEAD` is HEAD at the moment the review diff is cut, each round. On
  a DONE verdict, HEAD must still equal it; otherwise it wakes
  `head-moved-during-review` (exit 1). The `done` journal commit must have
  `REVIEWED_HEAD` as its parent and change only the journal.
- The goal then writes `reviewed=<sha> done=<sha>` to the result file, as its
  last act before exit 0.
- The `phase integrate` event stays, for display only. Nothing trusts it, and
  `events.py finished` is removed.

**B. The walker records it, and integrates in a scratch worktree.**
- **At the join, before any integration:** for every goal that exited 0,
  read its result file and require `cw/<goal>` == `done`, `done^` ==
  `reviewed`, and `reviewed..done` touching only the journal (otherwise that
  goal stops `integration-unverified`). Then journal
  `ORCHESTRATOR finished <goal> head=<done>` for every verified goal, in one
  walker commit on the walk branch. Those records, in walker-written history,
  are what a rerun reads, so a wave sibling whose integration never started is
  integrated from its record, not recut. Each verified result file is also
  copied to `<wt-base>/.results/<goal>` (walker-owned, outside the repo). If
  the `finished` commit does not land (a stray lock, a signal), the next start
  re-verifies the branch against that copy and writes `finished` from it
  before deciding anything else for the goal. The copy is deleted once the
  goal is integrated or recut.
- **Integration happens in a walker-owned scratch worktree,** a new folder
  per attempt (`mktemp -d` under `<wt-base>/.integrate/`, so a retry never
  meets a folder kept as evidence):
  `git worktree add --detach <scratch> <walk tip>`.
  In it, in order:
  1. the journal check (Amendment 2);
  2. `merge --no-ff --no-commit <done>`;
  3. the checked journal resolution;
  4. the conflict check and the GOALS.md check;
  5. the integrate commit;
  6. `worktree_setup`;
  7. the merged proofs, with tree snapshots taken in the scratch tree;
  8. `goals.py set <goal> done` and the `integrated` journal line, committed
     after a byte check against the expected journal.
- **Only if all of that is green,** the walker fast-forwards the walk branch
  in the main checkout: `walk_check`, a clean tree, then
  `merge --ff-only <scratch tip>`. After that it removes the scratch worktree
  and the goal's worktree and branch.
- **Any failure** (conflict, journal check, setup, red, tamper) stops that
  goal. The integration never moves the walk branch, and nothing is reset:
  the `finished` commit already on it stays. The scratch worktree is kept as
  evidence and named in the stop file. Nothing is ever reset, so `safe_reset`,
  the ancestor path and the "NOT reset" cleanup text are removed.
- **After a failed integration** the goal's recorded SHA stands: a rerun
  integrates that same SHA again, which is the path when the Architect fixes
  the walk branch (another goal, the plan's shared code). A commit added to
  `cw/<goal>` after the review is never merged, not even a descendant of the
  recorded SHA: it is unreviewed. To change the goal itself the Architect hands
  it back (`goals.py set <goal> ready`, committed); the walker then recuts it
  (C) and it is implemented and reviewed again. The stop file names both
  paths.
- `integration-dirty` is now only a dirty main checkout before the
  fast-forward. Its stop names `git status`, then restoring the working tree
  to HEAD (`git restore --staged --worktree .` and `git clean -fd`), and says
  not to move HEAD: HEAD holds the wave's `finished` records, and dropping
  them would recut those goals.

**C. Stopped goals restart fresh.**
- At the start of a walk, and at each wave, an `in_progress` goal is handled
  by what the walk journal (walker-written) says about it:
  - **A `finished <goal> head=<sha>` record after its last wave membership,
    with `cw/<goal>` == that SHA:** the walker integrates it without
    dispatching.
  - **A `finished` record, but the branch moved:** `integration-unverified`.
  - **No `finished` record:** the goal is recut. The old branch's journal
    suffix, if it passes the journal check, is appended to the walk journal as
    the abandoned attempt's record. The walker journals
    `ORCHESTRATOR recut <goal>`, removes the old worktree and branch, and the
    goal joins the wave as a fresh member. The wave commit's allow list
    permits an already `in_progress` member.
- **Walker-only records.** A goal's journal suffix may hold only what
  `run-goal.sh` and the implementer write. `journal-merge.py` refuses a suffix
  holding any record only the walker writes (`finished`, `recut`,
  `integrated`, `wave`, `wave-stop`, `walk`, `walk-start`, `walk-end`,
  `walk-stuck`) as `journal-tamper`, for every use: integrate, bounce and
  recut. A suffix that fails is not appended.
- A `ready` goal whose `cw/<goal>` or folder already exists is recut the same
  way when the walk journal shows it was a member of an earlier wave (a
  bounce, then the Architect's reset). Otherwise it is `worktree-exists`, as
  before. The goal branch's journal is never read to decide this.
- The re-attach checks of Amendment 2 (own commits, the journaled base,
  `wt_ok`) are removed: the walker never runs git in a leftover worktree
  except `git worktree remove --force` from the main checkout.
- The deny list names each member's admin folder as git created it, read
  from the new worktree's `.git` right after `git worktree add` and before
  any goal runs. `git worktree prune` runs before cutting worktrees.

**D. One exit path during a wave.**
- From the wave commit to the end of the join, every stop (a goal's, a
  walk-level `walk_stop`, `meta_stop`, a signal) goes into the combined stop.
  `wave_stop`:
  - clears the INT/TERM traps;
  - lists every goal that exited 0 and was not integrated as
    `finished-not-integrated`;
  - commits its journal line only when every precondition holds (the walk
    branch and tip, no stray lock or replace ref, the journal as expected,
    nothing staged, GOALS.md equal to HEAD); otherwise it notes in the stop
    file why the line is not committed. It never exits any other way.
- A signal sends TERM only to members that have not exited.

**E. Known limit, stated plainly (item 12).** The host proof and
`worktree_setup` run unsandboxed, as the user. Code they run can write the
walker's run folder, the events index and the main repository. Amendments 2
and 3 defend against the sandboxed implementer, not against that. Closing it
is item 12.

## Amendment 4 — the third review's findings (user-approved, 2026-10-15)

1. **The scratch integration is checked by commit structure, not by reading
   the scratch tree's HEAD at the end.** Something left running could repoint
   the scratch worktree's HEAD or rewrite its index, because its admin folder
   is created after the deny lists. So:
   - Right after the integrate commit, the walker captures its SHA, `M`. It
     requires:
     - `M^1` == the walk tip and `M^2` == the reviewed `done` SHA, with no
       third parent;
     - every path of `M` equals the walk tip's version or the goal's version,
       except the journal, which must equal the checked resolution;
     - a clean scratch tree with HEAD == `M` before and after setup and the
       merged proofs.
   - After the `integrated` commit it captures `F` and requires:
     - `F^1` == `M`, with only `GOALS.md` and the journal changed;
     - the journal blob byte-equal to what the walker wrote;
     - `GOALS.md` moved only by `<goal>: in_progress → done`.
   - The walk branch then fast-forwards to the captured `F`, never to
     whatever the scratch HEAD names. Any mismatch is `integration-tamper`.
2. **The goal's own worktree link files are protected.**
   - The implementer could point its worktree's `.git` gitfile, or its admin
     folder's `commondir` or `gitdir`, at a fake gitdir whose config defines a
     filter driver. The host's next git call there would then run that program
     outside the sandbox.
   - Each goal's deny list now names its own `<worktree>/.git`,
     `<admin>/commondir` and `<admin>/gitdir`.
   - `run-goal.sh` in worktree mode saves their bytes at start, before any
     implementer runs. Before every host git call (the `git()` wrapper) it
     compares them again, without running git. A difference taints host git,
     as a `.git` metadata change does (`git-metadata-tamper`).
   - Amendment 3 E's "defend against the sandboxed implementer" holds only
     with this in place.
3. **The join handles every outcome before it integrates:**
   1. verify each exit-0 goal's result and write its durable copy
      (temp file, then rename);
   2. record each stopped goal, and bounce each exit-3 goal;
   3. write the `finished` records;
   4. integrate.
   - A goal whose integration has not finished stays listed
     `finished-not-integrated`, together with the scratch worktree in use.
   - On a signal, every member that has already exited is handled the same
     way, with no git write: an exit-0 goal gets its durable copy and is
     listed; any other is listed from its own stop file.
4. **Smaller changes:**
   - `walk_record` reads the walk journal as bytes, decoded with
     replacement, and a failure to read it is a stop, never an empty answer.
   - A member's old result copy is removed at its wave commit.
   - A copy that no longer verifies at start is reported.
   - The admin folder path is taken from `git rev-parse --absolute-git-dir`
     right after the cut, so a relative gitdir works.
   - Worktree removal uses `remove -f -f`, which also handles a locked
     worktree.
   - Walk-end also lists leftover scratch worktrees.
   - Worktree mode's preflight is `--none`.

## Amendment 5 — the fourth review's findings (user-approved, 2026-10-15)

Round 4 found that Amendment 4's integration check refused correct merges,
and that the join's bookkeeping still lost goals in some orders. Three
simplifications replace those parts. Where they conflict with Amendment 4,
this amendment wins.

1. **One tree comparison, not a path-by-path check.**
   - The walker computes the expected integration itself:
     - `git merge-tree --write-tree --merge-base=<base> <walk tip> <done>`;
     - then, through a temporary index, the journal replaced by the checked
       resolution.
   - The integrate commit `M` must have exactly that tree, plus the parents
     Amendment 4 names (the walk tip and the reviewed `done` SHA).
   - This accepts every merge git makes cleanly (two goals editing different
     parts of one file, a rename on one side, non-ASCII paths) and refuses
     any other tree.
   - Amendment 4's rule "every path equals one side's version" is withdrawn.
2. **Host git never reads a worktree's link files.**
   - Every host git call into a linked worktree runs with `GIT_DIR`,
     `GIT_COMMON_DIR` and `GIT_WORK_TREE` pinned to the values recorded when
     the walker created that worktree, before anything else could run in it.
   - That covers `run-goal.sh`'s `git()` in worktree mode, and the walker's
     calls into a scratch worktree, including the tree snapshots around the
     merged proofs.
   - The `.git` gitfile and the admin folder's `commondir` are then never
     consulted. Amendment 4's byte check of them stays as a second layer.
   - In worktree mode `events.py` makes no git call of its own.
3. **The combined stop derives its list from each member's state.**
   - `wave_stop` goes through every member of the wave:
     - integrated (done in GOALS.md): skipped;
     - already holding its own stop: skipped;
     - still running: `interrupted`;
     - exited 0: its result is checked and kept, and it is listed
       `finished-not-integrated` (or `integration-unverified`);
     - exited 3 and not bounced: `bounced-not-recorded`;
     - any other exit: its own stop file.
   - `JOIN_LEFT`, `HANDLED` and the ordering rules they needed are removed.
   - The join still records stops before bounces, and bounces before
     integrations.
4. **Smaller changes:**
   - The walk-journal record must match
     `none | member | finished <sha>`; any other result, or a failed read, is
     a stop.
   - `F`'s `GOALS.md` must equal, byte for byte, the walk tip's `GOALS.md`
     with only `<goal>` set to `done`. The `integrated` record names `M`.
   - Tests:
     - a clean merge of a file two goals both edited, which must integrate;
     - Ctrl-C in wave 2;
     - the UTF-8 test with a pinned locale, checking that the bytes reached
       the walk journal;
     - the reviewed-SHA check reading the record that existed before the
       rerun.

## Amendment 6 — a merge conflict recuts the goal once (user-approved, 2026-10-23)

House item 17, its own crucible: `docs/features/merge-conflict-recut/PLAN.md`
(Grok, 3 rounds, approved; signed off by the user). A plain `merge-conflict` at
integration no longer stops the walk the first time: the walker saves the
conflicted paths, aborts the merge, removes the scratch tree, and after the
wave's integrations (and at the top of `wave_stop`) recuts the goal from its
verified SHA, keeping the attempt at `refs/cw-conflict/<g>/<n>` and writing
`recut <g> reason=merge-conflict`. The goal runs fresh in a later wave from the
new tip. One such recut per goal per walk, counted from the journal since the
walk's `walk-start`; a second conflict stops as before. Every other
integration stop is unchanged.
