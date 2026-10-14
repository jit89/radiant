# Plan Review Log: A red host proof becomes a fix round (house step 3)
Phases 0-1 (recon + interrogation) complete — plan locked with the user. MAX_ROUNDS=5.

## Round 1 — Grok

I'll review the plan skeptically against the domain docs and the code it depends on, looking for concrete breaks rather than style notes.The plan hinges on the host loop, redaction, and resume. I'll read those next and check the assumptions against the code.The no-progress stop does not survive the host's own journal commit, a resume after that stop dispatches the implementer again, and the redacted excerpt is not the text the implementer can read. Those are implementable as written and the new tests would still pass.

1. **No-progress compares `HEAD` to `head=`, and the host moves `HEAD` on the way out.** `record_wake` commits the journal (`run-goal.sh` 233–235) on every stop, including the kill in the resume test and the no-progress `proof-red` wake. That commit is only the fix, dispatch, and wake lines, but it is a new SHA, so the recorded `head=` no longer matches. The same miss happens in-process when the implementer commits the journal END record this handoff requires: the standing prompt already says to checkpoint and the first handoff says to `git add` the journal (`claude-implement.sh` 451–456, `run-goal.sh` 773). The round is then treated as progress and spends the shared budget until `max-fix-rounds`, so the sandbox-disagreement signal never repeats.
   Fix: call it progress only when `git diff <recorded-head> HEAD -- . ":!$JOURNAL"` is non-empty, and cover a journal-only commit in the tests.

2. **A no-progress wake leaves the proof fix pending.** `resume-state.py` only reads `dispatch`, `ids`, `review`, and `fix` (lines 22–24). The `wake … reason=proof-red` line does not clear it, so resume at line 743 replays the handoff and pays for another implementer pass. Step 2 runs only after that pass, and after finding 1 the SHAs differ, so the pass does not stop for no-progress either.
   Fix: if this attempt already has a `proof-red` wake and the non-journal diff against `head=` is empty, re-wake at the resume gate and do not dispatch.

3. **The raw proof log sits in the directory the implementer is given.** The handoff is `$RUN_DIR/handoff-…md`, and `claude-implement.sh` line 426 passes that directory as `--add-dir`. The unredacted log is `$RUN_DIR/proof-<id>-r<N>.txt` beside it. `denyRead` (lines 179–188) does not include it. The omission note says the excerpt is incomplete, which points the model at the raw file, so a printed key still reaches the implementer provider. Feeding that log back into the implementer thread is new: today the file stays local.
   Fix: keep the raw log outside any `--add-dir` path and out of the handoff text, redact before anything the implementer can read, and test that a secret present only in the raw log never appears under the add-dir.

4. **The 16 KiB cap, the line-boundary cut, and "redact after the cut" cannot all hold.** One line longer than 16 KiB has to be split or it blows the cap. A mid-line cut done before `redact()` can sever `sk-ant-…` or a 40-character token so neither `REDACTIONS` nor `_LONG` matches (`lessons.py` 108–140). A PEM that starts in the first 40 lines and ends in the last 160 is one DOTALL match and swallows the tail, or the reverse leaves the key body in the tail.
   Fix: redact the chosen lines first, then hard-cap at 16 KiB on a UTF-8 boundary, and redact again across the cut so a severed token is not emitted.

5. **`fix-r<K>.md` and journal `r<K-1>` are different indexes.** A review fix uses one number for the journal `r`, `ART_DIR/fix-rN.md`, the title, and `PENDING_FIX_ROUND` (`run-goal.sh` 1062–1076, `resume-state.py` 55–58). Step 6 names the file and the title with the new repair `K`; step 7 journals `r<K-1>`. Resume opens `fix-r${PENDING_FIX_ROUND}.md`, so a literal reading fails the hash gate or replays the wrong file. The tamper test's `fix-r<K>.md` is the other index.
   Fix: use the round whose proof was red for the journal `r`, the filename, the title, and `PENDING_FIX_ROUND`, and dispatch that number plus one.

6. **The resume `max-fix-rounds` detail cites a file the next process does not have.** `RUN_DIR` is a new temp directory on every invocation (line 578), and the proof log is not copied to `ART_DIR`. The wake at line 753 runs before any proof, so `<proof file>` is empty or points at the previous run. Applying "the same detail" there also labels a review-fix over-cap resume as "after a red proof" unless it is conditional on `source=proof`. Case 13's `MAX_FIX_ROUNDS=0` "proof-red-family" check disagrees with step 3, which wakes `max-fix-rounds`.
   Fix: store the cited proof log under `ART_DIR` next to the handoff, use the "after a red proof" detail only when `source=proof`, and expect `max-fix-rounds` for the `MAX_FIX_ROUNDS=0` check.

VERDICT: REVISE

### Architect's response

All six taken; 2 and 4 with a modification.

