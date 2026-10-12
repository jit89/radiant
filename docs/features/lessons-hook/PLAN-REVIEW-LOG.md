# Plan Review Log: Lessons hook
Phases 0-1 (recon + interrogation) complete — plan locked with the user. MAX_ROUNDS=5.

## Round 1 — Grok

I'll read the plan and the domain docs around it, then check the repo assumptions it depends on.The plan is not safe to implement as written. The distil command can execute untrusted transcript text, the injection hook it depends on is not the hook this install actually has, and the incremental extractor drops the failures it is supposed to count.

1. **Distil is an unsandboxed `claude -p` of untrusted tool output, and the flags that are supposed to cage it are not the ones Claude Code 2.1.296 documents.** `--no-session-persistence` appears nowhere in that changelog. An unknown flag makes every distil exit, and the "second failure on the same range advances anyway" rule then skips that transcript range for good. `--tools ""` is not the documented control; `--restricted` / `CLAUDE_CODE_RESTRICTED` is, and it still leaves file tools in the working directory. The plan sets that directory to the lessons cache and does not pass `--permission-mode`, `--max-budget-usd`, or the credential-env scrub `claude-implement.sh` uses. The house launchers pass the prompt as the `-p` argument and point stdin at `/dev/null`, while this plan puts the digest on stdin and also assumes a separate fixed prompt. `--output-format json` returns an envelope (`result` text plus `total_cost_usd`, as `agent-result.py` parses); a schema check of the raw stdout rejects every real reply. The tests stub `CW_LESSONS_CLAUDE` and only assert argv, so they stay green while the real CLI fails open or fails closed. Fix: one prompt body on `-p`, parse the envelope, pass `--safe-mode --restricted` with a tool set that cannot run commands or write, scrub the environment, set a budget, and leave the offset unmoved on exit, timeout, or rate limit.

2. **The system-prompt hook the plan is built around is not in this install.** Assumption 4 names `prompt.compose`, `session.compact`, and `session.end`. None of those strings are in the 2.1.296 changelog or in the installed mods (`walk` uses `session.start` / `command.run`; `code-modernization` uses `tool.call` and `prompt.submit`). `prompt.submit` appends `e.context` to that single message, which is the per-message path Q1 rejected because it accumulates in history and would re-enter the extractor. Classic `PreCompact` and `SessionEnd` already carry `transcript_path`. The 1.5 s figure is `CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS` for classic SessionEnd hooks, a different runtime from the long-lived plugin worker. `tool.call`'s `isError` is on the value returned by `next()`, and subagent calls set `agentId`. Fix: cite the type declaration for a session-scoped section, or hook `classic.PreCompact` and `classic.SessionEnd` for the path and inject only through a hook that does not append to every message; count `next().isError` and ignore calls with `agentId`.

3. **Incremental reads miss the join, and large failures collapse into one signature.** A `tool_use` sits on an earlier assistant `content[]` block; the `tool_result` (`is_error`, `tool_use_id`) arrives later inside a user message. Bytes after the stored offset often contain the result and not the command, so `timeout` / `sed` / zsh failures never grow a signature. On this machine's own transcript, a big result is a `<persisted-output>` stub whose first line is "Output too large", with the body under `tool-results/`. The plan signatures that header and never opens the spill file. A non-blocking per-transcript lock that exits 0 also drops the tail when `session.end` fires during the 120 s distil and nothing reschedules. Fix: keep a bounded map of unmatched `tool_use` id to program in the state file, signature spilled files after redaction, and have the lock holder re-read until the file stops growing before it exits.

4. **The store lock does not cover the files it replaces.** `flock` on a JSON file that is then `rename`d locks the old inode. `render` rewrites those files (30-day drop) and is not listed as taking the lock, while two sessions of one project are in scope. Offset, counts, and pending are separate files, and a crash between them duplicates or skips lessons. Pending dedupe is specified only against approved signatures. `approve N` is a shifting index under the cap of 20. Fix: hold one flock on a stable lock file across the read-modify-rename of all three files, commit the offset last, dedupe pending by signature, and approve by a stable id.

