# Journal: lessons-hook

## 2026-10-11T18:34:00Z — ARCHITECT phase1
Plan locked after 3 load-bearing decisions (Q1 prompt.compose system-prompt section, rebuilt only when the approved set changes; Q2 every new lesson pending until approved via /lessons, recurrence only refreshes last_seen; Q3 two scopes, global and per-project under ~/.claude/lessons/, user confirms at approval) and cosmetic C1-C11 at defaults (C10 off switch became /lessons off: a mod is not assumed to read the env). Research tier: none (engine type docs, recon, transcript measurement). Next: Grok round 1.

## 2026-10-11T18:44:11Z — ARCHITECT phase2 r1
Grok REVISE: 7 findings. Taken: 3-7 in full; 1 and 2 in part. Rejected with evidence: --no-session-persistence and --tools "" are documented in claude --help 2.1.296; prompt.compose / session.compact / session.end are declared in the engine type file (claude-code.d.ts:8329, 4390, 4434) though absent from the changelog. Round 2 next.

## 2026-10-11T18:50:51Z — ARCHITECT phase2 r2
Grok REVISE: 7 findings (detach vs process.run pipes; throttle drops triggers; daily cap forgets evidence; prompt.compose must call next; fenced JSON; /clear; casefold + transcript shape). All 7 taken. Round 3 next.

## 2026-10-11T19:01:16Z — ARCHITECT phase2 r3
Grok REVISE: 4 findings (capped run loses corrections / no distilled mark; malformed-retry count not persisted; child closes its own release pipe; due marker never removed). All 4 taken; 1-2 by an evidence-queue redesign (extract owns the offset, distil drains a persisted queue). Round 4 next.

## 2026-10-11T19:06:51Z — ARCHITECT phase2 r4
Grok REVISE: 2 findings (test list contradicted the offset rule; re-send rule had no stored baseline, corrections had no key). Both taken. Round 5 (last under MAX_ROUNDS) next.

## 2026-10-11T19:12:03Z — ARCHITECT phase2 r5
Grok APPROVED. 5 rounds, 20 findings (18 taken in full, 2 in part, the rejected parts being claims checked false against claude --help and the engine types). Awaiting user sign-off.

## 2026-10-11T19:13:50Z — ARCHITECT signoff
User signed off the plan (Grok APPROVED r5). Next: commit plan + log, then build in-session.

## 2026-10-11T19:16:29Z — ARCHITECT build prototype
Throwaway mod (scratchpad, claude -p --plugin-dir, Haiku): classic.SessionStart and classic.SessionEnd reach a mod with no settings hook and carry transcript_path (session.start fires after classic.SessionStart); a process released from the classic.SessionEnd hook was alive 4 s after the session ended; a prompt.compose section appended after next(e) lands after the 11 engine sections (1 shared, 10 session) and the model read it back. Plan risks 1-2 closed: the mod uses the classic events only (no session.compact / session.end fallback needed). Found: `--tools ""` swallows a following positional prompt (claude exits "Input must be provided"), so the distil argv puts the prompt before it. Deviation: a mod cannot read the session env (ProcessRunInit.env only sets vars over it), so the CW_LESSONS_CHILD guard lives in lessons.py (render prints nothing, run exits).

## 2026-10-11T19:44:03Z — ARCHITECT build
Built in-session: scripts/lessons.py (extract, evidence queue, distil, store, render, /lessons verbs, self-detach), mods/lessons (classic.SessionStart/PreCompact/SessionEnd, session.start, prompt.compose, tool.call, /lessons), scripts/tests/lessons-test.sh (9 sections) and register.test.tsx (8 tests); install.sh loops over both mods (MODS=(walk lessons), mod_copy_current), marketplace entry, cache.sh lessons/ 0700 and lessons/logs pruning, README, FUTURE-WORK. Deviations, each from measuring this session's 17 MB transcript: (1) the error line for a signature is the last error-looking line (a failed Bash result mixes output and error; the first line was `---`, `ready True`, `total 4`), Python exception lines included; (2) program = first non-plumbing word across && ; | segments, and shell-level errors ((eval):, zsh:) group as program "shell"; runs of = or - collapse, so `=== not found` / `==== not found` are one signature; (3) a prompt answering an assistant question (last text ends in ?) is not a correction, and the repeat rule needs 5+ words and no trailing ?: all 5 measured "corrections" were answers like "Go with your recommendation."; (4) a retry is decided at its result: one that fails the same way is that failure again, not a second count (found by the tests: 2 failures counted 3); (5) non-Bash evidence is the path/pattern, never file content (found live: Write evidence held the start of the file). Bugs found by the tests: Claude Code project keys start with "-", so argparse read `--project-key -Users-…` as a missing value; every caller passes --project-key=K. The redaction NAME rule redacted `KeyError: missing`; the secret word must now be a whole name component. A malformed render made the engine skip session.start (no /lessons): refresh() never throws.

