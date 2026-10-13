# Plan Review Log: Walk progress in the task list; the walk footer dropped
Phases 0-1 (recon + interrogation) complete — plan locked with the user. MAX_ROUNDS=5.

## Round 1 — Grok

I'll read the plan and the domain docs around it, then check the repo assumptions it depends on.The plan leaves the task list wrong in the cases that made the footer useless: a walk resumed elsewhere, `/clear`, a `TodoWrite`, and a walker-level stop.

1. Resuming a walk from another session does not move it. `ensure-walk` rewrites `session` on the existing file (`scripts/lib/events.sh` reuses that file for every `run-goal.sh`), but the mod untracks only when the file is gone. The launching session keeps updating its tasks, and the new session creates a second set. Fix: untrack when the file's `session` is a different id, and adopt only then.

2. `/clear` drops a live walk. The lessons mod already records that `/clear` continues under a new session id and does not run `session.start` (`mods/lessons/hooks/register.tsx`). The walker keeps the old `CLAUDE_CODE_SESSION_ID`, so `walks --session <$.session.id()>` misses the file; task ids from the old session then fail `TaskUpdate` and, by the "do not recreate" rule, are gone for good. Fix: on `classic.SessionStart` with `source: 'clear'`, keep polling the previous id and recreate that walk's tasks in the new list.

