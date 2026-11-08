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
7. ~~Step 3: a red host proof becomes a fix round~~ — done (2026-10-14):
   `docs/features/proof-fix/` (PLAN, review log, journal), ADR 0002. A red
   proof that clears the mechanical checks is a proof fix round inside the
   shared `MAX_FIX_ROUNDS`; a round with no change outside the journal wakes
   `proof-red`; a resume after it proves first. Still no real red-proof case
   from a dogfood: the evidence is planted (`scripts/tests/proof-fix-test.sh`).
   Parked from it: item 12 (sandbox the host proof).
8. ~~Item 3: implementer-prompt audit against the uregex and red-black tree
   evidence~~ — done (2026-10-14), run alongside step 3: `docs/features/prompt-audit/`
   (AUDIT.md, journal). Two follow-ups stay open: a live fix round on a mini
   dogfood to check the short resume message (M2), and a short pass on step 3's
   fix-handoff wording once built. Parked from its flags: Haiku's non-blocking
   questions ("Open for the Architect") reach nobody; a `question` record that
   the walk-end review lists would surface them. The run-goals skill's walk-end
   step now watches END records for repeated notes, the trigger for the next
   audit. (User, 2026-10-11: the lessons hook and the prompt audit come
   before the parallel walker.)
9. ~~Item 9: TypeScript tier rules~~ — done (2026-10-14):
   `skills/to-goals/TYPESCRIPT.md`, proved in `docs/features/ts-tier-rules/`
   (PLAN, review log, EVIDENCE, `fixture/run-plants.sh`: 72 cases). Vitest
   and node:test only. Carried inputs for the TypeScript project are in §9.
   (User, 2026-10-12: the dogfood after the red-black tree is in TypeScript,
   run in a separate session.)
10. ~~Item 6 / step 5: the parallel walker~~ — built (2026-10-15), in-session
   (user, Q1: no bootstrap): `docs/features/parallel-walker/` (PLAN, six Grok
   rounds, EVIDENCE with the step 0 sandbox measurements, journal).
   `run-goals.sh --jobs N` runs fork-join waves in worktrees
   (`scripts/lib/wave-walk.sh`); `--jobs 1` is the old loop. Live dogfood:
   an rbtree replay with `--jobs 3` (PLAN step 12). Follow-ups: items 13
   and 14.

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
   | Rust | superseded: rustc type-checks inside the `proof` itself; see `skills/to-goals/RUST.md` (rust-tier-rules) |
   | Go | `go vet` + `go test -run '^$'` against stub items |
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

Carried input from step 3 (proof fix rounds, 2026-10-14): how a hop ends
changed. A red host proof is a proof fix round, not a stop; fix lines carry
`source=review|proof` and, for a proof fix, `head=<sha>`; `resume-state.py`
prints three more fields (`PENDING_FIX_SOURCE`, `PENDING_FIX_HEAD`,
`PENDING_FIX_STUCK`), and a resume after a no-progress `proof-red` proves
before it dispatches. The no-progress rule diffs the tree outside the journal
and `GOALS.md` against `head=`; a worktree goal must diff its own worktree, and
the journal it excludes is the main checkout's. Implementer handoffs live in
`$RUN_DIR/implementer/`, the only run-folder path its Read, Edit and Write
tools are given (its shell still reads `$RUN_DIR`, item 12).

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

DONE (2026-10-24): `docs/features/mutation-checks/` (PLAN, Grok 8 rounds with a
redesign the user chose, journal). After a DONE review, run-goal.sh resumes the
reviewer for a turn of its own that writes up to `CW_MUTATIONS` (3) mutations;
each runs on a copy-on-write clone of the checkout with a private git dir,
after a green baseline, scored by the host's own rule. Survivors are recorded
(journal, warning event, walk-end line, the diff kept), not a stop;
`CW_MUTATION_GAPS=stop` stops the walk after the goal lands. Tests:
`mutation-test.sh`.

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