5. **`lessons@claude-coding-workflow` cannot be installed from the manifest the plan points at.** `.claude-plugin/marketplace.json` lists only `walk`. `install.sh`'s update path (`walk_copy_current`, the version-bump warning) is hardcoded to `walk@claude-coding-workflow`. Assumption 3 cites `install.sh:106-127`, which never edits the manifest. Fix: add a `lessons` plugin entry whose `source` is `./mods/lessons`, and give it the same install-and-update check walk has.

6. **The correction rule treats ordinary prompts as corrections.** "Starting with no" matches "Now", "Note", and "Nothing". Those prompts are sent to Haiku at count ≥ 1 and evict real items from the pending cap of 20. `approve N` with no scope word is unspecified while Haiku is allowed to propose `global`, so one approval can install a cross-project system instruction. The denylist does not cover `python -c`, `osascript`, `$(...)`, or backticks, and `/lessons edit` skips it. `pending` is not required to show the redacted evidence. Fix: match those words as whole tokens and only after an `is_error`; default approval to project; run the same denylist on edit; print the untrusted evidence next to each pending lesson.

7. **Redaction misses the forms transcripts actually use, and the run log is the spill.** `NAME=value` does not cover JSON `"api_key": "…"`, `export`, or a dumped `.env`. Invalid model text is logged in full under `~/.cache/claude-coding-workflow/lessons/`, whose mode the plan never sets (`cache.sh` only makes `runs/` and `grok/` 0700). There is no per-day cost cap, so a fail loop launches a distil every fifth error. Fix: redact those key shapes, create the log dir 0700 and the files 0600, log the drop reason and evidence id only, and persist a daily USD cap that coalesces triggers.

VERDICT: REVISE

### Architect's response

Taken in part (6) or in full (1); rejected the claims checked false against the installed build:

1. **Distil cage — taken, except two claims.** Prompt now on `-p` with stdin `/dev/null`; added `--restricted --strict-mcp-config --permission-mode dontAsk --max-budget-usd 0.05`; empty 0700 cwd; env scrubbed like `claude-implement.sh`; the `--output-format json` envelope is parsed (`result`, `total_cost_usd`, `is_error`); CLI failures never move the offset (the advance-on-second-failure rule now applies only to a parsed-but-invalid reply); the stub returns a real envelope and the live check proves the real CLI takes every flag. **Rejected:** "`--no-session-persistence` is undocumented" and "`--tools ""` is not the control" — both are in `claude --help` for 2.1.296 (lines 142 and 254–255, "Use \"\" to disable all tools"); the changelog is not the CLI's reference.
2. **Hooks — rejected in the main, taken in detail.** `prompt.compose`, `session.compact` and `session.end` are declared in this build's engine type file (`claude-code.d.ts:8329`, `:4390`, `:4434`; `PromptComposeResult.sections`, `shared`/`session` sides of the cache boundary); the changelog and other installed mods are not where the API is listed. Now cited in Assumption 4. Taken: triggers prefer `classic.PreCompact` / `classic.SessionEnd` (they carry `transcript_path`) with the mod events as fallback, and that is a build-time check in Risks; `tool.call` counts `(await next(e)).isError` and ignores `agentId` calls.
3. **Extraction — taken.** Bounded unmatched `tool_use` map in state; `<persisted-output>` spill read from `tool-results/` (path confined; 7 such stubs measured in this session); a held run lock leaves a `rerun` marker and the holder loops until the file stops growing (≤ 3).
4. **Store — taken.** One never-renamed `.lock` across every read-modify-write including `render`; pending, counts, unmatched map and offsets in one project file committed by one `rename`; ordered two-file write for global approval with dedupe as repair; dedupe against pending and approved; stable ids (`L` + 6 hex).
5. **Marketplace — taken.** `marketplace.json` gets a `lessons` entry; `install.sh`'s mod install/update/copy check loops over both mods.
6. **Corrections and approval — taken.** Whole-token match, only after an assistant tool call; `approve` defaults to project; edit runs the denylist; denylist widened (`python -c`, `osascript`, `eval`, `$(`, backticks, `base64 -d`, `sh -c`); `pending` shows the evidence marked untrusted.
7. **Redaction and spend — taken.** Export, `.env`, JSON and YAML key shapes; log dir 0700 / files 0600 via `cw_cache_init`; the log holds counts, reasons and ids only; daily cap 0.25 USD plus a 10-minute per-project throttle that coalesces triggers.

