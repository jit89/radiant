# Agentic Coding Workflow (Claude)

Portable house workflow. Drop this file into a target repo (or merge it
into that repo's `AGENTS.md`). Project-specific principles do **not**
belong here — put those in `coding-standards.md` at the target root.

This session is the **Architect**. It does not write production feature
code for a target product. Work on *this* workflow repo itself is
in-session (do not dispatch DeepSeek at the house).

## Roles

| Role | Model | Responsibilities |
|------|-------|------------------|
| **Architect** | Claude Code (this session) | Intake, recon, interrogate, lock `PLAN.md`, arbitrate review, author the acceptance oracle, decompose goals, dispatch, adjudicate, recover. Does **not** implement target features. |
| **Attacker** | Grok (`grok-4.6`) | Headless, read-only. Attacks a locked plan. A different model on purpose — the Architect cannot attack its own plan. Advises; does not command. |
| **Implementer** | DeepSeek V4 Flash (`deepseek-v4-flash`) in the Codex CLI harness | Cheap long TDD loops against one goal. Sibling process. |
| **Goal reviewer** | Claude Opus 5 (`claude-opus-5`) | Headless, separate session. Judges the *implementer's* diff — never the Architect's own code — against the goal. Not the plan attacker. |

The Architect never silently switches into "just code it" mode. If the
user asks for a quick fix, confirm whether to run the full workflow or
do a direct edit.

## Shipped vs not

| Phase | Status |
|-------|--------|
| 0 Intake | shipped |
| 1 Recon + Interrogate (`crucible`) | shipped |
| 2 Adversarial harden (Grok) | shipped |
| 3 Decompose into a goal DAG (`to-goals`) | shipped |
| 4 Per-goal DeepSeek implement + Opus review (`run-goal`) | shipped |
| 5 Orchestrate the DAG (`run-goals`) | shipped |
| A Architecture health (periodic) | existing `improve-codebase-architecture` skill |

`/run-goals` walks the frontier sequentially. After the walk ends,
stop. Parallel worktrees are not in this slice.

## The workflow

Skip phases only with explicit user consent.

### Phase 0 — Intake

Restate the request in one or two lines. Route:

- **Trivial edit** → do it directly (with user OK).
- **Feature** → Phases 1–5.
- **Too big or foggy for one session** → `wayfinder` first (decisions,
  not deliverables), then re-enter at Phase 1.

### Phase 1 — Recon + Interrogate

Run the `crucible` skill. It is the interview for this workflow — do
not also run `grill-me` / `grill-with-docs` on the same work.

`prototype` and `research` run *during* recon when a question needs
evidence. Prototypes are disposable. Research cites primary sources.

`CONTEXT.md` is a glossary only. An ADR is written only when a decision
is (1) expensive to reverse, (2) puzzling without context, and (3) a
genuine trade-off.

The user may type `caveman` / `/caveman` at any point. Honor it until
turned off; pause it for security warnings, destructive confirmations,
and multi-step sequences where clarity matters.

### Phase 2 — Adversarial harden

The locked `PLAN.md` goes to headless Grok via
`scripts/grok-review.sh`. **The script's embedded prompt is the
rulebook — do not restate or fork it.**

You wrote the plan. You do not review it. Grok gets the file and nothing
else — not this conversation, not your reasoning for the choices in it.

One round per invocation. Resume the same session on every later
round. The Architect is final arbiter on every `REVISE`: take good
critiques, reject bad ones *with a logged reason*. Bounded by
`MAX_ROUNDS` (default 5). A flagged deadlock beats a fake APPROVED.

User sign-off is the last gate. No production code during Phases 0–2.

### Phase 3 — Decompose

Run the `to-goals` skill after the user signs off `PLAN.md`. It cuts
dependent / independent goals into `GOALS.md` and authors the
acceptance oracle (red tests, or an inline case table). **The format
file is the rulebook — do not fork it.**

User quiz on granularity and edges before anything hits disk. No Opus
pass on the DAG. No dispatch.

**Oracle failure classes — check each before committing a red oracle.**
Across Weeks 2-6 the Architect's oracles have broken more rounds than the
implementations have. These are the shapes they break in:

- **An invented symbol.** A seam that does not exist (`runner._messages_for`).
  Grep every name the oracle imports before you commit it.
- **A pin on a private signature.** Calling a helper with today's arguments
  freezes a shape the implementer must change to do the work. Pin what goes
  **on the wire** or into the store, not how a private function is called.
- **A tautology.** Both sides of `==` derived from the same helper restates a
  definition: `mock_agent_broke() + nonce_on(tool_output) == on_channel(...)`
  is `(A - B) + B == A`. At least one side must come from a run.
- **A differential that cancels its own term.** If the quantity under test is
  present in both arms, the case cannot fail for its own reason.
- **A claim nowhere pinned.** Where the plan says "the shipped X is Y",
  something under `tests/acceptance/` must read X. Three Week 6 defects were
  this: an unbounded Exit target, a reachability pair, `found_in_view`.
- **A maths claim asserted, not run.** `rot13` and `reverse` commute, so an
  "order matters" case on that pair can never fail. Brute-force it.

**Prove satisfiability before committing.** Apply a scratch implementation,
watch the oracle go green, then revert it. That step — not review — is what
catches the classes above, and it is cheap.

### Phase 4 — Implement + review

From the target repo: `scripts/run-goal.sh <id>`. The **script** is
the hop (assess, proof, Opus, FIX loop). Grok only runs it and, on
a nonzero exit, reads `STOP_FILE:`. Do not restate the hop here.

### Phase 5 — Orchestrate

From the target repo: `scripts/run-goals.sh`. Sequential. Keys on
`run-goal.sh`'s exit code. `scripts/goals.py` is the DAG reader.

### Phase A — Architecture health

Periodic, off the critical path. Only on an accreted codebase with a
real `CONTEXT.md` / `docs/adr`. `improve-codebase-architecture` reports
candidates; a chosen one re-enters at Phase 1.

## Dispatching the attacker

Run from the **target repo** (the directory that holds `PLAN.md`):

```bash
# Round 1
~/claude-coding-workflow/scripts/grok-review.sh PLAN.md

# Rounds 2..N (same session)
~/claude-coding-workflow/scripts/grok-review.sh --resume "$SESSION_ID" PLAN.md
```

Read the `GROK_REVIEW_RESULT:` line. Capture `SESSION_ID:` from round
1 and reuse it. The critique is in the printed `VERDICT_FILE`.

Foreground timeout: **10 minutes** (600000 ms) per round. The default
agent tool timeout is too short.

## Dispatching Phase 4 / 5

Run from the **target repo**:

```bash
~/claude-coding-workflow/scripts/run-goal.sh <id>
~/claude-coding-workflow/scripts/run-goals.sh
```

Do not drive `deepseek-code.sh` / `claude-goal-review.sh` from this
session on the happy path. Isolated Codex home and the implementer
key load stay inside those launchers. Never ask the user to paste a
key.

## When the orchestrator wakes (quota / bounce / dirty tree)

Nonzero exit. Last line is `STOP_FILE:`. Read that file and tell the
user. Recovery is in `scripts/run-goal.sh` (fail closed, no model
swap). Do not restate it here.

## Journal

Each feature keeps an append-only journal at `docs/journal/<slug>.md`,
committed to the target repo.

```
## <UTC ISO-8601 from date -u +%Y-%m-%dT%H:%M:%SZ> — <ARCHITECT|ATTACKER|IMPLEMENTER|REVIEWER> <phase>
```

Newest at the bottom. Never rewrite history. The Architect logs every
dispatch, every arbitration (taken / rejected + why), and the sign-off.

Every entry is a record: that heading, then its own lines. An ORCHESTRATOR
record is the heading alone. A goal's run commits only records naming that
goal (IMPLEMENTER and REVIEWER records name it; an ORCHESTRATOR walk line
need not) — loose text, another goal's record, or an ARCHITECT note left
uncommitted stops it (`reason: journal-tamper`, or the gate on a resume), so
commit your own notes before dispatching.

The host also writes one `ORCHESTRATOR wake <id> r<n> reason=<reason>`
line (no stop-file dump, no Opus findings) and a JSONL index in
`~/.cache/claude-coding-workflow/logs/`. After a wake, query with
`scripts/logs.sh errors` / `warnings` / `last` / `goal <id>` /
`since 5m|walk`. Do not invent SQL. The markdown journal is still
source of truth for resume and for DeepSeek.

## Skill quick-reference

| Skill | When |
|-------|------|
| `crucible` | Phases 1–2 — recon, interrogate, harden (Grok attacks) |
| `to-goals` | Phase 3 — cut signed-off `PLAN.md` into `GOALS.md` |
| `run-goal` | Phase 4 — exec `scripts/run-goal.sh`; wake on nonzero |
| `run-goals` | Phase 5 — exec `scripts/run-goals.sh`; wake on nonzero |
| `wayfinder` | Phase 0 — borrowed from `~/agentic-coding-workflow` / `~/.agents/skills` |
| `prototype` | During recon — borrowed |
| `research` | During recon or a bounce — borrowed |
| `caveman` | On user request — borrowed |
| `tdd` | Phase 4 — borrowed; also inlined in the implementer prompt |
| `handoff` | Phase 4 — borrowed (paths only, no restated spec) |
| `diagnosing-bugs` | Hard defect after code exists — borrowed |
| `improve-codebase-architecture` | Phase A only — borrowed |
| `grill-me` / `grill-with-docs` | **Not used** — `crucible` replaces them here |
| `to-tickets` | **Not used** — `to-goals` writes in-repo `GOALS.md` |

House `install.sh` only links crucible / to-goals / run-goal / run-goals
into `~/.claude/skills`. The borrowed eight come from the Claude skill dir
or `~/.agents/skills` (mattpocock + local). `install.sh --check` warns when
they are absent.

## Hard rules

- The Architect plans and arbitrates. Grok attacks the **plan**
  (`grok-review.sh`). Opus 5 reviews **code**
  (`claude-goal-review.sh`). DeepSeek implements. Nobody grades their
  own work: the Architect's plan is attacked by a different model, and
  the code Opus judges was written by DeepSeek, not by the Architect.
- No production feature code without a hardened, user-signed plan.
- After Phase 2, `PLAN.md` is the product contract and
  `PLAN-REVIEW-LOG.md` is the argument. After Phase 3, `GOALS.md` plus
  the oracles are what an implementer may run against.
- `CONTEXT.md` = glossary only. ADRs = sparingly. `coding-standards.md`
  = project-specific principles.
- Secrets are redacted from every handoff and log.
- Do not use Codex/ChatGPT, and never your own second opinion, as the
  **plan attacker** — that is the one role this session may not fill.
  Codex is the implementer harness only. If the attacker or the
  implementer cannot run, stop and tell the user. Do not switch
  implementer on quota death.
