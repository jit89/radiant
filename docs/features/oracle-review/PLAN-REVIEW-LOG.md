# Plan Review Log: Oracle review and tiered satisfiability (Phase 3)
Phases 0-1 (recon + interrogation) complete — plan locked with the user. MAX_ROUNDS=5.

## Round 1 attempt — Grok (void, not counted)

Session b5b2a5bc-046a-429c-b3dd-1f8c38947602 ended `stopReason: cancelled` after 6 model calls: Grok called `run_terminal_command`, outside its read-only toolset, the call was refused, and the refusal ended the turn. The reply was only its 255-byte preamble, and `grok-review.sh` reported `GROK_REVIEW_RESULT: ok` with `VERDICT: MISSING`. House fix (outside this plan, journaled): the launcher reports any stop but `end_turn` as `error (turn stopped: <reason>)`, and both prompts name Grok's only tools. Covered by the new `scripts/tests/grok-review-test.sh`. Round 1 is rerun as a fresh session.

## Round 1 — Grok

I'll read the plan and the domain docs around it, then check the repo assumptions it depends on.The plan is not ready to implement. The tier check, the fork launcher, and the commit gate each disagree with the code they have to land in.

### 1. Tier 1 cannot see the trap it requires
The pass bar is that the oracle failed because a trap fired. That is the only check that would catch the cited harness bug (CTest `WILL_FAIL` ignoring `abort`). The language table it adopts from FUTURE-WORK item 5 stops at compile and collection: `pytest --collect-only`, `cargo test --no-run`, `go test -run '^$'`, `vitest list` / `jest --listTests`. None of those run a test body, so no trap fires. A Python stub that raises `NotImplementedError` is also a normal expected exception, so a test that expects it stays green.
**Fix:** Give each language a run command and the exact output that counts as the trap (signal, panic, or `NotImplementedError` traceback), and treat a green run or a collection error as a failed Tier 1.

### 2. The approved oracle is not the oracle that gets committed
Tier 1 runs before the review and is not repeated after Grok's edits. Tier 2 and Tier 3 run after the approved round and are allowed to change expected values. The commit gate then trusts the earlier verdict. Grok cannot rebuild, so an edit that stops compiling is invisible, and a Tier 2 correction never goes back through the review.
**Fix:** Re-run Tier 1 on the final oracle text, and reopen the review after any edit that follows an approved round.

### 3. The pin sweep and inline oracles fall out of the procedure
In `skills/to-goals/SKILL.md` §4, the pin sweep is a separate obligation, and its step 4 still requires a scratch fix that turns an existing test green. The new seven-step order never mentions the sweep, so the rewrite either drops pin handling or leaves that scratch rule in force. `oracle: inline` has nothing to build, while Tier 1 says every goal traps. Trap-stubbing an API that already exists makes a swept test die in old code, which meets "a trap fired" while the new assertion never runs. Stubs kept in a scratchpad outside the repo are also invisible to Cargo, Go, and a `tsconfig` that only compiles the module.
**Fix:** Keep the pin sweep, trap-stub only APIs that do not exist yet, skip the trap run for `oracle: inline`, and allow stubs in the worktree only if the commit check rejects every path except the intended files.

### 4. Fork and later rounds send the plan-revision prompt
In `scripts/grok-review.sh`, any `--resume` sends "I revised the plan. Re-review the file at PLAN.md". `--fork` is specified as `--resume <id> --fork-session --session-id <new>`, so it takes that branch. The oracle rubric is described only for the fresh prompt. The new tests check fork flags and, for fresh only, that the prompt names three paths, so they pass if round 2 reviews the plan. The fresh-prompt description also omits the sentence that the only tools are `read_file`, `grep_search`, and `list_dir`, which is what stopped the cancelled turn already logged for this feature.
**Fix:** Make fresh, fork, and resume each send an oracle prompt that names the oracles and that tool limit, and assert that text in all three dry-run cases.