## Round 2 — Grok

I'll re-read the revised plan and check it against the earlier findings and the repo.The type file is on disk. I'll check the cited lines and the distil flags against it.The revision covers the marketplace entry, the stable lock and ids, the spill-file join, the denylist, and the distil envelope. Four behaviors in the new text still drop or mis-apply lessons, and the detach path still does not match `$.process.run`.

1. **A forked child that still holds `$.process.run`'s pipes is not a process the command has let go of.** `process.run` reads stdout until EOF and waits out a background writer (default timeout 30 s). `SessionEndInput` gives the whole `session.end` chain one 1.5 s bound, then aborts a `$` call still in flight; only a process the command has already released outlives it. The plan redirects stdio to a log and exits the parent at once, and never closes the inherited pipe ends or waits until the child has called `setsid`. The "< 1 s" test does not use a pipe and does not kill the starter's process group. Fix: in the child, `setsid`, dup the log onto stdio, close the inherited pipe ends, then signal the parent to exit; assert the pipe hits EOF within 1 s and the child is alive after the starter's process group is killed.

2. **The 10-minute throttle swallows the trigger it was meant to coalesce.** A trigger inside the window does not set the `rerun` marker; that marker is only for a held run lock. `session.end` during the window, or during the 120 s distil if the throttle is checked before the lock, exits with nobody left to catch up. Each `run` is a new process, and the plan never stores the window. Fix: persist `last_run_at` in the project file, record a due marker for every throttled trigger, have the lock holder honor it, and let `session.end` bypass the window.

3. **Hitting the daily cap counts the range and then forgets its text.** At the cap the run still extracts and counts, and the offset is committed with that store write. The redacted command and error lines are not stored with the count, so the next under-cap digest is built only from bytes after that offset. Signatures that reached 2 on a capped day never reach Haiku. Fix: when distil is skipped, leave the offset put and keep each signature's redacted payload so a later run sends every undistilled signature with count ≥ 2.

4. **`prompt.compose` replaces the system prompt if it does not call `next`.** `PromptComposeResult` says a hook that never calls `next` answers the whole list, and a `shared` section placed after a `session` one skips the hook. A plugin section id is `<plugin>:<name>`; a bare id is the engine's. The plan says "append" and the plugin test only checks that the lessons section appears. Fix: append `{ id: "lessons:approved", text, scope: "session" }` to the `sections` from `await next(e)`, and fail the plugin test if an engine section is missing.

5. **A fenced array is the malformed reply that advances the offset.** Lessons are parsed from the envelope's `result` text, and a parsed reply with no valid JSON array is retried once and then skipped. The stub is specified as a raw envelope, so a ` ```json ` fence, which is how this model usually returns JSON, fails the schema twice and drops the range. Fix: read the first JSON array in `result`, unwrapping one fence, and cover that shape in the stub test.

6. **`/clear` keeps mining the transcript that just ended.** `SessionEndInput` says `reason: "clear"` continues the process under a new session id and does not fire `session.start`. The path for the 5th-error trigger is captured at `classic.SessionStart`, with no rule for a later `SessionStart` whose `source` is `clear`. Fix: on every `classic.SessionStart`, including `clear`, replace the transcript path and zero the error count.

7. **Correction tokens are case-sensitive, and the transcript shape is still implicit.** The tokens are the lowercase words `no` and `don't`; the positive test is `"no"`. A prompt that starts with `No` or `Don't` is not a correction. `tool_result` / `tool_use` are still not located: on disk they are blocks in `message.content[]` of a user row and an earlier assistant row, not row types. Fix: casefold the first token, accept `No,` and `Don't` in the tests, and read those two block types.

VERDICT: REVISE

### Architect's response

All 7 taken.

