---
name: crucible
description: Harden a plan before any code. Recon the codebase or research, interrogate load-bearing decisions, lock PLAN.md, then send it to headless Claude Opus 5 for bounded adversarial review. Use when the user says /crucible, "put this through the crucible", "harden this plan", "stress-test this plan", or is about to build something high-stakes (auth, schema, concurrency, migrations, payments, greenfield architecture). Replaces grill-me and grill-with-docs in this workflow. Not for reviewing already-written code and not for trivial edits.
---

# Crucible — Recon, Interrogate, Harden

Three phases. No production code in any of them.

- **Phase 0 — RECON** kills interviewing blind.
- **Phase 1 — INTERROGATE** kills building the wrong thing.
- **Phase 2 — REVIEW** kills a plan that sounds right but breaks. Claude Opus 5 attacks; Grok arbitrates.

You enter at three points only: confirming the assumptions ledger, answering the fire, signing off the converged plan. The attacker is read-only and never touches a file.

The review prompt lives in `~/grok-coding-workflow/scripts/claude-review.sh`. Do not fork it.

## PHASE 0 — RECON

Before asking the user a single question, determine the terrain.

### Detect the terrain

- **Brownfield** — the working directory has real source (not just scaffolding). Recon the code.
- **Greenfield** — empty dir, fresh scaffold, or a brand-new project. Research replaces recon.

### Brownfield

1. Explore architecture, relevant modules, patterns the plan must fit, current schema/auth/infra as applicable.
2. Load living docs: `CONTEXT.md` (or `CONTEXT-MAP.md`) and `docs/adr/`. If they exist, Phase 1 runs **docs-aware**.
3. If the task involves tech the repo can't answer, open the research gate.

### Greenfield

Open the research gate, then cover:

1. **Prior art** — how existing tools solve this; the standard shape.
2. **Stack** — a reasonable default plus one alternative worth considering.
3. **Known pitfalls** — 3–5 things people building this class of thing get wrong.

### Research gate (one question, when external research would help)

Do not silently pick a depth. Offer tiers with a recommendation:

- **`none`** — this session's knowledge + the codebase. Medium tasks on familiar ground.
- **`web`** — a handful of targeted searches (docs, gotchas, prior art). Default for most greenfield.
- **`deep`** — parallel research subagents (prior art, stack, pitfalls/postmortems, official docs), then one synthesis. Recommend only for high-stakes greenfield or unfamiliar tech.

If invoked with `research=none|web|deep`, skip the question and use that tier.

**If `deep`:** show the topic framing + the 3–5 questions the ledger needs answered. User edits or approves, **then** launch. Save the brief to `inbox/research/YYYY-MM-DD-<slug>-crucible-research.md` (with `## Key Takeaways`) and link it from the ledger entries it sourced and from `PLAN.md`.

`prototype` is available during recon for logic/state questions. Disposable — never merged. Fold measurements into the ledger as facts.

### Output: the Assumptions Ledger

One batch. Not one-at-a-time.

```markdown
## Assumptions Ledger
_Confirm or correct in one pass. Anything unmarked I treat as confirmed._
1. <assumption> — source: <code path / doc / research finding / convention>
2. ...
```

Each entry cites its source. Corrections that open real questions get promoted into the Phase 1 decision map.

## PHASE 1 — INTERROGATE

Every question must justify its own existence.

### Open with the Decision Map

```markdown
## Decision Map
### Load-bearing (asked one at a time)
- [ ] <decision> — irreversible / expensive-if-wrong
### Cosmetic (batched with defaults)
- [ ] <decision> — cheap to change later
```

Load-bearing = wrong answer costs a migration, a rewrite, a security hole, or user trust. Cosmetic = renameable, refactorable, swappable. Update the map as questions resolve.

### Load-bearing — one at a time

> **Q<n>: <the question>**
> **Why it matters:** <the dependency that makes this load-bearing>
> **Recommendation:** <your answer, committed — not a menu>
> **If we guess wrong:** <the concrete failure — migration, rewrite, breach, churn>

Wait for the answer before the next question. If "if we guess wrong" comes out weak, the question is cosmetic — demote it. If mid-interview a question is answerable from the code or the research, answer it yourself and log it to the ledger.

### Cosmetic — one batch

Recommendations with a one-line rationale each. Veto by exception; silence = accepted.

### Escape hatch

The user can say **"accept all remaining recommendations"**. Lock every open decision at its recommended answer, log them as such, proceed. Offer it explicitly if the load-bearing tier exceeds ~8 questions.

### Docs-aware (auto-on when Phase 0 found CONTEXT.md/ADRs; offer once on greenfield)