## 2026-10-11T19:44:03Z — ARCHITECT live check
One real distil on this session's transcript (lessons.py run --foreground --final): extract 36 signals, 17 queued, digest 9; Haiku 5.5 returned 2 valid lessons in 6 s for 0.0012 USD; the real CLI took every flag (--safe-mode --restricted --strict-mcp-config --tools "" dontAsk --no-session-persistence --max-budget-usd); no transcript was written for the call; store 0700/0600. Pending (left for the user): Ld091d7 zsh unmatched globs (its advice `setopt nomatch` is wrong: nomatch is the default that errors; the user can edit) and Lf38736 re-read before Write. The mod is not installed yet (install.sh, on the user OK).

## 2026-10-11T19:44:03Z — ARCHITECT planted bugs
14 planted bugs, each red: lessons.py 9 (answered question as correction; Bearer unredacted; curl allowed; release pipe closed before its byte; CLI failure marks distilled; retry double count; --safe-mode dropped; approve defaults global; throttle ignores --final), mod 5 (compose without next; subagent failures counted; session end without --final; /clear keeps the count; refresh throws). Two were green at first and the tests were tightened: curl was also caught by the `| sh` rule (added a curl-only lesson), and a throwing refresh was invisible because /lessons registers before it (now asserts the due run still happens).

## 2026-10-11T19:49:04Z — ARCHITECT effort comparison
User asked whether Haiku can run at xhigh. Same 9-entry digest (rebuilt read-only from the live store) at each effort, real flags, per-call cap raised to 0.50 for the measurement: low 7.7 s / 0.0012 USD / 2 lessons, missed the most frequent mistake (zsh `=====`, 10x); medium 11.4 s / 0.0012 / 4, adds a weak project lesson; high 13.9 s / 0.0015 / 3, all correct, and the only one to state the `=word` expansion right; xhigh 40.7 s / 0.0046 / 3, no better (its `=====` lesson says "starting a command", which is wrong) at 3x the cost and time. Changed --effort low -> high (plan C11 said low). The 0.05 USD cap keeps ~30x headroom over high.

## 2026-10-11T21:22:29Z — ARCHITECT review r1
FIX 1 tool.call `.catch(passThrough)` re-runs the tool when the hook throws after next(e).
  REJECTED with evidence: the engine documents that a handler's next(e) after the hook already called next "replays what that call settled to and nothing runs twice"; a new mod test (a trigger whose process.run rejects on the 5th failure) shows 5 tool runs for 5 calls. The post-next counting/trigger is now in try/catch anyway (logged, result returned).
FIX 2 cmd_run took the blocking store lock (off check) before mark_due and release; a session-end hook could block past 1.5 s with no due marker.
  TAKEN: mark_due then release first; `off` is checked only in the child (run_one), which also unlinks the marker when off.
FIX 3 control/format characters (ANSI escapes, zero-width, bidi) in lesson text could make /lessons pending show something other than what render injects.
  TAKEN: validate and edit refuse Unicode Cc/Cf/Co/Cs; show_pending prints evidence through visible().
FIX 4 secret names ending in a secret word (PGPASSWORD, AUTHTOKEN, MYAPIKEY) not redacted.
  TAKEN, but the planted-bug check showed it was a false positive: the pattern had no left anchor, so `PASSWORD=` inside `PGPASSWORD` already matched. The regex now states the suffix form explicitly; tests pin PGPASSWORD and AUTHTOKEN.
FIX 5 the "log holds no transcript text" checks were vacuous (foreground runs log to stdout).
  TAKEN: a detached run writes a real log; its mode (600) and content are checked.