1. **Detach.** The child `setsid`s, dups the log onto fds 0–2, closes every other inherited fd, then signals the parent over a private pipe to exit; the test runs `run` with stdout on a pipe, asserts EOF and exit within 1 s, and that the child survives a kill of the starter's process group.
2. **Throttle.** `last_run_at` persisted per project; every trigger leaves a due marker first; the lock holder and the next session's start (`run --due`) honour it; `--final` (session end, including `/clear`) bypasses the window.
3. **Daily cap.** Capped runs keep each signature's redacted evidence (≤ 50) in the project file; later digests draw from every undistilled signature with count ≥ 2.
4. **`prompt.compose`.** Always `await next(e)`, append `{ id: 'lessons:approved', scope: 'session' }` last; the plugin test fails if any engine section is lost.
5. **Fenced JSON.** First JSON array in `result`, after unwrapping one fence; tested.
6. **`/clear`.** Every `classic.SessionStart` (including `source: 'clear'`) replaces the path and zeroes the count; `session.end` with `reason: 'clear'` runs `--final` on the old transcript.
7. **Corrections and shape.** First token casefolded, trailing punctuation trimmed, curly apostrophe accepted; the on-disk block locations of `tool_use` / `tool_result` stated.

## Round 3 — Grok

I'll re-read the revised plan and check it against the last round of findings.I'll re-read the revised plan and the prior review log, then check only the repo spots the new text depends on.The revision covers the earlier seven items on paper. I'll check the new detach, due-marker, and digest rules against the engine types and the cache helper they depend on.Round-2 items 1, 2, 4, 5, 6, and 7 now match the engine: `$.process.run` holds the pipe until EOF, `prompt.compose` must `await next(e)` and append a trailing `session` section, `/clear` is `session.end` with `reason: "clear"` and no `session.start`, and classic hooks carry `transcript_path`. Item 3 is only half closed. The new detach and due-marker text adds two more holes.

1. **A capped run still loses corrections, and nothing records that a signature was distilled.** Evidence kept at the cap is the command, the error lines, and the count (≤ 50, oldest dropped). A correction is a prompt and is sent at count ≥ 1, while the recovery digest is defined as undistilled signatures with count ≥ 2. That same store write commits the offset, so those prompt bytes are not read again. Nothing marks a signature distilled after a digest that contained its evidence id returns a parsed array, so later runs rebuild from the same rows; the 8 KB rule drops the oldest of that slice, the newest slice is resent until `cap_usd_day`, and the omitted rows age out of the 50. Fix: store the redacted correction prompt on the signature, leave it undistilled until a distil that included its evidence id returns a parsed array, pack each digest oldest-first, and mark only those ids distilled.

2. **The one-retry rule for a bad reply has no field to live in.** A parsed envelope with no JSON array is retried once on the next run, and the second time the offset advances. `projects/<K>.json` holds pending, counts, the unmatched map, offsets, evidence, and `last_run_at`, and each `run` is a new process, so every poison reply takes the first branch and is distilled on every unthrottled trigger until the daily cap, then again from the stored evidence. Fix: persist a per-transcript malformed count beside the offset and advance only when that stored count is already 1.

3. **The child closes the fd that is supposed to release the parent.** After `setsid` and the dup onto fds 0–2, it closes every other inherited fd, then signals the parent on a private pipe. That write end is inherited, so it is in the close set. The parent still holds its own write end, reads nothing, and does not exit; `$.process.run` keeps stdout until its 30 s timeout, past the 1.5 s `session.end` bound, and the new "EOF within 1 s" test fails. Fix: leave the signal write fd out of the close, write one byte, then close it, and have the parent close its write end before it blocks on the read.

4. **A due marker outlives the run that caught up.** Every trigger touches `due/<session id>`, and `session.start` runs `run --due` for every marker of the project. No step removes the marker after extract and store, so the next session start outside the 10-minute window runs every transcript that was ever throttled. Fix: unlink the marker when the holder finishes a pass that saw no touch newer than that pass, and leave it when a trigger retouched it.

VERDICT: REVISE

### Architect's response

All 4 taken; findings 1 and 2 by a redesign rather than patches.

1+2. **Evidence queue.** Extract now writes every signal (failures and corrections) into a persisted evidence queue and commits the offset with it; distil reads the queue, never the new bytes, so neither the cap nor a failed distil can lose a range. Digests pack eligible entries oldest first to 8 KB; a parsed array marks exactly the ids it carried `distilled`; a malformed reply increments a persisted `malformed` count on the ids it carried, dropped at 2; a CLI failure changes nothing. A distilled signature is re-sent only if it produced no lesson and its count has doubled.
3. **Release pipe.** The child keeps the release pipe's write end out of the close set, writes a byte and closes it; the parent closes its own write end before reading.
4. **Due marker.** Unlinked when a pass ends with no retouch since it began.

