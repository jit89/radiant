# Future work

Ideas parked until the uregex dogfood run (`~/dogfood/uregex`) finishes.

## Execution plan (decided with the user, 2026-10-11)

One by one, in-session, after the walk ends. Not a bootstrap: the setup it
needs (frozen stage-0 worktree, feature worktree, a CLAUDE.md rule change, a
merge convention for plan files) outweighs the saving on changes this small.
What the bootstrap would have added that matters, independent review, is kept
directly: every item's diff goes to a different model.

Per item: **design** (a crucible with Grok's attack for the substantive items,
a direct edit for one-liners) → **build** in-session with tests in
`scripts/tests/` → **review** the diff with Opus, each finding taken or
rejected with a logged reason → **commit** per item, when the user is ready.

How the crucibles and reviews ran for item 5 (repeat for the next items):
- Plan files in `docs/features/<slug>/` (`PLAN.md`, `PLAN-REVIEW-LOG.md`,
  `journal.md`), never the repo root (it holds an older feature's PLAN.md).
  After sign-off, commit the plan and log on their own first.
- Grok rounds: `scripts/grok-review.sh docs/features/<slug>/PLAN.md`, then
  `--resume <SESSION_ID>`, always `run_in_background: true` (a first round
  takes ~20 min). A cancelled turn is now an `error`; log it void and rerun.
- Opus review of the diff: a fresh, read-only headless session given only the
  plan and the diff (`git diff HEAD` plus `git diff --no-index /dev/null <f>`
  for each untracked file), e.g.
  `claude -p --model claude-opus-5-5 --effort high --permission-mode plan
  --tools Read,Grep,Glob --add-dir <dir holding the diff> --output-format text
  "<brief>"`, the brief asking for `FIX: <path>:<line> — <defect> — <change>`
  lines and a final `VERDICT: DONE|FIX`. Round 2 is another fresh session
  seeded with round 1's review and the journaled response. Item 5 took two
  rounds (11, then 2 findings); a third was judged not worth it.
- After review: plant two or three bugs the new tests guard against and
  confirm each turns them red; then run `scripts/tests/run-all.sh -j 8` (every
  test, side by side, failing any that leaves files in its `TMPDIR` or
  `HOME`), `scripts/events.py --self-test` and `scripts/install.sh --check`
  (which runs the suite itself, at `-j4`).

Order (revised after the uregex walk, 2026-10-11; reordered 2026-10-12):
1. ~~Item 7.1 (Grok rounds in the background) and item 2.2's one line~~ —
   done: `CLAUDE.md`, `skills/crucible/SKILL.md`, `skills/run-goal{,s}/SKILL.md`.
2. ~~Item 5 / step 4: oracle review + tiered satisfiability~~ — done and
   committed (crucible, two Opus review rounds, tests green).
3. ~~Item 4: temp-file hygiene~~ — done (crucible, three Grok rounds, Opus
   review, tests green); today's `$TMPDIR` leftovers cleared once.
4. ~~Item 1: the lessons hook~~ — done, then extended on the user's requests:
   Addendum A (checklist dialog, Recommended, auto-approve from typed
   corrections; f14ddde) and Addendum B (compact review, suggested fix,
   approvals bound to the drawn text; 3025eb9). The base: crucible, five Grok
   rounds, Opus review, tests green; `mods/lessons`, `scripts/lessons.py`.
5. **Next: the red-black tree dogfood (C)** — the full workflow, crucible
   to walk; also the lessons hook's first real use.
6. ~~Item 10: walk progress in the task list; the walk footer dropped~~ —
   done (2026-10-14): `docs/features/walk-tasks/` (PLAN, review log, journal),
   `VERIFICATION.md` all ticked — scenario tests, randomised invariants, and a
   live mini dogfood (`~/dogfood/walktasks{,2}`). (User, 2026-10-13, during
   the rbtree walk: next house item after the dogfood, ahead of step 3.)
7. **Step 3: a red host proof becomes a fix round (crucible).** Today a
   proof that fails after the implementer's DONE wakes the walk
   (`proof-red`, `scripts/run-goal.sh`); step 3 sends the proof output back
   as a fix round within `MAX_FIX_ROUNDS`, so an implementer slip no longer
   stops an unattended walk or spends an Opus review on a red diff. The
   crucible has to tell causes apart: wrong implementation (fix round), wrong
   oracle (still a wake: the implementer may not edit it), host/sandbox
   difference, timeout or tamper (wakes, as today). (User, 2026-10-12: moved
   ahead of the prompt audit and the walker. Before the walker because the
   walker builds on how a hop ends; before the audit because it adds an
   implementer message the audit should cover; after the red-black tree,
   which may give the first real proof-red case: uregex had none, since
   Haiku runs the proof itself before DONE.)
8. Item 3: implementer-prompt audit against the uregex and red-black tree
   evidence. (User, 2026-10-11: the lessons hook and the prompt audit come
   before the parallel walker.)
9. Item 9: TypeScript tier rules — before the TypeScript project's Phase 3
   (user, 2026-10-12: the dogfood after the red-black tree is in TypeScript,
   run in a separate session).
10. Item 6 / step 5: the parallel walker (crucible); the one change big
   enough that a bootstrap might be reconsidered.

uregex walk evidence (for items 3 and 5): 7/7 goals done, 21:42Z-22:52Z;
Haiku 5.5 on every pass, no DECLINED, no DeepSeek fallback; 1 FIX round (g3,
oracle gap); 0 proof-red wakes; 1 wake (house false positive, item 7.2);
implementer cost ~3.19 USD estimated; 4 regression tests added by Haiku on its
own; clean rebuild 11/11 default, 13/13 ASan+UBSan.

rbtree walk evidence (2026-10-13): 7/7 goals done, 09:43-10:16 IST (33 min,
4-8 min per goal); Haiku 5.5 on every pass, no DECLINED, no DeepSeek fallback;
0 FIX rounds; 0 proof-red wakes (step 3 still has no real case); 0 wakes; Opus
DONE on every first review; 543 lines of library code; clean rebuild from a
fresh checkout 7/7 default, 9/9 ASan+UBSan. Phase 3 carried the cost instead:
two Grok plan rounds, three oracle rounds, a boxed 10-minute Tier 3 scratch.

If a bootstrap is ever reconsidered: launchers deny the sandbox read of
`$HOUSE/.env` by path only, so a stage-0 copy with a symlinked `.env` would
leave the real file (`~/claude-coding-workflow/.env`) readable to the
implementer. Deny the resolved real path too before running any walk from a
copy of the house.

## 1. Lessons hook: repeated failures become reminders (2026-10-11)

**The idea (user):** a Claude Code hook runs Haiku 5.5 over the session
transcript, finds what keeps repeating (failures, commands, corrections), and
adds it as a reminder Claude sees from the next message on. Not on every turn.

**Where the history is.** One JSONL per session at
`~/.claude/projects/<cwd with / as ->/<session-id>.jsonl`, beside a
`<session-id>/` folder (`subagents/`, `tool-results/`) and the project's
`memory/` (indexed by `MEMORY.md`). Hook inputs (`Stop`, `PreCompact`,
`SessionEnd`, `UserPromptSubmit`) carry `transcript_path`. Measured on the
workflow-optimisation session: 7.6 MB, 2,532 rows (390 user, 716 assistant),
9 tool results flagged `is_error`.

**Why it is worth doing.** That session repeated avoidable failures: `timeout`
assumed on macOS, GNU `cat -A` / `sed -i` assumed, zsh `bad substitution` and
`no matches found`, a Grok round run in the foreground past 600 s.

**Critique of the proposed shape:**
1. *Turn-count trigger (100 / 400) is the wrong signal.* Most sessions never
   reach it; long ones compact first. Trigger on `PreCompact` (detail is about
   to be summarised away), `SessionEnd`, or N new failures since the last run.
2. *Do not write CLAUDE.md.* It is checked in (churn, shared), and in a target
   repo a mid-walk edit is a tracked change the dirty-tree gate wakes on (and
   anything written under `.claude/` trips the `.claude` guard). It is also
   read at session start, not per message. Store in auto-memory (`feedback`)
   or a gitignored `CLAUDE.local.md` (outside `.claude/`, so neither guard
   sees it; check whether the safe-mode implementer loads it before relying on
   that); inject per message with a `UserPromptSubmit` hook.
3. *Overlap.* Auto-memory already holds corrections; `/fewer-permission-prompts`
   mines transcripts for repeated commands; compaction carries state. The hook
   should feed memory, not compete with it.
4. *Prompt injection becomes persistent (largest risk).* Transcripts hold
   untrusted text (web pages, tool output, files, video reports). Summarising
   them into standing instructions turns a one-off injection into a permanent
   one. Haiku reads the digest as data, answers in a fixed schema (lesson,
   evidence, count); nothing from tool output becomes an instruction without
   recurrence evidence; new lessons wait in a pending file for approval.
   Redact secrets before anything is written.
5. *Detection is deterministic.* `is_error` results, failing commands grouped
   by normalised signature, user corrections ("no", "don't", a repeated
   instruction) come from a stdlib script. Haiku only words the lessons from a
   small digest, never the whole transcript.
6. *Mechanics.* `claude -p` inside a hook re-fires hooks: run it `--bare`
   with an env-var guard, detached so the session never blocks; keep a
   per-transcript offset so runs are incremental and idempotent.
7. *Hygiene.* Cap (~10 lines), dedupe, expire lessons not seen again in ~30
   days, route by scope (machine-wide → user level; project → project).
8. *Repetition is not failure.* Count failures, retries after failure, and
   corrections; not `git status` run forty times.

**Proposed design:**

| Stage | What |
|---|---|
| Trigger | `PreCompact` + `SessionEnd`, or N new failures since the last run; detached, recursion-guarded |
| Extract | stdlib script over new transcript rows: failing commands by signature, error text, user corrections; secrets redacted |
| Distil | `claude -p --bare --model claude-haiku-5-5`, no tools, digest only, JSON lessons with evidence counts |
| Store | pending file; approved (or seen ≥3 times with no instruction-like text from tool output) → auto-memory `feedback` or `CLAUDE.local.md` |
| Use | `UserPromptSubmit` hook adds the capped list to each prompt |

**Done (2026-10-11/12)** — `docs/features/lessons-hook/` (PLAN, five Grok
rounds, journal). What changed from the shape above: a mod (`mods/lessons`)
instead of settings hooks, so the list is one `prompt.compose` system-prompt
section (no per-prompt injection); every lesson waits for `/lessons approve`
(no auto-promotion: recurrence does not make tool output safe); Haiku runs
`--safe-mode --restricted`, not `--bare` (which needs an API key); a persisted
evidence queue, so a capped day or a failed call loses nothing. Live: 6 s,
0.0012 USD, two lessons from this session's own zsh-glob and Write mistakes.

## 2. Verification-loop ideas from "Building verification loops in Claude Code" (2026-10-11)

Report: `~/Documents/claude-video-reports/2026-10-11/mQZB0l-rhxE/report.md`.
The house already has the loop (oracles + `proof:` rerun by the host + Opus;
the implementer runs the proof itself). Two small adoptions, both doc edits:

1. **Crucible asks "how would you check this by hand?"** The answer becomes a
   measurable acceptance check or a target `scripts/verify.sh` that `proof:`
   calls. Matters for app-shaped targets (web UI, server), where the host-run
   proof can drive a headless browser or hit an endpoint.
2. **After a wake:** when the Architect diagnoses a bounce by hand, ask
   whether a measurable check would have caught it; if so, the Architect adds
   it before re-dispatching — a `scripts/tests/` test for a house defect, an
   acceptance edit under `tests/acceptance/` for a target defect (never the
   target's `tests/regression/`, which is the implementer's). Done: the
   wording is in `skills/run-goal{,s}/SKILL.md`.

Not adopted: Claude Code's built-in `/verify` skill for the implementer. It is
headless and sandboxed, and a self-written skill ending in "Verdict: PASS" is
the self-grading the house forbids.

**Value, re-assessed during the uregex run: low.**
- 2.1 adds nothing for libraries, which is every dogfood target so far (ustr,
  skiplist, funnelsort, consistent-hash, udt, uregex): their oracle already is
  the hand check. Item 5's Grok oracle review also asks the question 2.1 asks
  ("what does the plan claim that no case checks?"). Keep 2.1 parked until the
  first app-shaped target (web UI, server), then add it to the crucible.
- 2.2 is already what happens: the g1 `claude-config-tamper` wake was
  diagnosed by hand and the fix landed with a regression test
  (`result-parse-test`, harness `.cc-writes`). Writing it down costs one line
  in the run-goal / run-goals skills' "after a wake" section; do that when
  those skills are next edited, not as its own change.

## 3. Review the implementer prompt for Haiku with dogfood evidence (2026-10-11)

From "10 New Rules for Claude Skills"
(`~/Documents/claude-video-reports/2026-10-11/VQyYzLJ6xos/report.md`): test a
prompt on the model that runs it. The implementer prompt in
`claude-implement.sh` was written for DeepSeek and now drives Haiku 5.5 at
xhigh. The uregex dogfood run is the test: per goal, keep fix rounds,
BLOCKED / DECLINED outcomes, DeepSeek fallbacks, proof failures and the
reviewer's recurring findings. Afterwards audit the prompt against that
evidence (`claude-api` skill's `prompt-audit`). The house already follows the
video's other nine rules (skills ≤ 228 lines, references one level deep,
risk-matched freedom, host-script checklists and FIX loop, pinned installs,
must-hold rules in code); a table of contents for files over 100 lines is
skipped unless the run shows a skill section being missed.

## 4. Temp-file hygiene (2026-10-11)

**Done (2026-10-11):** crucible at `docs/features/temp-hygiene/` (Grok APPROVED in
round 3, 10 findings: 9 taken, 1 in part), implemented in-session:
`scripts/lib/cache.sh`; `CW_OUT_DIR` in the three launchers (raw output dropped
only standalone and `ok`); run folders and walker stop folders under
`~/.cache/claude-coding-workflow/runs/`, Grok verdicts under `grok/`, both 0700
and pruned past 14 days; every test isolates `TMPDIR` and `HOME`; tests in
`scripts/tests/tmp-hygiene-test.sh`; the leak guard is `scripts/tests/run-all.sh`.
The measurements below are the input it started from.

Nothing in the house deletes its own temp files; macOS clears `$TMPDIR` at
reboot and by `tmp_cleaner`. Measured 3 days after a boot, in
`/var/folders/…/T/`: 1,385 `run-goal-*` folders (42 MB; removed only when a
goal succeeds), 581 `claude-implement-raw-*`, 180 `claude-goal-raw-*`, 153
`run-goals-*`, 14 `grok-review-*`. Almost all come from the test suites,
which call the real scripts and let them write to the real `$TMPDIR`. The
`.err` files are world-readable (`0644`); the raw outputs are `0600`.

1. **Tests:** every test script exports `TMPDIR` as its own temp folder, so
   what the scripts it drives write is removed with it (~95% of the files).
2. **Launchers:** delete raw output and `.err` on exit, keeping them only on
   failure or under a debug variable.
3. **Evidence that must outlive a run** (a woken goal's folder, Grok
   verdicts until logged): move under `~/.cache/claude-coding-workflow/`,
   pruned past 14 days when the next run starts.
4. **`mktemp -t` templates:** BSD `mktemp -t` treats `grok-review-raw-XXXXXX.json`
   as a prefix (files come out `grok-review-raw-XXXXXX.json.RbHZfde4ti`); use
   `mktemp "${TMPDIR:-/tmp}/grok-review-raw-XXXXXX"`.
5. **Clear today's leftovers** once the dogfood run ends: no walk or review
   may be live, since a woken goal's folder holds its stop file.

## 5. Oracle review, then tiered satisfiability instead of a full scratch implementation (2026-10-11)

**Done (2026-10-11):** crucible at `docs/features/oracle-review/` (Grok APPROVED in
round 5, 29 findings taken; always-fresh sessions), implemented in-session:
`grok-review.sh --oracle`, `scripts/lib/oracle-files.py`, `skills/to-goals/` §4-5
and `GOAL-FORMAT.md` tiers, CLAUDE.md, GLOSSARY.md, README; tests in
`scripts/tests/grok-review-test.sh`. The design below is the input it started
from; the signed plan supersedes it. Mutation checks moved to item 8.

Raised by the user during uregex Phase 3: the "prove the oracle satisfiable"
rule made the Architect (the most expensive model) write a ~550-line scratch
Pike VM, effectively the whole product, which the Haiku implementer then
writes again. That inverts the house's cost model and grows with project size.

Measured on uregex: the scratch caught two real oracle defects, and **both
were harness/build defects** (`check.h` failing `-Werror`; CTest `WILL_FAIL`
not covering a signal abort), not wrong expected values. Every computed
expectation held. Six planted bugs were each caught (mutation check), which
needs an implementation to plant them in.

Proposal, in this order (user, 2026-10-11): review first, then the cheapest
sufficient evidence. This is the Phase 3.5 oracle review already planned as
step 4 of the workflow optimisation; build them as one change.

0. **Review before any scratch code.**
   a. *Architect self-review* of every acceptance case against PLAN.md and the
      oracle failure classes: each expected value traced to a plan sentence,
      no invented symbol or private-signature pin, no tautology or cancelling
      differential, no case the plan leaves ambiguous (drop it, as with `[a\`
      in uregex, or bounce it to the plan), the oracle builds under the
      project's real flags.
   b. *Grok review for hardening*: `grok-review.sh --oracle`, resuming the
      plan-attack session (it knows the risks it raised) with a size guard,
      falling back to a fresh session seeded with PLAN-REVIEW-LOG.md. It gets
      PLAN.md, GOALS.md and `tests/acceptance/`; it attacks the oracles
      (missing plan cases, wrong expected values, ambiguity, vacuous passes,
      e.g. a proof that passes when the oracle is not registered).
      Architect arbitrates each finding with a logged reason, as in Phase 2.
1. **Always (cheap): a build check in the project's own toolchain**, against
   stubs of the planned API, with the project's real strictness. Catches
   invented symbols, signature pins, warning-as-error failures. It differs
   per language:
   | Language | Check |
   |---|---|
   | C / C++ | compile each oracle against the planned header, link against stub definitions, real flags (`-Werror`, sanitizers) |
   | Python | import the oracle against a stub module (`typing.Protocol`/stub functions), `pyright` or `mypy --strict` if the project uses one, `pytest --collect-only` so collection errors surface |
   | TypeScript | `tsc --noEmit` against a stub `.d.ts` for the planned API, the project's `strict` settings; the test runner's list mode (`vitest list` / `jest --listTests`) |
   | Rust / Go | `cargo test --no-run` / `go vet` + `go test -run '^$'` against stub items |
   The stub is the plan's API with every body a trap (`abort()`, `raise
   NotImplementedError`, `throw`), so the oracle compiles but cannot pass.
   Prove harness seams (sanitizer traps, test registration, discovery) with
   a tiny experiment.
2. **Computed expectations:** check against an existing reference (a mature
   library or tool with the same semantics) or a small brute-force model of
   the spec (slow, ~100 lines), not a production-shaped scratch.
3. **Full scratch only** when neither exists and the oracle carries novel
   computed claims; time-boxed, and never shown to the implementer.
4. **Mutation checks move after implementation:** plant bugs in the
   implementer's real code (host or reviewer step), so no scratch
   implementation has to exist to plant them in. The mutations themselves are
   still work to write; keep them few and aimed at the plan's riskiest rules.
Change belongs in `skills/to-goals/SKILL.md`, `GOAL-FORMAT.md` and the
oracle section of `CLAUDE.md`; decide after the uregex run shows how many
rounds bounce on oracle defects.

## 6. Parallel walker: goal statuses stay in GOALS.md (2026-10-11)

Decision for step 5 (`run-goals.sh --jobs N`): **a single-writer walker plus
atomic replace**, not a SQLite status store. Both are small, testable, and keep
GOALS.md as the one source of truth in git.

1. **Single writer.** Goal processes in worktrees never write GOALS.md. They
   report through their exit code (and the JSONL event index); only the walker
   sets statuses and commits them in the main checkout. With one writer there
   is no write-write race to lock against. Today `run-goal.sh` sets its own
   goal's status, so this is the real design change.
2. **Atomic replace.** `goals.py`'s `write_fence` truncates and rewrites
   GOALS.md in place, so a concurrent reader (the `/walk` pane, a starting
   goal) can see a torn file. Write a temp file in the same directory, flush
   and fsync it, then `os.replace` it over GOALS.md; readers see the old file
   or the new one, never half. About five lines.

SQLite was considered and rejected:
- it splits "what the goals are" (GOALS.md, the contract both agents read)
  from "where they stand", so resume, the journal, todos, the `/walk` pane and
  the contract-drift checks (`status-only-id`) would all be rewired;
- status history leaves git (every change is a commit today, e.g.
  `chore(g1-scaffold): orchestrator done`); a binary DB is not reviewable,
  merges badly, and does not travel with a clone;
- worktrees would share a DB outside the repo, making it per-machine state;
- locking modes, busy timeouts and schema migrations need their own tests and
  hardening, solving concurrent writers the single-writer rule already removes.

Where SQLite would earn its place: many processes writing fine-grained state
often, or real querying. The closest candidate is the JSONL event index, not
GOALS.md; `O_APPEND` of small lines from several goal processes is already
safe, and `logs.sh` covers today's queries.

Carried inputs for step 5 from the uregex run: the event index keys a repo by
its cwd (`repo_id`), so worktree goals must report into the main checkout's
index or the walk pane will not see them.

Carried input from item 10 (walk tasks, 2026-10-14): the footer is gone; the
`walk` mod's task list replaces it. A walk's tasks come from the walk file the
launching session owns (`events.py walks`, `session` / `root` in the walk
file) and the graph of that root, so worktree goals must also report into the
main checkout's index and walk file. Parallel goals each read `running`, so
several tasks are `in_progress` at once (the reconcile already allows it). The
list follows one walk per session; `walks`' `live` is the walker pid, so a
parallel walker must keep a `walk` row with a live pid while any goal runs.

## 7. House defects found by the uregex dogfood run (2026-10-11)

1. **Grok rounds outrun the 10-minute foreground call.** Measured from the
   verdict files (start in the name, finish as mtime): round 1 on the 237-line
   uregex plan took ~20 minutes at high reasoning effort, round 2 ~12 minutes,
   round 3 ~5 minutes. The first rounds, which do most of the reading, are the
   ones that run past 600 s. `CLAUDE.md` ("Foreground timeout: **10 minutes**")
   and `skills/crucible/SKILL.md:191` still say to run each round in the
   foreground with a 600000 ms timeout. Change both to `run_in_background:
   true` with the harness wake, as Phase 4/5 already do. One-line doc edits.
2. **`claude-config-tamper` false positive on g1 — fixed in-run.** Claude
   Code's sandbox creates `.claude/.cc-writes/` in the implementer's repo;
   `lib/claude-meta.py` now lists only files and links and skips it, and the
   stop detail no longer starts with a blank entry. Covered by
   `result-parse-test` (hermetic: the run carries its own global git ignore).
   Recorded here so the change is reviewed with the rest when committed.
3. **A cancelled Grok turn was reported as a review — fixed in-run.** On the
   oracle-review crucible, round 1 called `run_terminal_command` (outside the
   read-only set); the refusal ended the turn `stopReason: cancelled` with a
   255-byte preamble, and `grok-review.sh` printed `GROK_REVIEW_RESULT: ok`.
   Now any stop but `end_turn` is `error (turn stopped: <reason>)`, both
   prompts name the only tools, and `scripts/tests/grok-review-test.sh`
   (fake `grok` recording its real argv) covers it, wired into
   `install.sh --check`.

## 8. Mutation checks on the implementer's code (2026-10-11)

Deferred from item 5 (they need `run-goal.sh`, which that slice did not touch).
After a goal's proof is green, plant a few bugs in the implementer's real code,
aimed at the plan's riskiest rules, and require the goal's oracle to turn red
on each; a surviving mutation is an oracle gap. On uregex, six planted bugs
were each caught, but that needed a scratch implementation to plant them in;
on the real code it needs none. Open: who writes the mutations (host script
vs reviewer), how many, and whether a survivor wakes or only journals.

## 9. TypeScript rules for Tier 1 and Tier 2 (2026-10-12)

**Why (user):** planting bugs and running the cheap oracle checks is not meant
to catch every possible error, only the ones that really break an oracle in
this language, so the expensive model never has to fall back to Tier 3 (a full
scratch implementation of the feature to validate the tests). The next project
after the red-black tree is TypeScript, and `GOAL-FORMAT.md` gives TypeScript
one table row (`throw new Error("<feature>-trap")`; the message in the
runner's failure). C and Python have rules learned on the dogfoods (flushed
traps, `-Werror`, `WILL_FAIL`, `PYTHONDONTWRITEBYTECODE`); TypeScript has none
yet.

**Research:** `docs/research/2026-10-12-typescript-tier-rules.md` (two Haiku
5.5 agents, high effort, sourced, not yet verified by the Architect). The
gaps it found, by what they would let through Tier 1 or Tier 2:
1. *No type check in the run.* Vitest, Node's type stripping, Bun and Jest
   with babel/swc never check types, so an oracle with a wrong-typed call or
   an invented type still reaches the trap and passes Tier 1. Add a
   `tsc --noEmit --incremental false` step over the oracle and stubs, as well
   as the run (GOAL-FORMAT's "never compile-only" rules out compiling instead
   of running, not both).
2. *Ways to pass against the stub:* an un-awaited rejection, a bare
   `toThrow()`, a `vi.mock`/`jest.mock` of the feature module that replaces
   the trap. Pin the trap text and require it in the output.
3. *Vacuous runs:* `.only` allowed locally (Vitest unless `CI`), snapshots
   that auto-write or auto-pass, zero tests collected. `CI=1`,
   `allowOnly: false`, no snapshot oracles, count the tests.
4. *Files the proof leaves:* coverage, `.tsbuildinfo`, the Vitest/Vite and
   Jest caches, `__snapshots__` (the analogue of `PYTHONDONTWRITEBYTECODE`;
   otherwise the first goal wakes as tampering).
5. *Tier 2 semantics:* IEEE doubles and `-0`, string-order `sort()`, UTF-16
   `length`, date-only strings parsing as UTC, ICU-dependent collation,
   `toEqual` ignoring `undefined` keys; cross-check on the proof's runtime,
   TZ and ICU, with a reference, a brute-force model or fast-check.

**Plan:** a small crucible (it changes the to-goals rulebook): verify each
cited source; keep only the rules that would break a real oracle; write a
TypeScript block in `GOAL-FORMAT.md` (the Tier 1 `tsc` step, Vitest and
node:test recipes, the Tier 2 list) and the matching lines in
`skills/to-goals/SKILL.md` §4; prove it on a tiny throwaway TypeScript repo
the way the C rules were proved: plant each oracle defect class and show the
recipe turns it red. Done before the TypeScript project's Phase 3.

## 10. Walk progress in the task list; the walk footer dropped (2026-10-13)

Seen on the rbtree walk: the Architect seeds the task list from `goals.py todos`
at walk start, and the run-goals skill leaves it stale until the walk exits (the
walker is a separate process). The user read "7 tasks (0 done, 7 open)" as the
walk's state while the walk was 3/7, and prefers the task list to the footer.

Proposal (user, 2026-10-13): the `walk` mod keeps the task list current, and the
footer goes.
- The mod calls `$.tool.call({ tool: "TaskUpdate", ... })` (and `TaskCreate` /
  `TaskList`) from the walker's event stream it already reads: a goal's start
  → `in_progress`, done → `completed`, bounced → stays open with the reason.
  Better: the mod creates the tasks itself at walk start, so the Architect no
  longer seeds them and nothing drifts; the run-goals skill's "seed the todo
  list" step and its stale-badge note go.
- Sessions with `TodoWrite` instead of the `Task*` tools get the whole list
  rewritten with it.
- The footer (`walk <goal> r<n> · <phase> · <done>/<total>`) is removed; the
  `/walk` pane stays unless the user says otherwise.
Probe first, with a throwaway mod: (1) `TaskUpdate` called from a mod runs with
no permission prompt; (2) it changes the list this session displays, not a
separate one. If either fails, stop and tell the user before building.

## 11. House notes from the rbtree dogfood (2026-10-13)

1. `grok-review.sh` has no timeout and no liveness check: a round started before
   the Mac slept sat ~5 h with 3.5 s CPU and no output, indistinguishable from a
   slow round. Add a wall-clock cap and/or a no-output-for-N-minutes check that
   fails the round as void; long runs go under `caffeinate -i`.
2. to-goals tips: a planted-bug runner must compile each variant from scratch
   (Apple's `make` compares mtimes at 1 s, so a restored file inside the same
   second keeps the planted object); never splice text with `perl -e "s/…/$x/"`
   when `$x` can hold `$'`, `$(` or `$&` (it duplicated half of GOALS.md); zsh
   arrays are 1-indexed (a Tier 1 loop mislabelled every goal).
3. The rbtree DAG is the first real case for item 6: after g3, g4 / g5 / g7 are
   independent.
