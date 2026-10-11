---
name: to-goals
allowed-tools: Bash, Read, Glob, Grep, Write, Edit, AskUserQuestion
description: Cut a signed-off PLAN.md into a dependent/independent goal DAG in GOALS.md, with Architect-authored acceptance oracles. Use when the user says /to-goals, "decompose the plan", "cut into goals", "break this into goals", or after a crucible plan is signed off. Not for planning (use /crucible), not for implementing, not for reviewing already-written code.
---

# To Goals — cut a hardened plan into a DAG

Phase 3 of the house workflow. Input is a **signed-off** `PLAN.md`.
Output is `GOALS.md` plus oracles. No implementer runs.

Format (YAML, bodies, field rules, slice rules, oracle rules):
[GOAL-FORMAT.md](./GOAL-FORMAT.md). Do not fork it.

## 1. Gate

The signed plan exists — `PLAN.md` at the target root, or a feature's
`docs/features/<slug>/PLAN.md` — **and** the user has signed it off
(journal or this conversation). Missing plan → refuse; point at
`/crucible`. Unsigned plan → ask for sign-off, do not cut.

Done when the gate passes or you have refused.

## 2. Read

Read `PLAN.md`, `PLAN-REVIEW-LOG.md`, `GLOSSARY.md` (legacy `CONTEXT.md`), `docs/adr/`, and
the seams the interrogation already locked. Use the project's glossary.
Do not re-interview product decisions. A decision that looks wrong is a
crucible defect — bounce up, do not "fix" it in the DAG.

Done when every plan section and named ADR has been read.

## 3. Draft, then quiz

Draft the DAG **in chat**, not on disk: each `id`, `blocked_by`,
`conflicts_with`, `area`, one-line deliverable, `proof`. Apply every
slice rule in GOAL-FORMAT.md (vertical, implementer-sized, independence
test, ~8 cap, expand–contract).

Ask:

1. Does the granularity feel right? (too coarse / too fine)
2. Are the blocking edges true gates — and are `conflicts_with` only
   merge hazards, not fake dependencies?
3. Should any goals be merged or split?

Iterate until the user approves the breakdown. Then write files.

Done when the user has approved the list.

## 4. Author the oracle

Cheap, deterministic evidence first; the independent model last. In order:

**0. The plan is committed.** Before writing anything, `PLAN.md` and its
`PLAN-REVIEW-LOG.md` are committed on their own (`run-goal.sh` refuses a
`plan:` path that is not in `HEAD`); after any re-sign, again on their own.

**1. Write.** Draft `GOALS.md` (uncommitted) in the GOAL-FORMAT.md shape;
statuses `ready` if `blocked_by` is empty, else `blocked`. For every
approved goal, write the acceptance cases:

- Target has a test harness → `tests/acceptance/<id>.<ext>` from the case
  table, left **red**. That file is the `oracle`; `proof` runs it.
- No harness → `oracle: inline`; the case table in the goal body is the
  oracle.

Then **sweep** the acceptance files that already exist. The host guards the
whole `tests/acceptance/` directory, so every edit the plan owes there is
yours, now (GOAL-FORMAT.md, Oracle rules):

1. Search every existing file under `tests/acceptance/` — earlier goals'
   and earlier weeks', none excluded by name — for **pins** the plan
   changes.
2. Apply each acceptance edit, red, as **its own test case** (never folded
   into a case a later goal also edits), and list it under the goal's
   **Acceptance edits (applied, read-only)** as `file:line, old → new`.
3. List each pinned file outside the directory under the owning goal's
   **Edits owned**.
4. Set each `proof` to the acceptance files green once that goal is done.

Run `~/claude-coding-workflow/scripts/goals.py GOALS.md validate` now and fix
every error it names: the oracle review reads `GOALS.md`, and an edit to it
after an approval would make the approval stale.

The implementer is forbidden to edit any of these. A weak oracle (vague
assertions, missing plan cases) is a Phase 3 failure, not a Phase 4 problem.

**2. Tier 1 — every goal with a file oracle.** Stub the API the plan adds
with every body a trap carrying a unique message (C/C++ write it, flush
stdout and stderr, then `abort()`); existing API is the real code. Run the
goal's **`proof`** command — the command the host runs — with
`PYTHONDONTWRITEBYTECODE=1`. Pass bar (GOAL-FORMAT.md, "Prove the oracle is
satisfiable before committing it — the tiers", has the per-language notes):

- stubbed API: nonzero exit, the trap message in the output, and the test
  source shows this goal's assertion after the call;
- existing API: nonzero exit, this goal's new assertion in the failure.

A zero exit, a build or collection error, or a failure that is neither fails
Tier 1. An Acceptance-edits file the `proof` skips runs through the same
runner filtered to this goal's case. Prove harness plumbing (registration,
sanitizer traps) through the same `proof` command. Stubs live in the
scratchpad, or in the worktree for the run only; delete them before any
oracle review. An `oracle: inline` goal's case table skips Tier 1 (it gets
Tier 2); its swept edits do not — they run through the project's runner,
filtered to this goal's case, like any other.