**Carried inputs for the TypeScript project's Phase 1 recon** (item 9, Q3;
measured on `~/dogfood/ts-tiers`, 2026-10-14). Item 1 stops every goal when
the walk's `PATH` lacks Node; item 2 stops any goal that needs an install:
1. *The host proof may not find Node.* `run-goal.sh` runs the `proof` with
   `bash -c` (no login shell) in the walk's environment minus credential
   variables, so an `fnm`/`nvm` Node is on `PATH` only if the walk's `PATH`
   has it — this session's Bash did not — and a `node_modules/.bin` shim
   starts with `#!/usr/bin/env node`, which looks Node up on `PATH` again. What worked: the `proof` calls Node by absolute
   path and every tool by its script (`node_modules/vitest/vitest.mjs`,
   `node_modules/typescript/lib/tsc.js`), proved under `env -i
   PATH=/usr/bin:/bin bash -c`. The implementer's own shell needs the same
   (its launcher's `PATH`); decide how the target pins that path.
2. *The implementer's sandbox has no network*, so `npm install` cannot run
   during a goal. What worked: dependencies pinned in a committed lockfile and
   installed once (`npm ci`) before any dispatch, `node_modules/` ignored. A
   goal that needs a new dependency is a plan decision, installed by the
   Architect before that goal. A parallel walk does this through GOALS.md's
   `worktree_setup:` key (item 6), in every worktree and after every merge.
Also from item 9: TypeScript 7.0.2 was current (the research assumed 5); the
rules name the versions they were proved on, and `run-plants.sh all` reruns
them after an upgrade.

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
   **Done (2026-10-16):** `grok-review.sh` runs Grok under `run-timeout.py
   --wall` and `caffeinate -i`: a wall-clock cap (`GROK_REVIEW_TIMEOUT`,
   default 3600 s, exit 124) and a stop when the wall clock jumps more than
   `GROK_REVIEW_SLEEP_GAP` (120 s) between checks a second apart, i.e. the host
   slept (exit 125); both print a void `error` result. A no-output check was not
   built: `--output-format json` prints nothing until the end. A forward clock
   step of more than the gap, or the caller held stopped that long, also reads
   as a sleep (a void round, rerun). SIGHUP stops the session too. Tests in
   `grok-review-test.sh`; seven plants red.
2. to-goals tips: a planted-bug runner must compile each variant from scratch
   (Apple's `make` compares mtimes at 1 s, so a restored file inside the same
   second keeps the planted object); never splice text with `perl -e "s/…/$x/"`
   when `$x` can hold `$'`, `$(` or `$&` (it duplicated half of GOALS.md); zsh
   arrays are 1-indexed (a Tier 1 loop mislabelled every goal).
3. The rbtree DAG is the first real case for item 6: after g3, g4 / g5 / g7 are
   independent.

## 12. Sandbox the host proof (2026-10-14)

The host proof runs implementer-written code unsandboxed, with network and the
person's files readable (`run-goal.sh`, credential-named variables unset).
Step 3 (ADR 0002) feeds its output back to the implementer, so a test that
prints a secret could reach a model provider; the excerpt is redacted
(`redact_proof`) and the implementer's handoffs moved to their own folder,
which narrows it but does not close it. The real fix: run the proof under the
same kind of sandbox as the implementer (reads denied outside the repo and the
toolchain, no network unless the plan names hosts), with a measured list of
what a C, Python and TypeScript proof legitimately needs.
Known limits in the same area: the implementer's shell (Bash is allowed, and
the sandbox's read denials are paths, not the run folder) can still read the
raw proof logs in `$RUN_DIR`; only its Read, Edit and Write tools are confined
to `$RUN_DIR/implementer/`. Deny reads of `$RUN_DIR` outside that subfolder
in the launcher's sandbox settings, once a path rule that excepts a
subfolder is measured to work. The legacy `IMPLEMENTER=codex` launcher
(`deepseek-code.sh`, sandbox `workspace-write`) reads outside its handoff
folder the same way.

**Done (2026-10-17):** `docs/features/proof-sandbox/` (PLAN with Amendment 1,
ten Grok rounds, EVIDENCE with step 0 and step 6 measurements, journal). Every
`proof_exec` (host proof, `worktree_setup`, merged proofs) runs under a
generated `sandbox-exec` profile (`scripts/lib/proof-sandbox.py`), with a
self-test before any implementer pass and `CW_PROOF_SANDBOX=off` as the only
opt-out; no network by default (`proof_network: loopback|true`); one secret
list shared with the implementer (`scripts/lib/secret-paths.txt`); a
`secrets-in-checkout` gate (`CW_ALLOW_DOTENV=1`); a hard-link pre-check; a
dependency folder per walk; the implementer's folder under `handoffs/`,
denied every run folder.

Follow-ups from the build's Opus review (2026-10-17), not closed by item 12:
- `kern.procargs2`: a proof can read the arguments and environment of any
  process the user runs (Seatbelt does not gate it; EVIDENCE.md). Closing it
  needs proofs run as another user. Until then: keep keys out of long-lived
  processes' environments.
- `/tmp/claude-<uid>` (Claude Code's TMPDIR for every sandbox of the user) is
  shared by all of them; the implementer can read what another Claude Code
  session left there. Not reachable by proofs. Done 2026-10-23: each
  implementer run gets its own TMPDIR under `/private/tmp/cw-<uid>`
  (`CLAUDE_CODE_TMPDIR`), and the sandbox denies reads of both roots but that
  folder (proof-sandbox EVIDENCE, "The implementer's private TMPDIR"). The
  legacy `IMPLEMENTER=codex` launcher is unchanged.
- Probes not yet in the tests, all from inside the implementer's sandbox (each
  needs a model pass): the firmlink spelling of the temp roots
  (`/System/Volumes/Data/private/tmp/claude-<uid>`); a hard link that pulls
  another session's file into the implementer's re-allowed TMPDIR; plan step
  0's hard-linked-secret plant. In the tests since 2026-10-23
  (`proof-sandbox-test.sh`, `parallel-walk-test.sh`): the firmlink and case
  spellings (`.SSH`, `.GIT`, `.Git`) against the proof sandbox's secret, `.git`
  and temp-area rules, each with a control outside the sandbox; a ctypes
  `bootstrap_look_up` of securityd (1100 inside, 0 outside); the walker's
  `PROOF_SANDBOX_REASON` branches in `integrate` and `run_setup`.
  Done 2026-10-25: the three model-pass probes, in one real launcher pass
  (EVIDENCE.md, "Implementer probes left from item 12"): the firmlink spellings
  of `/tmp/claude-<uid>`, `/private/tmp/cw-<uid>` and `/var/folders` refused (a
  control read through the firmlink worked); `ln` of another session's file
  into the implementer's TMPDIR, and of a `--deny-read` file into the repo,
  refused.
- Test time: item 12 took the full suite from ~22 to ~49 min, mostly the
  parallel-walk files (~37 walks each). The sandbox self-test runs once per
  walk and once per goal (~1 s), and a red proof waits ~3 s for its denial
  listing. Cheap cuts: the walker passes its members "self-test passed" (only
  the walker sets their environment), a test-only setting skips the listing's
  wait, and the walk tests split across more files for run-all -j (done
  2026-10-22 for the trust checks: four files, 20m09s alone → 7m35s side by side).
  The other two done 2026-10-23: `--jobs` members get `CW_PROOF_SANDBOX_CHECKED=1`
  (honoured only in worktree mode), and `run-all.sh` passes
  `CW_PROOF_DENIALS=off`; `run-all.sh` also keeps the host awake
  (`cw_keep_awake`).
- A walker resume that only integrates finished goals runs merged proofs
  under `CW_PROOF_SANDBOX=off` / `CW_ALLOW_DOTENV=1` without a journal record
  (the walker prints it; members journal their own). Done 2026-10-23: the walker
  journals `ORCHESTRATOR overrides walk <notes>` after walk-start whenever an
  override is set (a walker-only record in `journal-merge.py`).

## 13. Parallel walker: dynamic dispatch (2026-10-15)

Item 6 ships fork-join waves (user's choice): a goal that finishes early waits
at the join for the slowest member of its wave. Each wave writes one
walker-owned `join_wait` event (`events.py`), with each goal's seconds of
waiting in its payload. If real walks show that idle time matters, those rows
are the case for dynamic dispatch: start the next frontier goal as soon as a
slot frees. It needs polling for whichever child exited (bash 3.2 has no
`wait -n`), integrations interleaved with running goals, and a drain policy
for a stop mid-flight, all of which waves avoid today.

**Deferred (2026-10-25, user):** three `--jobs` walks of the rbtree DAG had one
wave wider than a goal; its waits were 0-83 s of a ~55 min walk. Revisit when
`join_wait` rows show minutes, on a wide DAG with uneven goals.

## 14. Parallel walker: an integration-red as a fix round (2026-10-15)

A goal green on its own but red once merged (`integration-red`) stops the walk
in item 6: the walker resets its merge, the goal stays `in_progress` with its
branch and worktree, and the Architect decides. Turning it into a fix round
would mean moving the goal's base onto the new walk tip, which puts other
goals' changes into the review diff. Revisit with real cases; none exist yet.

**Deferred (2026-10-25, user):** still no real `integration-red`.

## 15. A "simpler?" question in the goal review (2026-10-15)

User proposal: enforce simplicity from the start, per goal, not with a pass
after the walk. The implementer prompt already says "Stop at green:
refactoring belongs to the review stage. Write the least code that passes"
(`claude-implement.sh`), and "allow refactor after green" was withdrawn on
2026-10-10. The goal reviewer has only "SMELLS — Fowler list as judgement
calls". Add a seventh heading to `claude-goal-review.sh`'s prompt: **SIMPLER**
— could this diff be materially smaller or plainer with the same behaviour,
the same tests passing and the same scope (dead code, duplicated logic, an
abstraction with one caller, a hand-rolled stdlib function)? A FIX only when
the simpler form is concrete and the saving real, otherwise a note: each FIX
spends one of the shared `MAX_FIX_ROUNDS`. A FIX becomes a fix round inside
the goal, re-proved and re-reviewed by the hop before anything is merged. Not
an end-of-walk pass: that would rework reviewed, merged code and, in a
parallel walk, several goals' code at once; cross-goal cleanup stays in
Phase A. Order (user, 2026-10-15): right after item 6's live dogfood, before
item 12, so the next real walk measures the extra fix rounds it causes.

**Done (2026-10-16):** heading 7 in `claude-goal-review.sh`'s fresh-review
prompt (the re-review reuses "the same rules"); pinned in
`review-fallback-test.sh`, and `findings-test.sh` shows a SIMPLER analysis line
is not a finding, even with a `FIX:` inside the line. The rbtree parallel re-run
measures the fix rounds it adds; if re-reviews burn rounds on new SIMPLER points
against code already passed, limit SIMPLER on a re-review to what changed since
the last round (Opus review note, 2026-10-16).

## 16. Porcelain parsing in run-goal.sh (2026-10-16)

From the parallel walker's seventh Opus review: `run-goal.sh` reads `git status
--porcelain` lines as `${line:3}` with surrounding quotes stripped. A path with
`"`, `\` or a control character (still C-escaped with `core.quotePath=false`)
or a rename (`old -> new`) is misread. `git status --porcelain -z` removes the
whole class. Low priority: such a journal or contract path is exotic.

**Done (2026-10-16):** the fresh-start gate and the after-pass dirty-tree
check in `run-goal.sh` read `git status --porcelain -z --no-renames`: each path
verbatim, a rename as its two paths (Opus's simpler form, over a parser for
the rename field). `scripts/tests/porcelain-test.sh` (serial mode): names with
`"`, `\`, a tab, a space and non-ASCII, a staged rename, a journal named with
`"`, an unexpected rename and a worktree (intent-to-add) rename after a pass.
Red on the old parser (10 checks) and without `--no-renames` (3). Needs git
2.18+, now stated in SETUP.md: older git rejects `--no-renames` and the empty
status passes both checks, the same fail-open as any failed `git status` before.

## 17. Parallel walker: recut a goal after a merge conflict (2026-10-16)

From the first live parallel walk (rbtree replay, `--jobs 3`): g4, g5 and g7
ran side by side; g4 integrated, g5 and g7 stopped `merge-conflict` on the
same `add_library(...)` line in `CMakeLists.txt`. Handing them back (`set
ready`) recuts them, but parallel siblings that edit one line conflict again,
so each wave integrates one of them. The planning fix shipped first
(GOAL-FORMAT.md "Registration points"; a to-goals quiz question). The walker
fix, decided with this evidence: on a plain `merge-conflict` (no tamper, the
reviewed SHA verified), recut the goal once and run it fresh from the new walk
tip in the next wave instead of stopping. It costs one more implementer pass
and review per conflicted goal, and every wave still integrates at least one
goal, so the walk finishes. It touches the integration and recut state the
item 6 reviews hardened over five rounds: its own crucible.

DONE (2026-10-23): `docs/features/merge-conflict-recut/` (PLAN, Grok 3 rounds
approved, journal) and parallel-walker Amendment 6. A plain merge conflict
recuts the goal once per walk (counted from the journal since the walk's
`walk-start`) and the walk goes on; the goal runs fresh from the new tip, the
old attempt kept at `refs/cw-conflict/<g>/<n>`. A second conflict in the same
walk stops as before. Tests in `parallel-walk-recut-test.sh` and
`walk-status-test.sh`.

## 18. `/walk` with no argument outside the target repo (2026-10-16)

`/walk` opens the pane for the session's working folder; from the house repo
it showed "No GOALS.md at or above …" while this session's own walk ran in
`~/dogfood/rbtree-par` (the task list followed it correctly, through the walk
file). When the working folder has no GOALS.md, default to the walk this
session launched (`events.py walks --session`), as the task list does.
`/walk <dir>` works today.

**Done (2026-10-16):** `mods/walk` 0.3.1. A bare `/walk` whose working folder
has no GOALS.md reads `walks` for every session id the task poll has kept plus
the current one, and shows the walk `chooseWalk` picks with the task list's
remembered walk (live first, else the remembered one, else the newest). The
task poll runs first in each tick, so the fallback sees the walk the list
chose. The reply names the folder. `/walk <dir>` never falls back. Six tests
in `register.test.tsx`, seven plants red. Opus noted the extra `walks` scan per
tick while the pane shows a fallback walk: acceptable, reuse the task poll's
result if it ever matters.


## 19. `install.sh --check` reuses a fresh suite run (2026-10-16)

The gate before a commit runs `scripts/tests/run-all.sh -j 8`, then `install.sh
--check`, which runs the whole suite again (~30 min together at the end of item
6). A full `run-all.sh` run records its results under
`~/.cache/claude-coding-workflow/tests/last/` with a key of the tree it tested
(every tracked and untracked, not ignored file of the house, plus the git and
python versions), stored only when the key is the same at the start and the end
of the run. `--check` reuses that run when its key matches the tree now, and
says so; otherwise, or with `CW_CHECK_RERUN=1`, it runs the suite as before.

**Done (2026-10-16):** `scripts/lib/tree-key.py`; `run-all.sh` publishes a full
run's results (each test's rc and out, the summary, when, and a key line
with the tree key and the fail count) to `tests/last/`; `install.sh
--check` reuses them on a matching key and never deletes them. A reused failed
run still reads `tests: FAIL` (its fail count, not a grep of the summary).
`--check` reads a copy, so a publish meanwhile cannot change it; a failed
publish never changes `run-all.sh`'s exit status. The key does not cover an
edit undone before the run ends, `.git`, the environment beyond `CW_*` (PATH,
LANG, the `*_BIN` overrides, `CLAUDE_CONFIG_DIR`), tool versions other than
git and python, or the checkout path (another checkout with the same content
reuses the run): fine for a gate that runs both back to back in one shell.
`scripts/tests/check-reuse-test.sh`. Not tested: a publish failing after its
first step (the chain is the same `if`).

## 20. No full suite rerun for doc-only changes (2026-10-17)

User, 2026-10-17: a change to documentation only must not make `install.sh
--check` (or the plain `install.sh` that ends with it) rerun the whole suite.
Today `lib/tree-key.py` keys over every file of the house, so appending a
journal entry after a green gate costs the full ~49 min again (seen on item 12:
the gate passed, two doc entries were added, and the closing check reran it).

Shape: `tree-key.py` leaves out files no test reads: `docs/**` (plans, review
logs, journals, evidence, FUTURE-WORK) and the top-level `README.md`,
`SETUP.md`, `CLAUDE.md`, `PLAN*.md`. It keeps everything under `scripts/`,
`mods/`, `skills/` and any top-level file a test copies or reads
(`GOALS.example.md`, `.gitignore`). The excluded set is a list in one place,
with a test that fails if any test script names a path in it, so a later test
that starts reading a doc file puts that file back in the key. Not "every
`.md` file": skills and fixtures are Markdown that tests and agents read.

DONE 2026-10-22: `lib/tree-key.py` leaves out `docs/**` and every top-level
`*.md` but `GOALS.example.md` (`KEPT_TOP_MD`); `check-reuse-test.sh` checks a
doc edit keeps the run, `GOALS.example.md` and a skill do not, and that no
test reads a left-out path through `$HERE/../`.

## 21. GOAL-FORMAT "Registration points": a test glob breaks committed-red oracles (2026-10-22)

The rule's example registers one test per file with a `foreach` over
`tests/acceptance/*.c`. A plan whose oracles are all committed before the
goals run (the house's own to-goals output) cannot do that: the scaffold
goal's build would compile every later oracle, which calls API that does not
exist yet, and fail. Found drafting the rbtree re-run (2026-10-22). What
worked there: sources globbed, and each goal registers its oracle in a file of
its own (`tests/register/<name>.cmake`, one `rbtree_add_acceptance(<name>)`
call) that the harness includes by glob. Fix: replace the example with that
one-file-per-goal pattern, and say why a glob over the oracles themselves is
wrong when they are committed up front. Prose only; to-goals quiz wording to
match.

DONE 2026-10-22: GOAL-FORMAT.md "Registration points" and the to-goals quiz
(SKILL.md question 4) now say: sources by glob; no step of a proof may build,
type-check or collect a later goal's red oracle (a self-discovering runner with
each proof naming its files, or one registration file, package or include per
goal for a build that compiles every oracle together).

## 22. DeepSeek as the primary implementer, Haiku second (2026-10-22)

User, 2026-10-22, after reading the DeepSeek API docs: DeepSeek implements
first and Haiku 5.5 is the second implementer. Reverses the 2026-10-10 lock.
Agreed shape, to crucible after the rbtree --jobs 3 walk is recorded:
- a switch `IMPLEMENTER_PRIMARY=deepseek|haiku` in `claude-implement.sh`;
- the fallback runs on a refusal, a decline, or DeepSeek's 402 (insufficient
  balance); a 429 or 503 is a rate limit and stops as today, no switch;