### 5. The fork rule counts headings the log does not have, and the session id is not stored
The script forks only when the log contains exactly one `## Round ` heading. This feature's log already has `## Round 1 attempt — Grok (void, not counted)`, which matches, so one real round plus that line refuses the fork. A critique pasted under the round heading can contain the same prefix. The plan-attack session id is not a log field (crucible keeps it in the conversation), and this slice does not change crucible, so a later `/to-goals` has no id to pass. `--resume` of the plan id without `--fork` writes into the plan-attack session. Dry-run never executes the flag, so a CLI that rejects `--fork-session` still ships green. A second `--fork` stays allowed after an oracle round and opens a second session.
**Fix:** Record `Session: <uuid>` on each plan round, count only `^## Round [0-9]+ — `, refuse `--fork` unless that count is 1 and no `## Oracle round` exists, and have `install.sh --check` grep `grok --help` for `--fork-session`.

### 6. The Phase 3 commit leaves the tree dirty, so `/run-goal` refuses to start
The gate commits `GOALS.md`, the oracles, and the journal. Oracle rounds are appended to `PLAN-REVIEW-LOG.md`, which stays dirty. `run-goal.sh` rejects a fresh start when `git status --porcelain` shows anything except a status-only edit of `GOALS.md` (`working tree is not clean`). Tier 1 and Tier 2 artifacts (`__pycache__`, a stub left behind) hit the same gate, and an ignored file under `tests/acceptance/` is the `contract-tamper-ignored` case `GOAL-FORMAT.md` already names.
**Fix:** Include `PLAN-REVIEW-LOG.md` in that commit, run the checks with `PYTHONDONTWRITEBYTECODE=1`, and refuse to commit while any other path is dirty.

### 7. The three-round cap is spent on the wrong failures
The prompt hands Grok all of `tests/acceptance/`, including earlier weeks' green oracles. A result other than `ok` (`error`, `rate_limited`, `MISSING`) is not defined, so a cancelled turn can be arbitrated and consume a round, which is the void round already in this feature's log. An accepted `PLAN:` finding bounces to the crucible while the oracles are already on disk, and the spent rounds still count against `MAX_ORACLE_ROUNDS` after the plan is re-signed. Nothing in the tests checks that the prompt demands the `PLAN:` prefix. The tie-break lets the user override a missing approval, while the gate allows a commit only on approval, so the override has no commit path unless someone writes a fake approval line.
**Fix:** Limit the prompt to `oracle:` paths and the acceptance-edit list. Count only `GROK_REVIEW_RESULT: ok`. Reset the oracle rounds after a re-signed plan. Record a user override in the journal and commit on that record.

### 8. The glossary still forbids the role this slice adds
**Attacker** is a critic of a locked plan, and **Goal reviewer** says that role only attacks `PLAN.md`. The crucible docs-aware rule treats that collision as a stop. The plan adds three entries and leaves these two. `CLAUDE.md`'s role table is updated. The glossary definitions Phase 3 is told to enforce are not.
**Fix:** Extend **Attacker** to Phase 3 oracles, and state the boundary as "Grok never reviews implementer diffs".

### 9. Tier 3 has no bound
"Announced and time-boxed" names no duration and no size. The cost this plan is reacting to is an unbounded scratch of about 550 lines written by the most expensive model.
**Fix:** Default the box to 30 minutes, stop when it ends, and journal the unproven claims.

### 10. The timeout edit points at a line that is not there
`grok-review.sh` already says to run in the background. The string "Foreground timeout 600000 ms" is absent. `scripts/claude-goal-review.sh` says "Timeout 10 minutes (600000 ms)."
**Fix:** Drop that bullet so this slice does not edit the goal-reviewer launcher.

Always-fresh is the smaller design for findings 4 and 5. The log is already the artifact the plan trusts, and the fork path is the one that depends on an untested flag, an unpersisted id, and a heading count.

VERDICT: REVISE

### Architect's response

All 10 taken; each checked against the code and the skill it lands in.

