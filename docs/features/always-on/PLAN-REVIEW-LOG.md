# Plan Review Log: an always-on house (the user signs; the loop walks)
Phases 0-1 (recon + interrogation) complete — plan locked with the user. MAX_ROUNDS=5.

## Round 1 — Grok

I'll review the always-on plan skeptically, starting with the plan and the domain docs it depends on.The plan is not ready to implement. Several of its safety claims depend on reason strings, journal headings, and a supervisor loop this repo does not have.

1. **The class table does not match the reasons the walker emits, and a billing failure never arrives as the strings in step 10.** `run-goal.sh` records an implementer 429 as `rate_limited` (`wake "rate_limited"`), which is not in the table, so the unknown-to-A rule holds the entry instead of waiting. `credits_required`, `enforced_spend_limit_reached`, and `billing_error` are not walker reasons. `is_transport_rate_limit` in `scripts/lib/dotenv.sh` folds "quota" into `rate_limited` / `reviewer-rate-limited`, and any other billing failure becomes `implementer-error` or `reviewer-error` (class C, two full recuts). The stop line is `rate_limited (exit N)`. There is no `retry-after`, and launcher changes are out of scope, so step 10 has nothing to wait on. Also absent, so they become A: `implementer-blocked`, `worktree-setup-dirty`, `journal-unreadable`, `walk-stuck`, `interrupted`, `trap`, `done-refused`, `bounced-not-recorded`. The walker's own text for `worktree-setup-dirty` says a rerun recuts it.
   **Fix:** Classify the walker's real tokens (`rate_limited` with the same wall-clock wait as `reviewer-rate-limited`; name the others). Scan the stop detail for spend-limit, billing, and credits strings and treat those as A. If no reset time is present, hold as A.

2. **The decider's reason is committed into the journal the walker parses.** A rerun reuses the walk id: `ensure_walk` in `scripts/events.py` returns the existing id once the journal mentions it, and `events_journal_walk_start` writes no new line. `conflict_recuts_used` and `done_this_walk` in `scripts/lib/wave-walk.sh` reset at a later `ORCHESTRATOR walk-start walk_id=<that id>`. The packet includes a journal tail, so that id is in the decider's input, and step 12 appends the model's reason under the `DECIDER` heading. A quoted or injected walk-start line zeros the one automatic merge-conflict recut (the supervisor's class D cap never fires because the walk does not stop) and drops already-integrated goals from the next merged-proof set. `journal-merge.py` does not check the walk side. A resume `ARCHITECT` record with free text has the same problem.
   **Fix:** Persist the reason only in `decisions.jsonl`. The journal line is one line, `## <utc> — DECIDER <action>`, rejected unless it matches that shape with no extra line.

3. **`resume` undoes the signature check for every class B remedy.** `bounced`, `blocked-oracle-edit`, and `oracle-gap` are fixed by editing the oracle or `tests/acceptance/` and committing (`bounce()` and `run-goals.sh` `mutation_gaps_stop` both say so). Step 3 then holds that commit as `contract-drift`. `resume` clears the hold and reruns, so the entry holds again. `sign` appends a second line rather than replacing the held one.
   **Fix:** `resume` on a class B hold whose oracle, acceptance files, `plan:` file, or `GOALS.md` body changed since the signature refuses and tells the user to `sign` the new `HEAD`. `sign` replaces a held entry for that same repo.

4. **The sign-off heading `sign` requires is not something to-goals writes.** Step 2 asks for "the user's `ARCHITECT` oracle-review sign-off line (a fixed heading the to-goals skill writes on sign-off)." `skills/to-goals/SKILL.md` writes `## <utc> — ARCHITECT decompose` and, only on a cap override, `ARCHITECT oracle-review override`. A normal approval is Grok's `VERDICT: APPROVED` in `PLAN-REVIEW-LOG.md`. `sign` would refuse every real DAG, or the build would invent a heading.
   **Fix:** `sign` accepts a committed `ARCHITECT decompose` plus either a current `VERDICT: APPROVED` in the plan's review log or a committed `ARCHITECT oracle-review override`, and refuses anything else.

5. **The signed plan file is the wrong path.** Step 3 freezes `PLAN.md`. The walker freezes the path in `GOALS.md`'s `plan:` field (`run-goal.sh` reads it via `goals.py meta`). A feature plan lives at `docs/features/<slug>/PLAN.md`. A commit that changes that file and leaves a root `PLAN.md` untouched passes the supervisor, and the next walk freezes the unsigned bytes as `BASE_SHA`.
   **Fix:** `git diff --quiet <signed> HEAD --` the `plan:` path from the signed `GOALS.md`, the oracle paths from `scripts/lib/oracle-files.py`, and `tests/acceptance/`.

6. **The mid-walk spend halt has no writer.** The supervisor is blocked in `run-goals.sh` for the whole walk. Nothing in the plan tails cost and writes `~/.cache/.../always-on/halt` while that child runs, and `run-goals.sh` has no halt check today. Ceilings apply only after the walk exits. The $20 walk cap is above the $10 rolling-day cap, so it never binds at those check points. Summing each call's `total_cost_usd` also mis-counts: implementer events are thread-cumulative (`IMPLEMENTER_COST_BASIS: thread`), and `events.py` already takes the max per thread. A failed `GET /user/balance` is unspecified, so a zero delta hides DeepSeek spend.
   **Fix:** Before each goal or wave, `run-goals.sh` appends the rollup from `events.py` under `flock` and writes `halt` itself when the 24-hour, walk, or 7-day ceiling is crossed. A balance read that fails is class A `budget`.

