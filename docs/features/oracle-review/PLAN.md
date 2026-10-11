# Plan: Oracle review and tiered satisfiability (Phase 3)
_Locked via crucible — by Claude + cobalt. Revised after Grok rounds 1-4; step order revised by the user._

## Goal

Phase 3 (`to-goals`) gains a cross-model review of the acceptance oracles and
replaces "prove the oracle satisfiable with a scratch implementation" by three
tiers of evidence, cheapest first. After the Architect writes the oracles
(and the pin sweep's acceptance edits), it proves each runs red for the
right reason through the goal's own proof command (Tier 1), checks computed
expected values against a reference or brute-force model (Tier 2), writes a
full scratch implementation only as an announced, bounded last resort
(Tier 3), self-reviews with that evidence in hand, and only then sends the
oracles to Grok for a capped adversarial review in a fresh session
(`grok-review.sh --oracle`): cheap deterministic evidence first, the
independent model last. The commit is gated on the review's APPROVED of
the **final** oracle text, or on a journaled user override. Evidence: on
uregex the scratch implementation (~550 lines, the most expensive model
writing the product) caught only two build/harness defects, both of which a
real Tier 1 run catches; the one FIX round in the walk was an oracle gap,
which is what the review targets.

## Approach

1. **`scripts/grok-review.sh --oracle`** — a second mode of the existing
   launcher (one rulebook; the oracle prompts live in this file, never forked
   into docs). Always a **fresh** session; no fork of the plan-attack session.
   - Usage: `grok-review.sh --oracle [--resume ORACLE_SESSION_ID] <PLAN.md>`.
     Run from the repo root. The log is `PLAN-REVIEW-LOG.md` beside the plan.
     The files under review are this DAG's: every `oracle:` value in
     `GOALS.md`'s fence other than `inline`, plus every `tests/acceptance/`
     path named in a goal body's **Acceptance edits** section (parsed from
     that section only — not **Edits owned**, whose `tests/acceptance/` paths
     `goals.py` rejects; entries are written `file:line, old → new`, so a
     trailing `:line` or `:line:col` is stripped before the existence check) — not the whole of `tests/acceptance/` (earlier
     weeks' green oracles are out of scope). The script lists them in every
     prompt. Exit 2 (usage) on: no `GOALS.md`; a listed path missing on disk;
     an Acceptance-edits section that names no parseable path (other than
     `None`). A DAG whose oracles are all `inline` reviews the case tables in
     `GOALS.md` itself.
   - **Round 1** (`--session-id <new uuid>`): the oracle prompt names the
     plan, the log (as the record of what the plan attack raised and how each
     point was settled), `GOALS.md`, and the listed files.
   - **Later rounds** (`--resume <oracle session id>`): an oracle re-review
     prompt ("I revised the oracles…") that repeats the in-scope file list,
     never the plan re-review prompt.
   - Every oracle prompt ends with the instruction to finish the reply with
     exactly one line, `VERDICT: APPROVED` or `VERDICT: REVISE`
     (`lib/verdict.py`'s grammar).
   - Both oracle prompts, like both plan prompts, name Grok's only tools
     (`read_file`, `grep_search`, `list_dir`; no shell). The read-only flag
     set is unchanged. Model and effort tunables are shared.
   - Findings asked for, each with a one-line fix: plan claims or cases with
     no assertion (gaps); expected values that do not follow from the plan
     (re-derived, not trusted); cases the plan leaves ambiguous; ways a proof
     can pass without the code working (unregistered oracle, tautology, a
     differential that cancels its own term, invented symbol, a pin on a
     private signature, an assertion that never runs, a test that expects the
     stub's own exception); harness defects. A finding that is a defect of the
     **plan** starts with `PLAN:`.
   - Result lines unchanged (`GROK_REVIEW_RESULT`, `SESSION_ID`, `VERDICT`,
     `VERDICT_FILE`); a turn that does not end `end_turn` is already
     `error (turn stopped: …)` (house fix during this crucible).

2. **`skills/to-goals/SKILL.md` §4–5 and `GOAL-FORMAT.md`** — after the
   user's granularity quiz (unchanged), in this order:
   0. **The plan is committed first.** The signed `PLAN.md` and its
      `PLAN-REVIEW-LOG.md` are committed on their own before Phase 3 writes
      anything (`run-goal.sh` refuses a `plan:` path that is not in `HEAD`),
      and again, in a commit of their own, after any re-sign.
   1. **Write `GOALS.md`** (uncommitted draft) and the new oracles, and run
      the **pin sweep** as today: apply each acceptance edit the plan owes to
      existing files, red, and list it under the owning goal.
   2. **Tier 1, every goal with a file oracle — the goal's own `proof`
      command:**
      - API the plan adds: stubbed with every body a trap carrying a unique
        message (C/C++: write the message, `fflush(stdout)` and
        `fflush(stderr)`, then `abort()` — CTest captures through a pipe, so
        unflushed stdio is lost on abort; `panic!`, `raise
        NotImplementedError("<feature>-trap")`, `throw new Error("<feature>-trap")`),
        so a test expecting a generic exception cannot mistake it. API that
        already exists: the real code, no stub.
      - Run the goal's **`proof`** command — what the host will run, so the
        harness (CTest properties, registration, sanitizers) is exercised.
        Pass bar, by what the case calls:
        - **Stubbed (new) API:** a nonzero exit with the unique trap message
          in the output, **and** the test source shows this goal's assertion
          after the call (read, not run: the trap fires before it, by
          design).
        - **Existing API:** a nonzero exit with this goal's new assertion in
          the failure output.
        A zero exit, a build error, a collection error, or a failure that is
        neither the trap nor this goal's assertion fails Tier 1.
      - Every **Acceptance-edits** file this goal's `proof` does not run
        (proof composition keeps a file carrying a later goal's red edit out)
        runs through the **same runner as `proof`**, filtered to this goal's
        case (CTest `-R`, a pytest node id, a vitest/jest name filter,
        `cargo test <name>`, `go test -run`), so a later goal's failing case
        in the same file does not fail this run. Authoring rule: each goal's
        swept edit is its own test case, never folded into a case a later
        goal also edits. Per-language
        notes in `GOAL-FORMAT.md` (C/C++, Python, TypeScript, Rust/Go) say
        where that output appears.
      - The harness probe (e.g. a sanitizer trap) runs through the same
        `proof` command and must show its expected outcome.
      - Stubs live in the scratchpad when the toolchain builds from there;
        otherwise in the worktree for the run only, deleted after it, and
        **always deleted before any `--oracle` launch** (Grok must never read
        a stub as if it were the API); the commit check below rejects any
        leftover.
      - `oracle: inline` goals skip Tier 1; their case tables get Tier 2.
      - Checks run with `PYTHONDONTWRITEBYTECODE=1` (as the host does).
   3. **Tier 2, wherever an oracle carries computed expectations** (any
      expected value the plan does not state verbatim): check each against an
      existing reference with the same semantics, or a small brute-force
      model of the spec, run in the scratchpad.
      **Tier 3, last resort:** a full scratch implementation only when no
      reference exists and brute force is infeasible; announced to the user
      first, boxed to **30 minutes by default** (the user may extend), never
      committed, never shown to the implementer. When the box ends the
      Architect stops and journals which claims stayed unproven.
   4. **Self-review**, with the tier results in hand, against PLAN.md and
      the oracle failure classes; recorded as a checklist in the journal's
      decompose entry (each class ticked; per goal the tiers run and what
      each showed).
   5. **Oracle review** (`grok-review.sh --oracle`, background), capped at
      `MAX_ORACLE_ROUNDS` (default 3) counted rounds. Only a
      `GROK_REVIEW_RESULT: ok` round counts. `rate_limited` **stops** the
      review (the house rule: no retry; the Architect tells the user). An
      `error` or `MISSING` result is logged as void and rerun, at most twice
      in a row; a third stops the review and goes to the user. The Architect
      sorts every finding: fix the oracle; reject with a logged reason; or,
      for a `PLAN:` finding it accepts, stop and bounce to the crucible — the
      plan is fixed, re-signed and committed (step 0) before any oracle
      changes, the counted-round total starts again at zero, and the next
      round is a **new fresh session** (the old one read the old plan).
      Before each next round, every file changed since the last round — by
      the last round's fixes or by a re-signed plan — reruns Tier 1, and
      Tier 2 where its values are computed; worktree stubs are then deleted;
      Grok sees only text that has passed them. Rounds are
      appended to the feature's `PLAN-REVIEW-LOG.md` as
      `## Oracle round <n> — Grok` plus `### Architect's response`.
   6. **Re-check the approved bytes:** after the last round, Tier 1 (and
      Tier 2 where values are computed) runs once more on the exact text to
      be committed; a failure blocks the commit and the fix goes back
      through the review. A file changed after an APPROVED round makes that
      approval stale; it goes back through the review in a new counted
      round. The final tier results go into the decompose checklist.
   7. **Gate and commit:** commit only on a current (not stale) APPROVED of
      the final text, or on a user override. The override path applies at
      the cap without a current APPROVED — including when the round that
      would confirm a late edit exceeds the cap: the Architect lists each
      unresolved point with its counter-position, the user decides, and the
      decision is journaled as an `ARCHITECT oracle-review override` record
      that the commit cites. The commit holds `GOALS.md`, the oracles, the
      swept edits, the journal and the feature's `PLAN-REVIEW-LOG.md`.
      Before committing, both must hold: `git status --porcelain` shows no
      path outside that allow-list — a dirty plan path fails it (step 0 is
      what keeps the plan out of porcelain) — and
      `git status --porcelain --ignored=matching` shows no `!!` path under
      `tests/acceptance/`, an oracle path, or the plan path (ignored files
      there are `contract-tamper-ignored` to `run-goal.sh`). Otherwise the
      Architect cleans up first. `run-goal.sh` refuses a dirty tree, so this
      is what lets `/run-goal` start.
   The "Prove the oracle is satisfiable" section of `GOAL-FORMAT.md` is
   rewritten to the tiers (the failure-class list stays); the swept-edit
   satisfiability note becomes Tier 1 (red for the right reason on the
   current code) plus Tier 2 where values are computed, replacing "the
   scratch fix that turned it green".

3. **`CLAUDE.md`** — Phase 3 text: the tiers replace "Apply a scratch
   implementation…"; the oracle review is named. Roles: Grok attacks plans
   and oracles and never reviews implementer diffs; Opus reviews implementer
   diffs. Skill table updated.

4. **`GLOSSARY.md`** — **Attacker** extended to Phase 3 oracles, with the
   boundary "never reviews implementer diffs"; **Goal reviewer** keeps
   implementer diffs only (its "only attacks `PLAN.md`" wording about the
   attacker is corrected). New entries: *Oracle review*, *Trap stub*,
   *Satisfiability tier*.

5. **Tests** — extend `scripts/tests/grok-review-test.sh` (the fake `grok`
   records the argv it really receives):
   - `--oracle` round 1: `--session-id`, no `--resume`; the prompt names the
     plan, the log, `GOALS.md`, every `oracle:` path and every Acceptance-
     edits file, and **not** an unlisted file present under
     `tests/acceptance/`; it names the only tools and asks for the `PLAN:`
     prefix;
   - `--oracle --resume`: `--resume <id>`, no `--session-id`; the oracle
     re-review prompt (not "I revised the plan"), naming the only tools and
     repeating the in-scope file list;
   - both oracle prompts require the closing `VERDICT:` line;
   - the file list: an `inline` oracle is skipped, an Acceptance-edits path
     written `file:line` is included without its `:line`, an Edits-owned
     path is not;
   - plan mode, rounds 1 and 2: argv identical to today's (regression);
   - every mode passes the full read-only flag set;
   - usage errors exit 2: `--oracle` without a plan; no `GOALS.md`; a
     listed oracle file missing; an Acceptance-edits section with no
     parseable path; `--fork` (not supported).
   Already wired into `install.sh --check`.

6. **README / FUTURE-WORK** — README lists the oracle mode; FUTURE-WORK
   item 5 marked done; planted-bug (mutation) checks moved to a new item
   (they need `run-goal.sh`, out of this slice).

## Key decisions & tradeoffs

- **Always a fresh oracle session, seeded with the plan and its review log**
  (Q1, simplified in round 1). Measured on uregex: a 3-round attack sits at
  ~168k tokens per call against a 256k window that auto-compacts at ~205k, so
  resuming would compact Grok's memory into its own lossy summary; the log
  carries every finding and resolution verbatim. The user approved "fresh by
  default, fork only after a one-round attack"; round 1 showed the fork path
  is the fragile one (a heading count the log already breaks, a plan session
  id nothing stores, an untested CLI flag) for a case that rarely arises, so
  it is dropped. Flagged for the user at sign-off.
- **The review gates the commit of the final oracle text** (Q2), capped at 3
  counted rounds; `PLAN:` findings bounce to the crucible and reset the cap;
  any later edit re-enters the review; the tie-break at the cap is a
  journaled user override the commit cites — never a written APPROVED.
- **Order: Tier 1 → Tier 2 (→ Tier 3) → self-review → Grok** (user,
  between rounds 2 and 3). Cheap deterministic evidence first, so Grok's
  capped rounds go to what only an independent reviewer finds (gaps,
  ambiguity, vacuous passes), Grok approves values already checked, and the
  self-review records evidence rather than predicting it. Cost accepted:
  Tier 3 work can be wasted if the review later changes a case; Tier 3 is
  rare and boxed.
- **Tier 1 runs the goal's `proof` command**, the command the host runs:
  only that exercises the harness (both uregex defects were harness
  defects). A zero exit under stubs is itself a finding: the oracle cannot
  fail.
- **Three satisfiability tiers, chosen per goal by the Architect** (Q3), with
  Tier 1 mandatory for file oracles and swept edits; Tier 3 announced and
  boxed at 30 minutes.
- **The pin sweep stays**, its satisfiability evidence moved onto the tiers.
- **Mutation checks deferred** (cosmetic Q4): they belong on the
  implementer's real code, which means `run-goal.sh`.
- **One launcher, one log**: `--oracle` is a mode of `grok-review.sh`;
  oracle rounds share the feature's `PLAN-REVIEW-LOG.md`, which the commit
  includes.

## Assumptions

1. Brownfield; house on `workflow-optimization` (`cc700a0` plus this
   crucible's journaled launcher fix); plan files in
   `docs/features/oracle-review/` — git, user instruction.
2. `grok-review.sh` owns the review prompts; read-only Grok; result-line
   contract; a non-`end_turn` stop is an error; `scripts/tests/grok-review-
   test.sh` drives it through a fake `grok` recording its argv — the script
   and test.
3. Plan-attack context measured on uregex: round 3, 2 calls, 335,335 input
   tokens; grok-4.7 window 256k, auto-compact at 80% — Grok session files,
   `models_cache.json`.
4. `PLAN-REVIEW-LOG.md` holds every round's critique and response — crucible
   skill.
5. Phase 3 today: oracles, the pin sweep, then a scratch implementation; no
   review — `skills/to-goals/SKILL.md`, `GOAL-FORMAT.md`, CLAUDE.md.
6. `run-goal.sh` refuses a fresh start on a dirty tree other than a
   status-only `GOALS.md` edit; an ignored file under `tests/acceptance/` is
   `contract-tamper-ignored` — `run-goal.sh`, `GOAL-FORMAT.md`.
7. uregex: scratch caught 2 build/harness defects; computed values held; 1
   FIX round from an oracle gap; 0 proof-red wakes — `docs/journal/uregex.md`.
8. Mutation checks were never a house rule — skills, format.
9. Docs-aware: `GLOSSARY.md` defines **Attacker** and **Goal reviewer**;
   ADR 0001 untouched — repo.
10. This slice does not change `run-goals.sh`, `run-goal.sh` or `goals.py` —
    locked decisions.

## Risks / open questions

- Tier 2 depends on a reference for the domain; for novel semantics the
  brute-force model is the Architect's own code and can share its misreading
  of the plan. The oracle review (an independent model) is the
  counterweight; the plan claims no more.
- A fresh session re-reads the plan and log each round 1 (a few thousand
  tokens of log, plus the oracle files); acceptable against the measured
  alternative.
- Oracle rounds add wall time to Phase 3 (plan rounds took 5-20 minutes);
  they run in the background.

## Out of scope

Mutation checks on implementer code; any change to the walker
(`run-goals.sh`, `run-goal.sh`, `goals.py`) or to `claude-goal-review.sh`;
forking or resuming the plan-attack session; a review of code by Grok (Opus
reviews implementer diffs); committing stubs, models or scratch code;
automating Tier 2 references per language.
