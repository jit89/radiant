# Plan: Walk progress in the task list; the walk footer dropped
_Locked via crucible — by Claude + cobalt. v2: after five Grok rounds on a
stateful lifecycle (v1) kept finding interactions between its states, the user
chose a stateless reconcile (option C); this is v2, reviewed in a fresh Grok
session._

## Goal

During the rbtree walk the user read the Architect-seeded task list ("7 tasks,
0 done") as the walk's state while the walk was 3/7: the run-goals skill seeds
the list once and leaves it stale until the walk exits, and the `walk` mod's
footer label looks in the session's cwd, so a walk launched with
`cd <target> && run-goals.sh` from a session rooted in the house never showed
there at all. The user prefers the task list. Make the `walk` mod keep one
task per goal for the walk **this session launched most recently**, in any
repo, by reconciling the task list against that walk on every poll, and drop
the footer label. The `/walk` pane stays.

## Approach

1. **The walk file records its launcher (`scripts/events.py`, additive).** The
   walk file `<cache>/<repo_id>/<slug>.walk` gains two fields beside
   `walk_id` and `journal`: `session` (the launching Claude session's
   `CLAUDE_CODE_SESSION_ID`, omitted when unset) and `root` (the repo root,
   absolute). `ensure-walk` writes both when it mints, and on reuse (a resumed
   walk) rewrites the file only when `session` (set from the variable) or
   `root` differs from what it holds, so a walk resumed from another session
   moves to that session, while the `ensure-walk` every goal's `run-goal.sh`
   makes leaves the file (and its `mtime`) untouched. Every write is a temp file in the
   same directory plus `os.replace`, so a reader never sees half a file.
   `ensure-walk`'s stdout stays `minted|reused<TAB><walk_id>` (`events.sh`
   takes the text after the last tab). Readers that know only `walk_id` and
   `journal` are unaffected.
2. **A query for this session's walks (`scripts/events.py`, additive).**
   `events.py walks --session ID [--session ID …] --json` prints a JSON list,
   one object per walk file under the cache root whose `session` is one of the
   ids: `{root, walk_id, journal, session, mtime, live, started}` (`started`
   is the earliest `ts_mono` among this walk_id's rows carrying the pid **and
   `pid_start`** that make `live` true, found by scanning the whole sibling
   `<stem>.jsonl` (not the 400-line `tail_rows` window, which a long walk
   outgrows; and not the pid number alone, which a reused pid shares with an
   older run) — the `walk` pid when it is alive, else the `dispatch` /
   `phase` pid — so it is when the running walker began, not when a file was
   last written; `null` when not live; `mtime` the walk
   file's modification time in milliseconds). `live` is true while the
   **walker process** is alive: in the event index beside that walk file
   (`<stem>.jsonl` in the same directory — not `paths_for`, which hashes the
   cwd), either the newest `walk` row or the newest `dispatch` / `phase` row
   of this `walk_id` (newest by `ts_mono`, a later line winning a tie — the
   same order as `reason`) carries a pid that is alive (`pid_alive` with its
   `pid_start`), and no `walk_end` row of this `walk_id` is newer, in that
   same order, than that pid row. (A `walk_end` older than the live pid row
   is stale: an interrupt between `walk_end` and the file's unlink leaves the
   file, and a later run reuses the id.) The `walk`
   pid is `run-goals.sh`'s and keeps a walk live between goals (after `done`,
   before the next `walk` row, no goal runs but the walker does); the
   `dispatch` / `phase` pid is `run-goal.sh`'s and makes a single `/run-goal`
   (which writes no `walk` row) live while it runs. It is not "a goal is
   running".
   No GOALS.md is read. A walk file without `session` or `root`, or that
   does not parse, is skipped. Exit 0 with `[]` when there are none or the
   cache root does not exist yet; nonzero only when it exists and cannot be
   listed. It needs no cwd: it lists the cache root.
3. **The graph names why a goal stopped (`scripts/events.py`, additive).**
   `events.py graph --json` gains a per-goal `reason`, a non-empty string for a
   goal whose state is `paused` or `bounced`, else `null`. "Newer" and
   "newest" order rows by `ts_mono` (milliseconds; `ts` is whole seconds and a
   fast gate writes two rows in one second), ties broken by position in the
   file (a later line is newer when `ts_mono` ties). In order: (a) the
   `reason` of the goal's newest `wake` or `bounced` row **that has a
   non-empty reason**, when that row is newer than the goal's newest `walk` /
   `dispatch` row; else (b) the `reason` of the newest goal-less `wake` row
   with a non-empty reason (the walker's own stops: `walk-stuck`,
   `orchestration-files-dirty`, …) newer than that goal row; else (c) the
   literal `stopped`. (A `bounced` row carries no reason, and the `wake` after
   it is best-effort and may be missing; both cases fall through.) The word
   `null` never reaches a subject.