1. Taken. Progress is now "a change outside GOALS.md and the journal since `head=`" (`git diff --quiet <head> HEAD -- . ':!GOALS.md' ':!<journal>'`), not a SHA comparison. The audit of item 3 (applied the same day) makes the implementer stage the journal in each checkpoint, so journal-only commits are now routine. Test added: a journal-only commit is still no progress.
2. Taken, modified (new step 2a). Re-waking at the resume gate without a proof run would trap a person who fixed the host (installed a missing tool) and resumed. Instead a resume with a pending `source=proof` fix reruns the proof first, with all of step 1's checks, before any dispatch: green → review; red with no progress → wake again, no dispatch; red otherwise → dispatch the pending fix. Tests for all three.
3. Taken. Every implementer handoff (first pass, review fix, proof fix) moves to `$RUN_DIR/implementer/`; the launcher passes the handoff's folder as `--add-dir`, so raw proof logs, briefs, diffs and reviewer output in `$RUN_DIR` are out of the implementer's reach. This also closes the existing exposure on review-fix rounds, where the implementer could already read the green proof's raw log. Test: the recorded `--add-dir` holds no proof log, and a secret only in the raw log appears nowhere under it.
4. Taken, modified. Order: redact the whole decoded output, then select head/tail lines, then truncate long lines (2 KiB, UTF-8 boundary) and cap at 16 KiB. Redacting the whole text first replaces every recognised secret, PEM blocks included, before any cut, so a cut can sever only a marker or unrecognised text; a second redaction pass adds nothing. Tests: PEM across the dropped middle, keys across both cuts, a 1 MiB single line.
5. Taken. One index R (the red round) for the journal line, `fix-rR.md`, the title and `PENDING_FIX_ROUND`; R+1 is dispatched, exactly as for a review fix.
6. Taken. The resume-time `max-fix-rounds` detail cites `$ART_DIR/fix-r<R>.md`, says "after a red proof" only for `source=proof`; case 13's `MAX_FIX_ROUNDS=0` check expects `max-fix-rounds`. Also: the handoff now names "the blocker rule" instead of a step number, so an audit renumbering cannot break it.

## Round 2 — Grok

I'll re-read the revised plan and check each earlier finding against the code it depends on.The resume rule changed. I'll check it against the wake, rate-limit, and dispatch order so a pending fix that never ran is not treated as no-progress.Findings 1, 3, 4, 5, and 6 are fixed. The new resume rule in step 2a is not: it treats every unfinished proof fix as a host/sandbox deadlock.

1. **Step 2a runs for every pending `source=proof` fix, so a handoff the implementer never finished is dropped.** The no-progress predicate is now `git diff --quiet <head> HEAD -- . ':!GOALS.md' ':!<journal>'`. That diff is empty whenever the repair round made no non-journal commit, which is also the state when the round never completed. `journal_implemented` is written only after a launcher returns `ok` (`run-goal.sh` 817–832); a kill, `rate_limited`, `implementer-timeout`, or `implementer-error` wakes before that, and a `max-fix-rounds` wake is before `continue` dispatches. On resume the tree still matches `head=` (the wake’s own journal commit does not count), the proof is still red, and step 2a wakes `proof-red` with nothing dispatched. That contradicts the kill test in step 10, which replays the handoff, and the existing cap contract (`resume-state-test.sh` 4d): raising `MAX_FIX_ROUNDS` never delivers the unsent excerpt. Applying “every check of step 1” before that dispatch also runs dirty-tree. A killed pass is allowed to leave a dirty tree (`run-goal.sh` 685–686); that check would wake `dirty-tree` and strand the in-flight edit.
   Fix: run the pre-dispatch proof only when this attempt already has an `implemented` line for round `PENDING_FIX_ROUND+1`. Otherwise dispatch the pending handoff as today.

2. **Redacting the whole log with `redact()` unchanged can erase the failure.** The PEM pattern uses a `$` alternative (`lessons.py` 109), so one unclosed `-----BEGIN PRIVATE KEY-----` replaces the rest of the file before the head/tail is chosen. The bare-hex rule redacts every 32+ hex word, including checksums and full git SHAs in assertion diffs. Both are harmless on a lesson transcript and blinding on a proof excerpt.
   Fix: in the proof excerpt only, require a closing PEM line, and do not apply the bare-hex rule; leave `redact()` itself unchanged so the lessons tests stay pinned.

3. **The decisions section still says the stop is “no new commit”.** Step 2 and the journal-only test say otherwise. A SHA compare reintroduces the wake-commit miss.
   Fix: change that sentence to the non-journal tree diff.

The handoff directory, the single index `R`, the 16 KiB cap after a whole-file redact, and the resume `max-fix-rounds` detail match the code those findings were about. `IMPLEMENTER=codex` (`deepseek-code.sh` `sandbox_mode = "workspace-write"`) can still read the parent of the handoff; the default launcher cannot. Say so in step 6 or deny that read.

VERDICT: REVISE

### Architect's response