- the model id moves to `deepseek-flash` (`deepseek-v4-flash` is retired and
  aliased to DeepSeek-V4.1-Flash-1017); decide the effort (DeepSeek maps
  `xhigh` to `high`; `max` is its top; the DeepSeek pass passes no
  `--effort` today);
- every goal's code now goes to DeepSeek (user accepted);
- proven by re-running the rbtree DAG with DeepSeek primary against the Haiku
  walk of 2026-10-22: fix rounds, review verdicts, cost, time.
Docs facts (api-docs.deepseek.com, read 2026-10-22): Anthropic endpoint
`https://api.deepseek.com/anthropic`; thinking on by default at `high`;
`reasoning_content` must be passed back on tool-call turns or the API returns
400; 2500 concurrent requests per account (429 beyond); peak pricing Beijing
09-12 and 14-18 on weekdays, off-peak half price.

## 23. The walker keeps the host awake (2026-10-22)

The rbtree `--jobs 3` walk lost 24 min to an idle sleep on battery
(05:49–06:13 UTC; parallel-walker EVIDENCE step 12b). Nothing failed. The run
paused and resumed on the user's wake. `grok-review.sh` already holds
`caffeinate -i` for its run (item 11.1); `run-goals.sh` and `run-goal.sh`
hold nothing. Shape: the walker holds `caffeinate -i -w $$` for the walk
(idle sleep only, so a closed lid still sleeps), and `run-goal.sh` does the
same when run alone.