4. **The mod reconciles the task list on every poll
   (`mods/walk/hooks/register.tsx`).** On the existing 3 s poll (only while a
   surface draws the session, as today; one poll in flight at a time). There
   is no walk lifecycle: each poll computes what the list should hold and
   makes it so.
   - **Ownership is on the task.** Every task the mod creates or adopts has
     `owner` set to `walk:<first 8 of walk_id>` (the probe: `owner` set by
     `TaskUpdate` comes back from `TaskList`; the list shows it after the
     subject). A task is the mod's exactly when its owner starts with `walk:`;
     the mod never touches any other task.
   - **Which walk.** The mod keeps, in `$.state`, every session id this process
     has had (it adds `$.session.id()` each poll): `/clear` continues the
     process under a new id while the walker keeps the old
     `CLAUDE_CODE_SESSION_ID`. It runs `walks` for all of them. Walk files are
     not always deleted (`/run-goal`, a stuck or interrupted walk leave theirs),
     so "newest file" alone is not "the walk this session launched last". The
     **current walk** is chosen in order, from the `walks` listing and the one
     `TaskList` read: (1) among listed walks with `live` true, the latest
     `started` (the walker that began most recently — not the newest file:
     every goal of a walk runs `ensure-walk`, and a reused file keeps its
     original `mtime`); else (2) the walk that owns the mod's tasks on the list (their
     `walk:<id8>` owner) — the walk already on screen, listed or not; when
     several `walk:` owners are listed (a delete failed after a switch), the
     walk the mod reconciled on the previous poll, if its owner is among them,
     else the one among them whose walk is listed with the newest `mtime`
     (ties: larger `walk:<id8>`); else, with none of the mod's tasks on the
     list, the walk reconciled last (remembered in `$.state`), so a leftover
     file does not fill a list the engine cleared after a finished walk; else
     (3) with nothing remembered (a fresh start, a restart), the listed walk
     with the newest `mtime`. Ties: larger `walk_id`. (The remembered-walk
     step was added after the Opus code review, user-agreed, 2026-10-14.)
     A launch that runs is live while its process runs, so (1) picks it
     within one poll. A launch that a gate stops before it writes any pid row
     (dirty tree, open blockers, a missing key, an immediate `walk-stuck`) is
     never live and does not take the list: the walk on screen stays, and the
     stop file the Architect reads reports the launch (user, 2026-10-14; a
     rule for it was tried in v2 round 4 and dropped after round 5). An
     idle leftover file never displaces the walk on screen, between goals or
     after a restart, because (2) reads the screen itself. A walk resumed by
     another session drops out of the listing by itself, because its file now
     names that session.
   - **What the list should hold.** For the current walk, read
     `graph --json --dir <root>` and derive one desired task per goal, in
     GOALS.md order, owner `walk:<id8>`: `done` → `completed`, subject
     `<goal-id> — <title>`; `running` → `in_progress`, `activeForm`
     `<goal-id> · <phase> · r<round>` (the ` · r<round>` part left off while
     `round` is null); `paused` → `in_progress`, subject
     `<goal-id> — PAUSED: <reason>`, `activeForm` `<goal-id> PAUSED: <reason>`;
     `bounced` → `pending`, subject `<goal-id> — BOUNCED: <reason>`;
     `ready` / `waiting` → `pending`, subject `<goal-id> — <title>`.
   - **Reconcile**, against one `TaskList` read per poll:
     - every mod-owned task whose owner is not the current walk's is deleted
       (`TaskUpdate status: deleted`), completed ones included — the previous
       walk leaves the list when a new one becomes current;
     - a mod-owned task of the current walk is matched to its goal by the
       subject prefix `<goal-id> — `; a field that differs from the desired one
       is updated (`activeForm`, which `TaskList` does not return, is compared
       with the value the mod last sent, kept in module memory, so a reload
       resends it once);
     - a goal with no matching task is first offered **adoption**: one task
       with no owner whose subject equals the goal's desired subject in any
       of its forms (`<goal-id> — <title>`, `… — PAUSED: <reason>`,
       `… — BOUNCED: <reason>`) — an Architect-seeded task, or the mod's own
       task whose owner update failed — gets the owner set and is then
       reconciled; else it is **created** (`TaskCreate` with the subject and
       the description `walk goal <goal-id> in <root>`, which the tool
       requires, then `TaskUpdate` for owner and status) — unless the person
       deleted it. A goal enters the created set only once its task's
       `owner` update has succeeded; until then the next poll adopts the
       ownerless task instead of creating another;
     - **the person's deletion.** `$.state` holds, per current walk id, the
       goal ids whose task the mod has created or adopted (owner set). A goal
       in that set with no task on the list is the person's deletion, and is
       not recreated — unless the list was replaced. `$.state` also keeps the
       ids of this walk's tasks listed on the **previous** poll. A replaced
       list (`/clear`, a `TodoWrite`) is: two or more ids were listed on the
       previous poll and none of them is listed now. Then exactly those
       tasks' goals are recreated (goals the person deleted earlier stay
       deleted). An absence while every desired task is `completed` is never
       a replaced list: that is the engine's all-completed clear (see the
       all-completed rule below), whatever the number of goals. Anything less — one id gone, including the last or only one,
       or some gone while others remain — is the person's deletion, so
       deleting tasks one by one never brings any back. Both are caches: a
       process restart loses them and the mod then recreates a missing task
       once (accepted);
     - **an all-completed walk is never recreated.** When every desired task
       is `completed`, none of the walk's tasks is listed, **and this walk was
       already the one reconciled on the previous poll** (the engine clears a
       list whose tasks are all completed), the list is left empty — the poll
       that first selects a walk creates its tasks, completed ones included;
       otherwise a finished `/run-goal` walk, whose file is never deleted,
       would be recreated as completed and cleared again every poll.
     - Two mod-owned tasks of the current walk with the same goal prefix: the
       older id is kept, the other deleted.
   - **The current walk no longer listed.** When rule (2) picks a walk that
     is not listed (walk-end deleted its file, or it moved to another
     session), the mod needs its `root` to read its graph: `$.state` keeps the
     `root` and `walk_id` of the last walk it reconciled, as a cache. If that
     matches, the mod reads the graph and reconciles once — retried each poll
     until one read succeeds, since it can race walk-end's rewrite of
     GOALS.md — and then does not reconcile it again **while it stays
     unlisted**; a poll that finds it listed again (a resumed walk) reconciles
     it as usual. If the cache does not match (a restart), the tasks are left
     as they are. A finished walk therefore reads "N done" until a live walk
     becomes current and deletes it (or the engine's all-done clear).
   - **Failures change nothing.** A failed `walks`, `graph` or `TaskList` call
     skips that poll's reconcile and logs to the debug log (five in a row log
     once to the transcript line). A failed `TaskCreate` / `TaskUpdate` is
     simply retried by the next poll's reconcile.
   - A session without the `Task*` tools (`$.tool.list`) does nothing and
     logs once to the debug log.