1. Taken. Step 2a now applies only when the attempt's journal shows `implemented <id> r<R+1>` after the pending fix line, i.e. the fix round's pass completed and its tree is final. Without it (kill, rate limit, timeout, implementer error, max-fix-rounds before dispatch) the pending handoff is dispatched as today and a killed pass's in-flight edits are left to the implementer; no proof, no dirty-tree check first. `resume-state.py` gains a third field, `PENDING_FIX_RAN`. Test added: kill during the proof-fix pass, resume with the tree unchanged → dispatched, not re-woken.
2. Taken in part. Verified: the PEM pattern's `|$` alternative (lessons.py:109) erases everything after an unclosed BEGIN line, and the bare-hex rule redacts git SHAs and checksums. Taken: a `redact_proof()` variant in redact.py whose PEM rule requires the END line (unclosed bodies are still caught by the long-opaque rule); `redact()` itself unchanged, so the lessons tests stay pinned. Rejected: dropping the bare-hex rule for proofs — 32+ hex tokens are a common secret shape, and a redacted checksum costs one value in an assertion, not the failure. Instead the excerpt header states how many values were redacted. Tests: unclosed BEGIN keeps the failure visible; the count matches.
3. Taken. The decisions bullet and the test list now say "no change outside the journal and GOALS.md".
Note on IMPLEMENTER=codex: taken as a stated known limit in step 6 (the legacy launcher is out of scope); it goes into FUTURE-WORK beside the host-proof sandbox item.

## Round 3 — Grok

I'll read the revised plan and check the last round's findings against the host loop.The earlier holes are closed: the no-progress diff ignores journal and `GOALS.md` commits, the handoff directory is outside the raw log, `redact_proof()` keeps an unclosed PEM from eating the failure, the round index is `R`, and the legacy Codex read is called out. The new `implemented` gate is still too early.

`PENDING_FIX_RAN` is set from `ORCHESTRATOR implemented <id> r<R+1>`, and step 2a treats that as "the pass completed, so its tree is final." `journal_implemented` runs at `run-goal.sh` line 832, before the proof and before the later stops. A proof-fix pass that follows the handoff and reports `BLOCKED` still writes that line, then wakes `implementer-blocked` at line 867. The host never ran the proof. The wake text says a blocked pass leaves its red tests uncommitted on purpose, and the goal stays `in_progress` so a resume can continue. On that resume `PENDING_FIX_RAN` is `1`, so step 2a runs every step-1 check before dispatch: the uncommitted tests wake `dirty-tree`, or a clean tree re-runs the proof and, with no non-journal change, wakes `proof-red` ("the host and the sandbox may disagree") and does not dispatch. The same gate catches `proof-timeout`, `proof-tamper`, and `journal-tamper`, all of which happen after `implemented` and are not a finished no-progress decision. Step 10 still says `resume-state-test.sh` gains two fields; step 7 adds a third, `PENDING_FIX_RAN`.

Fix: set `PENDING_FIX_RAN` only when a `wake <id> r<R+1> reason=proof-red` line follows that fix (the no-progress stop already fired). Any other pending proof fix, including `implementer-blocked`, is dispatched as today, and the resume-state test should cover that third field.

VERDICT: REVISE

### Architect's response

Taken as given. Verified: `journal_implemented` runs at run-goal.sh:832, before the BLOCKED stop (867), the dirty-tree and journal checks, and the proof, so an `implemented` line says nothing about a no-progress decision. The step 2a gate is now `PENDING_FIX_STUCK`: a `wake <id> r<R+1> reason=proof-red` line after the pending fix. Every other pending proof fix (never completed, or stopped on BLOCKED / dirty-tree / journal-tamper / proof-timeout / proof-tamper) is dispatched as today. Tests: BLOCKED in a proof-fix pass then resume → dispatched, no proof first, no dirty-tree; resume-state-test covers all three new fields and STUCK's 0/1 cases. Step 10's field count corrected.

## Round 4 — Grok

I'll read the revised plan and check the last finding against the wake and resume path.The stuck-gate changed. I'll check that wake line against contract and resume handling so a no-progress resume doesn't take another stop.The last finding is fixed. `PENDING_FIX_STUCK` is set only by a journal line `ORCHESTRATOR wake <id> r<R+1> reason=proof-red` after the pending fix, which is the line `record_wake` writes when the no-progress stop fires. `implemented` is no longer the gate.

A `BLOCKED`, dirty-tree, journal-tamper, timeout, tamper, kill, or cap wake does not set that flag, so the resume dispatches the handoff and leaves an in-flight tree alone. A real no-progress resume reruns the proof first: green goes to review, red with no change outside the journal and `GOALS.md` wakes `proof-red` again, and red after a real change dispatches. The tests cover those three fields, including stuck staying `0` after `implemented` or `implementer-blocked`.

The round index, the handoff directory, `redact_proof()`, and the resume cap detail still match the host loop.

VERDICT: APPROVED


### Resolution

APPROVED in round 4 of MAX_ROUNDS=5. Awaiting user sign-off.