## Round 4 — Grok

I'll re-read the revised plan and check it against the last four findings.The four round-3 findings are in the plan. The release pipe stays open until the byte is written and the parent drops its write end before reading. A finished pass unlinks the due marker unless it was retouched. Extract commits failures and corrections onto an evidence queue and distil reads that queue. A parsed array marks exactly the packed ids `distilled`, and a reply with no array bumps a persisted `malformed` count that drops the entry at 2.

Two holes in that new queue rule will still lose or re-bill a range.

1. **The test list contradicts the offset rule.** Step 6 commits the offset with extract, and a CLI failure, timeout, or `is_error` envelope leaves that commit alone. The test list still says those three leave the offset unmoved, and that a CLI failure leaves the queue unchanged. A suite written to that line rejects an implementation that follows step 6; the change that satisfies the test counts the same rows again on the next run. Fix: assert the offset stays at the extract commit, those queue entries stay undistilled with `malformed` unchanged, and a second run does not increment their counts.

2. **The re-send exception has no stored baseline.** Eligible digests are `distilled: false` failures with count ≥ 2 and undistilled corrections. A distilled failure is sent again only when no lesson came from it and its count has doubled since. The stored fields are the evidence id, `first_seen`, `distilled`, `malformed`, and `count`. With no count from the distillation and no bit for whether an accepted lesson cited the id, a signature distilled at count 2 already satisfies "doubled," so every later run sends it again until `cap_usd_day`. The queue is keyed by signature, and the signature formula (tool + program + normalised error line) is defined only for a failure, so a correction has no stable key. Fix: on the distill mark, store `count_at_distil` and `lesson` (true when an accepted lesson lists that evidence id); treat as eligible a distilled failure with `lesson` false whose count is at least twice `count_at_distil`; key a correction by its normalised prompt for the life of the entry, and use that same signature for the lesson id and dedupe.

VERDICT: REVISE

### Architect's response

Both taken.

1. **Test list.** Now asserts the offset stays at the extract commit after a CLI failure, the digest's entries stay undistilled with `malformed` unchanged, and a second run does not recount the rows.
2. **Re-send baseline and correction key.** The distill mark stores `count_at_distil` and `lesson`; a distilled failure is eligible again only with `lesson` false and count ≥ 2 × `count_at_distil`. A correction's signature is `correction:` + a hash of its normalised prompt, fixed for the entry's life, and is the key for lesson ids and dedupe.

## Round 5 — Grok

I'll re-read the revised plan and check it against the last two findings.Both round-4 findings are closed. A CLI failure, timeout, or `is_error` envelope leaves the offset at the extract commit, with those queue entries undistilled and `malformed` unchanged, and a second run does not count those rows again. The distill mark stores `count_at_distil` and `lesson`; a distilled failure is eligible again only when `lesson` is false and the count is at least twice that baseline. A correction is keyed by `correction:` plus a hash of its normalised prompt for the life of the entry, and that signature is what lesson ids and dedupe use.

The new eligibility rule matches the digest, the doubling test, and the queue cap. Distil still reads the queue after the offset commit, so a skipped or failed distil does not drop the range. The release pipe, the due-marker unlink, `prompt.compose` appending `lessons:approved` after `next`, and the `/clear` path recapture are unchanged and still consistent with the engine types. The remaining open items are the build checks the plan already lists (detach across `session.end`, and which classic events reach a mod).

VERDICT: APPROVED

### Architect's response

APPROVED. No changes. The two build-time checks Grok names (detach across session.end; which classic events reach a mod) are already in Risks.

## Addendum A (2026-10-12)
User-requested change after item 1 shipped: /lessons as a checklist dialog with (Recommended). Appended to PLAN.md as "Addendum A"; rounds below resume the plan session.

## Round A1 — Grok

The last review approved the plan. I'll read the revision and check whether anything new broke.Addendum A is the change. I'll check the dialog and the second Haiku check against the engine types.Round 5 still holds for the body of the plan. Addendum A is the new work, and two of its rules will either never mark a lesson recommended, or will pre-tick one the second leg was meant to keep unticked.