FIX 6 "no secret reaches the digest" was vacuous (secret failure seen once, never eligible) and covered 5 of the patterns.
  TAKEN: 15 secret shapes, in a failure seen twice and in a correction; asserts the evidence id and the correction reached the digest.
FIX 7 "digest packed the oldest" was a tautology: one now() for all signals of a run; sort_keys reorders ties on reload.
  TAKEN: first_seen = t + n*1e-6 by signal order; the fixture writes prog79 down to prog10 (name order = reverse age) and sends the digest in a second run after a zero-cap first run, so the reload's key order cannot stand in for age.
FIX 8 plan step 6 rejects "a backtick"; the code allows balanced backticks around a plain word.
  TAKEN as a journaled deviation: backticks around code names (`timeout`, `sed -i`) are how a lesson names a command; a backtick holding $ | ; & > < is refused; approval is the gate.

NOTES taken: /lessons mutating verbs (approve, edit, reject, forget, off, on) need --typed, which the mod passes only when command.run's engine-stamped origin.kind is 'composer' (the person's Enter), so injected text cannot get the model to approve a lesson; `<` escaped in the digest (tool output cannot close </digest>); render reads without the store lock (writes are renames) and locks only to drop expired lessons; /lessons cli timeout 15 s and an unparseable reply returns text; one distil per project at a time (non-blocking per-project lock; the other run leaves the queue); a rejected signature blocks a lesson citing it among others; per-transcript state pruned after 30 days or when the transcript is gone, counts capped at 2000, old locks/work files pruned; a corrupt store file is moved aside to <path>.corrupt-<time>, never overwritten.
NOTES left by design (journaled): a lesson whose mistake stops recurring expires after 30 days (plan: "not seen again in ~30 days"); module globals in the mod are per process, as in walk; a marker retouched between mtime and unlink on the last loop pass leaves its rows to the next trigger (the offset is persisted, nothing is lost).
Planted bugs after the fixes: 15 in lessons.py and 5 in the mod (FIX 4 plant dropped: a false positive). Two were green at first and the tests were tightened (hidden-character lessons cited the same evidence as a valid one and were deduped away; the ordering check could not fail inside one run because Python sort is stable).

## 2026-10-11T21:32:55Z — ARCHITECT review r2 (targeted)
Opus round 2, scoped to the round-1 fix code: VERDICT FIX, 1 FIX + 9 NOTE, all taken. FIX: the rejected-signature check had no test; now a distil citing a rejected signature beside a new one leaves pending empty. NOTEs: prune_logs no longer unlinks distil-*.lock and unlinks a session lock only after LOCK_EX|LOCK_NB succeeds (flock never touches mtime, so an old lock can be held); old work/ distil folders are removed (rmtree); the distil lock is taken before the digest is built (a run cannot re-send what the holder just marked distilled); load() moves a file aside only on bad JSON / non-dict, raises StoreError on other read errors (EMFILE, EIO; main prints it, exit 3), uses <path>.corrupt-<ns>-<pid>, and the lock-free render read never renames; prune_state drops state only for transcripts that are gone (a resumed old session keeps its offset) and keeps rejected and global-approved signatures; variation selectors and tag characters count as hidden; the mod replay test now makes ui.log throw so the try/catch cannot absorb it and .catch(passThrough) runs (10 mod tests pass, the tool ran 5 times for 5 calls); new tests for pruning (held lock kept, free lock and old work folder removed, distil lock kept, gone transcript dropped) and for visible() in pending; a duplicated test block removed. Round 2 confirmed the rest: the cmd_run order, the --typed gate (one argv token; composer only, tested for composer, plugin and missing origin), the digest escaping, first_seen, hidden characters, and the FIX 4 / FIX 8 decisions. A third round is not planned: round 2 found one missing test and slips in round-1 fix code, each now pinned.

## 2026-10-11T21:49:43Z — ARCHITECT planted bugs r2
26 planted bugs, each red: lessons.py 20 (the 9 earlier, plus hidden characters, digest escaping, the --typed gate, the per-project distil lock, a corrupt store overwritten, render moving a file aside without the lock, the rejected check on one signature only, prune deleting a held lock, variation selectors, prune dropping a live transcript, first_seen order), mod 6 (the 5 earlier plus --typed for any origin). Two were green at first and the tests were tightened: the rejected entry was never in the second digest (it was marked lesson=True), and the only live transcript checked was the one being run, which is always re-added.