**3. Tier 2 — computed expectations.** Any expected value the plan does not
state verbatim is checked against an existing reference with the same
semantics, or a small brute-force model of the spec, in the scratchpad.
**Tier 3, last resort:** a full scratch implementation only when no reference
exists and brute force is infeasible — tell the user first; boxed to 30
minutes unless they extend it; never committed, never shown to the
implementer; when the box ends, stop and journal the claims left unproven.

**4. Self-review**, with the tier results in hand, against PLAN.md and the
oracle failure classes (GOAL-FORMAT.md). Record a checklist in the journal's
decompose entry: each class ticked, and per goal the tiers run and what each
showed.

**5. Oracle review.** From the repo root, in the background:

```bash
~/claude-coding-workflow/scripts/grok-review.sh --oracle <path/to/PLAN.md>
~/claude-coding-workflow/scripts/grok-review.sh --oracle --resume "$ORACLE_SESSION_ID" <path/to/PLAN.md>
```

Round 1 is a fresh Grok session seeded with the plan and its review log; it
reviews only this DAG's oracles (`scripts/lib/oracle-files.py`). Cap:
`MAX_ORACLE_ROUNDS` (default 3) counted rounds; only `GROK_REVIEW_RESULT: ok`
counts. `rate_limited` stops the review — tell the user. An `error` or
`MISSING` result is logged void and rerun, at most twice in a row; a third
goes to the user. Sort every finding, with a logged reason:

- an oracle defect → fix the oracle;
- rejected → logged why;
- `PLAN:` and accepted → stop and bounce to `/crucible`; the plan is fixed,
  re-signed and committed (step 0) before any oracle changes; the round
  count restarts at zero in a **new** fresh session.

Before each next round, every file changed since the last one reruns Tier 1
(and Tier 2 where computed), and worktree stubs are deleted. Append each
round to the feature's `PLAN-REVIEW-LOG.md` as `## Oracle round <n> — Grok`
plus `### Architect's response`.

**6. Re-check the approved bytes.** After the last round, Tier 1 (and Tier 2)
run once more on the exact text to be committed; a failure blocks the commit
and goes back through the review. A file changed after an APPROVED round
makes that approval stale; it goes back through the review in a new counted
round. Record the final tier results in the decompose checklist.

**7. Gate.** Commit only on a current APPROVED, or on a user override: at the
cap without one (including a confirming round that would pass the cap), list
each unresolved point with your counter-position, let the user decide, and
journal it as an `ARCHITECT oracle-review override` record the commit cites.
Never write an APPROVED.

Done when every goal has a red acceptance file or an inline case table
covering every plan case for its slice, every existing acceptance file has
been swept, the tiers are recorded, and the oracle review approved (or the
user overrode it).

## 5. Write and stop

Append the journal (`docs/journal/<slug>.md`, or the feature's journal):

```
## <UTC from date -u +%Y-%m-%dT%H:%M:%SZ> — ARCHITECT decompose
```

Ids, edges the user changed, where the oracles live, the step 4
checklist and the step 6 re-check results.

Run `~/claude-coding-workflow/scripts/goals.py GOALS.md validate` once more;
it must pass unchanged (a fix here is an edit after approval: step 6).

**Commit** `GOALS.md`, every file oracle, every swept acceptance edit, the
journal and the feature's `PLAN-REVIEW-LOG.md` in one commit before telling
the user they can run. First both must hold, or clean up:

- `git status --porcelain` shows no other path (a dirty plan fails it);
- `git status --porcelain --ignored=matching` shows no `!!` path under
  `tests/acceptance/`, an oracle path, or the plan path.

The host orchestrator refuses an uncommitted DAG and a dirty tree.

Present the cut. Ask: *"/run-goal for one ready goal, or `/run-goals`
to walk the DAG."* Do not dispatch until they say so.

Done when `GOALS.md` and every oracle exist, they plus the journal and log
are committed on a clean tree, and the user has seen the stop.

## Hard rules

- Product decisions stay in `PLAN.md`. This skill only cuts.
- The Architect owns everything under `tests/acceptance/`: new oracles
  and edits to existing ones. Write them here, red.
- No Opus pass on the DAG (v1).
- No dispatch from this skill. `/run-goal` is Phase 4.
- `to-tickets` is not this skill. In-repo `GOALS.md` only.