1. Tier 1 cannot see its trap — taken: Tier 1 now **runs** the oracle (never collect-only), with a per-language pass bar (signal/abort, unique-message `NotImplementedError` traceback, runner failure text, panic); a green run, a build error or a collection error fails Tier 1; traps carry a unique message so a test expecting a generic exception cannot mistake it.
2. Approved ≠ committed — taken: any edit after an APPROVED round reruns Tier 1 on the file and re-enters the review; the gate is APPROVED of the final text.
3. Pin sweep / inline / existing APIs — taken: the sweep stays (step 1), its satisfiability moves onto the tiers; trap stubs only for API the plan adds, real code for existing API (red = assertion failure); `oracle: inline` skips the run but gets Tier 2; stubs may sit in the worktree only for the run and the commit check rejects leftovers.
4. Fork/resume send the plan prompt — taken: oracle mode has its own round-1 and re-review prompts, both naming the only tools; tests assert each.
5. Fork rule fragility — taken in Grok's simpler form: the fork is dropped, the oracle review is always fresh. The heading count already breaks on this log's void-round line, nothing stores the plan session id, and dry-run never exercises `--fork-session`. This narrows the user's Q1 answer (fork after a one-round attack); flagged for sign-off.
6. Dirty tree blocks /run-goal — taken: the commit includes the feature's `PLAN-REVIEW-LOG.md`; checks run with `PYTHONDONTWRITEBYTECODE=1`; `git status --porcelain` must show no other path before committing.
7. Cap spent on wrong failures — taken: the review covers this DAG's `oracle:` paths and Acceptance-edits files only; only `ok` results count (others are logged void and rerun); an accepted `PLAN:` bounce resets the count; the tie-break is a journaled user override the commit cites.
8. Glossary collision — taken: **Attacker** extended to Phase 3 oracles with the boundary "never reviews implementer diffs"; **Goal reviewer** wording corrected.
9. Tier 3 unbounded — taken: 30-minute default box (user may extend); on expiry stop and journal unproven claims.
10. Absent timeout line — taken: the bullet is dropped; the line was already rewritten by this crucible's launcher fix, and `claude-goal-review.sh` stays out of scope.

## Round 2 — Grok

I'll re-read the revised plan and check it against the earlier findings and the code those findings cited.Prior findings 3, 4, 5, 8, 9, and 10 are covered. Findings 1, 2, 6, and 7 are only partly covered, and the fixes open three new holes.

### 1. The commit check cannot see the files it names
Step 8 tells the Architect to run `git status --porcelain` and to treat a clean result as "no `__pycache__`, nothing ignored under `tests/acceptance/`". Porcelain omits ignored paths. `run-goal.sh` `contract_drift` then lists those paths with `git ls-files --others --ignored --exclude-standard` and wakes `contract-tamper-ignored` after the implementer has already run. `PYTHONDONTWRITEBYTECODE=1` avoids the usual bytecode case only when every tool honors it. The hint in `contract_ignored_hint` exists for the tools that do not.
**Fix:** Fail the commit on any `!!` path from `git status --porcelain --ignored=matching` under `tests/acceptance/`, the oracle paths, and the plan path, and on any other porcelain path outside the allow-list.

### 2. A stale approval at the cap cannot be repaired or overridden
Step 7 sends an oracle edited by Tier 2, Tier 3, or a Tier 1 rerun back through review "within the cap". Step 8's user override runs only "at the cap without APPROVED". The approving round can be round 3. The edit then invalidates that approval, the cap allows no counted round, and the override does not apply. The gate forbids committing that stale approval.
**Fix:** Treat a stale approval as not approved, and when the confirming round would exceed `MAX_ORACLE_ROUNDS`, take the journaled override path.

### 3. Void reruns include rate limits and have no ceiling
An `error`, `rate_limited`, or `MISSING` result is "logged as void and rerun", and only `ok` increments the cap. README and `CLAUDE.md` say a rate limit stops with no retry. A reply that never parses as a single verdict stays `MISSING` forever, so the cap never moves. Both oracle prompts, as specified, also omit the closing verdict line `verdict.py` requires, and the new tests do not assert it.
**Fix:** Stop on `rate_limited`. Require both oracle prompts to end the reply with one `VERDICT: APPROVED` or `VERDICT: REVISE` line, assert that in the dry-run, and stop after two void results.

