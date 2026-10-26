# Plan: an always-on house (the user signs; the loop walks)
_Locked via crucible — by Claude + the user, 2026-10-26_

## Goal

Today the user drives every step: after the research, the plan, the signed
`PLAN.md` and the oracles, they still start each walk, read every wake and
decide what happens next. This plan makes Phases 4-5 run unattended for days on
this Mac. The user keeps Phases 0-3 (research, interview, the signed plan,
`GOALS.md` and its oracles after Grok's oracle review) and signs a walk into a
queue. A host **supervisor** then walks each signed entry, waits through usage
limits, resolves operational stops through a fixed table, and asks an AI
**decider** (Claude Opus 5.5 at xhigh effort, high if it is ever Fable 5.1)
only to choose among the few exits that table allows. Security-class and
contract-class stops, budget ceilings, merges and any decider doubt stop the
entry and message the user on iMessage; the user answers at the Mac. Every
deterministic gate the house has stays exactly as it is.

Research: `inbox/research/2026-10-26-always-on-crucible-research.md`.

## Approach

### Step 0 — evidence before building (`docs/features/always-on/EVIDENCE.md`)

Each is measured on this Mac; a failure stops the build and goes to the user.

- **a. iMessage from launchd.** A LaunchAgent-started script sends an iMessage
  to the user's handle through `osascript` (Messages), the text passed as argv
  (`on run argv`), never spliced into the script. Record the Automation (TCC)
  prompt it needs, whether it survives a locked screen, and the exit status and
  text when Messages is not signed in.
- **b. API key routing.** With `ANTHROPIC_API_KEY` set from
  `~/.config/cw-secrets/anthropic-decider.key` (and only then), a walk's Claude
  calls (`claude-goal-review.sh`, the mutations turn, a Haiku fallback pass
  through `claude-implement.sh`, `claude-decide.sh`) bill the key and not the
  subscription (their costs appear on the key in the Console; the subscription's
  `/usage` does not move). Under launchd, with no shell profile.
- **c. A tool-less decider.** `claude -p` with no tools (the exact documented
  form, measured) answers a JSON packet with JSON at `--model claude-opus-5-5
  --effort xhigh`, `--permission-mode dontAsk --permission-prompts none`; its
  cost per call and output shape.
- **d. Billing and limit failures as the walker reports them.** For each
  launcher on the API key: a 429 with `retry-after`, an
  `enforced_spend_limit_reached`, a workspace spend limit, a `billing_error`, a
  DeepSeek 402. Record the exact stop reason (`rate_limited`,
  `reviewer-rate-limited`, `implementer-error`, `reviewer-error`, ...) and the
  stop detail text each produces, plus where the provider's sentence lands
  (the detail line, or only the raw output files the stop names on `LOG:` and
  `stderr:`), so the supervisor's markers (step 7a) match real text, and
  whether any carries a reset time. **A gate**: each recorded billing case,
  the reviewer's included (after step 7a's change to reviewer stops), is kept
  as a fixture of the real stop file and its named files, and must classify as
  A before any walk code is written.
- **e. Remote Control push from the walk mod.** The `walk` mod can call
  `PushNotification` (`$.tool.call`) on a stop event, and the phone receives it
  while an interactive session has Remote Control connected.
- **f. Version pin.** How to keep Claude Code from updating itself during an
  unattended run (a LaunchAgent environment setting or a pinned binary), and
  that it holds.
- **g. Commits under launchd.** The walker's own commits (and the supervisor's
  journal commits) complete under a LaunchAgent with no TTY, with the user's git
  signing configuration as it is (`GIT_TERMINAL_PROMPT=0`); if signing needs a
  prompt, record it: the plan then requires non-interactive signing set up by
  the user, or signing off for the always-on runs, asked of the user.
- **h. The cost of a killed turn.** One implementer and one reviewer turn run
  to their timeouts on a stub task; record what each billed and whether a
  partial envelope reports it, to set step 9's stand-ins.

### The queue and signing