DONE 2026-10-22: `lib/cache.sh` `cw_keep_awake` (`caffeinate -i -w $$`,
`CW_KEEP_AWAKE=0` off), called by `run-goals.sh` and by every `run-goal.sh`
(always, not only alone: simpler, and a wave's extra assertions are harmless).
Tests find the assertion by the script's pid and check it ends with the walk. A test asserts the assertion exists while a walk runs,
found by the helper's pid as in `650eb39`.

Item 22 status (2026-10-22): plan `a7aefd7`, step 0 `5d2a829`, the build
(default still `haiku`) reviewed DONE. Left for the flip commit, after the
rbtree comparison walk: the "who is primary" wording (CLAUDE.md roles table,
README intro, the run-goal skill description), and a goal that fell back to
DeepSeek and resumes after the flip would treat its `deepseek:` thread as the
primary (one switch back possible). Outside the plan: the `/walk-status` cost
(`events.py`) ignores `fallback_from`, so it undercounts a goal that fell back.

Addendum 2026-11-08 (prompt-audit `AUDIT-2026-11-08.md`, F1): `-i` was not
enough. The Paladin Amendment 2 walk stopped at 05:39 IST, its assertion died,
and the Mac idle-slept within 5 s (`pmset` `sleep 1`, on AC). From then on it
woke only in ~5 min DarkWake slices, and a PreventUserIdleSystemSleep assertion
does not stop a maintenance sleep out of dark wake. So the rerun's `-i`
assertions held nothing: ~3.6 h of a 7¼ h walk were asleep, and every 15–17 min
implementer "Request timed out"/"computer was asleep" stall fell in a sleep
window. `cw_keep_awake` and `grok-review.sh` now hold `caffeinate -i -s`
(PreventSystemSleep, honoured on AC); `orch-commit-test.sh` checks the
assertion's type in `pmset -g assertions`.

## 24. Serial walks check the journal against HEAD, not the goal's base (2026-10-22)

Found by Opus reviewing the item 22 prompt rule (EVIDENCE step 10). In a
serial walk, `run-goal.sh` holds the journal to HEAD (`orch_journal_problems
--records`). A pass that edits a committed record **and commits that edit**
leaves the working copy equal to HEAD, so nothing stops it. Only a `--jobs`
integration (`journal-merge.py`, against the merge base) catches it. Today's two
DeepSeek stops were caught only because the edit was left uncommitted. Fix:
`run-goal.sh` also requires the journal to start with its copy at `BASE_SHA`.
In reserve if the prompt rule is not enough: the implementer appends each
heading from the shell (`echo "## $(date -u …) — IMPLEMENTER …" >> journal`), so a
guessed time cannot be written at all.

DONE (2026-10-22): `run-goal.sh` commits the journal right after each dispatch
line (and the fix line before it), so every record the implementer can see is
committed. It then walks the journal's history (`orch_journal_chain_problems`,
`orch-files.py journal-chain`): its copy at `BASE_SHA`, at each first-parent
commit since that touched it, then the working copy. Each must start with the
last one kept, and the working copy must be kept. A record edited and
committed, in the same pass or an earlier one, stops the goal as
`journal-tamper` after the pass, or refuses a resume before dispatch, whatever
stop came between; putting the lines back (keeping what follows) clears it.
Within a run the pass is also held to its copy from just before it ran, which
covers a pass that amends or rebases the host's commits. Not caught: a pass
that amends or squashes away the first committed copy of one of its own
records, or rewrites history and then stops before the post-pass check (the
before-pass copy lives in the run's own dir). `journal-records-test.sh`
covers it.

Item 22 SHIPPED (2026-10-22): DeepSeek Flash is the default implementer with
Haiku 5.5 as the fallback, after the comparison walk (`12e6a6f`) and the
confirming walk after the journal prompt rule (`4e486f8`). The `/walk-status`
cost was done 2026-10-23: `events.py goal_stats` follows `lib/cost-rollup.py`'s
rule (a fallback's `fallback_from` counted on the primary's thread, a thread's
largest running total, `pass` values summed).

## 25. A forged ORCHESTRATOR record can move a resume's BASE_SHA (2026-10-22)

Found by Opus reviewing item 24. `orch-files.py --records` accepts
ORCHESTRATOR records in what the implementer appends: they are pure appends of
the documented shape. A forged `ORCHESTRATOR dispatch <goal> r0
BASE_SHA=<its own commit>` would be read by `resume-state.py` as the attempt's
base, so after a stop a plain rerun would compute `contract_drift` and the
review diff from that later base, hiding an earlier contract commit. Fix
direction: only the host writes ORCHESTRATOR records, so the appended text
may hold no ORCHESTRATOR record the host did not write itself (the host's own
lines are known: `journal_line` can keep them). That must hold at every
journal commit, the one `record_wake` makes on an early stop included, not
only after a pass.

DONE (2026-10-23): a resume no longer reads the journal. `run-goal.sh`'s
`journal_line` appends each record to the goal's host ledger
(`orch_host_ledger`:
`~/.cache/claude-coding-workflow/run-goal-<id>/host-records-<key>`, keyed by
the checkout's own git dir, worked out once at start while host git
is trusted) before the journal, and
`resume-state.py` and `attempt_fell_back` read the ledger. A line anyone writes
or commits to the journal (a forged dispatch, a body line, a replay of an old
record) changes nothing a resume decides. The ledger outlives a stop and the
implementer's sandbox cannot write it; a proof under `CW_PROOF_SANDBOX=off`
runs the implementer's code unsandboxed and could. A goal paused before
ledgers existed, run in another checkout, or in a repo since moved has none:
its resume stops and says how to hand it back safely (find the attempt's base,
review or reset the commits since, since a fresh start takes HEAD as its base). The journal's uncommitted tail is still held to the ledger
(`orch-files.py --records --host`), so a forged record is not committed under
the host's name. Tests: `journal-records-test.sh` (a forgery uncommitted, with
an early stop, committed with a contract change; another clone; a linked
worktree; a resume after a `.git` tamper stop),
`orch-commit-test.sh`.

## 26. A reviewer that changes .git stops under the wrong reason (2026-10-23)

Found by Opus reviewing item 24. Nothing checks `.git` right after the
reviewer. On a FIX verdict the check before the next dispatch commit
(item 24) reports it as `git-metadata-tamper`; on DONE, BLOCKED or bounced the
first git call after review runs inside `$(...)`, so only that subshell is
tainted, and the stop reads `head-moved-during-review` or
`orchestration-files-changed`, with GOALS.md already set to `done` on the main
checkout. Fix: `verify_git_meta "during review r${ROUND}"` right after the
reviewer returns, which covers every verdict route.

DONE (2026-10-23): `run-goal.sh` runs `verify_git_meta` and
`verify_claude_meta` "during review rN" right after the reviewer returns,
before any route, so a change to `.git` or to Claude Code's config stops the
goal under its own reason on every way out of the review (a verdict, a
timeout, an error, a rate limit). `result-parse-test.sh` covers three cases:
`.git` on FIX, `.git` on DONE, `.claude/` on DONE. The proof also gets a
`.claude/` check ("during proof rN"); the check before the dispatch commit
stays for a dispatch that follows a proof fix.

## 27. The implementer can read the user's macOS temp folder (2026-10-23)

Found while measuring item 12's shared `/tmp/claude-<uid>`: a sandboxed
implementer reads `$(getconf DARWIN_USER_TEMP_DIR)` (`/var/folders/…/T/`),
which holds other programs' temp files (database `-wal`/`-shm` files, service
folders), and presumably the rest of the per-user `/var/folders/…` tree (`C/`,
`X/`). What a `denyRead` of it breaks is unmeasured (caches such as clang's
module cache live under `C/`): measure a C, Python and Node build under it,
with the private TMPDIR in place, before adding it.

**Done (2026-10-25):** measured (EVIDENCE.md, "The user's macOS temp tree"):
denying the tree breaks only xcrun's lookup cache, so every `/usr/bin` `cc`,
`make` or `git` printed an error (clang's default module cache was already
unusable). `claude-implement.sh` denies reads of all of `/var/folders` in both
spellings, as the proof sandbox does, and re-opens `T/xcrun_db` only when
`getconf` names the usual `T/` folder and the file is a plain file of the
user's. Python and Node workloads passed under host `sandbox-exec` profiles;
real launcher passes confirmed the deny, `cc`, `make`, `git` and `tempfile`.
Tests in `implement-test.sh` (including `getconf` printing nothing, garbage or
a suffixed path).