5. **The footer goes.** Remove the `SessionMode` hook, the `label` atom and
   its type, the `status` poll from the mod, and the footer tests; the `/walk`
   pane and its graph poll are unchanged. `events.py status` stays (its tests
   and `run-goal.sh`'s phase events use it).
6. **The lessons mod counts only the model's own failures
   (`mods/lessons/hooks/register.tsx`).** Its `tool.call` hook counts a failed
   call only when `next.origin?.plugin` is `'engine'` or absent. A `tool.call`
   event carries no `origin` of its own (`ToolCallInput` is the envelope, the
   agent loop and request meta); the calling plugin is `next.origin.plugin`,
   `"engine"` for the model's call site (mod API types, `Origin`). The read
   uses optional chaining and cannot throw: the hook's `.catch(passThrough)`
   would otherwise run the tool a second time.
7. **Docs and skills.** `skills/run-goals/SKILL.md` drops "seed the todo list",
   the stale-badge note, the post-exit "re-run `goals.py todos` and
   `TodoWrite`" step, and `TodoWrite` from its `allowed-tools`, and says the
   walk mod keeps the task list current (the Architect writes no walk tasks);
   after the walk it reports from `goals.py` and the stop file as today.
   `CLAUDE.md` and `README.md` replace the footer lines with the task list;
   `scripts/install.sh`'s comment follows. `docs/FUTURE-WORK.md` item 6
   (parallel walker) gets a carried input: the task list replaces the footer;
   parallel goals each read `running`, so several tasks are `in_progress` at
   once (the reconcile already allows it); and the current walk stays one
   walk per session.
8. **Version and tests.** `mods/walk` 0.3.0, `mods/lessons` 0.3.1. The
   reconcile is a pure function `(desired tasks, TaskList, last-sent
   activeForms, created set) → tool calls`, tested directly, plus mod tests
   (`claude plugin test`) with a fake tool layer for the poll. Cases: create
   with description and owner; exact-subject adoption only (a near miss left
   alone; an owned-by-someone-else task never touched); each state mapping
   including paused `activeForm` and a null round; diff-only updates; a
   previous walk's tasks (completed too) deleted when a new walk is current;
   the current-walk rules (a launch stopped by a gate before any pid row does
   not take the list; a relaunch whose dead and live pid rows share one
   second is live (later line wins); a stale `walk_end` followed by a later live pid row
   (a reused id) is live; a live walk wins, the latest `started` of several, and
   an older live walk whose next goal reruns `ensure-walk` does not take the
   list back; an idle
   newer leftover file never displaces the walk on screen — between goals,
   at walk-end, or after a restart with `$.state` cleared; with nothing of
   the mod's on the list, the newest listed walk); a walk stays `live` in the
   gap between a goal's `done` and the next `walk` row, a single `/run-goal`
   (no `walk` row) is live while its `dispatch` / `phase` pid is alive, and a
   walk stops being live at `walk_end` or when those pids die; a finished walk unlisted and then
   listed again (resumed) is reconciled again;
   a single deleted task not recreated, down to the last one (five deleted
   one per poll: none comes back), and two of five deleted with three still
   listed staying gone; every task listed last poll gone at once (two or
   more) recreated, earlier person-deleted goals staying gone; an all-completed walk of one goal and of five goals cleared by the engine
   not recreated (the replaced-list rule does not fire);
   a failed owner update on a `PAUSED:` goal (one already `in_progress`)
   adopted next poll, not
   duplicated; duplicates collapsed; the current walk unlisted → one final
   apply with a failing first read retried, then left alone; failed reads
   changing nothing; `/clear`
   (a new session id) still finding the walk; no `Task*` tools. `events.py`
   tests: the walk file's `session` / `root`, atomic writes, reuse rewriting
   `session` with stdout unchanged, `walks` (several ids, other sessions,
   missing fields, unparsable files, `mtime`, `live`, `started` (the walker's
   first pid row, unchanged by later goals, found behind more than 400 later
   lines, and not confused with an older run that had the same pid number), a reused walk file left
   untouched by a same-session `ensure-walk`, a cwd unrelated to any
   root, a missing cache root → `[]` exit 0),
   each `reason` branch including a `bounced` row whose `wake` is missing
   (`stopped`) and two rows in one second. A lessons-mod test
   that a failed plugin-origin call is not counted and runs the tool once.
   Planted bugs, each shown red. The full house suite
   (`scripts/tests/run-all.sh -j 8`).
9. **Verification (required; user, 2026-10-14).**
   `docs/features/walk-tasks/VERIFICATION.md` is the checklist that gates the
   commit: (1) scenario tests against the real `events.py` (real walk files
   and event logs in a temporary `EVENTS_CACHE`, a live `sleep` standing in
   for the walker); (2) a randomised invariant test (thousands of random
   sequences, five invariants checked after every poll); (3) a live mini
   dogfood — a throwaway 3-goal target walked from the house-rooted session,
   the user checking ctrl+t at each scripted step. Each item is ticked with
   its evidence; a failing item blocks the commit, and none is skipped
   without the user's explicit OK.

## Key decisions & tradeoffs

- **Stateless reconcile over a walk lifecycle** (user, option C, after v1's
  five rounds). Each poll picks the current walk from the `walks` listing
  (`live`) and the list itself (the `owner` tags on screen), derives the
  desired list from that walk's graph, and fixes the difference; the `owner`
  marker says which tasks are the mod's. What `$.state` keeps (session ids,
  the created set, the task ids listed on the previous poll, the root and
  walk id of the last reconciled walk) is a cache: losing it in a restart recreates
  every missing task of the current walk once (deletions the person made
  before the restart included) and leaves a finished walk whose file is already gone as last shown. Rejected: v1's tracked / finished / retiring states with tombstones,
  whose interactions each review round extended.
- **The mod owns the tasks** (Q1). The Architect no longer seeds them; an
  Architect-seeded task with the exact subject is adopted. Rejected: the
  Architect seeds and the mod matches subjects.
- **One current walk per session: the most recently started live walk,
  else the one already on screen.** An idle file, newer or not, never
  displaces the walk on screen, and neither does a launch a gate stopped
  before any pid row (its stop file reports it; a rule to show it was tried
  in v2 round 4 and dropped after round 5, user, 2026-10-14). With none of
  the mod's tasks on the list, the remembered last walk stays current; only
  with nothing remembered does rule (3) pick the newest listed file.
  Walk files are left behind by
  `/run-goal` and stopped walks, so the newest file alone would let a
  leftover displace the walk on screen. Rejected: every listed walk at once (leftover `/run-goal` files would all
  show); cwd (the house session never saw a target walk); every live walk on
  the machine (another session's walks would fill this list).
- **Stopped goals are renamed** (Q2): `PAUSED:` stays `in_progress` with a
  `PAUSED:` spinner, `BOUNCED:` returns to `pending`, so a stopped walk never
  reads as running and never all-completes into an empty list.
- **Any `walk_id` counts** (cosmetic): `/run-goal` mints one too, and a
  restarted walk keeps its id, so both get the whole DAG's tasks.
- **`owner` as the marker.** It costs a short `(walk:3f9a1c2e)` after each
  subject in the list; in exchange the mod needs no record of which tasks are
  its own. Rejected: a marker in the subject (noisier); a stored id map
  (lost on restart — v1's problem).
- **A person's deletion wins; a replaced list does not.** A replaced list is
  two or more of the walk's task ids listed on the previous poll and all
  absent now; exactly those are recreated, and goals the person deleted
  earlier stay deleted. An absence while every desired task is `completed`
  is never a replaced list (the engine's all-completed clear). Anything less — one task gone, including the last,
  or some gone while others remain — is the person's deletion.
- **No `TodoWrite` fallback.** `TodoWrite` replaces the whole list and a mod
  cannot read it back, so the mod would erase the Architect's own items. Every
  interactive session on this machine has the `Task*` tools.
- **Footer removed outright**, not kept beside the list: two displays that can
  disagree is what started this item.

## Assumptions

1. `$.tool.call` reaches `TaskCreate` / `TaskUpdate` / `TaskList` with no
   permission prompt (4–13 ms) and acts on the list ctrl+t shows — probe,
   2026-10-13.
2. The model's context does not show the mod's tool calls — probe.
3. A list whose tasks are all completed clears itself, when nothing else is
   open — observed at the end of the rbtree walk.
4. `$.session.id()` equals `CLAUDE_CODE_SESSION_ID` in this session's Bash
   (36 characters, identical) — probe.
5. `owner` set by `TaskUpdate` is returned by `TaskList` and shown after the
   subject (`#16 [in_progress] PROBE … (walk:3f9a1c2e)`) — probe, 2026-10-14.
6. `events.py graph --json --dir D` returns every goal's state, round, phase
   in ~40 ms from any cwd — measured; `walk_status` reads only the cwd's repo
   — `scripts/events.py`.
7. `/run-goal` and `/run-goals` both call `events_ensure_walk`; `walk-end`
   (only `run-goals.sh`) deletes the walk file; a restart reuses the id —
   `scripts/lib/events.sh`, `scripts/events.py`.
8. Hooks see `next.origin.plugin`, `"engine"` for the model's own calls; a
   `tool.call` event has no `origin` — the mod API types.
9. The DAG walker, `run-goals.sh` and `goals.py` change only additively — house
   rule; this plan touches `events.py` additively and neither shell script.

## Risks / open questions

- **A single `/run-goal` never deletes its walk file** (only `run-goals.sh`
  ends a walk), so its file lingers. It stays on screen (rule 2) until a live
  walk becomes current; it never displaces one, because it is live only while
  its `run-goal.sh` runs, and a gate-stopped relaunch is never live. Its tasks stay truthful through the
  graph.
- **Rate of tool calls.** A 7-goal walk is ~7 creates plus owner updates, then
  a few updates per goal transition; the steady state is one `TaskList` per
  poll (every 3 s, 4 ms measured) while the session has a walk file, and no
  calls otherwise.

## Out of scope

- A `TodoWrite` fallback; non-interactive (`-p`) sessions.
- Changing the `/walk` pane, `events.py status`, or the walker's events.
- Showing walks launched outside any Claude session (no recorded session; the
  pane still shows them), or more than one walk per session at once.
- Parallel walking itself (item 6).