### 4. Tier 1 still does not run the harness that failed on uregex
The pass bar is "a green run fails" and "the trap's signal or abort message", while the run command is left to a future `GOAL-FORMAT.md` table. The cited defect is CTest `WILL_FAIL` not counting a signal abort. A direct run of the test binary shows the abort and clears the bar, while the goal's `proof` command is what the host will execute. On a file that also holds a later goal's red edit, any `AssertionError` clears the bar, including one from the other goal. The "tiny experiment" for registration and sanitizer traps still has no required result.
**Fix:** Run each goal's `proof` command. Require a nonzero exit whose failure is this goal's new assertion or the unique trap message, and use that same command for the one-case abort probe.

### 5. Round 1's file list is not a command the script can run, and later rounds drop it
The script must name every `oracle:` path and every Acceptance-edits file, and exit 2 when a listed file is missing. `GOALS.md` is still created in today's §5, after §4, and step 4 never says to write it first. `oracle: inline` is not a file, so treating it as a missing path exits 2 on every no-harness repo. Acceptance-edits paths live in prose. `goals.py` only extracts `tests/acceptance/` paths from **Edits owned** (`ACCEPTANCE_PATH_RE`), which are the paths that must not be reviewed as oracles. The resume prompt is specified only as "I revised the oracles…", and the tests require the file list only on round 1, so round 2 can wander into earlier weeks' oracles.
**Fix:** Write `GOALS.md` before Tier 1. Parse `oracle:` values other than `inline`, plus `tests/acceptance/` paths in the Acceptance-edits section. Exit 2 on a missing `GOALS.md`, an `inline` path treated as a file, or an edits section with no parseable path. Repeat the in-scope list in the resume prompt and assert it.

### 6. A revised plan cannot be committed and blocks the oracle commit
`run-goal.sh` dies at the gate until the `plan:` path is in `HEAD`. Step 8's allow-list is `GOALS.md`, the oracles, the swept edits, the journal, and the feature log. After a `PLAN:` bounce the re-signed `PLAN.md` is dirty, so the porcelain rule forbids the oracle commit, and the allow-list forbids adding the plan to it. The same deadlock holds when sign-off never committed the plan, which crucible does not require.
**Fix:** Commit the signed plan in its own commit before the oracle commit, and keep that path on the clean-tree allow-list.

VERDICT: REVISE

### Architect's response

All 6 taken, plus a user decision on step order.

1. Porcelain hides ignored files — taken: the commit check runs `git status --porcelain` (no path outside the allow-list) and `git status --porcelain --ignored=matching` (no `!!` under `tests/acceptance/`, an oracle path, or the plan path).
2. Stale approval at the cap — taken: a file changed after APPROVED makes the approval stale; a confirming round past the cap takes the journaled user-override path.
3. Void reruns — taken: `rate_limited` stops the review (house rule, no retry); `error`/`MISSING` rerun at most twice in a row, then stop and go to the user; both oracle prompts require the closing `VERDICT:` line, asserted in tests.
4. Tier 1 must run the harness — taken: Tier 1 runs each goal's `proof` command; pass bar is a nonzero exit showing this goal's assertion or the unique trap message; another goal's failure, a zero exit, a build or collection error all fail it; the harness probe goes through the same command.
5. File list not runnable — taken: `GOALS.md` is drafted first (step 1); the list is non-`inline` `oracle:` values plus `tests/acceptance/` paths parsed from Acceptance-edits sections only (not Edits owned); exit 2 on no GOALS.md, a missing path, or an unparseable edits section; the re-review prompt repeats the list; tests assert all of it.
6. Uncommitted plan blocks the oracle commit — taken: step 0 commits the signed plan and log on their own before Phase 3 and after any re-sign; the clean-tree check treats the committed plan as allowed.