## 28. Two other places hand a child the house's environment (2026-10-23)

Found by Opus reviewing the implementer's `CW_*` strip (the batch gate caught
run-all's `CW_PROOF_DENIALS=off` reaching the implementer's shell; the
launcher now strips every `CW_*`):
- Host proofs (`proof_env_unsets`, `lib/proof.sh`) strip only credential
  names, so a proof run by run-goal.sh sees the walk's `CW_*` settings
  (`CW_EVENTS_ROOT`, `CW_PROOF_DEPS`, `CW_PIN_*`, `CW_DENY_WRITE_FILE`) while
  the same proof run by the implementer does not. It matters only for a repo
  whose tests read `CW_*` (the house walking its own goals); strip them so
  both runs see the same environment.
- The legacy `IMPLEMENTER=codex` launcher (`deepseek-code.sh`) hands the
  Codex implementer's shell the full environment: every `CW_*` setting and
  any credential the caller exported. Give it `claude-implement.sh`'s
  `env_unsets`, or retire it now that DeepSeek runs through Claude Code.

**Done (2026-10-25):** host proofs, `worktree_setup`, merged proofs and
mutation runs strip every `CW_*` setting too (`proof_env_unsets`,
`lib/proof.sh`; `PROOF_ENV_KEEP` still keeps a named one), so a proof sees the
same environment from the host as from the implementer. `deepseek-code.sh`
starts Codex without any `CW_*`, `ANTHROPIC_BASE_URL` or credential-named
variable but `DEEPSEEK_API_KEY`, which Codex reads (`env_key`), and its config
keeps that key from Codex's shell tool (`[shell_environment_policy] exclude`).
Measured with Codex 0.163 and one real DeepSeek call each (a wrapper swapping
the prompt for `env | grep -c`): the shell saw `deepseek=0 cw=0`; with the
exclude line removed it saw `deepseek=1`, so Codex's own defaults do not drop
the key and before this change the legacy launcher's shell could read it.
Codex runs without `OPENAI_API_KEY`. Still open (not item 28): Codex itself
holds the key, and its `workspace-write` shell can read the `.env` it came
from (item 12's known limits: the launcher reads outside its handoff folder).
The launcher is kept, not retired. Tests: `proof-test.sh`,
`codex-env-test.sh`; five plants red.

## 29. The walker's done_this_walk reads unanchored journal text (2026-10-23)

Found by Opus reviewing item 25. `wave-walk.sh`'s `done_this_walk` reads the
working journal with substring searches (`walk-start walk_id=<id>` in a
line, `— ORCHESTRATOR integrated`), and `journal-merge.py` refuses walker-only
records only as headings. An integrated member could plant a body line
`walk-start walk_id=<id>` (the id is in its own journal); later integrations
would then skip the merged proofs of goals integrated before it. A planted
`integrated` line only adds proofs. Fix: anchor both on
`^## \S+ — ORCHESTRATOR `, as `walk_record` already is.

**Done (2026-10-25):** `done_this_walk` matches whole walker headings only
(`walk-start walk_id=<id>` and `integrated <g>`) and splits on `\n` only, as
`walk_record` and `journal-merge.py` do, so a heading behind a `\r` in a goal
record is not one. Test in `parallel-walk-trust4-test.sh` (a member plants this
walk's walk-start as a body line and behind a `\r`; a later goal deleting an
earlier goal's file still stops `integration-red`); three plants red. It reads
the walk tip's journal (the copy the journal check already made), not the
working file, and a list it cannot read stops the goal (`merge-failed`).

## 30. A walk's --jobs 1 goals get no merged proofs in a later --jobs N run (2026-10-25)

Found by Opus reviewing item 29. A goal finished by a `--jobs 1` run writes
`ORCHESTRATOR done` (`run-goal.sh`), not `integrated`, so if the same walk is
resumed with `--jobs N`, `done_this_walk` leaves it out and later integrations
never rerun its proof. `done` cannot simply be counted: it is not a
walker-only record (`journal-merge.py`), so a member could plant one. Needs a
walker-written record for serial goals, or reading the serial goals' host
ledgers (`orch_host_ledger`, `lib/orch-files.sh`), which no goal can write.

**Done (2026-10-25):** `done_this_walk` also counts a goal GOALS.md marks done
whose host ledger in the main checkout holds an `ORCHESTRATOR done <goal> rN`
record stamped at or after this walk's walk-start heading (both the house's
own writing; with no walk-start found every record counts). A ledger, GOALS.md
or the journal it cannot read stops the goal (`merge-failed`). Test in
`parallel-walk-trust4-test.sh` (g1-a done serially, the walk stopped at g2-b,
then `--jobs 3`: g3-c deleting g1-a's file stops `integration-red`); plant red:
no serial goals. Not tested: the walk-start filter (without it, goals an
earlier walk finished would also be proved: more proofs, never fewer).
Seen while testing: a serial walk stopped by a wake leaves the goal's
`in_progress` uncommitted in GOALS.md, and the parallel walker's start check
refuses that (`orchestration-files-dirty`) until it is committed; a serial rerun
does not mind. Fixed as item 31.

## 31. A serial walk's stopped goal under a later --jobs run (2026-10-26)

Found while testing item 30. A serial run (`run-goals.sh` without `--jobs`)
sets its goal `in_progress` without committing it, and a wake leaves it so; the
serial walker accepts that on its rerun, but the parallel walker's start check
refused it (`orchestration-files-dirty`) with the generic advice "commit them
yourself … or restore them". Restoring made the goal `ready`, so its next run
took HEAD as its base. Worse, even once committed, the parallel walker recut
the goal from the walk tip, and a serial goal's implementer commits straight
onto the walk branch: any commits the stopped pass made sat in the new base and
were never reviewed (the item 30 test passed only because its pass committed
nothing).

**Done (2026-10-26):** a parallel walk refuses to start while a goal a serial
run is mid-way through is still `in_progress`, and says to finish it with
`run-goals.sh` without `--jobs` (which resumes it from its own base), then
rerun with `--jobs`. The walker marks each goal it puts in a wave or recuts in
the goal's host ledger in the main checkout (`ORCHESTRATOR walker wave|recut
<goal>`, a line no sandboxed goal can write); a goal is a serial run's when
its `in_progress` is uncommitted in GOALS.md (the walker commits its own), or
that ledger holds a `run-goal.sh` record of any kind for it after the last
mark, or the ledger cannot be read. The check runs first at start, so the
serial goal's uncommitted `in_progress` gets this answer, never the dirty-file
refusal whose "restore" would start it over. It decides from GOALS.md and the
ledger alone, never the journal (a serial implementer commits onto the walk
branch and could forge a walker record) and never from a branch or worktree (a
goal a parallel walk bounced keeps both, then may run serially; the stop then
says to remove them first, since the serial walker will not run a goal that
has them; never when the ledger cannot be read or the branch holds a result
the walker recorded as reviewed or whose record cannot be read, where it says
to inspect it instead). The whole walk stops, before any goal runs: a serial
resume refuses a GOALS.md in which other goals moved since its base. Chosen
(user) over a takeover that judged what the stopped pass left behind (code,
GOALS.md, journal, dirty tree): two Opus rounds found holes in that analysis;
the flat refusal costs one serial rerun even when the pass left nothing.
Limits: a committed `in_progress` with no ledger file (a goal paused before
ledgers existed, 2026-10-23, a repo since moved, another HOME) is not checked;
a goal a parallel walk left in flight before this change, with older serial
records and no mark, is refused (safe; a finished one included, its reviewed
result lost whichever way out is taken); an uncommitted `in_progress` left by
a failed walker commit is refused as a serial one (the message names it with a
hand edit and a serial run). Tests: `parallel-walk-trust4-test.sh` (committed
code; item 30's scenario hands the goal back), `parallel-walk-serial-test.sh`
(nothing committed, the bounced path followed to `done`, a walker-marked goal
recut, a serial r1 record after the mark, an unreadable ledger with no advice
to delete the branch, no ledger at all with the `in_progress` uncommitted).


## 32. The proof sandbox refuses to set file times on macOS 27 (2026-11-03)

Found by the Rust tier-rules item at its step 2b: a `worktree_setup` of
`cargo fetch` could not set an unpacked file's mtime. On macOS 27.0.1, setting a
file's times is checked under an operation none of the profile's named write
operations match, so every proof and setup that sets times failed (`tar -x`,
`cp -p`, `shutil.copy2`, cargo's unpacking), in every language.

**Done (2026-11-03):** `docs/features/sandbox-write-times` (plan, Grok APPROVED
in round 3). Every write rule in `lib/proof-sandbox.py` carries `file-write*`
beside the named operations, denials after allows. The three named operations
the wildcard would newly open (acl, finderinfo, mount, unmount) are denied by
name on the allowed trees, last among the write rules. The self-test checks setting a time in the root and its
refusal in `.git`. The evidence is the proof-sandbox `EVIDENCE.md` correction.

## 33. Rust rules for Axum and SQLx (after the core Rust tier rules)

**SQLite half done (2026-11-04):** `skills/to-goals/RUST-AXUM-SQLX.md`, `docs/features/rust-axum-sqlx-rules` (Grok APPROVED in round 5). Postgres moved to item 35: it cannot run under the proof sandbox. The hazards below are kept as the item's original input.

The user's Rust stack is Axum, Tokio and SQLx. The core Rust item
(`docs/features/rust-tier-rules`) covers Tokio's test macro and futures that
are never awaited. Axum and SQLx need their own planted rules, in an item of
their own after it (the user's choice, 2026-11-03). Hazards already found, as
inputs to its recon:

- **SQLx's compile-time macros** (`query!`) read `DATABASE_URL`, usually from
  `.env` (through dotenvy). The host refuses a live `.env` in a checkout, and
  proofs have no network. Offline mode needs a committed `.sqlx/` and
  `SQLX_OFFLINE=true`; who runs `cargo sqlx prepare`, and when, is open,
  because the implementer's sandbox cannot reach a database either.
- **`#[sqlx::test]`** creates a database per test. It needs a running server
  (`proof_network: loopback`) and credentials. A `DATABASE_URL` holding a
  password is not stripped by name: it contains none of the parts
  `proof_env_unsets` strips (KEY, APIKEY, TOKEN, SECRET, PASSWORD, PASSWD,
  CREDENTIAL(S)).
- **`sqlx::migrate!`** embeds the migrations folder at compile time. A
  migration file is a registration point that parallel goals can both edit.
- **The load-bearing choice:** SQLite in memory versus a real Postgres for the
  oracles. Ask it first.
- **Axum:**
  - testing through `tower::ServiceExt::oneshot` needs no network; a real
    listener needs loopback and a timeout;
  - a handler panic on a runtime worker thread prints
    `thread 'tokio-runtime-worker' panicked at` and the test sees a 500 or a
    reset (plant it against the trap reader);
  - a server that never answers hangs to the proof timeout (rule: wrap in
    `tokio::time::timeout`);
  - `CatchPanicLayer` and mocks of the database layer have the shape of the
    mockall plant.

## 34. Carried to the first Rust project's Phase 1 (from rust-tier-rules, 2026-11-03)

What worked when proving the Rust tier rules (`skills/to-goals/RUST.md`,
`docs/features/rust-tier-rules/EVIDENCE.md`), and what is still open, for the
first Rust target's recon:

- **cargo in the proof.** The host's `bash -c` does not find a rustup proxy.
  Call the toolchain's own `cargo` and `rustc` by absolute path, and bind cargo
  to that rustc (`RUSTC="$RUSTC"`). Keep every other path in the proof relative
  to the checkout: the host runs a proof from the goal's checkout or a merged
  worktree, so an absolute repo path would point at the wrong tree.
- **Crates offline: vendor them.** Neither a proof nor the implementer's
  sandbox has network.
  - A serial run has no deps folder: `run-goal.sh` clears `PROOF_DEPS_DIR`
    outside a walk's worktrees, so the proof's `CARGO_HOME` is its own empty
    temp folder.
  - `claude-implement.sh` never sets `CARGO_HOME`, so a `worktree_setup` fetch
    never reaches the implementer.
  - Measured: committing `vendor/` (`cargo vendor`) with a `.cargo/config.toml`
    source replacement makes the proof pass with no deps folder at all. Its
    effect on the implementer (Claude Code's sandbox) is **not measured**:
    check it in the first Rust project's step 0b, or close the gap in the
    launcher.
  - `vendor/` and `.cargo/config.toml` are committed by the Architect in
    Phase 3, and no goal edits them (an edited vendored crate still passes
    `--locked`). The rule reaches the implementer and reviewer only through
    each goal's **Out of scope**, which names both. The run-goal host does not
    guard them yet; whether it should, as it guards `tests/acceptance/`, is for
    that project.
  - `cargo vendor` copies crates for every platform (the fixture's lockfile
    has `windows-sys`, `linux-raw-sys`, `r-efi`), so `vendor/` is large.
- **Build time** (cargo's own "Finished" time, Apple M1, fixture with insta,
  mockall, proptest and tokio as dev-dependencies): cold 6.2 s from the deps
  folder, 5.7 s vendored; warm 0.4 s. A real target's cold build is the number
  to check against `PROOF_TIMEOUT` (default 600 s).
- **Registration.** Every goal's `[[test]]` block is committed in Phase 3.
- **The environment.** Unset `RUSTFLAGS`, `RUSTC_WRAPPER`, `CARGO_*` and the
  like in the walk's environment (RUST.md lists them). The host passes it
  through.
- **The toolchain.** How the target pins and installs it is the project's
  choice. The house's machine has it isolated in `~/.local/rust`.

## 35. A Postgres per proof, started by the host (from rust-axum-sqlx-rules, 2026-11-04)

The user's production database is Postgres, but it cannot run under the proof
sandbox. Measured through `proof_exec`, at a real run-goal TMPDIR length
(`docs/features/rust-axum-sqlx-rules/EVIDENCE.md`):
- `initdb` cannot look up the current user. Confirmed by experiment, run
  with `sandbox-exec` and the generated proof profile rather than through
  `proof_exec`: with only the `com.apple.system.opendirectoryd.libinfo` lookup
  allowed, it gets past that and fails on shared memory instead
  (`fixture/postgres-initdb-cause.sh`);
- the server always attaches a System V shared-memory segment (`deny
  ipc-sysv-shm`), even with `shared_memory_type=mmap`.

Allowing global System V IPC to every proof is ruled out. The proposal is
that `run-goal.sh` and the walker start a throwaway Postgres **outside** the
sandbox for each proof:
- `initdb` (trust, `--locale=C`), then `postgres` on a unix socket, with
  `listen_addresses=''`;
- the proof gets `DATABASE_URL=postgres://postgres@/postgres?host=<TMPDIR>&sslmode=disable`;
- the host stops the server when the proof ends.

It needs its own crucible and security review: an unsandboxed process
serving a sandboxed one. **Its first load-bearing decision is where the socket
goes.** The sandbox allows unix sockets only under the proof's own `TMPDIR`
(`proof-sandbox.py`), and the path budget below rules out today's `TMPDIR`
paths for merged proofs. So, either:
- the host gives every Postgres proof a short `TMPDIR` (no profile change;
  **chosen by the user, 2026-11-04**); or
- the socket goes in a short directory elsewhere, which needs a new
  `remote unix-socket` allow in the profile, reviewed as such.

Inputs:
- the socket path budget: macOS caps it at 104 bytes with the NUL, and
  `$TMPDIR/.s.PGSQL.5432` takes 15 more than `TMPDIR`. On run-goal.sh's
  `$RUN_DIR/tmp` it fits for goal ids up to 20 characters (86 bytes at 2, 107
  at 23, with this `$HOME`). Other `proof_exec` paths are longer: the parallel
  walker's merged proofs use `$WAVE_DIR/tmp-proof-<g>-<p>` (`wave-walk.sh`),
  where two goal ids share about 7 characters, and mutation clones use their
  own;
- `pg_ctl start` daemonizes with `setsid`, so the server is run in the
  foreground and stopped by the host, with its `postmaster.pid` checked
  afterwards;
- from research only (the probes used `psql`, not sqlx): sqlx connects to a
  socket through its own URL form (an empty host, `?host=`), and ignores
  `PGHOST`. Measure it first;
- Postgres 18.6 is installed keg-only (`/opt/homebrew/opt/postgresql@18/bin`;
  Homebrew linked it, and it was unlinked);
- the rust-axum-sqlx-rules plan's Postgres plants and Tier 2 list (integer
  division, `C` collation order, `ORDER BY`, `timestamptz` precision, a
  `BIGSERIAL` gap) are written in its PLAN.md. The fixture (`notes-pg/`), the
  Postgres recipe and their rows still have to be built on its harness;
- sandboxed Postgres leaves System V segments behind: one from a server
  refused the attach and its cleanup, one from an `initdb` whose later step
  failed (two 56-byte segments, found and removed). The probes now remove what they leave; the host-run
  server must clean up its own, and a proof that tries Postgres inside the
  sandbox leaks one.

Also carried to the first Axum + SQLx project:
- the implementer's sandbox may not be able to reach a database, and with
  checked macros banned (RUST-AXUM-SQLX.md) it does not need one to build;
- lifting that ban needs a database for `cargo sqlx prepare`, or a host
  service like this one;
- `DATABASE_URL` is not stripped by name (`proof_env_unsets`); the recipes
  unset it and set their own;
- the SQLite cold proof takes about 17 s on an M1 (the bundled C build).

## 36. run-all.sh loses a failing test's full output (2026-11-04)

During rust-axum-sqlx-rules, a full suite run failed one test (`proof-test.sh`)
under 4-way load. It passed alone twice and in a second full run. The failing
assertion could not be read: `run-all.sh` prints only the tail of a failing
test's output and removes its working folder (`rm -rf "$G"` on exit), and
`--results` is filled only at the end. Fix: on any failure, keep that test's
full `out` (or copy it to `~/.cache/claude-coding-workflow/tests/failed/`) and
name the path in the report, so a one-off failure under load can be diagnosed
afterwards.

## 37. A bare /walk-status should show this session's live walk first (2026-11-05)

During the Paladin M0 walk, the session's working folder was `~/code-analysis-toolkit` (its own `GOALS.md`, last
goal `g9-local-approval`). The walk was launched there with `cd ~/Paladin && run-goals.sh`. A bare `/walk-status`
drew the toolkit's old DAG instead of the running Paladin walk. The user expected the session's walk.

**Cause:** `mods/walk/hooks/register.tsx` (`pollOnce`, about lines 105–117) reads the working folder's `GOALS.md`
first. It falls back to the walk this session launched only when that read finds no `GOALS.md` (`!graph.found`).
The header comment documents this order.

**Fix:** a bare `/walk-status` resolves the repo in this order:
1. an explicit `dir` argument;
2. a live (unfinished) walk this session launched, chosen with the existing `walks` lookup and `chooseWalk`;
3. the working folder's `GOALS.md`.

Also:
- The pane's "opened for" text names the repo it chose.
- Update the header comment to the new order.

**Test:** a session whose working folder has a `GOALS.md` and that launched a walk in another repo. A bare
`/walk-status` shows the walk's repo; after the walk ends, it shows the working folder's again.

**Workaround until then:** `/walk-status <repo>`.

## 38. Warm Rust build caches for parallel walks (2026-11-05)

A `--jobs` walk gives each goal its own worktree, and the Rust proof pins `CARGO_TARGET_DIR="$PWD/target"`
(RUST.md, "Kept"). So every worktree compiles the whole dependency graph from cold. Paladin M0 has about 110
vendored crates, and with them the cold build eats much of what a parallel wave saves. A serial walk builds in
one `target/` and pays the cost once.

**Constraints any fix must keep:**
- **The target directory stays where it is.** `CARGO_TARGET_DIR="$PWD/target"` is an anti-tamper rule: it stops a
  project `.cargo/config.toml` from building into `tests/acceptance/`. A shared target outside the worktree breaks
  that rule. It also serialises jobs on Cargo's build-directory lock.
- **No sccache inside proofs.** `RUSTC_WRAPPER=sccache` writes its cache outside the trees a proof may write, so
  RUST.md unsets it. The proof sandbox (`scripts/lib/proof-sandbox.py`) would also deny those writes.
- **sccache skips incrementally built crates.** It does not cache crates built with incremental compilation, which
  is on by default for dev and test builds. The workspace's own crates would not benefit.

**Options to measure:**
1. **Copy the main checkout's `target/` into each new worktree.** Use an APFS clone (`cp -c`, which is cheap) from
   `worktree_setup` or the walker's fork step, before the first proof.
   - Open question: do Cargo fingerprints survive the path change? Dep-info records absolute source paths, and
     vendored and workspace crates move with the worktree.
   - Measure how many crates rebuild.
   - Remedies if most rebuild: `--remap-path-prefix`, or keeping the vendored sources at a stable path.
   - **Answered (2026-11-08, item 42):** workspace crates survive the move: Cargo hashes their paths relative
     to the workspace. Every vendored crate rebuilds ("the path to the source changed": its absolute path is
     hashed). `--config "source.vendored-sources.directory='<main checkout>/vendor'"` in the worktree's
     proof rebuilt nothing in a probe. A `vendor` symlink and the `CARGO_SOURCE_…` env form do not help.
     That leaves the anti-tamper question: a proof that reads `vendor/` from outside its own worktree.
2. **Pre-build dependencies once per wave on the host,** into a read-only directory that each worktree's target
   reuses. This needs a Cargo mechanism to do it: check `-Zbuild-dir` / `build.build-dir` (stable status in
   1.99?) and whether it keeps the anti-tamper property.
3. **Run sccache on the host only** for the walker's warm-up build, never in proofs. This helps only if option 1
   or 2 still needs a build step.

**Done when:**
- A measured `--jobs 3` wave on a Rust target with vendored dependencies rebuilds only the workspace crates in each
  worktree.
- The anti-tamper rules in RUST.md still hold, with a `scripts/tests/` case that plants
  `build.target-dir = "tests/acceptance/x"` and stays red.
- The proof sandbox denies nothing new.

**First data point:** Paladin M0, after its walk ends. Time one cold proof against one warm proof in a worktree.

## 39. Put the pinned Rust toolchain's `bin` on the implementer's `PATH` (2026-11-05)

**Done (2026-11-05):** `docs/features/rust-toolchain-gates/` (PLAN, five Grok rounds signed off by the owner, two Opus diff-review rounds ending APPROVED, journal, EVIDENCE.md). GOALS.md's `tool_path:` key leads `PATH` for the implementer, every proof and the reviewer, never the host. `validate` rejects a folder inside the target repo or one the proof sandbox cannot read (`read_denied()`). Real evidence: the implementer's Bash tool sees it for both providers (`claude-implement.sh --probe-path`), and without it the fixture proof fails "no such command", the M0 failure.

In the Paladin M0 walk, four implementer END records in a row (g3, g4, g5 and g6) say "`cargo clippy` / `cargo
fmt` are unavailable in the pinned toolchain". They are installed: `cargo-clippy` and `cargo-fmt` sit next to
`cargo` in `~/.local/rust/rustup/toolchains/1.99.1-aarch64-apple-darwin/bin/`.

**Cause, reproduced on 2026-11-05.** Cargo looks for `cargo-<cmd>` subcommands on `PATH` and in `$CARGO_HOME/bin`,
not in its own folder. The RUST.md recipe calls `$CARGO` by absolute path, and that folder is not on the
implementer's `PATH`, so the subcommands are not found:

```
env -i HOME=$HOME PATH=/usr/bin:/bin $T/cargo clippy --version    # error: no such command: `clippy`
env -i HOME=$HOME PATH=$T:/usr/bin:/bin $T/cargo clippy --version  # clippy 0.1.99
```

**Result.** About 39 clippy errors and 137 rustfmt diffs reached `main` unseen. g1 ran clippy only because that
pass happened to have the toolchain on `PATH`. The repeated note is the signal that the implementer prompt and
environment no longer fit (`/run-goals`: "propose an implementer-prompt audit").

**Fix:**
- The walker prepends `dirname "$CARGO"` to `PATH` for the implementer and for the proof sandbox, in the same place
  it pins `$CARGO` and `$RUSTC`.
- The implementer prompt tells the implementer to run `cargo clippy` and `cargo fmt --check` before reporting
  `DONE`.

**Done when:**
- A Rust fixture's implementer pass can run both commands.
- A test under `scripts/tests/` fails if the prepended `PATH` is removed.
- The proof sandbox still denies nothing new.

## 40. Rust proof recipe: opt-in clippy and rustfmt gates (2026-11-05)

**Done (2026-11-05), with the addendum:** the same feature. RUST.md has the opt-in lint tail (`clippy --workspace --lib --bins --test <id> -- -D warnings`, `fmt --all --check`, a grep for blanket and group allows) and Tier 1 oracle linting, with each oracle linted on its own. The handoff tells the implementer to run the lint steps. The rust-tier-rules fixture's `run-plants.sh lint` rows cover the clean, `unwrap()` and sibling-oracle cases, and the sandbox logs no new denials. See EVIDENCE.md.

The RUST.md proof runs `cargo test --test <id>` only. Lint and format debt therefore passes every goal and piles up
over a walk: about 39 clippy errors and 137 rustfmt diffs by the end of Paladin M0.

**Fix:** an optional recipe tail, which a plan opts into, run after the test:

```
PATH="$(dirname "$CARGO"):$PATH" "$CARGO" clippy --offline --locked --workspace --all-targets -- -D warnings
PATH="$(dirname "$CARGO"):$PATH" "$CARGO" fmt --all --check
```

It depends on item 39.

**Open questions:**
1. **Gate placement.** Running clippy over the whole workspace makes every goal pay for every earlier goal's lint
   debt. The options:
   - run it per package for the goal's `area`;
   - run it workspace-wide only once the workspace is clean.
2. **Pedantic warnings.** `-D warnings` turns `pedantic = "warn"` into hard errors. RUST.md should say whether the
   gate denies only the plan's deny list (`-D clippy::<each>`) or every warning.
3. **Ordering.** Clippy reuses the test build's metadata only partly, so check that it stays inside the proof
   timeout on a cold `target/` ([[38]]).
4. **Tamper.** A target's `clippy.toml` or `rustfmt.toml` can weaken the gate. Treat them like `Cargo.toml`:
   Architect-owned and out of scope for goals. RUST.md already lists `clippy.toml`; add `rustfmt.toml` and
   `.rustfmt.toml`.

**Done when:** RUST.md documents the tail, and a `scripts/tests/` case has a planted `unwrap()` in a goal's crate
that turns the proof red.

## 41. `grok-review.sh --oracle` requires the self-review first (2026-11-05)

`/to-goals` step 4.4 puts the Architect's self-review before the oracle review in step 4.5. The self-review checks
each oracle against GOAL-FORMAT.md's failure classes, with the tier results in hand, and records a checklist in the
journal's decompose entry. Nothing enforces that order. In Paladin M0 it slipped twice:
- **The M0 cut:** the checklist was written while Grok round 1 was already running, so it could not change what Grok
  reviewed.
- **The follow-up goal `g8-m0-hygiene`:** it went to Grok with no self-review. Grok's round 1 then found 11 gaps.
  The late self-review found one more class, "claim nowhere pinned": the lint gate could be passed by switching lints
  off. Grok had missed it.

The owner noticed the skip; the workflow did not.

**Fix.** Before round 1 (no `--resume`), `grok-review.sh --oracle` refuses to start unless the target journal holds a
self-review record for every goal whose oracle `lib/oracle-files.py` lists.
- **Record format,** for example `## <UTC> — ARCHITECT self-review <id>[, <id>…]`. Under it, one line per
  GOAL-FORMAT.md failure class, each marked pass or fail. A fail line names the fix.
- **Freshness.** The record must be newer than the last change to each listed oracle file. Compare against the
  newest commit touching the file, or its mtime for an uncommitted file. A stale record refuses, so an oracle edited
  after its self-review is reviewed again.
- **Resumed rounds.** A `--resume` round checks only freshness: an oracle changed since the last record needs a
  fresh record line.
- **Refusal output.** It names the goals missing a record and the class list to fill in. It exits with a distinct
  code, so `/to-goals` can show it. There is no override flag: the only way past is to write the record.

**Placement.** Parsing lives in a new `scripts/lib/self-review.py`, with the class names read from GOAL-FORMAT.md so
the two cannot drift. `oracle-files.py` already supplies the goal and oracle lists.

**Done when** `scripts/tests/` covers:
- no record → refuse;
- a record missing one class → refuse;
- an oracle edited after its record → refuse;
- a complete, fresh record → round 1 starts;
- `--resume` with an unchanged oracle → no new record needed.

**Also:** in `skills/to-goals/SKILL.md` step 4.4, add "written before step 5 starts; `grok-review.sh --oracle`
refuses without it".

**Addendum to item 40 (2026-11-05, Paladin g8):** the Architect's own oracle files must pass the same gate.
- g8's proof ran `clippy --workspace --all-targets -D warnings`. The oracle carried 4 pedantic findings that only
  the Architect may fix.
- Tier 1 missed them because the proof was already red at a library crate, so clippy never compiled the test
  target.
- The implementer finished everything else and stopped BLOCKED. The goal had to be re-cut from its base and
  implemented again.
- **Fix:** when a proof includes a lint step, Tier 1 also runs it with `--keep-going` and filters to
  `tests/acceptance/` paths. Any finding there fails Tier 1.
- A `scripts/tests/` case plants a `similar_names` pair in an oracle and expects Tier 1 to stop.

## 42. Mutation copies rebuild every vendored crate (2026-11-08, Paladin g39)

The mutations run in a copy of the checkout at another path, with `target/` copied along. Cargo hashed each vendored
crate's absolute source path, so the copy rebuilt the whole vendored graph (`serde`, `syn`, `clap`, `strum`,
`sysctl` …) and every workspace crate after it. g39's mutation step took 20 minutes under load.

