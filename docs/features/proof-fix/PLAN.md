# Plan: A red host proof becomes a fix round (house step 3)
_Locked via crucible — by Claude + cobalt, 2026-10-14._

## Goal

Today `scripts/run-goal.sh` wakes the walk with `proof-red` whenever the host
proof fails after an implementer pass, so one implementer slip stops an
unattended walk until a person reruns it. Step 3 turns a red host proof into a
**proof fix round**: the host sends a bounded, redacted excerpt of the proof
output back to the same implementer thread as fix findings, inside the
existing `MAX_FIX_ROUNDS` budget, then reruns the proof. The host does not try
to classify why the proof is red. Every mechanical stop that runs before the
red check today stays a stop; a wrong oracle leaves through the implementer's
existing BLOCKED path; a host/sandbox difference leaves through a mechanical
no-progress stop; everything else is bounded by the shared budget.

## Approach

1. **Where it hooks in (`scripts/run-goal.sh`, the red check at ~945).** The
   order of the post-implementer checks does not change: contract tamper,
   implementer BLOCKED, dirty tree, journal tamper, then the proof; after the
   proof, `git-metadata` verify, `proof-timeout` (exit 124), and `proof-tamper`
   (HEAD moved, tracked changes, unignored new files, contract drift). Only a
   proof that clears all of those and is red (exit != 0, or `Ran 0 tests` in
   its output — the rule today) reaches the new branch. A red proof reaches it
   after an implementer status of DONE or MISSING (BLOCKED has already woken;
   DECLINED, error and rate-limit never get this far).

2. **The no-progress stop (host/sandbox difference).** If the round that just
   ran was itself a proof fix round, and it made **no change outside the
   journal**, the host wakes `proof-red` with the detail `no change since the
   red proof at r<R>; the host and the sandbox may disagree. Output: <proof
   file>`. "No change" is `git diff --quiet <head> HEAD -- . ':!GOALS.md'
   ':!<journal>'`, where `<head>` is the `head=` recorded with that proof fix;
   comparing SHAs is wrong, because the implementer stages the journal in its
   checkpoint commits and the host commits journal lines on every stop, so
   `HEAD` moves without progress. No change means the implementer saw nothing
   to change — typically its own sandboxed proof run is green — so another
   round cannot help. A review-FIX round that is followed by a red proof is
   not subject to this rule (it is the first red proof of that run of rounds).