User decision (between rounds 2 and 3): the order is Tier 1 → Tier 2 (→ Tier 3) → self-review → Grok oracle review → re-check changed files → commit, so deterministic evidence comes first and the independent model last. Recorded under Key decisions with its cost (Tier 3 work can be wasted if the review changes a case).

## Round 3 — Grok

I'll re-read the revised plan and check the earlier findings against the code they depend on.Round-2 findings on ignored files, the stale approval, rate limits, the verdict line, and writing `GOALS.md` first are covered. Four holes are still open, and the new pass bar adds one.

### 1. The Acceptance-edits parser treats `file:line` as a filename
`GOAL-FORMAT.md` still requires **Acceptance edits** to be written `file:line, old → new`. The house pattern `ACCEPTANCE_PATH_RE` stops at a comma and keeps the colon, so `tests/acceptance/g1-store.test.ts:40` is the token. The script then treats a missing listed path as exit 2. The new tests only require that "a path" is included, so a fixture without a line number stays green.
**Fix:** Strip a trailing `:line` or `:line:col` before the existence check, and cover `file:line` in the dry-run fixture.

### 2. A C trap message never reaches the proof output
The pass bar for stubbed code is a nonzero `proof` exit whose output contains the unique message, and the C stub is `abort()` after printing it. CTest captures the test through a pipe, so stdout is fully buffered, and `abort()` does not flush stdio. The message is gone, the exit is nonzero, and Tier 1 fails on every C oracle. That is the same harness the uregex evidence is about.
**Fix:** The C/C++ stub writes the message, `fflush`es stdout and stderr, then `abort`s. The language note says the pass bar reads that flushed line from `proof`.

### 3. Tier 1 never runs a swept file that `proof` excludes, and a trap hides a later assertion
Proof composition keeps a file that still carries a later goal's red edit out of this goal's `proof`. Step 2 runs only that command, while the key decisions say Tier 1 is mandatory for swept edits. The pass bar is this goal's assertion **or** the trap message, so a mixed file that aborts in a stub passes even when the new assertion never runs.
**Fix:** Run every Acceptance-edits file the `proof` command skips, and require this goal's new assertion in the output when the file has one. A trap message alone passes only for a file whose cases do not reach an assertion.

### 4. A passing Tier 1 is not part of the commit, and review-loop edits skip it
Steps 5 and 6 are sequential. Oracle fixes inside the capped loop are re-run through `proof` only after the review ends. The gate then commits on a current approval. A Tier 1 or Tier 2 failure on that text forces an edit only if someone decides it does. After a `PLAN:` re-sign the count returns to zero, and the resume prompt still says the oracles were revised, in the session that read the old plan.
**Fix:** Re-run Tier 1 and Tier 2 before the next `--oracle` round and again on the approved bytes. Block the commit while either bar fails. Start a cap reset with a new session after those tiers, and record the final results in the decompose checklist.

### 5. The clean-tree rule still lets a dirty plan through
Step 0 commits the plan, then step 7 allows porcelain paths in the commit set "plus the already-committed plan". The commit itself lists `GOALS.md`, the oracles, the swept edits, the journal, and the log. A dirty `PLAN.md` passes the check and stays dirty. `run-goal.sh` still rejects that path on a fresh start.
**Fix:** A dirty plan path fails the check. Step 0 is what keeps it out of porcelain.

VERDICT: REVISE

### Architect's response

All 5 taken.

1. `file:line` read as a filename — taken: a trailing `:line` / `:line:col` is stripped before the existence check; the test fixture writes `file:line`.
2. C trap message lost on abort — taken: the C/C++ stub writes the message, flushes stdout and stderr, then aborts (CTest captures through a pipe).
3. Swept files outside proof; a trap hiding an assertion — taken: Acceptance-edits files the proof skips run on their own; where a file has this goal's new assertion, that assertion must show in the failure; the trap message alone passes only for a file whose cases cannot reach an assertion first.
4. Tiers skipped inside the loop; stale session after a re-sign — taken: changed files rerun Tier 1/2 before each next round; Tier 1/2 run once more on the exact bytes to be committed and a failure blocks the commit; a `PLAN:` re-sign starts a new fresh session.
5. Dirty plan passes the check — taken: a dirty plan path fails the clean-tree check.