1. **The check call is not the distil cage, so the verdict the rule trusts does not come back.** The check is specified as `--safe-mode --restricted --strict-mcp-config --tools "" dontAsk --no-session-persistence` plus `--effort high` and `--max-budget-usd 0.05`. `dontAsk` is a bare token, and the argv leaves out `--model claude-haiku-5-5`, `--permission-mode`, `--output-format json`, and stdin `/dev/null`. The child has already dup'd the log onto fd 0, and the parser is the distil envelope parser. A reply that is not that envelope, or a call the default model will not run inside $0.05, becomes `unsure` / `not checked`, and the recommended tick never lights. Each lesson is another call of up to $0.05 against a $0.25 day, with no reserve between calls. Fix: use the step-5 argv unchanged except `--effort high`, stdin `/dev/null` and `CW_LESSONS_CHILD=1`, and under the store lock skip the call when today's spend plus $0.05 would pass the cap.

2. **`recommended` is true when any one cited entry clears the second leg, and the shell leg is just an error-line prefix.** The rule requires verdict `correct` and "at least one of" two sessions, a correction, or a shell failure. A lesson that cites a real `zsh:` line and a poisoned tool result satisfies that, and the risk note says one tool output cannot supply the leg. The shell leg is defined as the first error line matching `(eval):`, `zsh:`, `bash:`, or `sh:`. The extractor already rewrites `program` to `shell` from that prefix alone, so a program that prints `zsh: …` and exits 1 qualifies in a single session. With verdict `correct`, that lesson starts ticked. Fix: set `recommended` only when every cited evidence entry is a correction, was seen under two transcript ids, or is a Bash failure whose prefix is the shell's own diagnostic and whose program word never ran; a prefix a program printed stays program output and does not qualify.

VERDICT: REVISE

### Architect's response

Both taken.

1. **Check argv.** The check call now uses `distil_argv` unchanged (model, `--permission-mode dontAsk`, `--output-format json`, stdin `/dev/null`, `CW_LESSONS_CHILD=1`, same envelope parser); only the prompt differs. A spend reserve skips a call (distil or check) when today's spend plus the 0.05 USD per-call cap would pass `cap_usd_day`.
2. **Every entry, no shell leg.** `recommended` needs verdict `correct` and every cited entry to be a correction or seen in 2+ transcripts. The shell leg is removed: the transcript cannot separate a program's output from the shell's diagnostic (found independently by the Architect while answering the user). The remaining two-transcript leg is forgeable by a file read twice; accepted because Recommended is advice and the person presses Approve.

Also added (user request, between rounds): **A4**, auto-approve for lessons drawn only from the user's own typed corrections: a separate corrections-only distil (no tool output in its digest), the check call, project scope only, 3 a day, toast plus `forget`, `/lessons auto off`. Typed-prompt detection is measured in the build and fails closed.

## Round A2 — Grok

I'll re-read the revised addendum and check it against the two findings from the last review.The two earlier addendum findings are fixed in A2.1 and A2.2: the check uses the step-5 argv, stdin `/dev/null`, and `CW_LESSONS_CHILD=1`, and `recommended` requires verdict `correct` on every cited entry, with the shell leg removed. A4 adds a path that writes the system prompt with no press, and that path is not closed.

1. **The test list and the risk bullet still treat a shell error as a recommending leg.** A3 still lists `correct + shell` beside the two positive legs, and the risk note still says the second leg is "sessions, correction, shell" and that one tool output cannot supply it. A2.2 and the later A2 bullet say a single-transcript `zsh:` failure is not recommended, and that two reads of a poisoned file can meet the transcript leg. A suite that follows the first list puts the shell leg back. Fix: drop `correct + shell` from the positive cases and rewrite the risk bullet to match A2.2.

2. **The written shape of a "typed" prompt matches an SDK turn.** String content, not `isMeta`, no `toolUseResult`, no tag prefix, no paste, and ≤300 characters is also how an SDK row is stored (`promptSource: "sdk"`, `turnOrigin: "sdk"`, plain text such as `Reply with exactly: PONG`). A task notification is caught by its tag; an SDK prompt is not. Those rows already carry `origin.kind` and `promptSource`. Fix: set `typed: true` only when `origin.kind` is `human` and `promptSource` is `typed`; `sdk`, `system`, `task-notification`, `suggestion_accepted`, a missing origin, and `isSidechain` stay pending.

