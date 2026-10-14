# Prompt audit: the implementer prompt (house item 3)
_2026-10-14. Method: `claude-api` skill, `prompt-audit` (shared/prompt-audit.md)._

## Assumptions

- **Scope:** the implementer prompt and the code that assembles and sends it,
  `scripts/claude-implement.sh:433-552`, plus the handoff text the implementer
  reads, `scripts/run-goal.sh:766-781` (first pass) and `:1063-1070` (fix
  rounds). Out of scope: `scripts/deepseek-code.sh` (legacy codex launcher), the
  reviewer prompt, and step 3's new fix-handoff wording (not built yet; it gets
  its own short pass once built, the last step of item 3).
- **Target model:** `claude-haiku-5-5` at effort `xhigh`, headless through
  Claude Code (`claude -p`, `claude-implement.sh:231`). The prompt was written
  for DeepSeek. DeepSeek still receives the same text as the refusal fallback,
  so every edit below has to read correctly to both.
- **Evidence:** 14 goals across two walks. uregex
  (`~/dogfood/uregex/docs/journal/uregex.md`: 7 goals, 1 review FIX round,
  1 wake that was a house false positive) and rbtree
  (`~/dogfood/rbtree/docs/journal/rbtree.md`: 7 goals, 0 FIX rounds,
  0 wakes). Haiku ran every pass; there were no DECLINED results, no DeepSeek
  fallbacks and no failed host proofs.

## Summary

The prompt works. In both walks Haiku stayed inside its scope, refused nothing,
left the contract untouched every time, and checked more than it was asked to:
planted bugs, differential tests and sanitizer fuzzing in most goals. The
findings are therefore about fit, not failure. Two of them cost something on
every goal:

1. **The sandbox line is factually wrong** (H1). It says writes outside the
   repo are blocked, but every goal wrote its scratch drivers under `$TMPDIR`.
   It also omits the limit Haiku actually hit: the Read tool was denied outside
   the repo, so on rbtree g4 one planned check was dropped.
2. **Who commits the journal is stated two ways** (H2). All 14 END records
   spend lines reconciling the two (host lines "riding along" in a wip commit;
   whether the END record is committed). The two walks resolved it in opposite
   ways: uregex left END uncommitted for the host, rbtree committed it.
3. **"ONE test at a time" does not fit single-executable oracles** (M1). Six of
   the seven rbtree END records explain why they could not follow it literally.

