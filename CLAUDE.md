# Agentic Coding Workflow (Claude)

Portable house workflow. Drop this file into a target repo (or merge it
into that repo's `AGENTS.md`). Project-specific principles do **not**
belong here — put those in `coding-standards.md` at the target root.

This session is the **Architect**. It does not write production feature
code for a target product. Work on *this* workflow repo itself is
in-session (do not dispatch the implementer at the house).

## Roles

| Role | Model | Responsibilities |
|------|-------|------------------|
| **Architect** | Claude Code (this session) | Intake, recon, interrogate, lock `PLAN.md`, arbitrate review, author the acceptance oracle, decompose goals, dispatch, adjudicate, recover. Does **not** implement target features. |
| **Attacker** | Grok (`grok-4.7`) | Headless, read-only. Attacks a locked plan (Phase 2) and the Architect's acceptance oracles (Phase 3). A different model on purpose — the Architect cannot attack its own plan or oracles. Never reviews implementer diffs. Advises; does not command. |
| **Implementer** | Claude Haiku 5.5 (`claude-haiku-5-5`, effort `xhigh`), headless and sandboxed; DeepSeek V4 Flash (`deepseek-v4-flash`) through the same Claude Code harness when Haiku refuses or declines | Cheap long TDD loops against one goal. Sibling process. |
| **Goal reviewer** | Claude Opus 5.5 (`claude-opus-5-5`) | Headless, separate session. Judges the *implementer's* diff — never the Architect's own code — against the goal. Not the plan attacker. |

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
| 4 Per-goal implement (Haiku, DeepSeek fallback) + Opus review (`run-goal`) | shipped |
| 5 Orchestrate the DAG (`run-goals`) | shipped |
| A Architecture health (periodic) | existing `improve-codebase-architecture` skill |

`/run-goals` walks the frontier one goal at a time, or with `--jobs N`
(2-4) in fork-join waves, each goal in its own worktree. After the walk
ends, stop.

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
evidence. Prototypes are throwaway: never merged, kept at most on a
`prototype/<name>` branch as evidence. Research cites primary sources.

`GLOSSARY.md` is a glossary only (a legacy `CONTEXT.md` is read the
same way and renamed with `git mv` on first edit). An ADR is written
only when a decision is (1) expensive to reverse, (2) puzzling without
context, and (3) a genuine trade-off.

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

**Prove satisfiability, then have the oracles attacked, before committing.**
Cheapest evidence first (`skills/to-goals/SKILL.md` §4 is the procedure):
Tier 1 runs each goal's `proof` against trap stubs of the new API and must
fail for the right reason; Tier 2 checks computed expected values against a
reference or a brute-force model; Tier 3, a full scratch implementation, is a
last resort, announced and boxed. Then a self-review with that evidence, and
the **oracle review**: `grok-review.sh --oracle` in a fresh session, capped at
3 rounds, gating the commit. On uregex a ~550-line scratch caught only two
harness defects that a Tier 1 run catches; the walk's one FIX round was an
oracle gap, which the review targets.

### Phase 4 — Implement + review

From the target repo: `scripts/run-goal.sh <id>`. The **script** is
the hop (assess, proof, Opus, FIX loop). The Architect only runs it and,
on a nonzero exit, reads `STOP_FILE:`. Do not restate the hop here.

### Phase 5 — Orchestrate

From the target repo: `scripts/run-goals.sh`, one goal at a time. Keys on
`run-goal.sh`'s exit code. `scripts/goals.py` is the DAG reader.

`scripts/run-goals.sh --jobs N` (N from 2 to 4) walks in **waves**: up to N
frontier goals that do not name each other in `conflicts_with`, each in its
own worktree on `cw/<goal>`, joined before the next wave. The walker alone
writes `GOALS.md` and the walk branch; at the join it **integrates** each
finished goal one at a time in a scratch worktree (journal check,
`merge --no-ff` of the reviewed commit, `worktree_setup`, the merged proofs of
every goal done in the walk) and fast-forwards the walk branch only when all
of it is green. A stopped goal is recut and runs fresh. The contract is
`docs/features/parallel-walker/PLAN.md`; do not restate it here.

### Phase A — Architecture health

Periodic, off the critical path. Only on an accreted codebase with a
real `GLOSSARY.md` / `docs/adr`. `improve-codebase-architecture` reports
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

The Phase 3 oracle review is the same launcher with `--oracle`, from the
target repo with `GOALS.md` drafted (`skills/to-goals/SKILL.md` §4):

```bash
~/claude-coding-workflow/scripts/grok-review.sh --oracle <path/to/PLAN.md>
~/claude-coding-workflow/scripts/grok-review.sh --oracle --resume "$ORACLE_SESSION_ID" <path/to/PLAN.md>
```

Round 1 is always a fresh session; never pass it the plan-attack
`SESSION_ID`. After a `PLAN:` bounce and a re-signed plan, start a new
oracle session rather than resuming the old one.

Run each round with the Bash tool's `run_in_background: true`. A first
round on a ~240-line plan took ~20 minutes at high reasoning effort, past the
10-minute ceiling on a foreground call; later rounds are shorter. The harness
re-invokes this session when the round exits; do not poll it.

## Dispatching Phase 4 / 5

Run from the **target repo**:

```bash
~/claude-coding-workflow/scripts/run-goal.sh <id>
~/claude-coding-workflow/scripts/run-goals.sh
~/claude-coding-workflow/scripts/run-goals.sh --jobs 3   # parallel waves
```

While a walk runs, the `walk` mod (`mods/walk/`, installed by
`install.sh`) keeps the session's task list current: one task per goal of the
walk this session launched (in any repo), ticked as it runs, a stopped goal
titled `PAUSED:` / `BOUNCED: <reason>`. Write no walk tasks yourself. `/walk`
opens every goal as a live git graph; `scripts/events.py walks` and `graph`
give the same from a shell.

Run both with the Bash tool's `run_in_background: true`. A goal takes
up to ~40 minutes and a walk N times that, past the 10-minute ceiling
on a foreground call, so a foreground run gets killed mid-goal. The
harness re-invokes this session when the script exits; do not poll it.
Then read the output file's tail for the exit status and `STOP_FILE:`.

Do not drive `claude-implement.sh` / `claude-goal-review.sh` from this
session on the happy path. The sandbox, the stripped environment and the
key handling stay inside those launchers. `IMPLEMENTER=codex` selects the
legacy DeepSeek-in-Codex launcher (`deepseek-code.sh`) until the new one
has shipped goals. Never ask the user to paste a
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

**Carried inputs go in every slice that depends on them, not only the one that will
fix them.** A hazard gets written down by whoever discovers it — usually the current
slice, or the one taking the fix. The slice that actually *breaks* without it is often
much later, and it reads its own block. Recording it once, in the fixing slice's block,
loses it entirely if that fix slips. Name the later slice explicitly and say what
happens if the fix has not landed by then. The crucible's recon sweeps for this from
the other side, and the two together are what make a carried input survive.

The host also writes one `ORCHESTRATOR wake <id> r<n> reason=<reason>`
line (no stop-file dump, no Opus findings) and a JSONL index in
`~/.cache/claude-coding-workflow/logs/`. After a wake, query with
`scripts/logs.sh errors` / `warnings` / `last` / `goal <id>` /
`since 5m|walk`. Do not invent SQL. The markdown journal is still
source of truth for resume and for the implementer.

A wake's run dir (the stop file and everything it names) and Grok's verdict
files live under `~/.cache/claude-coding-workflow/` (`runs/`, `grok/`),
private and pruned after 14 days, not in `$TMPDIR`, which macOS clears.

## Skill quick-reference

| Skill | When |
|-------|------|
| `crucible` | Phases 1–2 — recon, interrogate, harden (Grok attacks) |
| `to-goals` | Phase 3 — cut signed-off `PLAN.md` into `GOALS.md`; prove the oracles by tier (Tier 1 runs each `proof` against trap stubs); Grok oracle review (`grok-review.sh --oracle`) gates the commit |
| `run-goal` | Phase 4 — exec `scripts/run-goal.sh`; wake on nonzero |
| `run-goals` | Phase 5 — exec `scripts/run-goals.sh`; wake on nonzero |
| `wayfinder` | Phase 0 — borrowed; needs `setup-matt-pocock-skills` once per repo (local tracker under `.scratch/`) |
| `prototype` | During recon — borrowed |
| `research` | During recon or a bounce — borrowed |
| `tdd` | Phase 4 — borrowed; also inlined in the implementer prompt |
| `handoff` | Phase 4 — borrowed (paths only, no restated spec) |
| `diagnosing-bugs` | Hard defect after code exists — borrowed |
| `improve-codebase-architecture` | Phase A only — borrowed |
| `grilling` / `domain-modeling` / `codebase-design` | Pulled in by `wayfinder` and `improve-codebase-architecture` — borrowed dependencies, not entry points |
| `setup-matt-pocock-skills` | Once per target repo, before the first `wayfinder` — borrowed |
| `grill-me` / `grill-with-docs` | **Not used** — `crucible` replaces them here |
| `to-tickets` | **Not used** — `to-goals` writes in-repo `GOALS.md` |

House `install.sh` links crucible / to-goals / run-goal / run-goals and
the borrowed skills into `~/.claude/skills`. The borrowed skills come from
a clone of [mattpocock/skills](https://github.com/mattpocock/skills) at
`~/mattpocock-skills`, pinned to a reviewed commit in `install.sh`; not
the self-updating plugin, because an upstream rename can silently break
the house. `install.sh --check` warns when one is missing or the clone
has drifted from the pin. `research` and `prototype` share names with
Claude Code built-ins: check `/skills` lists the borrowed copy before
leaning on the bare name.

## Hard rules

- The Architect plans and arbitrates. Grok attacks the **plan** and the
  **oracles** (`grok-review.sh`, `--oracle`). Opus 5.5 reviews **code**
  (`claude-goal-review.sh`). Haiku 5.5 implements (`claude-implement.sh`).
  Nobody grades their own work: the Architect's plan is attacked by a
  different model, and the code Opus judges was written by the
  implementer in its own session, not by the Architect.
- No production feature code without a hardened, user-signed plan.
- After Phase 2, `PLAN.md` is the product contract and
  `PLAN-REVIEW-LOG.md` is the argument. After Phase 3, `GOALS.md` plus
  the oracles are what an implementer may run against.
- `GLOSSARY.md` = glossary only. ADRs = sparingly. `coding-standards.md`
  = project-specific principles.
- Secrets are redacted from every handoff and log.
- Do not use Codex/ChatGPT, and never your own second opinion, as the
  **plan attacker** — that is the one role this session may not fill.
  If the attacker or the implementer cannot run, stop and tell the
  user. The implementer switches model in one case only: Haiku refuses
  or declines the goal, and the launcher reruns that pass once on
  DeepSeek and journals it (`IMPLEMENTER_FALLBACK`). Never on a rate
  limit, an error, or a goal that ran out of fix rounds.