1. **Queue file** `~/.config/cw-always-on/queue.jsonl` (0600; outside every repo
   and every sandbox's write set): one JSON object a line,
   `{"repo": "<abs path>", "signed": "<sha>", "jobs": N}` (`N` 2-4: the
   supervisor always walks in parallel mode, see Key decisions). An entry's id
   is the sha256 of its line; its state is `state/<id>.json`. At most one entry
   per repo may be active (`running` or `held`); a line for a repo that already
   has one is refused when it is signed and skipped (and reported) if found.
2. **`scripts/cw-decide.sh sign <repo> [jobs=N]`** (the user, at the Mac): the
   repo has a clean tree, a `GOALS.md` that validates (`goals.py validate`), a
   committed `ARCHITECT decompose` record in the plan's journal, and either a
   last oracle-review verdict of `VERDICT: APPROVED` in the plan's review log or
   a committed `ARCHITECT oracle-review override` record (the to-goals skill's
   own artefacts); anything else is refused, naming what is missing. It also
   refuses the house itself (a repo whose toplevel holds the
   `scripts/cw-supervisor.sh` the LaunchAgent runs): house work stays
   in-session. It writes
   the entry with the current `HEAD`, **replacing** a held entry for the same
   repo (its state file moves to `state/old/`).
3. **Every dispatch and rerun re-checks the entry** against its signed sha: the
   sha is an ancestor of `HEAD`, and since it the `plan:` file `GOALS.md` names
   (from the signed `GOALS.md`), the oracle paths (`scripts/lib/oracle-files.py`
   on the signed `GOALS.md`), `tests/acceptance/` and every `GOALS.md` field and
   body but `status` are unchanged (`git diff --quiet <signed> HEAD -- <paths>`,
   `goals.py status-transitions` with `*=*:*`). A drift holds the entry
   (class A, `contract-drift`): the loop never walks a contract the user did not
   sign.

### The supervisor (`scripts/cw-supervisor.sh`)

4. Run by a LaunchAgent (`com.cw.always-on`, `KeepAlive`, `ProcessType
   Standard`, `RunAtLoad`, absolute `PATH`, logs under
   `~/.cache/claude-coding-workflow/always-on/`) as
   `caffeinate -is cw-supervisor.sh`. It never daemonizes and never holds a
   Claude session. **It remembers no run state in memory and trusts none it
   wrote earlier about a live process**: each turn it derives every entry's run
   state from the world (step 5). Its files: the queue; `state/<id>.json`
   (status `queued` / `waiting` / `held` / `done`, the current attempt number,
   `acted_attempt` (the last attempt whose result was acted on),
   per-goal action counts, `wait_until`, the timestamps of this entry's
   rate-limit stops, the hold's class and reason); per attempt
   `attempts/<id>/<n>/` (step 5); the spend ledger; the decisions log. Every
   state write is to a temporary file, `fsync`ed, then renamed.
5. **Each walk attempt runs under a wrapper** (`scripts/lib/always-on-attempt.py
   <id> <n> -- run-goals.sh --jobs N`), started by the supervisor in a new
   session (its own process group, which the walker shares; the model calls the
   walker starts run in sessions of their own, below). The wrapper takes an exclusive `fcntl.flock` on
   `attempts/<id>/<n>/lock` and writes that process group there, runs the walker
   as its child, forwards `TERM`/`INT` to the walker, and on any exit of its own
   that is not the walker's (an exception, a signal it catches) sends the walker
   `TERM` and waits for it to exit before it releases the lock: the walker's own
   signal handling is what stops the model calls, which `run-timeout.py` starts
   in sessions of their own, outside this process group. On the walker's exit it writes `attempts/<id>/<n>/result.json`
   (`{"exit": <status>, "stop_file": <path or null>, "stop": <a copy of that
   stop file and of the files its LOG:/stderr: lines name>}`) by a temporary
   file and a rename, then releases the lock. The copy is complete: for a
   single stop, the files on its `LOG:` and `stderr:` lines; for a `wave-stop`,
   each per-goal stop file named in its `## Stopped` bullets and, for each of
   those, the files on its own `LOG:` and `stderr:` lines. Every such path is
   rewritten to its copy (in the bullets and inside each copied per-goal stop),
   so the billing scan (step 7a) reads only copies, after the run folder is
   pruned too. A result file exists only once,
   complete, for that attempt. **The run state of an entry's current attempt
   `n`** is then read, by any supervisor, from the world alone, keyed on the
   recorded walker only (its pid and start time, `pid_alive`); no other process
   in the old group changes it:
   - **running**: the attempt's lock is held (a non-blocking `flock` fails),
     **or** the recorded walker is alive: the wrapper records the walker's pid
     and its start time (`ps -o lstart=`) beside the pgid, and the walker is
     alive when that pid's start time still matches (`events.py`'s `pid_alive`
     check) and its command contains `run-goals.sh` (the repo is the working
     directory, not on the command line, so it is not required). A wrapper killed by `SIGKILL`
     cannot clean up, but its walker is still found; a recycled id held by an
     unrelated process is neither running nor signalled by `STOP`. The supervisor adopts it: it polls each minute, and on `STOP` it signals
     the process group recorded in the lock file (`TERM`; the walker's own
     handling records the stop), whether it or an earlier supervisor started
     it;
   - **finished**: the walker is not alive and `result.json` exists for
     attempt `n`. It is acted on **once**: only when `acted_attempt` differs from
     `n`. The order is fixed: first the decider, when the class calls for it,
     answering into memory only; then **one state-file rename** that writes
     `acted_attempt = n` together with the outcome (`done`; `waiting` with
     `wait_until` and the new rate-limit timestamp; `held` with its class,
     reason and any new count, a `needs_human` answer included; or, for a
     rerun, the incremented count and `queued`); only then any message or
     dispatch. A crash before the rename acts again from the start; a crash
     after it never dispatches the attempt again. `exit` 0 with no stop file is a
     completed walk: the entry is `done` and the walk-end digest goes out (once,
     by the same rule). Anything else is classified (step 7) from the copy
     inside the result (run folders are pruned after 14 days);
   - **interrupted**: the walker is not alive and there is no result (a reboot,
     a kill): the entry holds `interrupted` (class A),
     acted on once by the same rule. A result from
     an earlier attempt is never read for attempt `n`, so an old stop cannot
     replay after a crash.

   **One supervisor**: an exclusive `fcntl.flock` on
   `~/.config/cw-always-on/supervisor.lock`, held for its life; a second exits.
   A supervisor restart therefore adopts a live attempt instead of losing it.
6. **Each turn**, in order: the kill file `~/.config/cw-always-on/STOP`
   (present: signal every running attempt as above, then idle); every entry's
   run state (step 5); a `waiting` entry whose `wait_until` has passed (by wall
   clock) is rerun; the spend ceilings (step 9); the first `queued` entry
   (never one for a repo with a running, waiting or held entry); its signature
   check (step 3); then a new attempt `n+1` (the number written to the state file
   first) running `run-goals.sh --jobs N` in that repo, with `ANTHROPIC_API_KEY`
   from the decider key file, `CW_ALWAYS_ON_LEDGER` (the switch for the
   walker's spend and kill-file check, step 9) and `CW_ALWAYS_ON_ENTRY` (the
   entry id), and every other `CW_*` and credential stripped as the launchers
   already do. A rerun is the same: a new attempt number, a fresh attempt
   folder.
7. **Reading a stop.** A single stop (`# Stop: <goal>` or `# Stop: walk`) gives
   one reason from its `- reason:` line. A `wave-stop` gives one reason per
   `- <goal>: <reason> — <file>` bullet under `## Stopped`, and nothing else in
   the file is read (its detail text names `finished-not-integrated` for every
   wave-stop). Then the reason is classified through a fixed table in the host
   (`scripts/lib/always-on-classes.tsv`, the user's classification, Q5, written
   in the walker's real tokens):
   - **A — the user** (security, integrity, contracts, the loop's own safety):
     every `*-tamper`, `secrets-in-checkout`, `proof-sandbox-unavailable`,
     `walk-branch-moved`, `git-lock-stray`, `git-replace-ref`,
     `orchestration-files-dirty`, `orchestration-files-changed`,
     `integration-goals-edited`, `integration-unverified`, `integration-dirty`,
     `dirty-tree`, `head-moved-during-review`, `gate`, `worktree-exists`,
     `serial-goal-in-progress`, `journal-unreadable`, `walk-stuck`, `trap`,
     `bounced-not-recorded`, `contract-drift`, `budget`, `always-on-stop`,
     `interrupted`, and an empty reason.
   - **B — the user** (contract questions): `bounced`, `implementer-blocked`,
     `blocked`, `blocked-oracle-edit`, `oracle-gap`, `done-refused`,
     `implementer-declined`, `reviewer-flagged`.
   - **C — retry or resume** (operational): `implementer-error`,
     `implementer-timeout`, `reviewer-error`, `reviewer-timeout`,
     `proof-timeout`, `proof-excerpt-error`, `commit-failed`,
     `result-write-failed`, `merge-failed`, `worktree-add-failed`,
     `worktree-setup-failed`; and **wait**: `rate_limited`,
     `reviewer-rate-limited` (step 10).
   - **D — recut once** (quality): `max-fix-rounds`, `proof-red`,
     `integration-red`, `merge-conflict`, `worktree-setup-dirty`, `empty-diff`,
     `missing-verdict`, `fix-unparseable`.
   - `finished-not-integrated` is not a stop: the rerun integrates it without
     dispatch, and it uses no count.
   - **Any reason not in the table is A.** And before the table: a stop whose
     detail line, or any stop file it names, carries a billing marker (step 7a)
     is A `budget`, whatever its reason.
   - One A or B among a stop's goals holds the whole entry.

   **7a. Billing markers** (case-insensitive; matched on the `- detail:` line of
   each stop file and in the raw output files that stop file names on its
   `LOG:` and `stderr:` lines, nothing else in the stop file; measured in step
   0d), and only in error output: the `stderr:` file always, the `LOG:`
   envelope only when it is an error envelope (`is_error` true or an
   `api_error_status` present), never a successful `result`, which may quote
   any text: `credits_required`, `requires usage credits`, `spend limit`,
   `spend_limit`, `billing_error`, `insufficient balance`,
   `enforced_spend_limit_reached`, `HTTP 402`, `status 402`. No bare `402`
   (hex shas contain it). Such a stop is never retried or waited on.
   `write_stop` in `run-goal.sh` names only the implementer's raw output on
   `LOG:` / `stderr:` today; a reviewer wake (any `reviewer-*` reason, and a
   mutations turn's) now puts that call's raw envelope and its `.err` (the
   `.wrap` file on a non-limit error) on those lines instead, so the scan sees
   the provider's sentence for both roles.
8. **C and D.** A `rate_limited` / `reviewer-rate-limited` stop is not
   decided: it is step 10's wait, then a rerun, with no decider and no C count.
   For the rest, per-goal action counts live in the state file (C: at most 2
   automatic actions per goal; D: one recut per goal; a goal past its count, or
   stopped a second time for a B-or-worse reason, is `NEEDS_HUMAN`). The count
   is incremented and the state file `fsync`ed **before** the rerun is
   dispatched, so a crash never rearms it; a missing or unreadable state file
   is A. Within the count the decider is asked (step 11); its answer is `rerun`
   (the walker's own rerun re-attaches finished goals and recuts stopped ones,
   which is what both retry and recut mean in parallel mode) or `needs_human`.
   Any other answer, an invalid one, or a decider that cannot be reached is
   `needs_human`. `NEEDS_HUMAN` holds the entry; the supervisor moves to the
   next entry it can walk (never one for the same repo).

### Limits and money

9. **Spend.** The ledger (`~/.cache/.../always-on/spend.jsonl`, append-only;
   every append and read under Python `fcntl.flock`, as `events.py` locks,
   since this Mac has no `flock` binary) holds **observations, not amounts**: one line
   `{"ts", "entry", "kind", "id", "cumulative_usd"}` each time a cost is seen,
   where `entry` is the queue entry id (`CW_ALWAYS_ON_ENTRY`: the same across
   that entry's reruns, new when a line is signed again), `id` is the thread or
   session the cost belongs to and `cumulative_usd` is that
   thread's or session's total so far, exactly as the provider reports it:
   - `run-goal.sh` (when `CW_ALWAYS_ON_LEDGER` names the ledger) appends one
     after each implementer pass (the thread's `IMPLEMENTER_COST_USD`,
     thread-cumulative; on a fallback pass also the primary thread's figure
     from `IMPLEMENTER_FALLBACK_FROM`), and one after each review and mutations
     turn (the session's `total_cost_usd`, from a new `CLAUDE_REVIEW_COST:` line
     `claude-goal-review.sh` prints; a resumed session reports its whole total);
   - the supervisor appends one per decider call (each its own session);
   - **a model turn killed before it reports** (an `implementer-timeout`,
     `reviewer-timeout`, a kill on `STOP`, a timed-out decider call): the
     `total_cost_usd` of any envelope that parses from the killed call, or when
     none parses its previous observation plus a fixed stand-in for that role
     measured in step 0h, recorded as an observation **of that call's own
     session or thread id**. A later pass that resumes the session reports its
     cumulative total, and only the rise over the recorded figure counts, so a
     killed turn is counted once.

   `scripts/lib/always-on-spend.py` derives the amounts at read time: for each
   `id`, its observations in time order, each contributing its rise over the
   previous one (the first contributes all of it; a fall contributes nothing),
   dated at that observation. Observing the same total twice therefore adds
   nothing, however many times a caller records it.

   Before each goal is spawned (in parallel mode, before each member of a wave)
   and before every dispatch and rerun, `scripts/lib/always-on-spend.py` sums
   the derived amounts of the rolling 24 hours (ceiling **$10**), of this
   entry, all its reruns included (**$20**: the rises whose `entry` is this
   entry's id; it binds only for an entry walked over more than a day) and of
   the rolling 7 days
   (**$50**). Over any, it writes `~/.cache/.../always-on/halt` and the walker
   stops `budget` (class A) before spawning; under all of them it unlinks a
   `halt` left by an earlier check, so a passing check clears it. Goals already
   running finish; each is bounded by `MAX_FIX_ROUNDS`, so the overshoot is at
   most the goals running at once (up to `jobs`). The same check reads the kill
   file: `STOP` present stops the walker `always-on-stop` before the next spawn.
   **The DeepSeek account balance is a backstop, never summed** (a top-up or
   other use of the account would distort it): before each walk the supervisor
   reads `GET /user/balance` with the same key files `claude-implement.sh`
   loads; below a floor (default $2) or an unreadable balance holds the entry A
   `budget`, and a missing key fails `doctor` before any walk. Provider
   backstops: a monthly cap on the API key in the Console (the user sets it),
   DeepSeek prepaid about a week. All three numbers are re-measured in the
   dogfood run (step 15).
10. **Waits.** `rate_limited` and `reviewer-rate-limited` wait to a reset time
    when the stop detail carries one (the launcher's own text, measured in step
    0d: `retry-after`, `resets <time>`), plus 60-120 s of jitter. Without a
    reset time it backs off 15, then 30, then 60 minutes, by the number of this
    entry's rate-limit stops in the last 24 hours; a fourth within 24 hours holds
    the entry A. **The wait is durable**: the entry's status becomes `waiting`
    with `wait_until` (an absolute wall-clock time) and the stop's timestamp
    appended, written before the wait begins; the supervisor compares `date`
    each minute, so a sleeping Mac does not stretch the wait and a restart
    resumes it exactly. A wait ends in a rerun with no decider and no C count. A billing
    marker is never waited on (7a).

### The decider (`scripts/claude-decide.sh`)

11. A launcher like the others, owning its prompt: `claude -p --model
    claude-opus-5-5 --effort xhigh` (high for `claude-fable-5-1`), no tools,
    `--permission-mode dontAsk --permission-prompts none`, the API key only.
    Input: one JSON packet the supervisor builds: the entry, the class and
    reason of each stopped goal, its action counts, the verdict labels, wave
    and goal counts, and a bounded tail of the walk journal. Stop-file details,
    journal text and reviewer findings are included only as quoted data marked
    untrusted; model names are left out (the decider and the reviewer are both
    Opus 5.5). Output: `{"action": "rerun" | "needs_human", "reason": "<one
    line>"}`, parsed strictly: the output must be exactly the single JSON object
    of the shape step 0c recorded, else `needs_human`. The call runs under
    `run-timeout.py` (default 10 minutes; `STOP` is read again when it returns);
    a timeout is `needs_human`. It never sees an exit the table does not allow
    and can change no gate, verdict or file.
12. **Records.** The reason (and the packet's hash, the action, the cost) goes
    only to `~/.cache/.../always-on/decisions.jsonl`. The target journal gets one
    fixed-shape line, `## <utc> — DECIDER <action>` (`action` from the two
    allowed), and nothing else: no model text reaches a journal the walker
    parses. The supervisor commits it with `GIT_TERMINAL_PROMPT=0`, the journal
    path only (`git commit -- <journal>`), and only when the tree is otherwise
    clean; a commit that fails (signing, a hook) holds the entry A
    `commit-failed`. `journal-merge.py` treats `DECIDER` headings as
    walker-only, so a goal cannot forge one. An `events.py` `decision` event
    carries action and cost. The user's `resume` / `skip` records have the same
    fixed shape: `## <utc> — ARCHITECT always-on <resume|skip>`.

### Reaching the user (notify-only)

13. **iMessage** from the host (`scripts/lib/notify.sh`, `osascript` to Messages,
    every field passed as argv and used through `quoted form of` / argv items,
    never spliced into script text; the recipient in
    `~/.config/cw-always-on/notify.conf`). A message carries only fixed fields:
    repo basename, entry id (short), class, reason code, the commands to run,
    counts and spend; never stop-detail text, findings, diffs or secrets. Sent
    on every hold, on every walk-end (the digest: goals done, decisions with one
    in five marked for a spot check, spend). **Remote Control push** as a
    convenience: the `walk` mod calls `PushNotification` with the same fixed
    fields on a stop or `NEEDS_HUMAN` event while an interactive session is
    open. Nothing replies.
14. **Heartbeat**: a second LaunchAgent (`com.cw.always-on.heartbeat`,
    `StartCalendarInterval` 09:00 local) runs `cw-decide.sh heartbeat`, which
    reads the state files and sends a daily message: alive when the
    supervisor's lock is held (between walks and during a wait, too), with the
    day's decisions and spend; "the supervisor is not running" when the lock is
    free (whatever attempts are running: a live attempt without a supervisor is
    still reported, with its entry). Silence on a day therefore
    means the Mac itself is off or asleep. **At the Mac**, `cw-decide.sh`:
    `status` (the queue, holds, each entry's last stop), `resume <entry>` (clears
    a hold and dispatches one rerun; on a hold at a goal's count cap it sets
    that goal's count to one below the cap, so the pre-dispatch increment lands
    on the cap and the user's rerun is the only extra one; refused when
    the signed paths of step 3 changed since the signature, as after any class B
    fix, telling the user to `sign` the new `HEAD`; refused on
    `serial-goal-in-progress`, printing the serial `run-goals.sh` command that
    finishes the goal, since always-on runs only parallel walks), `skip <entry>`, `sign`, `stop` / `start` (the kill file and the
    LaunchAgent), `doctor` (LaunchAgents loaded, the Mac on AC, auto-login, keys
    present, Messages reachable, the git signing check of step 0g).

### Install, tests, dogfood

15. `install.sh --always-on` writes both LaunchAgent plists and the
    `~/.config/cw-always-on/` skeleton but loads neither; `cw-decide.sh start`
    loads them (`launchctl bootstrap gui/<uid>`). SETUP.md documents the Mac's
    own setup (auto-login, `pmset -c sleep 0`, `autorestart 1`, lid open, the
    Automation permission, git signing for unattended commits). Tests: a new
    `always-on-test.sh` with stubbed `run-goals.sh`, decider and notifier, and
    real stop-file fixtures copied from the walker's own output: a `wave-stop`
    with its `finished-not-integrated` sentence beside an `implementer-error`
    goal (rerun) and beside a `bounced` goal (held); every class, the real
    tokens (`rate_limited`, `implementer-blocked`, `walk-stuck`, ...), an empty
    reason, an unknown reason; a billing marker in an `implementer-error`
    detail (held, never retried); the counts across a supervisor crash (no
    rearm); an attempt with neither a held lock nor a result (held
    `interrupted`, not redispatched); a second supervisor
    (refused by the lock); `STOP` mid-walk (the child's group stopped, held); the
    budget halt before a dispatch and inside the walker; a failed balance read;
    a supervisor killed while an attempt runs (the new one adopts it, polls it,
    and `STOP` still stops it); a wrapper killed by `SIGKILL` while its walker
    lives (still running, adopted, never a second attempt beside it); a
    completed walk (`done`, one digest, never held); one finished result polled
    for many minutes (acted on once: one timestamp, one count, one message); a
    review killed at $5 and resumed to $7 (counted $7); a supervisor killed
    between acting on a result and any later step (no second dispatch of that
    attempt); a recycled process-group id (not running, not signalled); a stop
    classified after its run folder was pruned (the billing marker still found
    in the copies, for a single stop and for a member of a `wave-stop`); a
    walker whose wrapper was `SIGKILL`ed (still running by its recorded pid and
    start time); a dead walker whose old group holds another process (finished
    or interrupted, never stuck); a crash during the decider call (acted on
    again from the start, no rerun persisted early); the wrapper's own exit
    (the walker `TERM`ed and waited for, its model calls stopped); a reboot during attempt n after an attempt n-1
    that stopped `rate_limited` (held `interrupted`, the old stop never
    replayed); a restart during a backoff wait (resumed at the same
    `wait_until`, the ladder and the 24-hour count kept); a timed-out review
    (its parsed cost, or the stand-in, in the ledger); each kind of signature
    drift, and `resume` refused after a class B fix until
    `sign`; a quoted or injected walk-start line in a decider reason never
    reaching the journal; a forged `DECIDER` heading from a goal refused; a quote
    in a stop detail never reaching `osascript`; the heartbeat during a walk and
    during a backoff wait (alive while the supervisor's lock is held); the
    observation ledger (a resumed review session observed at 1 then 3 adds 2; the
    same total observed twice adds nothing; a fallback's primary thread counted
    once); a reviewer spend-limit stop whose sentence is only in the reviewer's
    envelope (held); a hung decider (timed out, `needs_human`); `resume` at a cap
    (exactly one extra rerun);
    a stale `halt` cleared by a passing check; a four-goal wave whose spend
    crosses the ceiling (the next spawn refused); a spend-limit sentence only in
    the envelope a stop names (held); a hex sha containing `402` (not a billing
    stop); a `proof-timeout` whose successful envelope `result` quotes
    `billing_error` (stays class C); the $20 summed per entry across reruns and
    not across entries; concurrent appends from a wave (no torn line); a `rate_limited` stop (waited and rerun, no decider, no count);
    `resume` after a count cap (one rerun) and on `serial-goal-in-progress`
    (refused); `sign` on the house (refused).
    Plants for each. Then a **dogfood run**: one real queue entry on a small
    target (the rbtree DAG), to measure the spend per walk and per goal and tune
    the three ceilings.

## Key decisions & tradeoffs

- **Routing only (Q2).** The decider never re-judges code: a FIX stays a FIX, a
  DONE stays a DONE. Its whole vocabulary is `rerun` or `needs_human`. Most of
  what the user decided by hand becomes deterministic table lookups; the
  decider's judgment is spent on one question: try again, or call the user.
- **Always parallel mode.** The supervisor runs `--jobs N` (N ≥ 2) even for a
  chain DAG, because there a stopped goal is recut in its own worktree from the
  walk tip and nothing a stopped pass did lands on the walk branch unreviewed.
  In serial mode an automatic retry could inherit a stopped pass's commits
  (item 31). Cost: a worktree per goal and a join per wave.
- **API key, not Pro (Q1).** Clear under the terms for automation, no 5-hour
  windows starving the user's own sessions, a hard monthly cap. Cost: real
  per-token spend.
- **Opus 5.5 at xhigh (user).** Fable 5.1 needs usage credits on Pro. The same
  family as the reviewer; mitigated by routing only and leaving model names
  out of the packet.
- **A signed queue only (Q3).** The loop never invents work, never plans, never
  touches the house, never merges; a contract change needs a new signature.
- **Notify-only (Q4).** No reply channel to secure in v1; every human decision
  is made at the Mac. Cost: a held entry waits until the user is back.
- **A fixed table decides the class (Q5), unknown reasons and empty reasons are
  A, billing markers override the table.** The model never classifies a stop.
- **No model text in a journal.** The decider's reason lives only in the
  supervisor's own log; journal records are fixed-shape lines.
- **A rate limit without a reset time is retried on a capped backoff** (15, 30,
  60 minutes), not held at once: holding every limit would make always-on stop
  for routine throttling. A fourth within a day holds.
- **Run state from the world, not from memory.** Each attempt's wrapper holds
  a lock while it lives, records its walker's pid and start time, and leaves an
  attempt-numbered result when it ends. Any supervisor, a restarted one
  included, reads the state from those files and the live process table alone
  (step 5): running is the lock held or the recorded walker alive (`pid_alive`);
  finished is the walker gone with a result; interrupted is the walker gone with
  none. It adopts a live attempt and can never replay an earlier attempt's stop.
  Waits are durable state. Rounds 1 and 5 found holes in a design that kept the
  pid and a copied stop as the supervisor's own memory of a run; here nothing
  about a run is trusted unless the world still shows it.
- **Spend from observations, amounts derived at read time.** Callers record
  each session's or thread's cumulative cost as reported; the checker turns
  those into amounts (each id's rises). Rounds 2 and 3 each found a different
  double count in a ledger of increments; this shape cannot double-count by
  construction, whoever records what, however often.
- **The supervisor is a host script, not a Claude session.** Fresh context per
  decision; nothing grows for days.

## Assumptions

The ledger confirmed by the user (crucible, 2026-10-26), with sources:

1. Every deterministic gate keeps running in the host scripts; the decider only
   chooses among exits the scripts allow (house design; research takeaway 6).
2. Roles unchanged: Grok attacks plans and oracles, DeepSeek implements (Haiku
   fallback), Opus 5.5 reviews; the decider is a new separate role (CLAUDE.md).
3. The user owns Phases 0-3 with sign-off on each; always-on starts only after
   the plan and the oracles are signed (the user's request).
4. The decider takes over: the wake decisions, starting the next signed walk,
   and (by the table) the operational stops (run-goal skills; this session).
5. A Grok deadlock in Phase 2 stays with the user (Phase 2 is plan-making).
6. Hard stops enforced in code: the security and contract classes, sandbox /
   dotenv / network overrides, edits to oracles or the signed plan, budget
   ceilings, merges, a goal stopping twice, concealment, the decider disagreeing
   with a gate (the wake taxonomy; research §4).
7. A `NEEDS_HUMAN` exit (research: ImpossibleBench's flag option).
8. A LaunchAgent-run host supervisor, `caffeinate -is`, one fresh `claude -p` per
   decision, state in files (research §1).
9. The Mac logged in, on AC, lid open; auto-login for reboots; Claude Code
   pinned (research §1).
10. Headless calls with explicit `--permission-mode`, an allowlist (none, for
    the decider) and `--permission-prompts none` (research §1).
11. A kill file checked before every dispatch and decision (research §4).
12. Usage-limit waits by wall clock to the reset; never retry on credits or
    spend errors (research §2).
13. A local append-only spend ledger and ceilings, with provider backstops
    (research §2).
14. Notify-only; the user decides at the Mac (Q4; research §3).
15. Every decision journaled as `DECIDER`; digest and spot checks; approve rate
    tracked (research §4).
16. House work, in-session; plan files here (house convention).
17. Fable 5.1 needs usage credits on Pro (probe 2026-10-26); Opus 5.5 at high
    and xhigh needs none.
18. Unattended 24/7 use of Pro is a grey area under its terms; an API key is
    clearly allowed (research §2).

## Risks / open questions

- **iMessage under launchd** is unverified (Automation permission, a locked
  screen): step 0a. If it fails, the fallback is Pushover (the research's
  second choice), asked of the user.
- **Which launcher reads which key**: a Haiku fallback pass or the mutations
  turn could still reach the subscription login; step 0b measures each.
- **Billing text is only as good as step 0d**: the markers match the launchers'
  current text; a launcher whose wording changes could turn a billing failure
  into a class C retry. Bounded by the C count and the spend ceilings.
- **The decider adds little over the table** on many stops. Accepted: it is
  bounded, cheap per call, and its one judgment (try again or call the user)
  is where a human's pattern sense helped; the dogfood run measures how often
  it says `needs_human` against the table alone.
- **Parallel mode for chain DAGs** costs a worktree and a join per goal; the
  dogfood run measures it.
- **The walk ceiling ($20) is above the daily one ($10)**, so it binds only for
  a walk longer than a day; the user's numbers, re-measured in the dogfood run.
- **A walker killed outright** (`SIGKILL`, not via the wrapper) leaves the
  model calls it started running in their own sessions until their own
  timeouts (at most the implementer's 20 minutes), when `run-timeout.py` ends
  them. The attempt holds `interrupted` (class A) in the meantime, and the hold
  message tells the user to let those finish before `resume`.
- **A Mac that sleeps or reboots** pauses the loop; the heartbeat says so by its
  absence, and an attempt whose recorded walker is gone with no result holds
  the entry `interrupted` rather than redispatching (a walker still alive
  without its wrapper is adopted, step 5).

## Out of scope

- Remote approval from the phone (a later item on the same notifier).
- Fable 5.1 as the decider until credits are set up; cloud routines; more than
  one Mac.
- Any automation of Phases 0-3, of house work, or of merging a walk branch.
- The decider judging code, oracles or plans.
- Changes to the gates, the launchers' prompts or the walker's merge rules,
  beyond the spend and kill-file check before each spawn, `run-goal.sh`'s
  ledger observations (only with `CW_ALWAYS_ON_LEDGER`), a reviewer stop naming
  the reviewer's raw output on `LOG:` / `stderr:`, the `CLAUDE_REVIEW_COST:`
  line and `DECIDER` as a walker-only record.