## 2026-10-11T21:57:07Z — ARCHITECT END
Item 1 done: committed and installed on the user OK. Full suite 21/21 at -j8 (152 s), events self-test, install.sh --check exit 0 (181 s); 26 planted bugs red; Opus rounds 1 (8 FIX, 1 rejected with a test) and 2 (targeted, 1 FIX + 9 NOTE, all taken). Next: the red-black tree dogfood (C).

## 2026-10-11T22:22:37Z — ARCHITECT addendum A
User asked for /lessons as a checklist with (Recommended), instead of approve/reject by id. Locked with the user: recommended lessons start ticked; one scope for every approved lesson. Asked why a mod and not the terminal: a mod dialog is drawn in the same terminal; the alternative, the Architect's own question tool, would route the approval through the model, which an injection could steer and the engine cannot attest; the mod's buttons run only on the person's key press. Addendum A appended to PLAN.md (dialog, recommended rule: Haiku check verdict correct AND evidence from 2+ sessions, a correction, or a shell-level error). Next: Grok round on the addendum (resume the plan session).

## 2026-10-11T22:28:28Z — ARCHITECT addendum A r1
Grok REVISE: 2 findings (check argv not the distil cage, no spend reserve; recommended rule "any" not "every" and the shell leg forgeable). Both taken; shell leg removed. A4 added on the user request: auto-approve lessons drawn only from the user's typed corrections (separate clean distil, check, project scope, 3/day, toast + forget, auto off). Round A2 next.

## 2026-10-11T22:32:18Z — ARCHITECT addendum A r2
Grok REVISE: 4 findings (stale shell leg in tests/risks; typed-prompt detection must use origin.kind human + promptSource typed; clean call must store first; daily counters undated and reserve not deducted). All taken; #2 verified first on this project's transcripts (113 typed; suggestion_accepted 13, sdk 10, task notifications, 14 origin-less rows excluded). Round A3 next.

## 2026-10-11T22:33:48Z — ARCHITECT addendum A r3 void
Round A3 void: the round-A2 edits had not reached PLAN.md (a multi-replace script stopped at a failed assert; the log, journal and Grok round ran after it unconditionally). Reapplied with Edit, verified by grep (promptSource 3, correct + shell 0, dated auto_today, **Order:**). Round A4 next.