3. Any `TodoWrite` ends tracking forever. `TodoWrite` replaces the whole ctrl+t list (the plan's own reason for refusing it), and the run-goals skill still does that after the script exits (`skills/run-goals/SKILL.mdThe plan drops the only live display and then loses the task list in the cases the user actually hits. The walk stays invisible or reads as still running.

1. A failed `TaskUpdate` is treated as "the person deleted this task," and that goal is never recreated. `TodoWrite` replaces the whole list (the plan says so), and `skills/run-goals/SKILL.md` still tells the Architect to `TodoWrite` again after the script exits. That wipe fails every mapped id, the mod drops the goals, and the live walk never comes back. The same thing happens if crucible, or any other skill, writes todos mid-walk. Fix: recreate goals that disappear together while the walk file still exists, and delete the post-exit `TodoWrite` from the skill (drop `TodoWrite` from its `allowed-tools`).

2. A paused goal stays `in_progress`, and `activeForm` is set only for `running`. The ctrl+t row shows `activeForm` for `in_progress` (the spinner falls back to the subject only when `activeForm` is absent, changelog 2.1.68). After a wake, the row still reads `g4 · review · r1`. Fix: on `paused`, set `activeForm` to `Paused: <reason>` in the same `TaskUpdate`.

3. `reason` is "the last wake or bounce event naming that goal," but the stops that leave a walk sitting there do not name a goal. `run-goals.sh` `walk_stuck` and `walk_stop` append `wake` with `--reason` and no `--goal` (`run-goals.sh` around the `walk-stuck` and `walk_stop` writers). A goal left `in_progress` is `paused` in `walk_graph` with `reason: null`, so the subject becomes `PAUSED: null`. A kill with no new wake reuses an older per-goal wake (`live_goals` already says a hard kill writes nothing). Assumption 8 forbids changing those shell scripts, so `events.py` cannot see a `goal_id` that was never written. The `bounced` row also has no `--reason` (`run-goal.sh` bounce append); only the wake after it does. Fix: if the goal's newest `wake`/`bounced` is older than its newest `walk`/`dispatch`, or there is none, use the newest goal-less `wake` (`walk-stuck`, `orchestration-files-dirty`, `git-metadata-tamper`); otherwise use `stopped`, and never print the word `null`.

4. "Reuse rewrites `session`, so the walk moves to the new session" does not remove it from the old one. Untrack is specified only when the walk file is gone. The file is rewritten, not deleted, so the old session keeps updating its tasks and the new session adopts a second set. `events.sh` also sets `WALK_ID` to whatever follows the last tab of `ensure-walk`'s stdout. Fix: untrack when this session's id is no longer the file's `session`, and keep stdout as `minted|reused<TAB>walk_id`, written by temp file plus rename.

5. Superseding a walk deletes only non-completed tasks, so the next DAG shares the list with the previous DAG's completed rows. The "N tasks, M done" header is the misread this plan is for. The all-done clear is a global list behavior observed when the list was only that walk. It does not run when any other task is still open, and a finished `/run-goal` never deletes its walk file, so the other goals stay pending forever. Fix: on supersede and on walk-end, delete every task id in that walk's map, and do not use the engine clear as the deletion mechanism.

6. `/clear` continues the process under a new session id and does not run `session.start` (`mods/lessons/hooks/register.tsx`). The walker already stored the old `CLAUDE_CODE_SESSION_ID`, and the poll is registered only from `session.start`. A new poll's `walks --session <new id>` does not see the in-flight walk. The plan only says `$.state` survives a mod reload. Fix: on `classic.SessionStart` with `source: 'clear'`, keep the tracked map and keep matching the walk file's previous session id.

7. `GOALS.md` is rewritten on every goal (`refresh` and the status commits). `walk_graph` raises on a mid-write file, and today's status poll keeps the last label for five failures. The plan removes that poll and does not say a failed `graph` is not walk-end. One bad read can untrack a live walk or leave the list stale with no debug line. Fix: keep the last applied tasks across a failed `graph`, log the failure, and untrack only after the walk file is confirmed gone.

8. Tasks are created once, when the walk is first seen. A `TaskCreate` that fails (the plan never passes `description`, which this tool still requires; only `activeForm` became optional) is not covered by the "do not recreate" rule, and the next poll will not create it because the walk is already tracked. A subject that merely starts with `<goal-id> — ` is adopted, including a task the person wrote, and supersede then deletes it. Fix: create any goal that has no map entry, remember ids the person actually deleted, require `description`, and adopt only an exact seeded subject `<goal-id> — <title>`.

9. The lessons filter reads `next.origin.plugin`. Every origin this repo and the installed mods read is `e.origin` (`kind`, not `plugin`), including `command.run` in `mods/lessons`. The `tool.call` handler already `await next(e)` and is registered with `.catch(passThrough)`, which calls `next(e)` again. A missing `next.origin` runs the tool twice and then counts no failures. Fix: read the engine-vs-plugin origin off the event, and ignore plugin-origin failures without throwing.

VERDICT: REVISE

### Architect's response
(The verdict file holds a cut-off first draft followed by the full critique; the numbered list below answers the full one.)
1. Taken. A missing task is told apart by `TaskList`: all of a walk's ids gone = a replaced list (`/clear`, `TodoWrite`), recreated; one gone while others remain = the person's deletion, never recreated. run-goals drops the post-exit `goals.py todos` / `TodoWrite` step and `TodoWrite` from allowed-tools.
2. Taken. A paused goal's `activeForm` becomes `<goal-id> PAUSED: <reason>` in the same update.
3. Taken. `reason` order: the goal's newest wake/bounced row if newer than its newest walk/dispatch row (a bounce reads the wake after it); else the newest goal-less wake newer than that; else `stopped`. Never `null`.
4. Taken. A tracked walk whose file names another session is untracked at once. ensure-walk keeps its `minted|reused<TAB>walk_id` stdout and writes the walk file by temp file + os.replace.
5. Partly taken. Supersede deletes every task id of the old walk, completed included (the engine's all-done clear is not the mechanism). Rejected: deleting at walk-end — the person would lose the finished walk's "N done" the moment it ends; the tasks stay until the next walk supersedes them or the list clears.
6. Taken. The mod keeps every session id this process has had (in $.state, adding $.session.id() each poll) and queries walks for all of them (`walks` takes several --session), so `/clear` keeps tracking; the recreated-list rule rebuilds the tasks in the new list.
7. Taken. A failed walks/graph read keeps tasks as last applied and logs; untrack only when a successful `walks` call no longer lists the walk.
8. Taken. Any goal with no map entry (and not person-deleted) is created on each poll, so a failed create retries; TaskCreate carries a description; adoption only on the exact subject `<goal-id> — <title>`.
9. Rejected as stated, with evidence; the robustness part taken. The mod API types give `tool.call` no `origin` on the event (`ToolCallInput = ToolCallEnvelope & AgentLoop & ToolRequestMeta`); `e.origin` with `kind` exists on command/prompt events, which is what the lessons mod reads there. The calling plugin is `next.origin.plugin` (`Origin { plugin, tier }`, `"engine"` for a call site). The read is `next.origin?.plugin`, absent counted as engine, and cannot throw, so `.catch(passThrough)` never reruns the tool; a test pins that the tool runs once.

## Round 2 — Grok

I'll re-read the revised plan and check it against the earlier findings and the code those findings came from.The earlier holes in stdout, atomic writes, paused `activeForm`, the lessons origin read, the skill's post-exit `TodoWrite`, failed `graph` reads, and create retries are closed in the text. Four interactions in the new rules still break the list.

1. Supersede deletes the previous walk's task ids and leaves that walk tracked. The same poll treats "none of this walk's mapped ids are in `TaskList`" as a replaced list, drops the map, and creates the tasks again. A delete that succeeds still comes back on the next update: the applied state is the old status, `TaskUpdate` hits a dead id, and the all-gone rule recreates the walk. Two DAGs share the header again. Walk-end untracks a finished walk and does not say the map is kept, so a later supersede has no ids left to delete and the finished tasks sit beside the new DAG. Fix: retire the previous walk in that poll (out of the tracked set, out of the all-gone recreate) and keep its task ids until the `deleted` updates succeed.

2. A replaced list is noticed only when a `TaskUpdate` fails, and an update is sent only when a field changes. Steady state is zero tool calls, which is the long implement phase. `/clear` starts a new session task list (tasks are stored per session id) while the map still holds the old ids, and a `TodoWrite` from any other skill does the same. The walk is missing from ctrl+t until the next phase change. Fix: one `TaskList` per poll for each tracked walk, and run the all-gone check even when no field changed.

3. Adoption matches only `<goal-id> — <title>`. A paused or bounced goal's subject is `<goal-id> — PAUSED: …` or `BOUNCED: …`. `$.state` is gone after a process restart; a resumed session keeps the same session id, so the walk file matches and the tasks are still on disk. The title does not match, `TaskCreate` adds a second task, and the renamed one stays forever because the mod only touches ids in its map. Fix: also adopt one task whose subject is exactly the title or the mod's own `PAUSED:` / `BOUNCED:` line.

4. "Newer" is not tied to a field. `ts` is whole seconds (`utc_now`) and `ts_mono` is the millisecond clock on the same row. A fast gate writes `walk` and `wake` in the same second, `>` on `ts` fails, and the goal shows `stopped` instead of `dirty-tree` or `proof-red`. Fix: order rows by `ts_mono`, and break ties by file order.

VERDICT: REVISE

### Architect's response
All 4 taken.
1. Walks now have three sets: tracked, finished (walk-end or resumed elsewhere: map kept, no updates, no creates, no replaced-list check) and retiring (on supersede, in the same poll, every tracked and finished walk other than the new one: out of the tracked set and out of the replaced-list check; each id deleted, leaving the map on success or when TaskList no longer lists it, retried otherwise).
2. While any walk is tracked, every poll reads TaskList once before any update and runs the all-gone / some-gone check whether or not a field changed.
3. Adoption also takes the mod's own `PAUSED:` / `BOUNCED:` subject for that goal (a restart loses $.state while the session's tasks persist).
4. "Newer" orders rows by ts_mono, ties broken by file position.

## Round 3 — Grok

I'll read the revised plan and check the four open findings against the code they depend on.The four earlier holes are closed in the approach: retiring walks stay out of the replaced-list check, `TaskList` runs every poll, a `PAUSED:` or `BOUNCED:` subject can be adopted, and `reason` orders rows by `ts_mono` with file order as the tie-break. The lifecycle those rules add is still inconsistent, and one deletion case rebuilds a task the person removed.

1. A superseded walk is still listed by `walks` (a `/run-goal` file is never deleted). Its task ids leave the retiring map as the deletes succeed, and nothing says the empty walk key stays retired. The next poll treats that key as a new walk, retires the walk just shown, and the two swap every poll. Line 91 makes this worse: "untracked only when a successful `walks` call no longer lists it" forbids retiring a walk that is still listed, so the old walk stays tracked, its deletes look like a replaced list, and the create step builds it again. Fix: keep a tombstone for every key that enters retiring or finished until `walks` stops listing that file, and delete the "only when" sentence.

2. Walk-end moves a walk to finished as soon as `walks` omits it, then reads the graph. That read often races the walk-end rewrite of `GOALS.md` and fails. A failed read leaves the last applied state, and finished walks are never updated again, so a goal that just finished stays `in_progress` in the "N done" list. Fix: stay tracked and retry the final graph read until it succeeds, and only then move to finished.

3. The missing-task rule treats "no mapped id is listed" as a replaced list. After the person deletes tasks one poll at a time, the last remaining id hits that branch and the create step puts it back within 3 seconds. A one-goal walk does this on the first delete. Fix: a single missing id is always a person-delete, and the person-deleted set survives a map drop. A replaced list is two or more mapped ids, all absent in one poll.

4. The rate note still says the steady state sends zero tool calls. That drops the per-poll `TaskList` and the `/clear` / `TodoWrite` check does not run during the implement phase. Fix: the steady state is one `TaskList` per poll.

VERDICT: REVISE

### Architect's response
All 4 taken.
1. Tombstones: every key that enters finished or retiring is remembered until a successful `walks` call stops listing its file; a listed key with a tombstone is never tracked again. The "untracked only when walks no longer lists it" sentence is replaced by "a failed read never moves a walk out of tracked".
2. Walk-end keeps the walk tracked (no creates) and retries its final graph read each poll until one succeeds; only then finished.
3. A replaced list is two or more mapped ids all absent in one poll with none listed; a single missing id is always the person's delete; the person-deleted set survives a map drop. A one-goal walk whose list is replaced stays gone (accepted, logged in the plan).
4. The rate note now says one TaskList per poll while a walk is tracked.

## Round 4 — Grok

I'll read the revised plan and check the last findings against the walk lifecycle and the code it relies on.The fourth review was cut off before a verdict. I'll re-read the revised plan and check the prior findings against the code they depend on.The four earlier findings are closed. A still-listed superseded walk is tombstoned and not tracked again. Walk-end stays tracked and retries the final graph read before it moves to finished. One missing task id is always a person-delete, and that set survives a dropped map. The steady state is one `TaskList` per poll while a walk is tracked.

Four new problems:

1. The first poll that sees more than one walk locks in the wrong one. `walks` is an unordered directory listing. `events_end_walk` runs only from `run-goals.sh` when the frontier is empty, so a `/run-goal` file and a `walk-stuck` file stay on disk with this session id. A process restart clears `$.state`, including tombstones, and the plan already relies on that for adoption. Every leftover file then looks new. "Starts tracking a new walk" retires every other tracked walk in that same poll, so the last key in listing order tombstones the rest, including the walk that is still running. Those tombstones stick, because those files remain listed.

Fix: when one poll lists more than one non-tombstoned walk, track only the walk file with the newest mtime and tombstone the other listed keys in that same poll.

2. A session move and walk-end are the same `walks` result with two procedures. `walks --session <our ids>` omits a file both after walk-end unlinks it and after `ensure-walk` rewrites `session` to another id. Lines 56–57 untrack a session move at once and leave its tasks. Lines 100–104 treat "no longer lists" as a deleted file, keep the walk tracked, and retry the graph. Using the first procedure for every absence skips the final apply, so the goal that just finished stays `in_progress`. Using the second for a session move keeps updating a walk this session no longer owns until that read returns.

Fix: remember `journal` and stat `~/.cache/claude-coding-workflow/logs/<sha256(root)[:16]>/<stem>.walk`; a missing file retries the graph and then moves to finished, and a file whose `session` is not ours is untracked at once, moved to finished, with its tasks left in place.

3. The locked decision contradicts the one-goal rule just added. Lines 83–89 recreate a list only when two or more mapped ids are all absent in one poll, and they accept that a one-goal wipe stays gone. Lines 183–186 still say that every task of the walk missing at once is a replaced list and is recreated. For a single mapped id, that is the recreate-on-delete bug.

Fix: make the decision match the approach: two or more mapped ids, all absent in one poll, is a replaced list; a single missing id is always a person-delete.

4. The running `activeForm` can show `rnull`. Per-goal `round` comes from `goal_stats` and stays null until an event carries `--round`. `run-goals.sh` writes the opening `walk` event with a pid and no round, and `phase_of` reports that row as `start`, so the template `<goal-id> · <phase> · r<round>` renders `g1 · start · rnull` until dispatch. `graph_text` already leaves the round off when it is null.

Fix: omit the `r<round>` segment when `round` is null.

VERDICT: REVISE

### Architect's response
All 4 taken.
1. `walks` reports each file's `mtime`; when one poll lists more than one untracked, untombstoned walk, only the newest is tracked and the rest are tombstoned in that poll.
2. New `events.py walk-file --root R --journal J --json` ({exists, walk_id, session}). A tracked walk `walks` omits is checked with it: same walk_id under another session → finished at once, tasks left; gone or a different walk_id → Walk-end (tracked, final read retried, then finished). A failed walk-file call changes nothing.
3. The decision now matches the approach: two or more mapped ids all absent in one poll is a replaced list; a single missing id is always the person's deletion, even the last or only one.
4. The ` · r<round>` part of the running activeForm is left off while round is null.

## Round 5 — Grok
I'll re-read the revised plan and check the four open findings against the code they depend on.The four earlier fixes are in the text. I'll check the new `walk-file` path and the mtime rule against the code they call.The four earlier findings are closed in this revision. A restart that lists several untombstoned walks tracks only the newest `mtime`. `walk-file` is what separates a moved session from a deleted file. The decision matches the one-goal rule. A null `round` leaves ` · r<round>` off `activeForm`.

Three new problems:

1. A walk that returns to this session stays frozen. A file whose `session` is no longer ours moves to *finished*, which tombstones the key, and that same `walks` result does not list the file, so the tombstone is dropped. The key stays *finished*. When this session launches it again, `ensure-walk` writes our session onto the same `walk_id`, `walks` lists the key, and the update loop skips *finished* keys. The mtime election runs only when more than one listed walk is untombstoned and untracked, so a single returning key is never moved back to *tracked*. The tasks stay on the handoff snapshot while the walk runs here.

Fix: when `walks` lists a *finished* key that has no tombstone, move it back to *tracked* on that poll and update it.

2. `walk-file` looks in the session cwd. `paths_for` (`scripts/events.py` lines 87–90) hashes `git_root()`, which is `Path.cwd()`. The mod runs that process with `$.session.cwd()` (`mods/walk/hooks/register.tsx` lines 70–74), the house checkout in the case this feature exists for. The walk file is under `sha256` of the target root. The command then returns `exists: false` for a file that is present, and lines 69–70 treat that as walk-end: the walk stays *tracked* and a graph read is applied, so a moved session is not finished at once with its tasks left. The `$.state` map stores `root + walk_id` only, and the `walks` row is already gone when `walk-file` needs the journal.

Fix: resolve `cache/sha256(abspath(--root))[:16]/<journal stem>.walk` from `--root`, keep `journal` on the tracked walk, and test `walk-file` with the process cwd different from `--root`.

3. The restart election can leave two DAGs on the list. A resumed session keeps its tasks and loses `$.state`. The election tracks the newest file and tombstones the rest, but only walks that sit in a map have their tasks deleted. A walk launched again while tombstoned still gets its file rewritten, so after restart it is the newest file, while the tasks on screen are the walk that was showing. The winner adopts exact subject matches and creates the rest; the previous walk’s other tasks stay, because that key never enters *retiring*.

Fix: for each walk the election tombstones, read its graph once, adopt tasks whose subjects are exactly that walk’s, and `TaskUpdate` them to `deleted` in the same poll.

VERDICT: REVISE

### Architect's response — deadlock at MAX_ROUNDS, user decision
REVISE at round 5 of 5. The Architect agreed with all three points (a finished walk relaunched here stays frozen; walk-file resolved its path from the session cwd, not --root; the restart election left the losing walks' tasks). The Architect observed that every round had found 3–4 new holes, all in v1's stateful lifecycle (tracked / finished / retiring / tombstones, $.state lost on restart), and offered A (apply and sign off as an override), B (apply and a sixth round) or C (replace the lifecycle with a stateless reconcile). The user chose C (2026-10-14). PLAN.md is rewritten as v2: ownership by the task's `owner` (`walk:<id8>`, probed: TaskList returns it), one current walk = the newest walk file this session launched, a reconcile on every poll, `walk-file` dropped. v1's round 1–5 fixes that still apply are carried into v2 (atomic walk file, stdout unchanged, reason ordering by ts_mono and its fallbacks, paused activeForm, no rnull, replaced list = two or more gone, single delete is the person's, failed reads change nothing, lessons origin read). v2 goes to a fresh Grok session; the round count restarts.

## v2 Round 1 — Grok (fresh session d08a272e)

I'll read the plan and the domain docs around it, then check the repo assumptions it depends on.The review log shows v1 died on lifecycle state. I'll check v2's reconcile against the walk file, graph, and the mods that would implement it.v2's stateless reconcile reintroduces the leftover-walk problem, and a few of its own rules fight the task list. The walk file is only rewritten by `ensure-walk`, and `events_end_walk` runs only on `run-goals.sh`'s empty-frontier success (`scripts/run-goals.sh` around the `walk-end` exit). `/run-goal`, `walk_stuck`, and the signal path leave the file in place.

1. Newest-mtime among files that still exist is not "the walk this session launched most recently." A later `/run-goal` file is never deleted, so it stays current and the reconcile deletes the older walk's tasks even while that walk is still running in another repo (the house-session case). When a newer `run-goals` file is removed at walk-end, an older leftover becomes current in that same poll and deletes the finished "N done" list the plan says to keep. Fix: prefer a listed walk whose graph has a running goal, and when the current file disappears, apply that walk once and ignore listed files with an older mtime.

2. The engine's all-completed clear and the replaced-list rule loop. Assumption 3 clears a list whose tasks are all `completed`. A `/run-goal` that finishes the last goals of a DAG with two or more tasks does not delete its walk file, so the next poll sees the created set absent, recreates every task as `completed`, and the engine clears them again, every 3 seconds. Fix: when every desired task is `completed` and none of them is listed, leave the list empty.

3. A failed owner update on a paused or bounced goal creates a second task. `TaskCreate` writes the subject first and `TaskUpdate` sets `owner` after. Adoption matches only the exact title `<goal-id> — <title>`, while those states use `PAUSED:` / `BOUNCED:` subjects, so the next poll does not see the ownerless task and creates another. The ownerless one is never touched again. Fix: adopt one unowned task whose subject equals the desired subject, and add the goal to the created set only after `owner` is set.

4. The replaced-list exception is tautological. "Two or more of the set are missing and none of them is listed" is true whenever two tasks disappear, so a deliberate multi-delete is recreated within 3 seconds. The tests never pin "two gone, others still listed, the two stay gone." Fix: a replaced list is the entire created set absent in one poll with size at least 2. Any proper subset stays deleted.

5. `reason` can still render as the word `null`. A `bounced` row has no reason (`run-goal.sh` writes it with no `--reason`, then `wake`), and `events_append` is best-effort, so the wake row can be missing. Step (a) then selects that row, whose stored reason is `None`. The parenthetical "read the wake that follows" is not in the ordered steps. Fix: use the newest `wake` or `bounced` row that has a non-empty reason. If it is not newer than the goal's newest `walk` or `dispatch`, fall through to the goal-less `wake` or the literal `stopped`, and treat a later line as newer when `ts_mono` ties.

6. A missing cache root is a hard error. `walks` is specified to exit nonzero when the cache root cannot be listed, and before the first walk `~/.cache/claude-coding-workflow/logs` does not exist. Every idle session then fails every poll and, after five failures, writes a transcript line. Fix: a missing cache root prints `[]` and exits 0. Exit nonzero only when the directory exists and listing it fails.

VERDICT: REVISE

### Architect's response
All 6 taken, inside v2's model (no lifecycle states added).
1. `walks` reports `live` per walk (live_goals on its event index, the check `status` already uses). Current walk: the newest live walk; else the last current (kept in $.state, listed or not) unless a listed walk has a newer mtime; else (restart) the newest listed. A leftover file never displaces the walk on screen, and an idle newer `/run-goal` file never deletes a walk running in another repo. When the current walk is unlisted it is reconciled once (retried until a read succeeds) and then left alone. Variation: Grok proposed reading each listed walk's graph to find a running goal; `live` in `walks` gives the same answer with no extra process per walk.
2. An all-completed walk with none of its tasks listed is left empty, never recreated.
3. Adoption takes one unowned task whose subject equals the goal's desired subject in any form (title, PAUSED, BOUNCED); a goal enters the created set only after its owner update succeeds.
4. A replaced list is the entire created set (size >= 2) absent in one poll; any proper subset stays deleted. Test pins two of five deleted with three listed.
5. `reason` uses only rows with a non-empty reason; a bounced row with a missing wake falls through to the goal-less wake or `stopped`; a later line wins a ts_mono tie.
6. A missing cache root makes `walks` print `[]` and exit 0.

## v2 Round 2 — Grok

I'll re-read the revised plan and check each prior finding against the code it depends on.The previous holes in adoption, the all-completed clear, the whole-set wipe, `null` reasons, and a missing cache are closed in the approach. The new election rule still drops the walk it just chose, and three older sentences contradict the rules that replaced them.

1. An idle newer file still takes the list whenever `live` is false, which is the normal gap between goals. `live_goals` (`scripts/events.py`) treats a goal as finished as soon as its last event is terminal (`done` is terminal), so it returns nothing after a goal's `done` row and before the next `walk` row. That gap covers `refresh` and `commit_goals` in `run-goals.sh`, and at the end it covers `walk_end` plus `commit_journal` before `events_end_walk`. The walker pid on the `walk` row is still alive then. Rule (2) runs because nothing is `live`, and any listed file with a newer `mtime` becomes current. A finished `/run-goal` launched while a longer walk was running has that newer `mtime`. Every goal boundary swaps the list to it, and the final gap does so for good: the finished walk's tasks are deleted before its file is unlinked, so the "N done stays when its file is removed" sentence never happens. Fix: keep `live` true while the pid on this `walk_id`'s newest `walk` row is alive and no later `walk_end` exists, reading the sibling `<stem>.jsonl` next to that walk file (not `paths_for`, which hashes the session cwd). Let a file replace the current walk only when it is the newest `live` one, or its `mtime` is greater than the mtime the mod already saw for that `walk_id`.

2. The final-apply flag freezes a walk that comes back. It is recorded against the walk and the plan only says "after that it leaves the list alone." `ensure-walk` reuses the same `walk_id` and lists the file again on resume. Nothing clears the flag, so rule (2) can select that walk while the mod still refuses to reconcile it. Fix: suppress reconcile only while that walk stays the current unlisted walk; a later poll that finds it listed reconciles it.

3. The decision and risk text still specify the rules this revision removed. "Derives the desired list from the newest walk file" and the risk "a `/run-goal` stays current until a newer walk file exists" are the election that drops a live walk. "Two or more gone at once, none listed, is a replaced list" is the reading that recreates a proper subset. "Loss costs at most one recreated task or one missed final apply" is wrong under rule (3): a restart with no live walk elects the newest leftover and deletes the on-screen tasks. Fix: make those three sentences match the approach and the tests already listed for them.

VERDICT: REVISE

### Architect's response
All 3 taken; the fix for 1 also simplifies the rule.
1. `live` now means the walker process is alive (the newest `walk` row of this walk_id has a live pid and no later `walk_end`), read from the event index beside the walk file, so a walk stays live between goals. The current walk is chosen without $.state: the newest live walk; else the walk owning the mod's tasks on the list (the `walk:<id8>` owner, i.e. what is on screen); else the newest listed. The mtime-replacement rule is dropped: a relaunch is live, so rule 1 picks it. Variation from Grok's fix: "already seen mtime per walk_id" bookkeeping is not needed once rule 2 reads the screen.
2. The final-apply suppression holds only while the walk stays unlisted; listed again (resumed), it is reconciled.
3. The decision, the replaced-list decision and the /run-goal risk now match the approach; the restart case is covered by rule 2 (the on-screen walk), and the state-loss sentence says what a restart actually costs.
Also: a step-9 Verification section cites docs/features/walk-tasks/VERIFICATION.md (user, 2026-10-14: scenario tests, randomised invariants, a live mini dogfood are required before commit).

## v2 Round 3 — Grok

I'll re-read the revised plan and check the last findings against the walk and event code.The election rule changed. I'll check whether a live `/run-goal` actually writes the `walk` row that `live` now depends on.The live-gap fix, the unlisted-walk resume, and the decision text about restarts are in place. A `/run-goal` still never counts as live, so the new election rule will not switch to it.

1. `live` is defined only on a `walk` row, and `run-goal.sh` never writes one. The only `walk` event with a pid is in `run-goals.sh` (the `events_append --event walk` before the child). A single goal records its pid on `dispatch` and `phase`. So a running `/run-goal` has `live` false for the whole run. Rule (1) never selects it. Rule (2) keeps whatever `walk:` owner is already on screen. A second repo launched with `/run-goal` from the house session stays off the list, and so does a `/run-goal` after `run-goals` deleted the file and minted a new id, for as long as the old tasks are still there. The sentence "a relaunched or newly launched walk is live, so (1) picks it" is false for `/run-goal`. Fix: `live` is true when there is no later `walk_end` for this `walk_id` and either the newest `walk` row's pid is alive or the newest `dispatch` or `phase` row's pid is alive. The `walk` pid keeps `run-goals` live between goals; the `dispatch`/`phase` pid covers `/run-goal`.

2. Deleting tasks one poll at a time brings the whole walk back. The rule recreates whenever the entire created set (size at least 2) is absent. After the person has already removed four of five, the poll that removes the fifth sees the whole set absent and recreates all five, including the ones removed earlier. The test says a single delete is not recreated, down to the last one. The pure function `(desired, TaskList, last-sent activeForms, created set)` cannot tell a one-task disappearance from a wipe. Fix: keep the ids listed on the previous poll. A replaced list is two or more of those gone in this poll. One id disappearing, including the last one, stays deleted.

3. The decision still says the on-screen walk is kept "unless a newer file appears." The approach and the tests say an idle newer file never takes the list. Only a `live` walk does. Fix: delete that clause so the decision matches rule (1) and rule (2).

VERDICT: REVISE

### Architect's response
All 3 taken.
1. `live` = no `walk_end` for this walk_id, and the pid on the newest `walk` row or on the newest `dispatch` / `phase` row is alive: the walk pid covers run-goals between goals, the dispatch/phase pid covers a single /run-goal (no walk row).
2. A replaced list is judged against the previous poll: $.state keeps the ids of this walk's tasks listed last poll; two or more of those all gone now = replaced, and only their goals are recreated (earlier person-deleted goals stay deleted). Deleting one per poll never brings any back. Tests and VERIFICATION.md updated.
3. The decision now reads "a live walk first, else the one already on screen; an idle file, newer or not, never takes the list".

## v2 Round 4 — Grok

I'll re-read the revised plan and check the last three findings against the walker events.I'll re-read the revised plan and the launch paths it depends on, then check the last round's findings against that text.The walker-pid `live` check, the previous-poll wipe rule in the approach and tests, and the idle-file decision are in place. Two problems still block implementation.

**Prior finding 1 — closed.** `live` is the walker: no `walk_end` row for this `walk_id`, and a live pid on the newest `walk` row or the newest `dispatch` / `phase` row (PLAN.md lines 36–46). That covers the `done`→`walk` gap, a single `/run-goal` (no `walk` row), and stopping at `walk_end` or when those pids die. The tests at lines 193–196 match. A finished `run-goals.sh` unlinks the file and the next `ensure_walk` mints a new id (`scripts/events.py` lines 126–133), so the old `walk_end` does not stick to the next walk.

**Prior finding 2 — still open in Key decisions.** The approach (lines 126–132) and the tests (lines 198–201) recreate only the ids that were listed on the previous poll when two or more of those are all gone, and they leave earlier deletions deleted. The decision bullet still says the opposite:

```256:258:docs/features/walk-tasks/PLAN.md
- **A person's deletion wins; a replaced list does not.** One missing task is
  always the person's, and so is any proper subset; only the entire created
  set (two or more) absent in one poll is a replaced list and is recreated.
```

Following that bullet brings back goals the person already removed. The cost sentence beside it ("at most one recreated task", lines 233–236) is the same section left behind: a restart drops both caches and recreates every missing task once, which the approach already accepts.

Fix: rewrite that bullet to the previous-poll rule — a replaced list is two or more ids listed last poll and all absent now, and exactly those are recreated — and state that a restart recreates every missing task once.

**Prior finding 3 — closed.** Lines 241–246 say a live walk first, otherwise the walk already on screen, and an idle file never takes the list.

**New: a launch that exits before any poll sees a live pid never replaces the walk on screen.** Rule (1) is the only way a new walk displaces the one already shown, and `live` stays false until a pid-bearing row exists. For `/run-goal`, `events_ensure_walk` runs at `scripts/run-goal.sh` line 618, and the first pid row is `dispatch` at line 787. Every `die_gate` between them (wrong status, open blockers, uncommitted plan or oracle, dirty tree, missing key, contract drift) writes the walk file, writes a `wake` with no pid, and exits. Those exits finish inside one 3 s poll. `run-goals.sh` has the same hole before its first `walk` row at line 235: an immediate `walk_stuck` (lines 222–224) or a signal during refresh writes the file and no pid. The poll then sees `live` false, rule (2) keeps the previous owner, and the launch the session just made never appears. Lines 87–89 assume a new `/run-goal` is live while its process runs, so (1) picks it. That is false for these exits. A long run is only late by one poll, because the next poll sees the pid. Treating any newer mtime as current would let an idle leftover take the list again once the on-screen walk stops being live.

Fix: remember the `walk_id`s from the previous poll; a `walk_id` listed now that was absent then becomes current for this poll even though `live` is already false, and an empty remembered set (restart) must leave rules (1)–(3) unchanged. Narrow line 86 so this cache is the one `$.state` value allowed to choose.

VERDICT: REVISE

### Architect's response
Both taken.
1. The replaced-list decision now states the previous-poll rule (two or more ids listed last poll, all absent now; exactly those recreated; earlier deletions stay). The cache sentence says what a restart really costs: every missing task of the current walk recreated once, rule (0) skipped for one poll, a finished walk whose file is gone left as last shown.
2. Rule (0): a walk_id listed now but not on the previous poll becomes current, live or not, so a launch stopped by a gate before any pid row still shows (its goals PAUSED: <reason>). The previous poll's walk_ids are the one $.state value used to choose; an empty set (process start, mod reload) skips rule (0). Tests and VERIFICATION.md include the gate-stopped /run-goal and the restart case.

## v2 Round 5 — Grok

I'll re-read the revised plan and check the last round's two open items against the launch and election code.The deletion decision and the restart cost now match the approach. Rule (0) covers a `walk_id` that appears for the first time. A second launch of a walk file that is already listed still never reaches the screen, and two reconcile rules can undo a switch that did.

**Prior findings.** The decision bullet (lines 269–273) now recreates only the ids listed on the previous poll, and a restart recreates every missing task once (lines 245–248). Rule (0) (lines 82–95), the tests (lines 198–200), and the decision (lines 253–255) make a `walk_id` that was absent last poll current even when a gate already killed it. The walker-pid `live` check is unchanged and still right.

**A relaunch of an already-listed `walk_id` still does not show.** `/run-goal` never unlinks its file, and a stuck `run-goals.sh` keeps its id (`scripts/events.py` `ensure_walk`, lines 126–133, returns the existing id when the file is still there). The second dirty-tree run, the second status/blocker/plan gate, and an immediate `walk_stuck` on a reused id all call `events_ensure_walk` and exit before any pid row (`scripts/run-goal.sh` 618, then 634–683 and 787; `scripts/run-goals.sh` 145, then 222–235). That `walk_id` was already in the previous-poll set, `live` is false, and rules (1) and (2) keep the other walk. Lines 92–95 and 253–255 say a gate-stopped launch still shows. That holds the first time the file appears and fails on every later launch in that repo. A raw mtime bump on every `ensure-walk` would also re-select a walk that is still running, because each goal's `run-goal.sh` calls `ensure-walk` again and would take the list back from a newer launch.

Fix: replace the walk file on every `ensure-walk`, including reuse with the same session, and extend rule (0) to a listed id whose walk-file mtime moved since the previous poll and that was not `live` then; an empty store still skips rule (0).

**Rule (2) with two `walk:` owners undoes that switch.** The plan retries a failed `TaskUpdate` on the next poll (line 164) and says rule (2) is "the" owner on the list (lines 85–86). After rule (0) selects the new walk, a failed delete leaves the previous owner in place. On the next poll the new walk is already in the stored set and is not live, so rule (0) and rule (1) miss it. Whichever owner rule (2) picks, the other walk's tasks are deleted. Picking the old owner removes the launch that just appeared.

Fix: when several `walk:` owners are listed and rules (0) and (1) miss, keep the last reconciled `walk_id` if its owner is present.

**The all-completed exception matches a walk that was just selected.** It fires whenever every desired task is `completed` and none of that walk's tasks is listed (lines 143–147). That is also true on the first reconcile, before any create: a `/run-goal` that dies at the status gate on an already-done DAG (`run-goal.sh` line 634) is exactly that. Read as "leave the list empty", the poll deletes the on-screen owner and creates nothing, and every later poll hits the same exception, so the list stays blank. The same sentence is what tells the engine-clear loop to stop.

Fix: apply the exception only when this `walk_id` was already current on the previous poll; the poll that first selects it creates its tasks, completed ones included.

**The new test oracle marks a fresh gate as `PAUSED:`.** Lines 92–95 and 199 say the goals read `PAUSED: <reason>`. `walk_graph` sets `paused` only when the goal's status is `in_progress` (`scripts/events.py` lines 752–761). A fresh-start gate runs before `goals.py set in_progress` (`run-goal.sh` line 704), so the goal stays `ready` or `waiting` and the subject stays `<goal-id> — <title>`. `PAUSED:` applies to a resume gate or a `walk-stuck` on a goal already `in_progress`. The risk at lines 305–309 also still says a dead `/run-goal` never displaces the on-screen walk; rule (0) does that on purpose.

Fix: expect `PAUSED:` only for goals already `in_progress`, and say a lingering file displaces the list only when rule (0) selects it.

VERDICT: REVISE

### Architect's response — cap reached; user decision
REVISE at round 5 of 5 on v2. All four points valid; three were caused by round 4's rule (0) (show a newly listed walk even if not live). The Architect recommended dropping rule (0) and applying the rest. The user agreed (2026-10-14) and, instead of a sign-off override, asked for one more Grok round on the result ("I want it hardened") — an explicit extension past MAX_ROUNDS to round 6 in the same session.
1. Rule (0) dropped. A launch a gate stops before any pid row does not take the list; its stop file reports it. The relaunch-of-a-reused-walk_id problem goes with it.
2. Several `walk:` owners listed: keep the walk reconciled on the previous poll if its owner is present, else the one whose walk is listed with the newest mtime.
3. The all-completed exception applies only to a walk already reconciled on the previous poll; the poll that first selects a walk creates its tasks, completed ones included.
4. Tests and VERIFICATION expect `PAUSED:` only for goals already in_progress; a gate on an unstarted goal keeps the plain title. The /run-goal risk sentence and the decision text are corrected.

## v2 Round 6 — Grok (extension, user-requested)

I'll re-read the revised plan and check the last round's four items against the election and reconcile rules.The multi-owner rule, the all-completed exception, and the `PAUSED:` case are fixed, and the dropped gate-stop display is an explicit decision. Rule (1) still uses a clock that moves every goal.

**Prior findings.** Several `walk:` owners keep the walk reconciled on the previous poll (lines 84–88). The all-completed skip applies only when that walk was already current, and the poll that first selects it creates its tasks, completed ones included (lines 142–148). The adoption test is limited to a goal already `in_progress` (lines 212–213). A gate-stopped launch leaving the on-screen walk in place is now the stated choice (lines 91–95, 253–256, 307–311), with a test that it does not take the list (lines 199–200).

**A second live walk loses the list when the older one starts its next goal.** Rule (1) is the newest walk-file `mtime` among walks with `live` true (lines 82–83), and the test expects the newest of several live walks (line 200). `ensure-walk` on reuse rewrites the file whenever `CLAUDE_CODE_SESSION_ID` is set (lines 25–28), and `os.replace` moves `mtime`. `run-goals.sh` writes the parent `walk` pid at line 235 and then runs `run-goal.sh`, which calls `events_ensure_walk` again at line 618 for every goal. The parent pid is already alive, so the older walk stays `live` while its file becomes the newest. The next poll's rule (1) switches the list back to it. The same `mtime` is the wrong clock in the other direction for a reused file that is not rewritten: a relaunch that does run is `live`, but the file's `mtime` is from the original mint, so an older live walk that was minted later wins. `pid_start` cannot break the tie by string order; `ps` `lstart` is a display date (`scripts/events.py` `proc_start`).

Fix: have `walks` report the walker start as the earliest `ts_mono` on a row carrying the pid that made `live` true (the `walk` pid when that pid is alive, otherwise the `dispatch` / `phase` pid), and have rule (1) pick the latest of those; on reuse, replace the walk file only when `session` or `root` changes.

**The decision forbids a selection the approach and the tests require.** Lines 253–256 say an idle file never takes the list, and neither does a gate-stopped launch. Rule (3) (lines 88–89) and the test at lines 202–203 select the newest listed file whenever none of the mod's tasks is listed, which is that idle file, including one a gate just wrote.

Fix: say an idle or gate-stopped file never displaces the walk already on screen, and an empty mod list still follows rule (3).

VERDICT: REVISE

### Architect's response
Both taken.
1. `walks` reports `started`: the earliest ts_mono among the walk_id's rows carrying the pid that makes it live (the walk pid if alive, else the dispatch/phase pid). Rule (1) picks the latest `started`, not the newest mtime. `ensure-walk` on reuse rewrites the walk file only when `session` or `root` changes, so each goal's own `ensure-walk` leaves the file and its mtime alone. Tests and VERIFICATION cover an older live walk starting its next goal without taking the list back.
2. The decision now says an idle or gate-stopped file never *displaces* the walk on screen, and that with none of the mod's tasks listed, rule (3) still picks the newest listed file.

## v2 Round 7 — Grok (extension, user-requested)

I'll re-read the revised plan and check the walker-start ordering and the empty-list rule against the code they depend on.The walker-start clock and the empty-list rule are in place. The engine's all-completed clear is still defined as a replaced list, so a finished multi-goal walk is recreated every poll.

**Prior findings.** Rule (1) uses `started`, the earliest `ts_mono` of the pid that makes `live` true (the `walk` pid when that pid is alive, otherwise the `dispatch` / `phase` pid), and a same-session `ensure-walk` leaves the file and its `mtime` alone (lines 25–30, 37–41, 88–91). The tests cover an older live walk whose next goal reruns `ensure-walk` (lines 208–210) and a same-session reuse that does not rewrite (lines 230–233). The decision now says an idle or gate-stopped file never displaces the walk on screen, and rule (3) still applies when none of the mod's tasks is listed (lines 265–270).

**A finished walk of two or more goals is both an engine clear and a replaced list.** The wipe rule recreates a walk when two or more of its task ids were listed last poll and none are listed now (lines 141–145). Assumption 3 is that clear: every task completed, and the engine removes them all in one step. The all-completed exception (lines 150–156) and its test (line 221) say those tasks stay gone. For one goal the wipe rule does not fire, so the exception holds. For two or more goals both rules match. A finished `/run-goal` leaves its file, rule (2) or rule (3) keeps selecting it, and following the wipe rule creates the completed tasks again every 3 s. That is the loop the exception exists to stop.

Fix: when the all-completed condition holds, the absence is not a replaced list; add that case beside the wipe test.

**`started` moves forward if it is computed like the other jsonl readers.** It is defined as the earliest row of the live pid (lines 37–41), and the test says later goals leave it unchanged (lines 230–231). `tail_rows` keeps 400 lines (`scripts/events.py` line 474). `graph` already passes 20000 (line 742) because a walk outgrows that. A 400-line window drops the first pid row, the earliest row left in the window is a later goal, and `started` jumps. Rule (1) then hands the list back to that older live walk. Matching the pid number alone has the other failure: `pid_alive` treats a reused pid as a different process, but the earliest row with that number is the previous run, so a relaunch loses to an older live walk.

Fix: scan the whole sibling `<stem>.jsonl` and take the earliest `ts_mono` among rows with that pid and its `pid_start`; cover it with a fixture whose first pid row sits behind more than 400 later lines.

VERDICT: REVISE

### Architect's response
Both taken.
1. An absence while every desired task is completed is never a replaced list (the engine's all-completed clear), whatever the number of goals; tests and VERIFICATION cover one-goal and five-goal walks.
2. `started` is the earliest ts_mono among rows with the live pid and its pid_start, scanning the whole sibling jsonl (not tail_rows' 400 lines, not the pid number alone); a fixture puts the first pid row behind more than 400 lines, and a reused pid from an older run does not count.

## v2 Round 8 — Grok (extension, user-requested)

I'll re-read the revised plan and check the all-completed wipe exception and the `started` scan against the event reader.The all-completed exception and the full-file `started` scan are in the approach and the tests. Two spec holes are still open.

**Prior findings.** An absence while every desired task is `completed` is never a replaced list, for one goal or for five (lines 148–150, 226–227). `started` is the earliest `ts_mono` of the rows with the live pid and its `pid_start`, read from the whole sibling `<stem>.jsonl`, with a fixture whose first pid row sits behind more than 400 lines and an older run that reused the pid number (lines 37–42, 236–238).

**The locked deletion decision still recreates that clear.** Lines 292–296 say two or more of the walk's task ids listed last poll, all absent now, are a replaced list and are recreated. That is the engine clear of a finished multi-goal walk. The approach and the tests say that absence is not a replaced list. An implementer who follows the decision brings the completed tasks back every poll.

Fix: in that decision, state that an absence is not a replaced list when every desired task is `completed`.

**`live` still picks its pid row without the same-second order the graph uses.** `started` uses `ts_mono`. The `live` check uses the newest `walk` row or the newest `dispatch` / `phase` row (lines 48–50) and never says how "newest" is ordered. Section 3 defines newest only for `reason`: `ts_mono`, and a later line wins a tie, because `ts` is whole seconds and a fast gate writes two rows in one second (lines 62–65). A relaunch in that same second has a dead pid row and a live one with the same `ts`. Keeping the earlier row makes `pid_alive` fail, `live` stays false for the whole first goal, and rule (2) leaves the previous walk on screen.

Fix: choose those rows by `ts_mono`, later line on a tie, the same order as `reason`.

VERDICT: REVISE

### Architect's response
Both taken (text consistency).
1. The deletion decision now says an absence while every desired task is completed is never a replaced list.
2. `live` picks the newest walk / dispatch / phase row by ts_mono, a later line winning a tie (the order `reason` uses); a test covers a relaunch whose dead and live pid rows share one second.

## v2 Round 9 — Grok (extension, user-requested)

I'll re-read the revised plan and check the deletion decision and the same-second `live` ordering.The deletion decision and the same-second `live` order are fixed. A `walk_end` that leaves the walk file in place still marks that `walk_id` dead for every later run.

**Prior findings.** The decision now says an absence while every desired task is `completed` is never a replaced list (lines 297–298), matching the approach (lines 149–150) and the one-goal and five-goal tests (lines 228–229). The newest `walk` row and the newest `dispatch` / `phase` row use `ts_mono`, with a later line winning a tie (lines 49–51). The test covers a relaunch whose dead and live pid rows share one second (lines 214–215).

**A `walk_end` that does not delete the file makes every later run of that id not `live`.** `live` requires that no `walk_end` row of this `walk_id` exists (lines 48–49). `run-goals.sh` appends `walk_end` at line 227, then commits the journal, then calls `events_end_walk` at line 229. A SIGINT during that commit runs `on_signal` (lines 165–175), which exits without unlinking, and `events_end_walk` swallows an unlink error (`scripts/lib/events.sh` lines 43–46; `end_walk` only ignores a missing file, `scripts/events.py` lines 136–141). The file stays. The journal still contains `walk_id=`, so the next `ensure_walk` reuses the id (`scripts/events.py` lines 126–130). Assumption 7 says a restart reuses the id. The new run writes a later `walk` or `dispatch` row with a live pid, and the old `walk_end` still fails the check. Rule (1) never selects it. Only a later `run-goals.sh` that reaches `events_end_walk` and unlinks clears the poison; a `/run-goal` never unlinks, so every later `/run-goal` in that repo stays off screen while another walk owns the list.

Fix: `live` is false when a `walk_end` row of this `walk_id` is newer, in the same `ts_mono` order, than the pid row that would make it live. Add a test where a `walk_end` is followed by a later pid row that is alive.

VERDICT: REVISE

### Architect's response
Taken. `live` ignores a `walk_end` row older (ts_mono, later line on a tie) than the live pid row: an interrupt between walk_end and the unlink leaves the file and a later run reuses the id. Test and VERIFICATION cover a stale walk_end followed by a later live pid row.

## v2 Round 10 — Grok (extension, user-requested)

I'll re-read the revised plan and check the `walk_end` liveness rule against the restart path.The `walk_end` rule is fixed, and the rest of the reconcile still matches the decisions and the tests. Nothing new is material.

**Prior finding.** `live` is a newest `walk` or `dispatch` / `phase` row, by `ts_mono` with a later line winning a tie, whose pid `pid_alive` accepts, and no `walk_end` of this `walk_id` newer than that row (lines 48–54). A `walk_end` left behind when the unlink does not run is stale once a later run reuses the id and writes a newer pid row. The tests cover that reused id being live (lines 218–219) and a `walk_end` that is the newest row stopping `live` (line 227).

The election order, the previous-poll wipe rule and its all-completed exception, the walker `started` clock, and the same-second pid-row order are unchanged and still consistent between the approach, the decision, and the test list.

VERDICT: APPROVED

### Architect's response
APPROVED in v2 round 10 (rounds 6-10 were user-requested extensions past MAX_ROUNDS). No changes. Awaiting user sign-off.

## Post-sign-off amendment (Opus code review, 2026-10-14)
Rule (3) refined, agreed with the user: with none of the mod's tasks on the list, the walk reconciled last stays current; the newest listed walk is chosen only with nothing remembered (a fresh start or restart). Reason: after the engine clears a finished walk's completed tasks, rule (3) as written let an older leftover walk file fill the empty list, against the plan's intent that a leftover never takes the screen. Found by the Opus code review (round 1 NOTE); PLAN step 4 and Key decisions updated to match.
