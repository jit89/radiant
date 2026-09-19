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

**Acceptance edits (applied, read-only):** <edits the Architect already made under `tests/acceptance/` for this goal — file:line, old → new — or None>

**Edits owned:** <files outside `tests/acceptance/` this goal must change because an acceptance assertion pins them (config, packaging, unit tests), or None>

**Out of scope:** <bounds + ceilings that need a ponytail comment>

**Oracle:** `tests/acceptance/g1-store.test.ts` (read-only to the implementer)
**Proof:** `pnpm test tests/acceptance/g1-store.test.ts`
````

If the target has no test harness, set `oracle: inline` and `proof: (case table)`.
The case table in the body *is* the oracle.

`plan:` names the signed plan, committed. A goal's run freezes it at the goal's base commit: both agents read that copy, and a change to the live file during the run stops the goal as contract tampering, like an oracle edit.

## Field rules

- `id` — `g<n>-<slug>`, numbered in dependency order (blockers first). Stable once written.
- `blocked_by` — ids that must be **done** before this goal can start. A true gate: B is a lie until A exists.
- `conflicts_with` — ids that are not gates but share an area hard enough that Phase 5 must not merge them in parallel. Same-`area` is not automatic conflict; only declare it when a parallel merge would actually collide.
- `area` — coarse module lock (`mailer/inbound`, not a file path). File paths go stale.
- `proof` — exact command that counts as done. Architect runs it, not the implementer's word. It must leave the repo as it found it: every file it writes (caches, reports, coverage) must match `.gitignore`, or the goal stops as `proof-tamper`. `.gitignore` does not excuse a path under `tests/acceptance/` or the plan: an ignored file there is tampering, because the reviewer's diff would never show it. Python bytecode is the common case: the host runs the implementer and the proof with `PYTHONDONTWRITEBYTECODE=1`, so run your own Phase 3 checks the same way (or delete `tests/acceptance/**/__pycache__` before committing), or the first goal wakes `contract-tamper-ignored`.
- `oracle` — path of the Architect-authored acceptance file, or `inline`.
- `status` — `ready` (no unfinished blockers) or `blocked` when first
  written. Phase 4 sets `in_progress`, then `done` or `bounced`.

`blocked_by` and `conflicts_with` in the markdown body must match the YAML. The YAML wins if they drift.

Each goal has exactly one `## <id> — <title>` section: the id, then a space or end of line (`## g1-store:` does not count). `goals.py validate` rejects duplicates, and a goal with no section, whatever its oracle: the section is the handoff's spec, and for `oracle: inline` its case table is the oracle.

## Slice rules

- Vertical: a narrow complete path (schema + API + tests, or the equivalent), demoable or verifiable alone. Not a horizontal layer ("just the types").
- Sized for **one DeepSeek context window** — tighter than a human ticket.
- Independence test: if two goals landed tomorrow in separate worktrees, would either be a lie without the other? If yes, they are not independent — add an edge or merge them.
- Cap ~8 goals. More than that → merge, or the plan is still too big (bounce to crucible).
- Wide mechanical change (rename, retype, blast radius that no vertical slice can land green): **expand → migrate batches → contract**. Each step is its own goal; migrate batches `blocked_by` the expand; contract `blocked_by` every migrate batch.

## Oracle rules

The Architect authors the oracle. The implementer makes it pass and does not edit it. A case that looks wrong is a blocker to bounce, not a license to change the test.

Each case is an example: concrete input → concrete output, plus the edges the plan named. Assertions are exact values, not "does not throw".

### The whole directory is the Architect's

The host guards all of `tests/acceptance/`, not only a goal's own oracle: a change to any file there during a goal's run — an earlier goal's, an earlier week's — stops that goal as tampering, and a resume refuses one made while the goal was paused. So every edit under `tests/acceptance/` is the Architect's, applied in Phase 3 before dispatch and listed under **Acceptance edits (applied, read-only)**. **Edits owned** holds only paths outside the directory; `goals.py validate` rejects a `tests/acceptance/` path there.

### Pins

A **pin** is an existing assertion that fixes something the plan changes. When a plan changes behaviour an earlier oracle already covers, each pin owes an edit. The kinds that slipped through before:

- exact counts and totals — a whole-library count, `len(x) == 22`, `{"held": 1, "skipped": 22}`
- field, parameter, and signature lists, including argument order
- pinned lists and sets, including ones a test reads from config (a package list in `pyproject.toml`)
- single-row picks — `[0]`, `fetchone()`, a read of the first row where the plan adds rows of another kind
- example values whose width or format the plan changes
- docstrings and comments saying "until g<n>" or describing the old behaviour

A pin on a file outside the directory (the `pyproject.toml` list itself) is implementer work under that goal's **Edits owned**.

### Proof composition

Pre-applied edits stay red until their goal lands. A goal's `proof` runs only acceptance files that are green once that goal is done; a file carrying a later goal's red edit stays out of it.