## 2026-10-11T22:36:19Z — ARCHITECT addendum A r4
Grok REVISE: 1 finding (reserve return wording could assign the day's spend from one call). Taken: adjust by total_cost_usd - 0.05, tested. Grok confirmed the four A2 fixes are in. Round A5 next.

## 2026-10-11T22:43:40Z — ARCHITECT addendum A r5
Grok APPROVED Addendum A (rounds A1-A5; A3 void). 8 findings taken, none rejected. Awaiting user sign-off.

## 2026-10-11T22:44:36Z — ARCHITECT addendum A signoff
User signed off Addendum A (Grok APPROVED rA5). Next: commit addendum + log, then build in-session.

## 2026-10-11T23:08:52Z — ARCHITECT addendum A build
Built: lessons.py: typed_by_person (origin.kind human + promptSource typed, no paste marker), queue entries keep sessions (<=10) and typed (fail closed across sightings); reserve()/settle() take 0.05 before every call and adjust by cost-0.05 after, local-date day; call_model() shared by distil and the new check(); clean-then-mixed distil rounds; recommended() (check correct AND every entry a typed correction or 2+ sessions); auto_approve() (clean call only, every gate, project scope, 3/local day, notices); verbs: cli --json-list, review (--typed, explicit ids), recheck (detached), notices, auto on|off; pending/list show Recommended, check reasons, auto. Mod 0.2.0: checklist dialog pane (focus, closeOnEscape, holdToasts), $.state contract types/index.d.ts, buttons pass --typed with the ids drawn, notices toast at session start. Found in build: (1) the engine refuses a whole pane over one control character, so the mod filters every drawn string itself (cleanItem/visible) besides lessons.py; (2) Text drops `key`, keyed lines are wrapped in Box; (3) the clean-digest test was vacuous (no failure in its transcript) until a repeated failure and per-call prompts were added. Tests: lessons-test.sh section 11 (25 checks), register.test.tsx 16/16. 15 planted bugs red (11 script, 4 mod; the any-for-every plant re-run in its pure form, red on d). Live: recheck on the 2 real pending lessons: Ld091d7 incorrect ("setopt nomatch is already the default and still errors; ... needs unsetopt nomatch"), Lf38736 correct but not Recommended (one session); 0.001 USD.

## 2026-10-11T23:31:31Z — ARCHITECT addendum A review r1
Opus (fresh, read-only, this change only): VERDICT FIX, 2 FIX + 10 NOTE; found no path to the system prompt without a key press or a typed correction passing every A4 gate. Taken: FIX 1 (auto-approval toast only at session start: refresh() now shows notices whenever it re-reads, i.e. after /clear and /lessons changes too); FIX 2 (A4.2 "only the clean call" unpinned: stub gained per-call reply-N/mode-N/check-mode; new cases j: the clean call fails and the mixed call's lesson on the typed correction goes to pending; a mixed lesson citing the correction and a failure goes to pending). NOTEs taken: dialog opens only for origin composer; typed needs string content; an entry queued before `typed` stays untyped; settle() takes the reservation's day and leaves a new day's total alone; add_pending recommends only when every cited entry is still queued; only new lessons are checked (store and in-batch duplicates; the store-only version left test l vacuous, so in-batch dedupe was added and the plant went red); why_not() gives a reason for every unrecommended lesson, a correct one included; mod HIDDEN widened and rewritten with escapes only (the first version had literal invisible characters in the source); missing A3 cases added (sessions cap 10, check CLI failure and cap skip through the pipeline, sidechain row, gone evidence id, list content, hidden character in mod evidence). NOTE recorded, not acted on: the pasted-block markers are unmeasured (no real paste in any local transcript); kept as a fail-closed extra. No test for the add_pending guard (needs a concurrent prune). 8 more plants red (6 script, 2 mod). Full suite 21/21 at -j8 (153 s), mod 18/18, walk, events self-test, TMPDIR unchanged.

## 2026-10-12T08:36:17Z — ARCHITECT addendum A review r2
Narrow Opus round on the round-1 fixes (the first attempt hit the session limit and produced nothing; rerun after the reset): VERDICT DONE. Both round-1 FIXes and every taken NOTE confirmed (j1 red without `if clean`; n red under the old settle and under a reset; l red without the batch set; HIDDEN compiles with gu and leaves astral pairs alone). 5 NOTEs, all taken: j2 given a correct check so only the clean-call rule and the typed-only gate hold it (red only with both removed, as the review predicted; that double plant first crashed in auto_approve building `from` off a failure entry, so `from` now lists corrections only, and j2 then went red for the right reason, an auto-approval); the no-screen test asserts notices are never read (they are consumed on read); pending lessons record `gone` and why_not says "some of its evidence is no longer queued"; case e's L4 has one queued typed correction plus a gone id, pinning recheck's guard (red without it); mod HIDDEN adds U+0890-0891. 3 more plants red. Full suite 21/21 at -j8 (153 s), mods 18/18 and walk, TMPDIR unchanged. Addendum A done.

## 2026-10-12T08:54:20Z — ARCHITECT addendum B
User: the review is hard to read (long commands, every error line) and asked how a lesson is fixed. Answered: /lessons edit replaces the text verbatim (no Haiku). Locked with the user: B1 compact view (3 lines, summary from the failing segment, expand per lesson, /lessons show ID) and B2 a suggested fix from the check on an incorrect verdict, applied only by a press (Use suggested fix / /lessons fix ID), which clears the check until recheck. Next: Grok round on Addendum B.

## 2026-10-12T09:01:25Z — ARCHITECT addendum B r1
Grok REVISE: 3 findings (re-read re-ticks cleared lessons; stale check reason after a fix/edit; compact snippet unmarked and text path applies an unseen fix). All taken. Round B2 next.

## 2026-10-12T09:04:17Z — ARCHITECT addendum B r2
Grok APPROVED Addendum B (rounds B1-B2). 3 findings taken, none rejected. Awaiting user sign-off.

## 2026-10-12T09:04:58Z — ARCHITECT addendum B signoff
User signed off Addendum B (Grok APPROVED rB2). Next: commit addendum + log, then build in-session.