- Enforce the glossary — wording collision → stop, quote both meanings, make them pick.
- Pin down loose words with a proposed canonical replacement before continuing.
- Probe blurred concepts with a concrete edge case.
- Check claims against the code; a mismatch is a question.
- Maintain `CONTEXT.md` as terms settle (format: [CONTEXT-FORMAT.md](./CONTEXT-FORMAT.md)). Glossary only.
- Offer an ADR only past the three-part test (format: [ADR-FORMAT.md](./ADR-FORMAT.md)).

### Lock the plan

When the decision map is fully checked, write `PLAN.md` at the **target repo root**:

```markdown
# Plan: <task>
_Locked via crucible — by Grok + <user>_

## Goal
<one paragraph — what the interrogation actually settled>

## Approach
<numbered, concrete steps>

## Key decisions & tradeoffs
<contestable choices — name them so the attacker has something to bite; link any ADRs; mark escape-hatch locks>

## Assumptions
<the confirmed ledger — with sources>

## Risks / open questions
<anything still genuinely open>

## Out of scope
<bounds the interrogation established>
```

Initialize `PLAN-REVIEW-LOG.md`:

```markdown
# Plan Review Log: <task>
Phases 0-1 (recon + interrogation) complete — plan locked with the user. MAX_ROUNDS=<n>.
```

Append a journal START at `docs/journal/<slug>.md`.

## PHASE 2 — REVIEW (Grok ↔ Opus 5)

### Prerequisites (verify once, fast)

- `~/grok-coding-workflow/scripts/claude-review.sh` is executable.
- Echo the resolved model before Round 1 (`CLAUDE_REVIEW_MODEL`, default `claude-opus-5`). If the user objects, stop.
- Run from the target repo root (where `PLAN.md` lives).

### Tunables

| Var | Default | Meaning |
|-----|---------|---------|
| `MAX_ROUNDS` | `5` | Hard cap. The loop ALWAYS terminates here. |
| `PLAN_FILE` | `PLAN.md` | The plan Phase 1 produced. |
| `LOG_FILE` | `PLAN-REVIEW-LOG.md` | Append-only argument transcript. |

If invoked with `rounds=3`, use that for `MAX_ROUNDS`. Echo resolved values before starting.

### The loop

Maintain `ROUND` (start 1) and `SESSION_ID` (empty until round 1 returns).

**Round 1**

```bash
~/grok-coding-workflow/scripts/claude-review.sh PLAN.md
```

Read `SESSION_ID:` and `VERDICT_FILE:`. Confirm `CLAUDE_REVIEW_RESULT: ok`. Any other result → stop and tell the user.

**Rounds 2..MAX** — resume the SAME session:

```bash
~/grok-coding-workflow/scripts/claude-review.sh --resume "$SESSION_ID" PLAN.md
```

Every invocation is a foreground shell call with timeout **600000** ms.

### Each round, after the script returns

1. Read the verdict file. Append to `LOG_FILE`: `## Round <n> — Opus 5` + the full critique.
2. Grep the last line for the verdict:
   - `VERDICT: APPROVED` → Resolution (converged).
   - `VERDICT: REVISE` → decide **what is actually worth acting on**. Revise `PLAN_FILE`. Append `### Architect's response`: what changed, what was rejected, why. Increment round.
3. If round > `MAX_ROUNDS` → Resolution (deadlock).

### Resolution (user sign-off)

- **APPROVED:** present the final `PLAN_FILE`, a 3-bullet summary of what the crucible improved, and the round count. Ask: *"Interrogated + survived N rounds of Opus 5. Sign off? Next is `/to-goals`."* On sign-off, run `to-goals`.
- **MAX_ROUNDS without APPROVED:** do not fake convergence. List each unresolved point + the Architect's counter-position. The user breaks the tie.

Append a journal END with the outcome.

## Hard rules

- Phases run 0 → 1 → 2. Do not write `PLAN.md` until the decision map is resolved (or the escape hatch fired).
- The assumptions ledger is presented ONCE as a batch.
- Opus 5 is read-only every round. The script enforces it. Do not pass it write tools.
- The loop ALWAYS terminates at `MAX_ROUNDS`.
- Grok is final arbiter on every REVISE. Don't cave to everything; don't ignore it.
- Code only after user sign-off. Implementation is `/to-goals` then `/run-goal`.
- `LOG_FILE` is the deliverable. Keep the whole argument.
- `CONTEXT.md` stays a glossary.
- If the attacker cannot run, stop. Do not self-review as a substitute.

## What NOT to do

- Don't review already-written code.
- Don't skip Phase 1.
- Don't ask questions recon already answered.
- Don't ask a load-bearing-format question whose "if we guess wrong" is weak.
- Don't launch deep research without an approved prompt.
- Don't invoke `grill-me` or `grill-with-docs` on the same work.
- Don't offer `/codex-build` or flip roles into an implementer. After sign-off, run `to-goals`.
