# grok-coding-workflow

House workflow for Grok-driven planning and (later) multi-model implementation.

## Terms

**Architect**
The main Grok session. Plans, interrogates, arbitrates, decomposes, authors oracles. Does not write target-product feature code. Wakes on a Phase 4/5 stop. Does not sit in the implement/review hop.
Not: "Orchestrator"

**Orchestrator**
A host script (`scripts/run-goal.sh`, `scripts/run-goals.sh`) that walks one goal or the DAG: dispatch implementer, host-assess, dispatch goal reviewer, route the verdict. Not a model.
Not: "Architect", "implementer"

**Host assess**
The Orchestrator's independent check after DeepSeek exits: git state, proof command run on the host, oracle-untouched, then a host-written `DIFF_FILE` + `PROOF_OUTPUT`. Opus does not start until this passes.
Not: "the implementer's test log", "return handoff"

**Attacker**
Headless Claude Opus 5. Read-only critic of a locked plan. Advises; does not command.
Not: "reviewer" (that word is reserved for the goal reviewer)

**Implementer**
DeepSeek V4 Flash in the Codex CLI harness. Executes one goal under TDD.

**Goal reviewer**
Headless Claude Opus 5 judging an implementer diff until the goal is done.
Not: "Attacker" (that role only attacks PLAN.md)

**Goal**
One shippable vertical slice of a hardened plan. Identity is `g<n>-<slug>`.
Not: "ticket", "issue"

**GOALS.md**
The DAG for a signed-off plan: YAML preamble plus per-goal bodies and oracles.

**blocked_by**
A true gate — the blocked goal is a lie until those ids are done.

**conflicts_with**
A merge hazard, not a gate. Recorded for a future parallel walker.
v1 of Phase 5 runs sequentially and ignores it for scheduling.

**frontier**
The goals that may start now: `ready` or `in_progress`, every
`blocked_by` id already `done`. File order.

**Assumptions Ledger**
The single batch of things recon resolved without asking. Confirmed or corrected in one pass.

**Decision map**
The visible tree of still-open choices, split into load-bearing and cosmetic.