7. **A restart dispatches a second walker, and `STOP` is invisible mid-walk.** State is files, but an entry left running is not defined when the pid is dead. LaunchAgent `KeepAlive` starts another supervisor while the orphaned `run-goals.sh` still holds the repo. `STOP` is checked on the supervisor's turn, and the supervisor is blocked in the child, so `cw-decide.sh stop` does not stop a walk already dispatched. Stop files live under `~/.cache/claude-coding-workflow/runs/`, which `cw_prune` deletes.
   **Fix:** Take an exclusive lock on `~/.config/cw-always-on/supervisor.lock`. On startup, if the recorded pid is dead, classify the copy of the stop saved in the state file, or hold `interrupted`. Do not dispatch. `run-goals.sh` checks `STOP` before each goal and wave and exits `always-on-stop`. The supervisor `TERM`s the child's process group when `STOP` appears.

8. **Every parallel stop can be read as class A.** `wave_stop` in `scripts/lib/wave-walk.sh` puts the sentence "A goal listed finished-not-integrated passed review" in the detail of every wave-stop. That token is not in the table. A scan of the whole file holds every parallel entry. On a real `## Stopped` bullet, `finished-not-integrated` means the rerun integrates without dispatch. The join path at line 1303 can also record an empty reason (`reason_of || true`), which is not defaulted to `interrupted`.
   **Fix:** Parse only the `- <goal>: <reason> — <file>` bullets under `## Stopped`. Treat `finished-not-integrated` as "integrate on rerun" and an empty reason as A. Fixture the test with a real wave-stop file that contains that sentence plus an `implementer-error` sibling.

9. **The queue line breaks on real paths, and two entries can walk one repo.** The format is `<abs repo path> <signed sha> jobs=<N>`. A macOS path with a space splits into extra fields. A held entry is skipped, so a later line for the same repo starts while the held walk's `cw/<goal>` worktrees and git locks still exist. `state/<entry>.json` cannot be a filename if `<entry>` contains slashes. Action counts have no crash order: a rewrite that loses the file rearms the two class C retries.
   **Fix:** One JSON object per line, reject a second active entry for a repo already `running` or `held`, name the state file by the line's sha256, and `fsync` an incremented count before dispatch. A missing or corrupt state file is class A.

10. **The supervisor's journal commit can hang or sweep the tree.** `git commit` with `commit.gpgsign` set prompts on a LaunchAgent with no TTY and never returns, so the heartbeat also stops. The plan does not say the commit is limited to the journal path.
    **Fix:** Commit with `GIT_TERMINAL_PROMPT=0`, only the journal path, and only when the worktree is otherwise clean. If signing is required and cannot complete non-interactively, hold class A `commit-failed`.

11. **iMessage is built from stop text.** Step 13 interpolates "reason" and "what to run" into `osascript`. A stop detail that contains a quote is AppleScript. The push path is not held to the same "no finding, no secret" rule as iMessage.
    **Fix:** `notify.sh` passes a fixed set (repo basename, class, reason code, commands) as `osascript` argv using `quoted form of`. The Remote Control body is those same fields.

12. **Silence during a healthy walk means "still alive" and "dead" at once.** The daily 09:00 heartbeat and the one-minute wait loop run on the supervisor turn. A walk that spans 09:00 produces no message. The plan says silence means something is wrong.
    **Fix:** A second LaunchAgent on `StartCalendarInterval` sends the heartbeat from the state files. A walk whose pid is alive counts as alive.

`scripts/tests/always-on-test.sh` needs fixtures for 1, 2, 3, 7, and 8. The stubbed class table will not catch them.

VERDICT: REVISE

### Architect's response