## Round 4 — Grok

I'll re-read the revised plan and check the last round's findings against the code they still depend on.Round-3 items are in the text. The assertion rule that was added makes Tier 1 impossible for a stubbed oracle, and two smaller holes sit beside it.

### 1. A stubbed oracle cannot show the assertion Tier 1 now requires
The pass bar still says a nonzero `proof` exit plus this goal's assertion (existing code) or the trap message (stubbed code). The next bullet says the trap message is enough only when the cases cannot reach an assertion, and that a trap that fires first hides an assertion that never ran. A new oracle calls the stub, then asserts. The stub aborts or raises on that call, so the assertion is not in the output. Tier 1 fails for every stubbed file. Requiring the assertion in the output and trapping before the assertion cannot both hold.
**Fix:** For stubbed code, the bar is a nonzero exit and the trap message, and the source of the test must contain this goal's assertion after the call. For existing code, the bar is that assertion in the failure output. A build error, a collection error, a zero exit, or a failure that is neither the trap nor that assertion fails the tier.

### 2. The extra file run is a different harness, and a later edit in the same test hides this goal
Acceptance-edits files left out of `proof` are run with "the project's test command," so a CTest `WILL_FAIL` or registration bug on that file is not the command the host will run. Those files contain a later goal's red edit by construction. Step 1 applies every edit before any Tier 1 run. In one test, the later assertion fails first and this goal's assertion never runs, so the new "assertion must show" rule cannot pass on the final bytes.
**Fix:** Run the excluded file with the same runner as `proof`, filtered to this goal's case. A later goal's failure in another case does not fail this run. Keep later goals' edits in separate tests.

### 3. Worktree stubs are still on disk for the Grok round
Stubs for Cargo, Go, and a module-only `tsconfig` sit in the worktree and are "deleted after" the Tier 1 run. Step 5 runs Tier 1 again before the next round, which puts them back, and nothing deletes them before `grok-review.sh --oracle`. Grok can read the trap body, so an invented symbol looks real. The commit check only runs at step 7.
**Fix:** Delete worktree stubs before every `--oracle` launch. Plan-driven edits after a re-sign are part of the pre-round Tier 1 and Tier 2, not only fixes from the previous Grok round.

VERDICT: REVISE

### Architect's response

All 3 taken.

1. Stubbed oracles cannot show their assertion — taken; the contradiction was introduced in round 3. Pass bar by case: stubbed API → nonzero exit with the trap message, and the source shows this goal's assertion after the call (read, since the trap fires first by design); existing API → this goal's assertion in the failure output.
2. Different harness, mixed cases — taken: excluded Acceptance-edits files run through the same runner as `proof`, filtered to this goal's case; authoring rule that each goal's swept edit is its own test case.
3. Stubs readable by Grok — taken: worktree stubs are deleted before every `--oracle` launch; pre-round tiers cover plan-driven edits after a re-sign too.

## Round 5 — Grok

I'll re-read the revised plan and check the last round's findings against the parts of the repo they still depend on.The three round-4 findings are in the plan and no longer contradict each other. The plan is sound enough to implement.

The stubbed pass bar is a nonzero exit plus the trap message, with this goal's assertion read from the source. The existing-API bar is that assertion in the failure output. A zero exit, a build error, a collection error, or any other failure fails the tier. An excluded Acceptance-edits file uses the same runner as `proof`, filtered to this goal's own case, and each swept edit is its own test. Worktree stubs are deleted before every `--oracle` launch, including after a pre-round Tier 1 that covers a re-signed plan. Step 6 runs the tiers again on the commit bytes and blocks the commit on a failure. A dirty plan path fails the porcelain check, and ignored files under `tests/acceptance/`, an oracle path, or the plan path are rejected with `--ignored=matching`.

VERDICT: APPROVED

### Resolution

Converged: APPROVED in round 5 of 5 (plus one void attempt). 29 findings across rounds 1-4, all taken. Awaiting user sign-off.
