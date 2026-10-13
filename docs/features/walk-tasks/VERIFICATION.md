# Verification (required): walk progress in the task list

_User, 2026-10-14: these three are a must before item 10 is committed as done.
Each item is ticked here with its evidence (command, output, date). A failing
item blocks the commit; none is skipped without the user's explicit OK._

## 1. Scenario tests against the real `events.py`

Real walk files and event logs in a temporary cache (`EVENTS_CACHE`), real
`live` checks (a live `sleep` process standing in for a walker), the mod's
reconcile with a fake task list.

- [x] **Current walk.** A single `/run-goal` (no `walk` row) is live while it
  runs and becomes current. A `/run-goal` stopped by a gate before any pid
  row (dirty tree) does not take the list: the walk on screen stays. Two
  `walk:` owners listed after a failed delete: the walk reconciled last poll
  stays current. A newly selected walk whose goals are all done gets its
  (completed) tasks created; only a walk already reconciled last poll and
  cleared by the engine is left empty. A gate stop on a goal already
  `in_progress` reads `PAUSED:`; one on a goal not yet started keeps its
  plain title. A live walk plus an idle *newer* leftover: the live
  one stays current, including in the gap between two goals (walker alive,
  no goal running). The live walk ends with an older leftover present: the
  finished walk keeps "N done". A newer idle file appears: it does not
  displace the walk on screen. A new walk launched (live): it becomes current
  and the old walk's tasks are deleted. A restart with only leftovers and the
  old walk's tasks still listed: the on-screen walk stays; with none of the
  mod's tasks listed: the newest listed wins. Two live walks in different
  repos: the most recently started one wins, and stays current when the older
  one starts its next goal (which reruns `ensure-walk`). `started` stays
  fixed when its first pid row is more than 400 lines back, and a reused pid
  number from an older run does not count. A stale `walk_end` (older than a later live pid
  row of a reused id) does not stop the walk being live.
- [x] **No recreate loop.** All tasks completed and the list cleared, for a
  one-goal and a five-goal walk: zero creates over 20 polls.
- [x] **Owner failure.** The owner update fails once on a `PAUSED:` goal: the
  next poll adopts it; exactly one task per goal after 10 polls.
- [x] **Replaced list.** Every subset size 1..n-1 deleted: those stay
  deleted. Tasks deleted one per poll down to the last: none comes back. All
  tasks listed on the previous poll gone at once (n >= 2): those recreated,
  earlier person-deleted goals staying gone. A one-goal walk deleted: stays
  gone.
- [x] **`reason`.** One log fixture per branch, including a bounce whose wake
  is missing (-> `stopped`) and two rows in the same second.
- [x] **Cache root.** Missing -> `[]`, exit 0; present but unreadable ->
  nonzero.


Evidence (2026-10-14): `scripts/tests/walk-tasks-test.sh` — 46 checks against
the real `events.py` (walk file, `walks` with `live`/`started`, every `reason`
branch, missing/unreadable cache root) plus a freshness check that regenerates
`mods/walk/hooks/fixtures.ts` with `scripts/gen-walk-fixtures.py` (real walk
files and event logs, a live walker pid) and diffs it; `claude plugin test
mods/walk` — the scenario tests in `tasks.test.ts`, seven of them fed from those
real fixtures through the real poll (gate-stopped launch, between goals,
walk-end with a leftover, two live walks, a lone /run-goal, a new live walk
replacing, a gate stop on an unstarted goal). Full suite 22/22 at -j8; walk
56/56; lessons 25/25. Each case has a planted bug shown red (journal).

## 2. Randomised invariant test

A few thousand random sequences of walk starts and ends, restarts, `/clear`,
person deletes, replaced lists and failed calls. After every poll:

- [x] the mod never touches a task it does not own (except an exact-subject
  adoption);
- [x] at most one task per goal of the current walk;
- [x] no task of a non-current walk survives;
- [x] a person-deleted goal never comes back (a replaced list recreates only
  the tasks listed on the previous poll);
- [x] no subject or `activeForm` contains `null` or `rnull`.


Evidence (2026-10-14): `tasks.test.ts` "random sequences keep the invariants
after every poll" — 2500 seeded sequences x 25 steps (walk starts and ends,
stops, goal changes, person deletes, replaced lists, foreign and
someone-else's tasks, restarts, /clear, injected call and graph failures), the
five invariants checked after every poll. It found two real bugs during the
build (journal, build entry), both fixed and pinned by scenario tests.

## 3. Live mini dogfood

A dedicated throwaway target repo with 3 trivial goals (about $1 of
implementer time), walked from this house-rooted session so the real mod and
the real task list are exercised. The user checks each step in ctrl+t:

- [x] a `/run-goal` that leaves its walk file behind — its goals appear;
- [x] then `/run-goals` — the list follows the walk live;
- [x] the user deletes one task mid-walk — it stays deleted;
- [x] the user runs `/clear` — the walk's tasks come back in the new list;
- [x] a goal is made to bounce — `BOUNCED: <reason>`, never `null`;
- [x] a second walk starts — it replaces the first walk's tasks.
- [x] the lessons mod does not count a plugin's failed tool calls as the
  person's: a throwaway probe mod makes five failing `$.tool.call`s
  — no lessons run; as a control, five failed
  model tool calls trigger one. (Run: `TaskUpdate` on a bogus id answers
  without error, so the probe used `Read` on a missing file — five
  `isError` results, no new run log; five failed model `Read`s, exactly one.)
