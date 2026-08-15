# GOALS.md format

One file at the **target repo root**. YAML preamble is what Phase 5
will parse. Markdown bodies are for humans and for the implementer.

Do not publish to a tracker. Do not split into per-goal files.

## Shape

````md
# Goals: <task>
_Cut from PLAN.md — signed <date>_

```yaml
plan: PLAN.md
log: PLAN-REVIEW-LOG.md
journal: docs/journal/<slug>.md
goals:
  - id: g1-store
    title: Persist inbound mail
    blocked_by: []
    conflicts_with: []
    area: mailer/inbound
    proof: pnpm test tests/acceptance/g1-store.test.ts
    oracle: tests/acceptance/g1-store.test.ts
    status: ready
  - id: g2-ack
    title: Label-ack after enqueue
    blocked_by: [g1-store]
    conflicts_with: []
    area: mailer/inbound
    proof: pnpm test tests/acceptance/g2-ack.test.ts
    oracle: tests/acceptance/g2-ack.test.ts
    status: blocked
```

## g1-store — Persist inbound mail

**What it delivers:** <end-to-end behaviour, user-facing — not a file list>

**Blocked by:** None — can start immediately.

**Conflicts with:** None.

**Seams:** <pre-agreed TDD seams; the implementer must not wait to confirm these>

**Case table:**

| input | expected |
|-------|----------|
| <concrete> | <concrete> |

**Out of scope:** <bounds + ceilings that need a ponytail comment>

**Oracle:** `tests/acceptance/g1-store.test.ts` (read-only to the implementer)
**Proof:** `pnpm test tests/acceptance/g1-store.test.ts`
````

If the target has no test harness, set `oracle: inline` and `proof: (case table)`.
The case table in the body *is* the oracle.

## Field rules

- `id` — `g<n>-<slug>`, numbered in dependency order (blockers first). Stable once written.
- `blocked_by` — ids that must be **done** before this goal can start. A true gate: B is a lie until A exists.
- `conflicts_with` — ids that are not gates but share an area hard enough that Phase 5 must not merge them in parallel. Same-`area` is not automatic conflict; only declare it when a parallel merge would actually collide.
- `area` — coarse module lock (`mailer/inbound`, not a file path). File paths go stale.
- `proof` — exact command that counts as done. Architect runs it, not the implementer's word.
- `oracle` — path of the Architect-authored acceptance file, or `inline`.
- `status` — `ready` (no unfinished blockers) or `blocked` when first
  written. Phase 4 sets `in_progress`, then `done` or `bounced`.

`blocked_by` and `conflicts_with` in the markdown body must match the YAML. The YAML wins if they drift.

## Slice rules

- Vertical: a narrow complete path (schema + API + tests, or the equivalent), demoable or verifiable alone. Not a horizontal layer ("just the types").
- Sized for **one DeepSeek context window** — tighter than a human ticket.
- Independence test: if two goals landed tomorrow in separate worktrees, would either be a lie without the other? If yes, they are not independent — add an edge or merge them.
- Cap ~8 goals. More than that → merge, or the plan is still too big (bounce to crucible).
- Wide mechanical change (rename, retype, blast radius that no vertical slice can land green): **expand → migrate batches → contract**. Each step is its own goal; migrate batches `blocked_by` the expand; contract `blocked_by` every migrate batch.

## Oracle rules

The Architect authors the oracle. The implementer makes it pass and does not edit it. A case that looks wrong is a blocker to bounce, not a license to change the test.

Each case is an example: concrete input → concrete output, plus the edges the plan named. Assertions are exact values, not "does not throw".