3. **The clean call and the mixed call share a signature, and dedupe does not say which one survives.** A4.2 puts the same correction in both digests and keeps one lesson. The store rule drops a new lesson whose signature is already pending, and refreshes `last_seen` when it is already approved. If the mixed call is stored first, the clean lesson is the one dropped and the auto-approval never happens. Fix: apply the clean call first; a later mixed lesson with that signature only refreshes the approved lesson.

4. **Neither daily counter has a date, and the reserve is not taken out of the balance.** `auto_today` and today's spend are persisted numbers. A process that starts a new session can reset `auto_today` and auto-approve three more lessons the same day, or the counter can stick at 3 forever. The spend check skips a call when spend plus 0.05 would pass the cap, without adding 0.05 before the next check in the same batch, so one distil of several lessons can launch every check. Fix: store the local date beside both counters and reset only when it changes; under the lock, add 0.05 to today's spend before each distil or check and reconcile to `total_cost_usd` when the call returns.

VERDICT: REVISE

### Architect's response

All 4 taken.

1. **Stale shell leg.** A3's positive cases and the risk bullet rewritten to match A2.2 (no shell leg; the two-transcript leg's forgeability stated).
2. **Typed prompts.** Verified on this project's transcripts before taking it: 113 typed prompts carry `origin.kind: human` + `promptSource: typed`; `suggestion_accepted` (13), `sdk` (10), task notifications and 14 origin-less rows do not. `typed: true` now requires exactly that pair (and not `isSidechain`); anything else fails closed.
3. **Clean call first.** The corrections-only call runs and stores before the mixed call; a later mixed lesson with that signature only refreshes or is dropped.
4. **Dated counters, reserve deducted.** `spend` and `auto_today` carry their local date and reset only when it changes; 0.05 USD is added to spend before each call and reconciled to `total_cost_usd` after, under the store lock.

## Round A3 — Grok (void)

Round A3 reviewed an unchanged PLAN.md: the Architect's round-A2 edit script stopped at an assert, and the log, journal and round ran anyway. Grok correctly reported the four A2 findings as still open. The edits are now applied with the Edit tool and verified by grep; round A4 reviews them.

## Round A4 — Grok

I'll re-read the addendum and check whether the four open findings are actually in the file this time.The four findings are now in the spec. The shell leg is gone from the positive tests and the risk bullet. `typed: true` requires `origin.kind` `human` and `promptSource` `typed`, and the other origins fail closed. The clean call is stored before the mixed call. `spend` and `auto_today` each carry a local date and reset only when it changes, and 0.05 is added before the call.

One wording in that reserve still zeroes the cap.

**The return path can assign the whole day's spend from a single call.** The new sentence adds 0.05 before the call and, when it returns, says that reservation is "replaced by" `total_cost_usd`, which is 0 when a CLI failure has no envelope. The safe reading swaps the 0.05 for the actual cost and leaves earlier calls alone. The other reading, `spend = total_cost_usd` (or `spend = 0` on a timeout), drops the rest of the day's total. The next check then sees a balance under the cap and launches again. The new test only covers the skip when `spend + 0.05` would pass, so a wiped balance still goes green. Fix: on return, under the lock, add `total_cost_usd − 0.05` to today's spend (a failure with no envelope adds `−0.05`); do not assign the day's spend from that one call.

VERDICT: REVISE

### Architect's response

Taken. The return path now adjusts today's spend by `total_cost_usd − 0.05` (a failure with no envelope by `−0.05`), never assigns it; a test pins that earlier calls' spend survives a return and a CLI failure takes back only its own reservation. Verified in PLAN.md by grep before the next round.

## Round A5 — Grok

I'll re-read the revised plan and check the spend-reconcile wording against the last finding.The spend-reconcile finding is fixed in the file. Before each distil, clean distil, or check, the plan adds 0.05 to today's spend under the store lock, and on return it adjusts that balance by `total_cost_usd − 0.05` (by `−0.05` when a failure has no envelope). The same paragraph says the day's spend is never assigned from one call, and it requires a test that an earlier call's spend survives both a normal return and a CLI failure.