DONE (2026-11-08, in-session):
- `mut_run` exports `CW_MUT_CHECKOUT`, the checkout's physical path, to the mutation proof. Only the copies get it;
  the host proof does not.
- A vendored Rust project's `mutation_proof` adds
  `--config "source.vendored-sources.directory='$CW_MUT_CHECKOUT/vendor'"` to each cargo call. That is
  RUST.md, "Mutation proofs".
- Probe (1.99.1, a different `CARGO_HOME`, serde with its build script and derive): nothing rebuilt.
- Test: `mutation-test.sh`, "the mutation proof is told the checkout it was copied from". Planted without the export:
  red (the baseline red, the mutation skipped).

**Open:**
- Measure one real Paladin mutation step with the flag (`cargo test -v --no-run` in a copy: no `Dirty` vendored
  crate). The first goal cut after this lands carries it.
- Re-measure the per-run overhead on a quiet machine.
- The same remedy for `--jobs` worktrees: item 38, option 1.

## 43. A goal's soak: the long check a proof is too short for (2026-11-08, Paladin M1b.1 exit)

Paladin M1b.1's exit check ran each parser's fuzz target for 600 s. The YAML target found two bugs that every
goal's proof (a 30-case fuzz smoke) and every mutation step had passed:
- a panic in the vendored scanner (g42);
- 146 parity errors, only visible as `read_error` in the report and confirmed by an origin probe.

The owner asked for the long check to move into each goal.

DONE (2026-11-08, in-session):
- GOALS.md gains a per-goal `soak:` key. The host runs it after a green proof and before the review, under
  `SOAK_TIMEOUT` (default 1,800 s).
- Red or timed out, it is a proof fix round. The handoff says "red soak", and the fix record carries `step=soak`.
- The output is kept as `soak-r<n>.out`, and the journal records `ORCHESTRATOR soak`. A tree change wakes
  `soak-tamper`.
- Docs: GOAL-FORMAT.md, and RUST.md "Soaks" (the release fuzz recipe).
- Test: `soak-test.sh`, 18 checks. Two plants are red: a red soak not standing in for the proof (7 failures), and
  a soak run after a red proof (1 failure).

**Not here:** the origin check of a green soak's `read_error`/`internal_error` counts. That needs origin, which only
the Architect runs, so it is a step in the Architect's per-goal review. Paladin's fuzz report should tally notes and
keep a sample input per note to make it cheap (a Paladin goal).