Counts: Group 1: 3 (M1, M2, L1). Group 2: 2 (H1, H2). Group 3: not applicable
(no custom tool definitions; Claude Code's built-in tools). Group 4: 1 flag (F3).
House-mechanism flags: 2 (F1, F2).

## Findings

### H1 — The sandbox sentence contradicts what the runs did
- **Location:** `scripts/claude-implement.sh:494-495`
- **Evidence:** "You run in a sandbox: writes outside the repo, to .git/hooks,
  .git/config and .claude/ are blocked, and network access is off."
- **Pattern:** Group 2, volatile specifics (a stated environment fact the
  repository contradicts).
- **Why:** shell writes under `$TMPDIR` succeed. Every goal of both walks from
  g2 on built its scratch driver there: uregex g2 "a scratch driver under
  $TMPDIR", rbtree g4 "a clean `git archive` export … in $TMPDIR". What does
  fail is the Read/Edit tools on paths outside the repo and the handoff folder
  (headless, no permission prompts, `--add-dir` covers only the handoff
  folder). rbtree g4 END: "Reading the scratch copy was denied by the
  permission layer, and I did not retry it", so a planned no-writes mutant
  check was skipped.
- **Confidence:** High for the `$TMPDIR` writes, which happened in 12 goals.
  Medium for the Read-tool rule, which rests on one denial plus the settings in
  `claude-implement.sh:173-197`.
- **Action:** rewrite (hunk 1).

### H2 — Journal commit ownership is stated two ways
- **Location:** `scripts/claude-implement.sh:449-450` against
  `scripts/run-goal.sh:773`.
- **Evidence:** prompt: "The host commits the journal only when it grew by
  whole records of this goal, so keep every line you add inside one of your
  records." Handoff: "Journal: `$JOURNAL` — git add this path on every
  checkpoint".
- **Pattern:** Group 2, instruction texts that disagree. Read together they
  leave open who commits what.
- **Why:** 14/14 END records carry a note reconciling them. uregex g1: "The
  first commit also carried the orchestrator's uncommitted dispatch line,
  because the handoff says to stage this path." The g2-g7 ENDs say "This END
  record is uncommitted for the host to commit." rbtree ENDs say "This END
  record is committed after it." The host's journal check accepted both, so
  neither reading is wrong. The text just does not say which is intended, so
  each run picks one and justifies it.
- **Confidence:** High (repository evidence in both walks).
- **Action:** rewrite (hunks 2a, 2b). The intended rule is the behaviour the
  host already accepts: stage the journal by path in each checkpoint commit;
  other agents' lines in it ride along, which is expected; whatever is left
  uncommitted at the end, the host commits.

### M1 — "ONE test at a time" over-specifies the TDD bar
- **Location:** `scripts/claude-implement.sh:463`
- **Evidence:** "STRICT TDD: red, then green, ONE test at a time, testing
  behavior through the seams the handoff names."
- **Pattern:** Group 1c, step-by-step choreography; Group 1a, capitals with no
  reason attached.
- **Why:** the house's acceptance oracles are often one executable with
  sequential checks. rbtree g2-g7: "the oracle is one executable with
  sequential sections, so each red was the next unmet check" (six times).
  uregex g3: "bracket_errors was not run red on its own"; g7: "written after
  the implementation, so it was not seen red first". Haiku keeps the intent,
  seeing each check fail before making it pass, and then spends a paragraph
  defending the literal rule. Current models follow instructions literally, so
  the literal form invites that defence. The outcome form keeps the bar and
  covers oracles of any shape.
- **Confidence:** Medium.
- **Action:** rewrite (hunk 3).

### M2 — The whole prompt is sent again on every resumed pass
- **Location:** `scripts/claude-implement.sh:527` (via `run_pass`, which sends
  `$PROMPT` as the `-p` message on `--resume` too); used by every fix round
  (`run-goal.sh:795`).
- **Pattern:** Group 1d, an instruction re-inserted on a cadence.
- **Why:** a resumed thread already holds the first message. Sending the
  eleven steps again restates rules the model keeps. It also makes the fix
  round's real news (the new handoff path) one line among sixty. uregex g3 r1
  shows the round needs only the handoff ("fix round r0 for g3-classes
  (handoff-g3-classes-fix-r0.md)").
- **Confidence:** Medium. It is untested on the target model; this is the
  removal that needs a live check (Step 7: a fix round on a mini dogfood).
- **Action:** rewrite (hunk 4). On `--resume`, send a short message naming the
  new handoff and the return document, and saying the first message's rules
  still apply. Every path that starts a fresh session (a lost thread, the
  DeepSeek fallback) keeps the full prompt.

### L1 — Capitalised step labels
- **Location:** `scripts/claude-implement.sh:444, 451, 457, 463, 472, 481, 489`
- **Evidence:** "JOURNAL:", "CHECKPOINT YOUR WORK.", "THE ACCEPTANCE GATE IS A
  CONTRACT.", "REPORT HONESTLY.", "SCOPE", "RESUMABILITY:".
- **Pattern:** Group 1a.
- **Why:** these act as headings, and each is followed by its reason, so the
  pressure-language row only partly applies. No run shows over-application.
- **Confidence:** Low.
- **Action:** flag only.

### F1 — Non-blocking questions have nowhere the Architect sees them (house mechanism)
- **Evidence:** uregex g1 "Finding for the Architect", g4 and g5 "Open
  question" (the nullable-loop divergence between the per-pc mark and
  backtracking), g6 "Open for the Architect" (two items). These live in END
  records and the return handoff. Nothing surfaces them, and the return handoff
  is read only on a wake. The g4/g5 divergence was a real spec question that no
  one answered.
- **Pattern:** Group 1d, unenforced: step 11 asks for "open questions", but
  nothing reads them.
- **Action:** flag. This is not a prompt edit. It is parked as a house item: a
  `question` record the walk-end summary lists.

### F2 — A journal heading was typed by hand, not read from the clock
- **Evidence:** uregex g6 END: "the two checkpoint headings … were typed by
  hand, not read from the clock". Haiku reported this itself.
- **Pattern:** Group 1d, unenforced.
- **Action:** flag. One occurrence in 14 goals. A host check that headings are
  in order would enforce it, if it ever matters.

### F3 — Effort `xhigh` on Haiku has never been compared with lower settings
- **Location:** `scripts/claude-implement.sh:74`
- **Pattern:** Group 4, request config.
- **Why:** Haiku's default is `medium`. Cost per goal ran $0.14-0.70, so there
  is no cost pressure, and the quality evidence above was all gathered at
  `xhigh`. A sweep is only worth it if cost becomes a problem.
- **Action:** flag.

## Keep list (checked, deliberately unchanged)

- **Steps 5, 8 and 9 and the DONE/BLOCKED definitions.** They carry the
  contract, the anti-gaming line ("a bounced blocker is a success; a gamed test
  is a failure"), and the requirement to run the proof before DONE. Step 3
  (proof fix rounds) relies on all three, including the step numbers, which
  its fix handoff refers to.
- **The `git add` by path rule with its reason.** It held: no goal staged
  `GOALS.md` or the Architect's files.
- **The ponytail format, and the out-of-scope re-read.** Both are used in every
  END record.
- **The `IMPLEMENTER_STATUS` line.** It is format-pinning; the host parses it.
- **Step 2's artifact list.** It is context; the GLOSSARY / findings paths are
  optional by their own wording.
- **"Stop at green: refactoring belongs to the review stage".** True: the
  reviewer's checklist includes SMELLS (`claude-goal-review.sh:310`).

## Proposed diff

Proposed, not applied. One finding per hunk. No test pins the prompt text (a
grep of `scripts/tests/` for these phrases finds none).

### Hunk 1 (H1) — `scripts/claude-implement.sh:494-495`
```diff
-You run in a sandbox: writes outside the repo, to .git/hooks, .git/config and .claude/ are
-blocked, and network access is off. That is expected, not a blocker to report.
+You run in a sandbox. Shell commands can write inside the repo and under $TMPDIR; put
+scratch drivers, copies and planted-bug builds under $TMPDIR. Writes to .git/hooks,
+.git/config and .claude/ are blocked, and network access is off. The Read, Edit and Write
+tools reach only the repo and the handoff's folder, so handle scratch files from the shell.
+None of this is a blocker to report.
```

### Hunk 2a (H2) — `scripts/claude-implement.sh:448-450`
```diff
    the goal. When you finish or stop, append an END record: outcome, commit shas, test
-   result, blockers. The host commits the journal only when it grew by whole records of
-   this goal, so keep every line you add inside one of your records.
+   result, blockers. Keep every line you add inside one of your records. Stage the journal
+   by path in each checkpoint commit; lines other agents added ride along, which is
+   expected. The host commits whatever you leave uncommitted, so the END record needs no
+   commit of its own.
```

### Hunk 2b (H2) — `scripts/run-goal.sh:773`
```diff
-      echo "- Journal: \`$JOURNAL\` — git add this path on every checkpoint"
+      echo "- Journal: \`$JOURNAL\` — stage it by path with each checkpoint commit"
```

### Hunk 3 (M1) — `scripts/claude-implement.sh:463-464`
```diff
-6. STRICT TDD: red, then green, ONE test at a time, testing behavior through the seams
-   the handoff names. You are headless, so take those seams as agreed. Stop at green:
+6. TDD: see each test or check fail before the code that makes it pass, in small steps,
+   testing behavior through the seams the handoff names. Where the oracle is one
+   executable, the next failing check is the next red. You are headless, so take those
+   seams as agreed. Stop at green:
```

### Hunk 4 (M2) — `scripts/claude-implement.sh`, before the main `run_pass`
```diff
+# A resumed thread already holds the full instructions; it needs only the new handoff.
+PASS_PROMPT="$PROMPT"
+if [[ "$MODE" == resume ]]; then
+  PASS_PROMPT="Next pass for the same goal. Read the handoff: ${HANDOFF_ABS}
+Keep the return handoff at ${RETURN_DOC}. Everything in your first message still applies,
+including the journal records and the final IMPLEMENTER_STATUS line."
+fi
-run_pass "$PROVIDER" "$MODE" "$SID" "$PROMPT" "$TOOLS"
+run_pass "$PROVIDER" "$MODE" "$SID" "$PASS_PROMPT" "$TOOLS"
```
The lost-thread retry (`:532-539`) and the DeepSeek fallback (`:546-553`) keep
`${PROMPT}`: both start a fresh session.

## Verification plan (Step 7)

- H1, H2, M1: re-read against the two journals (done above), then watch the
  next dogfood's END records. Expected: no journal-ownership notes, no
  "one test at a time" defences, and no Read denials on scratch files.
- M2: one live fix round (review FIX or step 3's proof fix) on a mini dogfood,
  comparing the resumed pass's START record and behaviour with uregex g3 r1.
  If it regresses, re-add only the one rule it lost.
- Every hunk: `scripts/tests/run-all.sh -j 8` (`implement-test.sh` stubs the
  launcher's model call), then a fresh Opus review of the diff per the recipe.