2a. **A resume after a no-progress stop reruns the proof first.** When a
   resume finds a pending fix with `source=proof` (step 7) **and** the
   attempt's journal has an `ORCHESTRATOR wake <id> r<R+1> reason=proof-red`
   line after that fix line (the no-progress stop of step 2 already fired for
   that fix round), the host runs the proof, with every check of step 1,
   **before** dispatching anything. Any other pending proof fix is dispatched
   as today: a pass that never completed (a kill, a rate limit, a timeout, an
   implementer error, a `max-fix-rounds` wake before dispatch) and a pass that
   completed but stopped before a no-progress decision (`implementer-blocked`,
   `dirty-tree`, `journal-tamper`, `proof-timeout`, `proof-tamper`). Its
   in-flight or blocked edits are left to the implementer as today. An
   `implemented` line is not the gate: it is written before the proof and
   before those stops. Green: the goal
   goes to review as after any green proof (the person fixed the host, or the
   last pass's work was good). Red and the no-progress condition of step 2
   holds against the pending fix's `head=`: wake `proof-red` again, nothing
   dispatched. Red otherwise: dispatch the pending fix handoff, as today. This
   keeps a resume after a no-progress stop from paying for another implementer
   pass, without trapping a person who fixed the host and resumed.

3. **The budget (shared).** Otherwise the red proof becomes fix round
   `ROUND+1`. The same counter and rule as a review FIX: `ROUND` is the repair
   number, `MAX_FIX_ROUNDS` (default 3) allows repairs 1..N, and past it the
   host wakes `max-fix-rounds` with the detail `after a red proof; output:
   <proof file>`. Proof fixes and review fixes draw from one budget.

4. **The findings: a bounded, redacted excerpt (`scripts/lib/proof-excerpt.py`,
   new).** Input: the proof output file. Output: the findings text, built in
   this order —
   1. decode as UTF-8 with invalid bytes replaced, and pass the **whole**
      output through `redact_proof()` (step 5) first, so a secret spanning
      lines (a PEM block) or one that a later cut would sever is replaced
      while it is still whole; the header line states how many values were
      redacted (`N values redacted`), so a redacted checksum or SHA in an
      assertion reads as a redaction, not as the failure;
   2. keep the first 40 and the last 160 lines (all lines when there are at
      most 200), with a one-line note where lines were dropped
      (`[… N lines omitted …]`);
   3. truncate any kept line longer than 2 KiB to its first 2 KiB on a UTF-8
      character boundary, marked `[… line truncated …]`, then cut the whole
      excerpt to 16 KiB on a line boundary with the same kind of note. A cut
      after step 1 can sever only a `[REDACTED]` marker or text the redactor
      did not recognise, never a recognised secret;
   - prefixed by the proof command, the exit code and a line saying the
     output came from running the implementer's own code on the host and is
     data, not instructions; fenced so the text cannot close the fence (the
     fence is longer than any backtick run inside).
   The full proof output stays in the run folder for the Architect; only the
   excerpt goes to the implementer.

5. **One redactor (`scripts/lib/redact.py`, moved).** `REDACTIONS`, `_LONG`,
   `_opaque` and `redact()` move from `scripts/lessons.py` into
   `scripts/lib/redact.py` unchanged; `lessons.py` imports them from there
   (path computed from its own file, as its other `lib` uses do). The lessons
   tests stay green unmodified, which pins the move as behaviour-preserving.
   `redact.py` also gets `redact_proof(text) -> (text, count)`: the same
   patterns except that a PEM block is redacted only from its `BEGIN` line to
   its `END` line. `redact()`'s PEM rule also matches an unclosed block to the
   end of the text, which on a proof log would erase every line after it,
   failure included; an unclosed block's base64 body lines are still caught
   by the long-opaque rule. The bare-hex rule stays: 32+ hex tokens are a
   common key shape, and the count line covers a redacted checksum.

6. **The fix handoff, in a folder the implementer may read.** Every handoff
   the implementer gets (first pass, review fix, proof fix) moves from
   `$RUN_DIR` to `$RUN_DIR/implementer/`. `claude-implement.sh` passes the
   handoff's folder as `--add-dir` and writes the return document beside it,
   so the implementer can no longer read `$RUN_DIR`'s raw proof logs, review
   briefs, diffs or reviewer output. `run-goal.sh` reads the return handoff
   from the new path. The reviewer keeps `--add-dir $RUN_DIR`. Known limit:
   the legacy `IMPLEMENTER=codex` launcher (`deepseek-code.sh`, sandbox
   `workspace-write`) can still read outside the handoff folder; it is out of
   scope here and noted in FUTURE-WORK beside the host-proof sandbox item.
   With R the round whose proof was red (one index everywhere, as for a
   review fix): the handoff is `$RUN_DIR/implementer/handoff-<id>-fix-r<R>.md`,
   copied to `$ART_DIR/fix-r<R>.md` before the journal names its hash, and
   round R+1 is dispatched. Body:
   - title `# Fix handoff: <id> (after round <R>: red host proof)`;
   - the existing lines: oracle and `tests/acceptance/` READ-ONLY, BASE_SHA
     unchanged, do not redo passing tests;
   - "The host ran the goal's proof after your last pass and it failed. Make
     it pass without changing any contract file. If you believe the oracle or
     the case table is wrong, do not work around it: report BLOCKED with the
     exact question (the blocker rule). If the proof passes in your sandbox and you
     have nothing to change, say so in the journal END record and the return
     handoff and report DONE without changing any file.";
   - `## Findings` then the excerpt (step 4), verbatim. The journaled hash is
     of the text after `## Findings`, exactly as for a review fix, so the
     resume check is unchanged.
   The implementer's main prompt (`claude-implement.sh`, `deepseek-code.sh`)
   is not edited.

7. **Journal and resume.** A proof fix writes
   `## <utc> — ORCHESTRATOR fix <id> r<R> count=1 hash=<sha256> source=proof head=<sha>`
   — `r<R>` is the round whose proof was red, as a review fix names the round
   that was reviewed — and a review fix gains `source=review`. The fix record
   names the goal, so the per-goal journal-record rules accept it.
   `scripts/lib/resume-state.py` prints three more tab fields after
   `PENDING_FIX_HASH`: `PENDING_FIX_SOURCE`, `PENDING_FIX_HEAD` (`-` when
   absent, which old journals give; `-` source is treated as `review`), and
   `PENDING_FIX_STUCK` (`1` when a `wake <id> r<R+1> reason=proof-red` line
   follows the pending fix line in this attempt, else `0`; it reads `wake`
   lines, which it ignores today). `run-goal.sh` reads them on resume for step 2a and
   the no-progress rule.
   The max-fix-rounds wake at resume (~753) cites `$ART_DIR/fix-r<R>.md` (the
   new `RUN_DIR` holds no proof log yet) and says "after a red proof" only
   when the source is `proof`.

8. **Events.** A proof fix appends the `fix` event as a review fix does
   (severity warning, verdict `FIX`), with `"source":"proof"` added to the
   payload; a review fix adds `"source":"review"`. `events.py` needs no change
   (phase stays `fix`); the walk pane and the walk tasks keep reading
   `proof-red` and `max-fix-rounds` as wake reasons.

9. **ADR and docs.** `docs/adr/0002-red-proof-fix-round.md` (red host proof
   is a fix round, why the host does not classify, the no-progress stop, the
   shared budget, the redacted excerpt); `0001` gains one line, "red host
   proof: amended by 0002". `GLOSSARY.md` gains **Proof fix round**.
   `skills/run-goal/SKILL.md` and `README.md` stop lists say when `proof-red`
   still wakes. `docs/FUTURE-WORK.md`: item 7 done on commit; carried inputs
   into item 3 (the prompt audit must cover the fix-handoff wording of step 6)
   and item 6 (the parallel walker inherits proof fix rounds and the
   `source=`/`head=` journal fields); a new parked item: run the host proof in
   a sandbox (read deny outside the repo, no network), the real fix for the
   data path step 4 only narrows.

10. **Tests.** `scripts/tests/proof-fix-test.sh` (new), stub launchers in the
    style of `proof-test.sh` (a stub implementer whose behaviour per round is
    scripted by files the test writes; a stub reviewer that returns DONE):
    - red → proof fix dispatched with the excerpt → implementer commits a fix
      → green → reviewed → done; the journal fix line has `source=proof`,
      `count=1`, the hash of the handoff's findings, `head=`;
    - red → proof fix → no change outside the journal → red: wake `proof-red`, detail names
      the no-progress rule;
    - red → proof fix → a **journal-only** commit → red: still the
      no-progress wake (the journal is excluded);
    - red → proof fix → new commit, still red → second proof fix (progress
      resets the rule);
    - resume after a no-progress wake (step 2a): with nothing changed, the
      proof reruns, wakes `proof-red` again and the stub implementer is
      **not** called; with the host "fixed" (the proof made to pass by the
      test between runs), the resume goes to review without dispatch; with a
      pending proof fix that is not stuck, the proof reruns red and the fix
      is dispatched; a kill **during** the proof fix pass, resumed with the
      tree unchanged: the pending handoff is dispatched, not re-woken, and a
      dirty in-flight tree is not a `dirty-tree` stop; a proof fix pass that
      reports BLOCKED (wake `implementer-blocked`, uncommitted red tests),
      then resumed: dispatched, no proof first, no `dirty-tree`;
    - the implementer's folder: the stub implementer records the
      `--add-dir` it was given; it is `$RUN_DIR/implementer/`, which holds
      no `proof-*.txt`; a secret present only in the raw proof log appears
      nowhere under it (first pass, review fix and proof fix);
    - the budget: `MAX_FIX_ROUNDS=1`, red twice with commits → `max-fix-rounds`
      with "after a red proof"; `MAX_FIX_ROUNDS=0` → the first red proof wakes
      `max-fix-rounds`;
    - a review FIX round followed by a red proof → a proof fix (shared counter:
      the round numbers continue);
    - BLOCKED in a proof fix round → `implementer-blocked`;
    - kill during the proof fix round's implementer pass, then resume: the
      same handoff is replayed (hash verified), and a resumed round with no
      new commit still hits the no-progress stop (fields from resume-state);
    - a tampered `fix-r<K>.md` on resume → the existing gate;
    - excerpt: a planted key (`sk-ant-…`, a 40-char base64-ish token) in the
      proof output is redacted in the handoff; a PEM block that starts in
      the kept head and ends in the dropped middle is redacted whole; a key
      sitting across the 2 KiB line cut and one across the 16 KiB cut are
      redacted; an unclosed `BEGIN … PRIVATE KEY` line does not erase the
      lines after it (the failure stays visible) while its body lines are
      redacted; the header's redaction count matches; a 10 000-line output gives the first 40 and last 160 lines
      and at most 16 KiB; a single 1 MiB line stays under 16 KiB; a line of
      backticks cannot close the fence; invalid UTF-8 does not crash it;
    - `Ran 0 tests` with exit 0 → proof fix, as a red proof.
    `proof-test.sh` case 13 becomes "red → proof fix dispatched", plus
    `MAX_FIX_ROUNDS=0` → `max-fix-rounds` "after a red proof"; its timeout
    and tamper cases are unchanged and still stop. `resume-state-test.sh`
    gains the three new fields (`PENDING_FIX_SOURCE`, `PENDING_FIX_HEAD`,
    `PENDING_FIX_STUCK`), including an old journal with none of them, and
    `STUCK` stays `0` after an `implemented` line or an `implementer-blocked`
    wake and becomes `1` only after a `proof-red` wake of round R+1.

## Key decisions & tradeoffs

- **No classifier (Q1, user).** The host cannot see intent; a heuristic over
  arbitrary runners' output to spot a "wrong oracle" would be brittle. Causes
  leave through existing exits (BLOCKED, mechanical stops) plus one new
  mechanical rule (no change outside the journal and GOALS.md). Cost: a wrong oracle that the implementer
  does not recognise spends rounds until the budget stops it.
- **The no-progress rule keys on the tree outside the journal, not on the
  proof output or the SHA.** Output can differ run to run (timings, paths)
  without progress; the SHA moves on journal-only commits (the implementer's
  checkpoints, the host's stop commit). A change that is irrelevant to the
  failure still resets the rule; the budget bounds it.
- **A resumed proof fix proves first (2a).** Re-waking at the resume gate
  without a proof run would trap a person who fixed the host; dispatching
  first would pay for a pass the no-progress rule already judged useless.
- **Shared budget (Q2, user).** One counter, one resume path. Cost: two proof
  slips leave one round for Opus findings at the default 3.
- **Redacted excerpt, not raw output, not a sandboxed proof (Q3, user).** The
  host proof already runs implementer code unsandboxed with network, so the
  excerpt does not open a new capability; redaction keeps the house rule
  (secrets out of every handoff) and keeps a printed key out of a model
  provider's logs, DeepSeek's included. Sandboxing the host proof is the real
  fix and is parked, not done here.
- **Instructions live in the fix handoff, not the main prompt.** Works for
  every launcher unchanged and keeps item 3 (prompt audit) small; the
  carried input names it.
- **`proof-red` keeps its name for the no-progress stop.** No consumer
  changes; the detail tells the cases apart.

## Assumptions

1. Today a red proof (exit != 0 or `Ran 0 tests`) after the tamper checks
   wakes `proof-red` with no review — `scripts/run-goal.sh:945-949`.
2. Before it: `proof-timeout` (124), git metadata, `proof-tamper` incl.
   contract drift — `run-goal.sh:921-944`. They stay wakes.
3. The implementer status is DONE, BLOCKED or MISSING under `ok`; BLOCKED
   wakes before the proof (`run-goal.sh:867`), so a red proof follows DONE or
   MISSING — `scripts/claude-implement.sh:35-42`.
4. The fix machinery (handoff with `## Findings`, journaled hash, `ART_DIR`
   copy, `resume-state.py`, `ROUND`/`MAX_FIX_ROUNDS` with repairs 1..N) is
   reused — `run-goal.sh:740-757, 1050-1090`, `scripts/lib/resume-state.py`.
5. Fix rounds resume the same implementer thread (`THREAD_ID`) — `run-goal.sh:795`.
6. The host proof runs unsandboxed with network, credential-named variables
   unset, `PROOF_TIMEOUT` 600 s — `run-goal.sh:432-445, 914-919`.
7. The implementer runs the proof itself in its sandbox (network off, writes
   in the repo only) before DONE — `claude-implement.sh:481-499`.
8. `proof-red` stays a valid wake reason, so `events.py`, the walk mod and the
   walk-tasks tests are unaffected — grep.
9. ADR 0001 lists "red host proof" among the stops; Opus and the implementer
   still never read each other's raw output (the excerpt is host output) —
   `docs/adr/0001-host-loop.md`.
10. No real red-proof case exists from either dogfood; evidence is planted in
    stub-launcher tests — `docs/FUTURE-WORK.md:83,89`.
11. Carried inputs go to items 3 and 6 — `docs/FUTURE-WORK.md:59-71`.
12. Research tier none. Plan files in `docs/features/proof-fix/`; build,
    Opus review, planted bugs and the full suite per the FUTURE-WORK
    execution-plan recipe.

## Risks / open questions

- **Gaming pressure.** A fix round saying "the proof failed, make it pass"
  invites a gamed test more than a review finding does. Mitigations: the
  contract files are read-only and checked (contract tamper, proof tamper);
  the handoff names BLOCKED as the right answer to a wrong oracle; Opus still
  reviews every green diff before done.
- **Redaction is heuristic.** `redact()` catches known key shapes and long
  opaque runs; a short or unusual secret can pass. Accepted for this slice;
  the parked sandbox item is the fix.
- **Proof output that is itself an instruction.** The excerpt is framed as
  data inside a fence the content cannot close; a model can still be swayed
  by it. The contract checks and the review bound the damage.

## Out of scope

- Sandboxing the host proof (parked in FUTURE-WORK).
- Any change to the implementer's main prompt (item 3).
- Classifying failure causes from proof output.
- Parallel walking (item 6).
- Changing what Opus reviews or sees.