Verified against the code (rate_limited from run-goal.sh, the missing tokens, the wave-stop sentence, to-goals' ARCHITECT decompose / oracle-review override, IMPLEMENTER_COST_BASIS: thread, cw_prune). All 12 taken:
1. The table rewritten in the walker's real tokens (rate_limited and reviewer-rate-limited wait; implementer-blocked and done-refused B; worktree-setup-dirty D; journal-unreadable, walk-stuck, trap, bounced-not-recorded, interrupted and an empty reason A); billing markers on the detail line override the table as A budget (step 7a), measured in a new step 0d. Not taken as proposed: a rate limit with no reset time is not held at once; it backs off 15/30/60 minutes and a fourth within 24 h holds (holding every throttle would defeat always-on).
2. The decider's reason goes only to decisions.jsonl; the journal gets a fixed-shape DECIDER line, and the user's resume/skip records are fixed-shape too.
3. resume refuses when the signed paths changed (always so after a class B fix) and tells the user to sign the new HEAD; sign replaces a held entry for the same repo.
4. sign accepts the to-goals artefacts: a committed ARCHITECT decompose plus a last oracle-review VERDICT: APPROVED or a committed ARCHITECT oracle-review override.
5. The signed paths are the plan: file from GOALS.md, oracle-files.py's paths, tests/acceptance/ and GOALS.md beyond status.
6. run-goals.sh checks spend and the kill file before each goal and wave (always-on-spend.py under flock: implementer cost as max per thread, a CLAUDE_REVIEW_COST: line, the decider log, the DeepSeek balance delta; a failed balance read is budget); noted that the walk ceiling binds only for walks over a day.
7. A supervisor lock; a dead pid on start holds (interrupted) or classifies the copied stop file, never redispatches; STOP checked by the walker before each dispatch and the supervisor TERMs the child's process group; the stop file copied into state at once.
8. Only the Stopped bullets of a wave-stop are read; finished-not-integrated is not a stop; an empty reason is A; fixtures from real wave-stop files.
9. queue.jsonl, one active entry per repo, state named by the line's sha256, counts fsynced before dispatch, a missing state file A.
10. Journal commits with GIT_TERMINAL_PROMPT=0, the journal path only, a clean tree, a failure A commit-failed; new step 0g measures commits under launchd with the user's signing config.
11. notify.sh passes fixed fields as osascript argv (quoted form of), never stop text; the Remote Control push uses the same fields.
12. A separate heartbeat LaunchAgent at 09:00 reads the state files; alive while the lock is held and a running pid lives.
Also: the weekly ceiling is now $50 (the user, during this round).

## Round 2 — Grok

I'll re-read the revised plan and check each prior finding against the repo.The signature check, the journal line, the queue, the lock, and the stop-file parser are in place. The spend meter, the billing scan, the heartbeat, and `resume` still do the wrong thing.

1. **The spend check, as written, will not measure what the ceilings mean.** `always-on-spend.py` appends "this walk's cost so far" and then sums the ledger, so each snapshot is counted again on every later check. That sum also adds the DeepSeek balance delta on top of the implementer rollup, and `events.py` already prices DeepSeek threads (`journal_implemented` / `IMPLEMENTER_COST_USD`). The balance is the whole account: a top-up makes the delta go negative and hides spend, and any other local DeepSeek use inflates it. Reviewer Opus cost is not in `events.py`; `CLAUDE_REVIEW_COST:` is only a line on `claude-goal-review.sh`'s stdout, and nothing says where the checker reads it after the process exits. A failed balance read writes `halt`, and nothing clears `halt` when a later check is under the ceiling, so one blip stops every later walk. The overshoot is "at most one goal," but the supervisor always uses `--jobs` 2–4 and `wave-walk.sh` starts the whole wave in one burst, so the overshoot is one wave. Step 6 strips every `CW_*` from the child, which removes `CW_ALWAYS_ON_LEDGER`, the switch that turns the check on. Under launchd the DeepSeek key is not in the environment; it is loaded from dotenv files inside `claude-implement.sh`. A balance read that cannot see that key fails and holds `budget` on the first goal.
   **Fix:** Each ledger line is a delta (implementer rollup from `events.py`, plus reviewer and decider costs the walker appends into that ledger). Do not add the account balance to the sum; a balance read is only a backstop, using the same key files as `claude-implement.sh`, and a missing key fails `doctor` before any walk. Unlink `halt` when the check passes. Check again before each goal is spawned, and keep `CW_ALWAYS_ON_LEDGER` in the child while stripping every other `CW_*`.

2. **A billing failure still will not match step 7a.** The walker writes details such as `IMPLEMENTER_RESULT=rate_limited (exit 75)` and `CLAUDE_REVIEW_RESULT=error (exit 1)` (`claude-implement.sh` `emit_and_exit`, `claude-goal-review.sh`). The spend-limit sentence stays in the raw envelope. The stop file only points at it (`LOG:`, `stderr:` in `write_stop`). Scanning the `- detail:` line misses it, so a spend limit that arrived as `rate_limited` is waited on and retried. The token `402` is also too wide if "any stop file it names" means the whole file: `BASE_SHA` is hex, and `402` occurs inside SHAs. Step 8 puts `rate_limited` in class C (decider, count of 2) while step 10 says those waits use no C count and follow their own backoff.
   **Fix:** Step 0d is a gate: each billing fixture must be classified A before any walk code. Scan the detail line and the envelope paths the stop file names, not the whole stop file, and do not use a bare `402`. A `rate_limited` / `reviewer-rate-limited` stop is the step 10 wait, then a rerun, with no decider and no C increment; a billing marker or a fourth limit in 24 hours is A.

3. **The heartbeat reports a healthy wait as a dead supervisor.** It is alive only when the lock is held and a running entry's pid is alive. Between walks, and during the 15/30/60 minute backoff, the lock is held and there is no child, so the 09:00 message says the supervisor is not running.
   **Fix:** The lock held means alive. A running entry whose pid is dead, or a lock that is free, is the "not running" message.

4. **`resume` livelocks on the holds it is meant to clear.** It clears the hold and the next turn reruns. Step 8 then sees a goal already past its C or D count, or a second B, and holds `NEEDS_HUMAN` again without dispatching. `serial-goal-in-progress` is the same loop: resume starts `--jobs` again, and the walker stops with the same reason. Always-on never runs the serial finish `serial_goal_why` tells the user to run.
   **Fix:** `resume` on a count cap resets that goal's count once and dispatches one rerun. `resume` on `serial-goal-in-progress` is refused and prints the serial `run-goals.sh` command. A change to the signed paths still requires `sign`.

5. **`sign` can still enqueue the house.** The key decision says the loop never touches the house, and the LaunchAgent runs `scripts/cw-supervisor.sh` from that checkout. A signed house walk can commit changes to those scripts while the supervisor is running them.
   **Fix:** `sign` refuses a repo whose toplevel contains the supervisor script the LaunchAgent runs.

`always-on-test.sh` needs plants for the delta ledger, a stale `halt`, a four-goal wave that spends past the ceiling, a spend-limit envelope that is not on the detail line, a heartbeat during backoff, and a `resume` after the count cap.

VERDICT: REVISE

### Architect's response

All 5 taken:
1. The ledger holds increments, never snapshots: run-goal.sh appends each implementer pass's thread-cost increase and each review's CLAUDE_REVIEW_COST (with CW_ALWAYS_ON_LEDGER, now kept in the child); the supervisor appends decider costs. The check runs before each goal spawn (each wave member), sums 24 h / walk / 7 d, and unlinks a stale halt when under. The overshoot is up to jobs goals, stated. The DeepSeek balance is a backstop only, never summed: read before each walk with claude-implement.sh's key files, below a floor or unreadable holds budget, a missing key fails doctor.
2. Billing markers are matched on the detail line and in the raw output files the stop names (LOG:, stderr:), nothing else; no bare 402 (HTTP 402 / status 402 instead); step 0d is a gate with billing fixtures that must classify A first. rate_limited / reviewer-rate-limited are step 10's wait then a rerun, no decider, no C count.
3. The heartbeat reports alive whenever the lock is held; not running when the lock is free or a running entry's pid is dead.
4. resume dispatches one rerun and, at a count cap, resets that goal's count once; refused on serial-goal-in-progress (it prints the serial command) and when the signed paths changed (sign first).
5. sign refuses the house (the repo holding the supervisor the LaunchAgent runs).
The tests list gains plants for each.

## Round 3 — Grok

I'll re-read the revised plan and check the last round's findings against the code they still depend on.The queue, the journal line, the house refusal, the serial-goal resume block, and the implementer cost delta are in place. Four holes remain in the parts that were just rewritten.

1. **A reviewer billing failure still does not land on the lines step 7a reads.** `write_stop` in `scripts/run-goal.sh` sets `LOG:` and `stderr:` from `IMPL_LOG` and `IMPL_ERR`, which are captured only after the implementer pass. A reviewer wake does not update them. `reviewer-rate-limited` puts `rate_limited (exit N)` on the detail line and nothing else. `claude-goal-review.sh` leaves the provider sentence in the raw envelope (`VERDICT_FILE`) and, on a non-limit error, in `$RV_OUT.wrap`, which is named only inside that detail sentence. Step 7a opens `LOG:` and `stderr:` and does not open `VERDICT_FILE` or a path written inside the detail. Step 0d's parenthetical assumes the sentence is already in one of those two fields, so the new gate fails on a real reviewer stop and the plan has no change that makes the fixture pass.
   **Fix:** A reviewer wake copies that call's raw envelope and its `.err` onto the stop's `LOG:` and `stderr:`. Step 0d's fixtures are those real reviewer stops, and each one classifies as A before walk code is written.

2. **Reviewer and fallback costs are still cumulative, so the ledger double-counts the expensive calls.** Reviews and the mutations turn both `--resume` the same `SESSION_ID` (`run-goal.sh`). Claude's envelope `total_cost_usd` on a resumed session is the whole session, which this repo already relies on for the implementer. Step 9 deltas the implementer thread and then appends each `CLAUDE_REVIEW_COST:` figure whole, and it never mentions `IMPLEMENTER_FALLBACK_FROM`, where the primary thread's cost sits on a fallback pass. A review of $1 followed by a resumed review whose envelope says $3, then a mutations turn whose envelope says $4, records $8.
   **Fix:** Each appended review, mutations, and fallback-from figure is the increase over the last recorded cost of that session or thread, including a fallback call's own new spend. Plant a resumed session whose envelope grows 1 then 3 and assert the ledger gains 2.

3. **The heartbeat's two clauses disagree during a wait.** It is alive while the lock is held "during a wait, too", and it says the supervisor is not running when an entry marked `running` has a dead pid. After the child exits, the supervisor waits 15, 30, or 60 minutes on that same entry. If the status stays `running` and the recorded pid is the child that just exited, every backoff that crosses 09:00 is reported as a dead supervisor.
   **Fix:** Clear the running pid when the child exits, before the wait. The dead-pid alarm is only a `running` entry whose child died without the supervisor reaping it.

4. **`resume` refills the automatic cap, and the decider can stall the loop.** A hold at the cap "resets that goal's count once", then step 8 increments the count before the rerun. A reset to zero leaves another unsupervised C retry under the cap of 2 after the one rerun the user just allowed. Separately, the supervisor polls `STOP` only while the walk child runs. `claude-decide.sh` is a blocking `claude -p` with no timeout. A hung decider holds the lock, so the heartbeat stays "alive", and `STOP` is not read until the call returns.
   **Fix:** `resume` sets that goal's count to one below its cap so the pre-dispatch increment lands on the cap. Bound `claude-decide.sh` with a timeout. On expiry the action is `needs_human`. The parser accepts only the single JSON object whose shape step 0c recorded.

VERDICT: REVISE

### Architect's response

All 4 taken.
1. A reviewer wake (and a mutations turn) puts that call's raw envelope and .err (.wrap on a non-limit error) on the stop's LOG:/stderr:, so step 7a sees the provider sentence for both roles; step 0d's gate fixtures include real reviewer stops.
2. Redesigned rather than patched (the second round in a row to find a double count in the increment ledger): the ledger now holds observations ({ts, kind, id, cumulative_usd} as reported per thread or session, the fallback's primary thread included), and always-on-spend.py derives amounts at read time from each id's rises. A resumed session observed at 1 then 3 adds 2; the same total twice adds nothing. Recorded as a key decision.
3. The supervisor clears an entry's child pid as soon as the child exits; the heartbeat's not-running case is a free lock or an unreaped dead child.
4. resume sets the count to one below the cap (the user's rerun is the only extra one); claude-decide.sh runs under run-timeout.py (10 min default), a timeout is needs_human, and the output must be exactly the single JSON object step 0c recorded.

## Round 4 — Grok

I'll re-read the revised plan and check the last round's four findings against the walker code they still depend on.The prior findings are in the revised plan. I'll check the spend ceiling, the billing scan, and the ledger lock against the current text before judging anything new.The four findings from the last pass are in this revision: reviewer wakes name that call's envelope on `LOG:` / `stderr:`, the ledger stores cumulative observations and spends the rise, the child pid is cleared before a wait, and `resume` sets the count to one below the cap while the decider runs under `run-timeout.py` and must match the step 0c JSON shape. Two holes in the new text are still material.

**1. The $20 walk ceiling cannot be computed from the recorded fields.** An observation is `{"ts", "kind", "id", "cumulative_usd"}`, and `id` is the thread or session. `state/<id>.json` holds status, per-goal counts, the child pid and process group, and a copy of the last stop file. The ledger is one global file. Step 9 then sums "the lines … of the walk ($20)", which is the cap that is supposed to bind once a walk runs past a day. Dated rises define the $10 / 24 h and $50 / 7 d windows. Nothing defines which rises belong to this walk. Summing the whole file makes $20 a lifetime cap, so the next signed entry holds as `budget` once earlier walks have spent $20. Summing only the current `run-goals.sh` process resets the figure on every rerun, so the multi-day walk the cap is written for never accumulates it. `scripts/events.py` already reuses `walk_id` until walk-end so a quota or bounce restart stays the same job; a skip that never reaches walk-end would carry that id into the next signature.

Stamp each observation with the queue entry id, which is constant across that entry's reruns and new when a new line is signed, and sum the $20 from that id's rises only.

**2. The billing scan matches the model's successful transcript.** Step 7a matches `billing_error`, `spend limit`, `insufficient balance`, and the other markers in every file named on `LOG:` and `stderr:`. That file is the stdout envelope (`{"session_id", "result"}`, `scripts/lib/agent-result.py`). `claude-implement.sh` keeps it when `CW_OUT_DIR` is set, including after an ok pass, and a later stop still names it. A `proof-timeout` (class C) whose `result` quotes those phrases — billing code, a test name, a quoted error — is class A `budget` and is never retried. `resume` runs the goal again, the new stop names the same kind of transcript, and the entry holds again. The hex-sha `402` fixture does not cover this. A real DeepSeek 402 does put `Insufficient Balance` in `result`, alongside `api_error_status` (`scripts/tests/implement-test.sh`), so the scan still has to see error envelopes.

Match the markers in the stderr file and in an envelope only when `is_error` is set or `api_error_status` is present, and leave a success `result` unread. Plant a `proof-timeout` whose success `result` contains `billing_error` and assert it stays class C.

**3. `flock` is not on this Mac.** Wave members append the same ledger at once, and step 9 calls it `flock`ed. There is no `flock` binary here; `scripts/events.py` locks with `fcntl.flock`. Two appends can tear a line, and a torn line makes the ceiling sum undefined.

Append and read under Python `fcntl.flock`, the same call `events.py` uses.

VERDICT: REVISE

### Architect's response

All 3 taken.
1. Each observation carries the queue entry id (CW_ALWAYS_ON_ENTRY, kept in the child; the same across an entry's reruns, new on a new signature); the $20 sums that entry's rises only.
2. Billing markers are matched only in error output: the stderr file always, the LOG: envelope only when is_error is true or api_error_status is present; a successful result is never read. A plant: a proof-timeout whose successful result quotes billing_error stays class C.
3. Appends and reads under Python fcntl.flock, as events.py does (no flock binary on this Mac); a plant for concurrent wave appends.

## Round 5 — Grok

The last review left three holes: the $20 walk sum had no entry key, the billing scan read successful transcripts, and the ledger lock named `flock`. I'll check those against the revised plan and look for anything new.The three earlier holes are closed. Observations carry the queue entry id (`CW_ALWAYS_ON_ENTRY`), the $20 sum is that entry's rises across its reruns, the billing scan reads stderr and an envelope only when `is_error` is set or `api_error_status` is present, and the ledger lock is Python `fcntl.flock`. The restart path of the supervisor is still unspecified in a way that loses walks and replays old stops.

**1. A supervisor restart loses a live child, and `STOP` no longer reaches it.** The lock is held for the supervisor's life and dies with the process, so `KeepAlive` starts a new one while `run-goals.sh` is still in its own process group. On start, the only rule is for a `running` entry whose recorded pid is dead. A live pid matches nothing. Each turn dispatches only a `queued` entry, so this one is left `running` and unpolled. When that child later exits, nobody copies `STOP_FILE:`, clears the pid, or classifies the stop. The heartbeat then sees a dead recorded pid and reports that the supervisor is not running. `STOP` is applied only to the child this process launched, so the kill file does not stop the orphan.

On start, adopt a `running` entry whose pid is alive: poll it, signal that process group when `STOP` appears, and classify its exit as usual.

**2. The copied stop survives into the next attempt, so a reboot replays the previous reason.** The state keeps "a copy of the last stop file," and nothing clears it at dispatch. A dead pid with any copied stop is classified. Sequence: the entry stops `rate_limited`, the stop is copied, a rerun is dispatched, then the Mac reboots and the new child dies without writing a stop. On start the pid is dead and the copy is still the old `rate_limited` stop, so the supervisor waits and reruns. That is another dispatch of a walk that was killed mid-attempt. The rule that a crash with no stop holds as `interrupted` never fires, because the old copy is still there.

Clear the copied stop when a child is dispatched. A dead pid with no stop from this attempt holds as `interrupted`.

**3. The rate-limit ladder is not in the state file.** The pid is cleared before a wait, and the recorded fields are status, per-goal counts, pid, process group, and the last stop. Rate limits do not increment the C count. The 15/30/60 steps and the fourth limit within 24 hours therefore live only in the process. After a restart the entry is `running` with no pid, which the turn loop will not dispatch and the dead-pid rule does not name. If that case is forced through the old stop, the wait starts again at 15 minutes and the daily count starts at one.

Record a durable `waiting` status and the timestamps of this entry's rate-limit stops, and resume that wait on start.

**4. A killed model turn adds nothing to the ceiling.** The ledger appends `IMPLEMENTER_COST_USD` and `CLAUDE_REVIEW_COST` after a pass returns. `implementer-timeout` (default 20 minutes) and `reviewer-timeout` (default 10 minutes) kill the process before those lines exist, and class C retries them. The $10 / $20 / $50 checks never see that spend.

Record `total_cost_usd` from any envelope that parses, and a fixed stand-in measured in step 0 when a model turn ends with no cost. A proof timeout after a recorded pass stays class C.

VERDICT: REVISE

### Architect's response

MAX_ROUNDS reached without APPROVED. All 4 findings are valid. Rounds 1 and 5 both found holes in the supervisor's remembered run state (pid, copied stop, wait progress), so the proposed answer is a redesign, not a patch: run state derived each turn from the world (a per-attempt wrapper holding a lock file with its process group, writing an attempt-numbered result file on exit; lock held = running and adopted, result for this attempt = finished, neither = interrupted), a durable wait_until and rate-limit timestamps, and cost from any parsed envelope with a measured stand-in for a turn killed with no output. Put to the user: revise and allow a sixth round, or sign off with these as plan amendments.

User decision (2026-10-26): redesign and allow a sixth round. Revised: a per-attempt wrapper (always-on-attempt.py) holds an fcntl lock with its process group and writes an attempt-numbered result.json (with a copy of the stop and its named files) on exit; run state is read from those alone (running = lock held, adopted by any supervisor, STOP signals the recorded group; finished = result for this attempt; neither = interrupted, held); an earlier attempt's result is never read; state writes are temp+fsync+rename; the rate-limit wait is a durable waiting status with wall-clock wait_until and the stop timestamps; a killed turn records any parsed envelope cost or a stand-in measured in new step 0h. Recorded as a key decision; tests added for adoption, no replay after a reboot, a resumed wait, a timed-out review's cost.

## Round 6 — Grok

The last review left four holes in the supervisor's restart path and in unrecorded timeout spend. I'll check those against the revised plan and look for anything new.The four earlier holes are closed: a live attempt is adopted from the wrapper lock, an old attempt's stop cannot replay, a wait survives a restart with its timestamps, and a killed turn records a parsed cost or a step 0h stand-in. Three new holes follow from that design.

**1. A finished walk has no stop, and an empty reason is class A.** A parallel walk that completes exits 0 from `scripts/lib/wave-walk.sh` without printing `STOP_FILE:`. The wrapper then stores `stop_file: null`. Step 7 classifies whatever is in the result, and step 7 lists an empty reason as class A. The success path never sets `done` and never sends the walk-end digest. It holds the entry and pages the user.

Treat exit 0 with a null stop as `done`, and send the digest once.

**2. A finished attempt is acted on again every minute.** Each turn derives the attempt from the world, and `result.json` stays after the wrapper exits. Nothing records that attempt `n` was already classified. One `rate_limited` result appends another timestamp on every poll, so the fourth poll holds the entry as A. A class C stop increments its count the same way and spends both retries on one result. The durable-wait rule never gets a quiet minute to reach `wait_until`.

Record `acted_attempt` in the state file. Classify attempt `n` only when that field differs, and `fsync` it before any count, timestamp, message, decider call, or rerun.

**3. A killed turn's cost is counted again when its session resumes.** Step 9 records the parsed `total_cost_usd`, or the stand-in, as a fresh id, so the first observation contributes the whole amount. The next review or implementer pass resumes that same session and reports its cumulative total, which includes the killed turn. That id's first observation contributes the whole cumulative too. A session killed at $5 and resumed to $7 is recorded as $12.

Record the parsed cost or the stand-in under that call's real session or thread id. A later observation of the same id contributes only the rise. Apply the same rule to a decider call that times out.

**4. A wrapper that dies leaves the walker running.** The walker sits in its own process group, and the wrapper only forwards `TERM` and `INT`. If the wrapper is killed and writes no result, the lock drops with the process. The supervisor reads "neither" as `interrupted` and assumes the walker died with it. The walker is still alive, `STOP` has no process group to signal, and `resume` starts attempt `n+1` beside it.

The wrapper must kill the walker's process group on any exit that is not the walker's own. If that group is still alive and attempt `n` has no result, the attempt is still running.

VERDICT: REVISE

### Architect's response

Round 5's four holes confirmed closed. All 4 new findings taken (the user chose fixes plus a seventh round):
1. Exit 0 with no stop file is a completed walk: done, one digest.
2. acted_attempt in the state file, written (fsync, rename) before any count, timestamp, message, decider call or rerun: each result is acted on once.
3. A killed call's parsed cost, or its previous observation plus the stand-in, is recorded under that call's own session or thread id (the decider's too), so a resumed session adds only its rise.
4. The walker shares the wrapper's process group; running = lock held or a live member of the recorded group (a SIGKILLed wrapper's walker is still found and adopted); the wrapper kills the group on any exit of its own that is not the walker's.

## Round 7 — Grok

The last review left four holes: a clean exit treated as an empty reason, finished attempts re-acted every minute, killed-turn cost counted twice, and a dead wrapper leaving the walker alive. I'll check those and look for anything new.The four earlier holes are closed. A clean exit with no stop file is `done` and the digest goes out once, a result is acted on only while `acted_attempt` differs from `n`, a killed turn is recorded on its own session or thread id, and a wrapper that dies leaves the attempt running while its process group is still alive. Two holes in that new machinery remain.

**1. Marking the attempt acted and recording the outcome are separate writes, and the dispatch rule only skips `running`, `waiting`, and `held`.** Step 5 writes `acted_attempt = n` and syncs it before the count, the timestamp, the message, the decider, or the rerun. While a walk is in progress the stored status is still `queued`; `running` is derived from the lock. If the supervisor dies after that rename and before the status write — during the decider's ten minutes, or between the two writes — the new process sees a finished, already-acted attempt that is not running, waiting, or held. Step 6 then starts attempt `n+1`. A `budget` or `bounced` result is walked again, and a rate-limit result is retried immediately, with no timestamp appended.

Put the outcome in that same rename: `done`, `waiting` with `wait_until` and the new timestamp, or `held` with the class, the reason, and any new count. A crash before the rename acts again. A crash after it does not dispatch.

**2. `kill -0 -<pgid>` treats a reused process-group id as the walker.** After a reboot, or once that pid is recycled, an unrelated process makes a dead attempt look running. The result is never acted on, so a finished walk never becomes `done` and a killed one never holds as `interrupted`. `STOP` then signals that other group. The wrapper's flock cannot cover this: a child does not inherit an `fcntl` lock, so when the wrapper dies the lock drops and the pgid check is the only liveness bit left.

Count a live group member only when its command is the walker. A recycled pid does not keep the attempt running, and `STOP` does not signal it.

**3. The billing scan still opens the paths written in the stop file, not the copies the wrapper keeps.** The result stores a copy of the stop file and of the files named on its `LOG:` and `stderr:` lines because run folders are pruned after 14 days, and step 7 classifies from that copy. Those lines still name the run-dir paths. After the prune, a spend-limit sentence that existed only in the envelope is gone, and the stop is classified from its reason alone.

When the wrapper writes the copy, point that copy's `LOG:` and `stderr:` lines at the copied files.

VERDICT: REVISE

### Architect's response

Round 6's four holes confirmed closed. All 3 new findings taken:
1. acted_attempt and the outcome (done; waiting with wait_until and the timestamp; held with class, reason, count; or the rerun's count and queued) are one state-file rename, before any message, decider call or dispatch; the decider is asked into memory first.
2. A live group member counts only when its command is this attempt's walker (ps by group, the repo, and the walker's start time the wrapper records); a recycled id is neither running nor signalled.
3. The copied stop's LOG:/stderr: lines point at the copied files, so the billing scan works after the run folder is pruned.

User decision (2026-10-26): an eighth round.

## Round 8 — Grok

The last review left three holes: the acted-attempt write separated from its outcome, a reused process-group id treated as the walker, and the billing scan still opening run-dir paths. I'll check those and look for anything new.The three earlier holes are closed. The outcome shares a rename with `acted_attempt`, a live group member counts only when it is this attempt's walker, and the copied stop file's `LOG:` and `stderr:` lines point at the copies. Two checks in that new text do not match the processes and stop files the loop actually produces.

**1. The walker check looks for the repo on the command line, and the command line does not contain it.** Step 5 starts `always-on-attempt.py <id> <n> -- run-goals.sh --jobs N` with the repo as the working directory. `ps -o command=` shows that argv, not the cwd. Requiring `run-goals.sh` with the entry's repo makes the live walker fail the check. After `SIGKILL` of the wrapper the lock is gone, the attempt is `interrupted` while `run-goals.sh` is still running, and a resume starts a second attempt beside it. The start time written beside the pgid is the right second check, and `scripts/events.py` already implements it: `pid_alive` compares `ps -o lstart=` with the recorded start so a reused pid reads as gone.

Record the walker's pid and that `lstart`. A live member is this walker when `pid_alive` matches and the command contains `run-goals.sh`. Do not require the repo path on argv.

**2. A parallel stop names its per-goal files in the bullets, and those paths are not rewritten.** Always-on walks with `--jobs N`, so a goal stop is a `wave-stop`: `- <goal>: <reason> — <file>` under `## Stopped`. Step 7a then opens each named stop file and the files on its `LOG:` and `stderr:` lines. The wrapper rewrites `LOG:` and `stderr:` on the wave-stop itself, which has neither. The bullet paths still name the run directory. After the 14-day prune, a spend-limit sentence that lived only in a member's envelope is gone, and that member is classified from its reason alone. A `reviewer-error` that was really a spend limit is retried.

Copy each file named in the `## Stopped` bullets, rewrite those paths to the copies, and rewrite `LOG:` and `stderr:` inside each copied per-goal stop the same way.

VERDICT: REVISE

### Architect's response

Round 7's three holes confirmed closed. Both new findings taken:
1. The walker is identified by its recorded pid and start time (events.py's pid_alive) and a command containing run-goals.sh; the repo (the working directory) is not required on argv.
2. The wrapper copies every file a stop names, a wave-stop's per-goal stop files in its Stopped bullets and their LOG:/stderr: files included, and rewrites every such path to its copy.

User decision (2026-10-26): a ninth round.

## Round 9 — Grok

The last review left two holes: the walker check required the repo on the command line, and wave-stop bullets still pointed at the run directory. I'll check those and look for anything new.The two earlier holes are closed. The walker is the recorded pid whose `lstart` still matches (`events.py` `pid_alive`) and whose command contains `run-goals.sh`, and a `wave-stop` copy includes each `## Stopped` file plus that file's `LOG:` and `stderr:` targets, with those paths rewritten. The run-state predicates and the decider timing still contradict themselves.

**1. `finished` and `interrupted` still treat any process-group member as the walker.** `running` is the recorded pid. `finished` is `result.json` and "no member of its group lives." `interrupted` is no lock, no live group member, and no result. A reused pgid, or any leftover process in that group, is neither the walker nor an empty group. The attempt matches none of the three. While a walk is in progress the stored status stays `queued` (`running` is only derived). Step 6 then starts attempt `n+1`: a killed walk with no result is dispatched again, and a finished result that shares its old pgid with another process is never classified.

Key `running`, `finished`, and `interrupted` off the recorded walker pid only. `pid_alive` failing with a result is `finished`. `pid_alive` failing with no result is `interrupted`. Another process in the old group does not change that.

**2. The rename is specified both before the decider and after it.** The outcome rename, including `queued` and the incremented count for a rerun, is "before any message, decider call or dispatch." The next sentence asks the decider first and writes the rename after it returns. Following the first clause persists a rerun before the decider has answered. A crash during the call leaves the entry `queued` with `acted_attempt` already equal to `n`, and step 6 dispatches that rerun. A `needs_human` answer that was only in memory never becomes a hold.

Ask the decider first, into memory, as the second sentence says. The rename records that answer and precedes only the message and the dispatch.

**3. Killing the wrapper's process group does not stop the model calls.** `scripts/lib/run-timeout.py` starts every implementer and reviewer with `start_new_session=True`, so those processes are not in the wrapper's group. The wrapper's own-exit path "kills the group." An uncatchable kill skips the walker's `TERM` handler, which is what signals those sessions. The group then looks dead, the attempt is `interrupted`, and the model calls keep editing the repo. A later resume starts another walk beside them.

On the wrapper's own exit, send `TERM` and wait for the walker to exit, so its handler stops the `run-timeout.py` sessions.

VERDICT: REVISE

### Architect's response

Round 8's two holes confirmed closed. All 3 new findings taken:
1. running / finished / interrupted are keyed on the recorded walker only (pid + start time); no other process in the old group changes them.
2. The order is stated once: the decider into memory, then one rename recording acted_attempt with the outcome (a needs_human answer included), then any message or dispatch.
3. The wrapper's own exit TERMs the walker and waits for it, so the walker's handler stops the run-timeout.py sessions. Recorded as a risk: a walker SIGKILLed outright leaves its model calls running until their own timeouts (at most 20 min); the attempt holds interrupted (A) and the message says to let them finish before resume.

User decision (2026-10-26): a tenth round.

## Round 10 — Grok

The last review left three holes: run state still keyed off any process-group member, the decider ordered both before and after the outcome rename, and a group kill that does not stop model calls. I'll check those and look for anything new.The three earlier holes are closed. Run state follows the recorded walker (`pid_alive`), the decider answers into memory and one rename writes the outcome before any message or dispatch, and the wrapper sends the walker `TERM` and waits so its handler stops the `run-timeout.py` sessions. One contradiction with that is still in the plan.

The key decision "Run state from the world, not from memory" says a restarted supervisor reads running, finished, and interrupted from the lock and the result alone, and that the pid was removed from memory. The reboot risk says the same thing: neither a lock nor a result holds the entry `interrupted`. Step 5 says otherwise. After `SIGKILL` of the wrapper there is no lock and no result, and the walker is still alive. Following the key decision or the risk holds that attempt `interrupted`. `resume` then starts attempt `n+1` beside it. Step 5 and the `SIGKILL` test adopt that walker instead.

Make those two sentences match step 5. Running is the lock, or the recorded walker pid whose start time still matches. Neither a lock nor a result is `interrupted` only when that walker is gone.

VERDICT: REVISE

### Architect's response

Round 9's three holes confirmed closed. The one finding taken: the key decision and the reboot risk now state step 5's rule (running = lock held or the recorded walker alive; interrupted = walker gone with no result; a walker alive without its wrapper is adopted).

User decision (2026-10-26): an eleventh round.

## Round 11 — Grok

The last review found one contradiction: the key decision and the reboot risk still treated “no lock and no result” as `interrupted`, which drops a live walker after the wrapper is killed. I'll check that wording and look for anything new.The earlier contradiction is gone. The key decision and the reboot risk now match step 5: running is the lock or a recorded walker that `pid_alive` still confirms, finished is that walker gone with a result, and interrupted is that walker gone with no result. A wrapper killed by `SIGKILL` is adopted, not held.

The three run states, the decider-then-rename order, the wave-stop copies, and the wrapper's `TERM`-and-wait shutdown are consistent with each other and with the tests. The parenthetical in step 5 that says everything the walker starts shares its process group is corrected in the next sentence: model calls run in their own sessions, and the walker's handler stops them. That is sound enough to implement.

VERDICT: APPROVED

### Architect's response

APPROVED. Grok's remark on step 5's parenthetical taken as a wording fix: the walker shares the wrapper's process group; the model calls it starts run in sessions of their own.

## Resolution

Converged: APPROVED in round 11 (MAX_ROUNDS 5, extended by the user after rounds 5 to 10). Findings per round: 12, 5, 4, 3, 4, 4, 3, 2, 3, 1, 0. Two redesigns along the way: the spend ledger to observations with amounts derived at read time (after rounds 2 and 3), and the supervisor's run state derived from the world, a per-attempt wrapper's lock and attempt-numbered result (after rounds 1 and 5). Awaiting the user's sign-off.
