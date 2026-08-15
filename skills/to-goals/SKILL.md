---
name: to-goals
description: Cut a signed-off PLAN.md into a dependent/independent goal DAG in GOALS.md, with Architect-authored acceptance oracles. Use when the user says /to-goals, "decompose the plan", "cut into goals", "break this into goals", or after a crucible plan is signed off. Not for planning (use /crucible), not for implementing, not for reviewing already-written code.
---

# To Goals — cut a hardened plan into a DAG

Phase 3 of the house workflow. Input is a **signed-off** `PLAN.md`.
Output is `GOALS.md` plus oracles. No implementer runs.

Format (YAML, bodies, field rules, slice rules, oracle rules):
[GOAL-FORMAT.md](./GOAL-FORMAT.md). Do not fork it.

## 1. Gate

`PLAN.md` exists at the target root **and** the user has signed it off
(journal or this conversation). Missing plan → refuse; point at
`/crucible`. Unsigned plan → ask for sign-off, do not cut.

Done when the gate passes or you have refused.

## 2. Read

Read `PLAN.md`, `PLAN-REVIEW-LOG.md`, `CONTEXT.md`, `docs/adr/`, and
the seams the interrogation already locked. Use the project's glossary.
Do not re-interview product decisions. A decision that looks wrong is a
crucible defect — bounce up, do not "fix" it in the DAG.

Done when every plan section and named ADR has been read.

## 3. Draft, then quiz

Draft the DAG **in chat**, not on disk: each `id`, `blocked_by`,
`conflicts_with`, `area`, one-line deliverable, `proof`. Apply every
slice rule in GOAL-FORMAT.md (vertical, DeepSeek-sized, independence
test, ~8 cap, expand–contract).

Ask:

1. Does the granularity feel right? (too coarse / too fine)
2. Are the blocking edges true gates — and are `conflicts_with` only
   merge hazards, not fake dependencies?
3. Should any goals be merged or split?

Iterate until the user approves the breakdown. Then write files.

Done when the user has approved the list.

## 4. Author the oracle

For every approved goal, write the acceptance cases **before** treating
`GOALS.md` as done.

- Target has a test harness → Architect writes
  `tests/acceptance/<id>.<ext>` from the case table. Leave them **red**.
  That file is the `oracle`. `proof` runs it.
- No harness → `oracle: inline`; the case table in the goal body is
  the oracle.

The implementer will be forbidden to edit these. A weak oracle (vague
assertions, missing plan cases) is a Phase 3 failure, not a Phase 4
problem.

Done when every goal has either a red acceptance file or an inline
case table covering every plan case for that slice.

## 5. Write and stop

Write `GOALS.md` at the target root in the GOAL-FORMAT.md shape.
Statuses: `ready` if `blocked_by` is empty, else `blocked`.

Append the journal (`docs/journal/<slug>.md`):

```
## <UTC from date -u +%Y-%m-%dT%H:%M:%SZ> — ARCHITECT decompose
```

Ids, edges the user changed, where the oracles live.

Present the cut. Ask: *"/run-goal for one ready goal, or `/run-goals`
to walk the DAG."* Do not dispatch until they say so.

Done when `GOALS.md` and every oracle exist, the journal is appended,
and the user has seen the stop.

## Hard rules

- Product decisions stay in `PLAN.md`. This skill only cuts.
- The Architect owns every oracle. Write them here, red.
- No Opus pass on the DAG (v1).
- No dispatch from this skill. `/run-goal` is Phase 4.
- `to-tickets` is not this skill. In-repo `GOALS.md` only.