The earlier Addendum A rules are still in the file: the check uses the distil argv, Recommended needs `correct` and every cited entry (typed correction or two transcripts, no shell leg), `typed: true` is only `origin.kind` `human` plus `promptSource` `typed`, the clean distil is stored before the mixed one, and `spend` and `auto_today` each carry a local date.

No new material flaw.

VERDICT: APPROVED

### Architect's response

APPROVED. No changes.

## Addendum B (2026-10-12)
User-requested change after Addendum A shipped: a compact review (three lines per lesson, evidence on demand) and a suggested fix the person applies with one press. Appended to PLAN.md as "Addendum B"; rounds below resume the plan session.

## Round B1 — Grok

The last review approved the plan. I'll re-read the revision and check whether anything new broke.Addendum A’s earlier rules are still in the file: the spend return path adjusts by `total_cost_usd − 0.05` under the lock, Recommended needs every cited entry, `typed: true` is only a human typed prompt, the clean distil is stored first, and both daily counters carry a date. Addendum B is the new work, and three of its rules break the review gate.

1. **A re-read after Use suggested fix puts ticks back on lessons the person cleared.** The dialog loads ticks from `recommended` when it opens, and B2.2 tells it to re-read the list and stay open without saying what happens to ticks or scope. The rewritten lesson is supposed to come back unticked, so the natural reload ticks every still-recommended lesson again, including ones the person had unticked, and ticks a recommended lesson that arrived while the dialog was open. The next Approve selected then approves that set. Fix: on that re-read, keep the current scope and the current ticks for ids that are still pending, leave the rewritten id unticked, and leave new ids unticked.

2. **The old check reason stays attached to the new text.** B2.2 says the lesson is shown as `not checked`, but “check is cleared” is defined as removing `verdict` and setting `recommended` false. The stored `check` string is what the dialog prints once `verdict` is gone, and that string was written about the previous wording. The same gap is in B2.3 for `/lessons edit`. Fix: clear the stored `check` string in the same write as the text change, so the line is `not checked`.

3. **The line the person approves from shows tool output with no untrusted mark, and the text path applies a fix it never shows.** The compact summary is `e.g. \`<command>\` → <first error line>`, and `/lessons pending` has no expand. That error line is the same untrusted tool output A1 marks, and a Recommended lesson is already ticked, so Approve selected can land on a snippet that is not labelled. Separately, `suggested: <fix>` is specified only inside the dialog; `/lessons fix ID` applies the stored fix on the text path, and neither `pending` nor `show ID` is required to print it first. Fix: prefix that snippet with `untrusted tool output:`, and print `suggested: <fix>` in `pending` and `show ID` before `fix ID` can apply it.

VERDICT: REVISE

### Architect's response

All 3 taken.

1. **Ticks after a re-read.** B2.3: the re-read keeps the scope and the ticks of ids still pending; the rewritten lesson and newly arrived ids come back unticked; ticks come from `recommended` only when the dialog first opens. Tested.
2. **Stale check reason.** Use-fix and edit clear verdict, the stored `check` reason, `gone` and recommended in the same write; the line reads `not checked`. Tested.
3. **Untrusted mark and the text path.** The summary's error snippet is prefixed `untrusted tool output:`; `pending` and `show ID` print `suggested: <fix>` before `fix ID` can apply it. Tested.

## Round B2 — Grok

I'll re-read Addendum B and check the three open findings against the file.The three open findings are fixed in the file. A re-read keeps the current scope and the ticks of lessons still pending, and both the rewritten lesson and any lesson that arrived while the dialog was open come back unticked. Use-fix and edit clear the verdict, the stored check reason, `gone`, and `recommended` in the same write, and the line reads `not checked`. The compact summary prefixes the error snippet with `untrusted tool output:`, and both `pending` and `show ID` print `suggested: <fix>`. The new tests cover those cases.

Addendum A’s earlier rules are unchanged: the spend return path adjusts by `total_cost_usd − 0.05` under the lock, Recommended needs every cited entry, `typed: true` is only a human typed prompt, the clean distil is stored first, and both daily counters carry a date.

No new material flaw.

VERDICT: APPROVED

### Architect's response

APPROVED. No changes.
