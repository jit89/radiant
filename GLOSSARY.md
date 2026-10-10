# claude-coding-workflow

House workflow for Claude-driven planning and multi-model implementation.

## Terms

**Architect**
The main Claude Code session. Plans, interrogates, arbitrates, decomposes, authors oracles. Does not write target-product feature code. Wakes on a Phase 4/5 stop. Does not sit in the implement/review hop. May not attack its own plan.
Not: "Orchestrator"

**Orchestrator**
A host script (`scripts/run-goal.sh`, `scripts/run-goals.sh`) that walks one goal or the DAG: dispatch implementer, host-assess, dispatch goal reviewer, route the verdict. Not a model.
Not: "Architect", "implementer"

**Host assess**
The Orchestrator's independent check after the implementer exits: git state, proof command run on the host, oracle-untouched, then a host-written `DIFF_FILE` + `PROOF_OUTPUT`. Opus does not start until this passes.
Not: "the implementer's test log", "return handoff"

**Attacker**
Headless Grok. Read-only critic of a locked plan, and a different model from the Architect on purpose. Advises; does not command.
Not: "reviewer" (that word is reserved for the goal reviewer)

**Implementer**
Claude Haiku 5.5 in headless, sandboxed Claude Code (`claude-implement.sh`). Executes one goal under TDD. When Haiku refuses or declines the goal, the same pass reruns once on DeepSeek V4 Flash through the same harness.

**Goal reviewer**
Headless Claude Opus 5.5 judging an implementer diff until the goal is done. A separate session with no access to the Architect's conversation; it needs `--add-dir` for the run dir or it cannot read the diff and proof it is judging.
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

**Finding**
One defect the goal reviewer wants fixed, emitted as a `FIX: <path>:<line> — <defect> — <what to change>` line. The path it opens with is the file the implementer must change; naming the oracle there bounces the goal.
Not: a numbered analysis heading in the reviewer's prose

**Implementer fallback**
The one model switch the implementer makes: Haiku's safeguards flag the pass, or it ends `IMPLEMENTER_STATUS: DECLINED`, and the launcher reruns it once on DeepSeek in a fresh session, journaled as `FALLBACK=`. Never on a rate limit.
Not: "retry", "quota fallback"

**Codex home lock**
The exclusive lock the legacy `deepseek-code.sh` (`IMPLEMENTER=codex`) holds on the shared `CODEX_HOME` while it rewrites `config.toml` and runs. Makes concurrent runs queue rather than read each other's config.
