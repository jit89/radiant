# Using it with Claude Code

Your Claude Code session is the **Architect**. It plans with you, writes the
contract, and dispatches; it never writes the target feature's code itself.
Implementation and review happen in separate headless sessions started by the
host scripts. This guide walks one feature from idea to merged goals.

## Before you start: the target repo

1. A git repository with a clean tree and, ideally, a test runner.
2. Copy `~/claude-coding-workflow/CLAUDE.md` into it (or merge it into the
   repo's own `CLAUDE.md` / `AGENTS.md`). It tells the Architect its role, the
   phases and the hard rules.
3. Optional: a `coding-standards.md` at the repo root for project-specific
   principles (the goal reviewer judges against it), and a `GLOSSARY.md` for
   domain terms (the crucible keeps it up to date).
4. No live `.env` in the checkout (see [Getting started](getting-started.md#3-keys)).

Open Claude Code in the target repo.

## Phase 0 — say what you want

Describe the change. The Architect restates it and routes it: a trivial edit
it offers to do directly (with your OK); a feature goes through the phases; a
request too big or foggy for one session goes to `/wayfinder` first (a borrowed
skill that turns it into decisions), then comes back here.

## Phase 1-2 — `/crucible`: the plan, attacked

```
/crucible add per-user rate limiting to the public API
```

1. **Recon.** The Architect reads the codebase (or, for a new project, offers a
   research depth: none, web, or deep with parallel research agents) and
   presents an **assumptions ledger** in one batch: each assumption with its
   source. Correct what is wrong; anything unmarked counts as confirmed.
2. **Interrogate.** A **decision map** splits open decisions into
   *load-bearing* (asked one at a time, each with a recommendation and what a
   wrong guess would cost) and *cosmetic* (one batch with defaults; silence
   accepts). You can say "accept all remaining recommendations".
3. **Lock.** `PLAN.md` at the repo root (goal, approach, key decisions,
   assumptions, risks, out of scope), `PLAN-REVIEW-LOG.md`, and a journal at
   `docs/journal/<slug>.md`.
4. **Attack.** `scripts/grok-review.sh` sends the plan, and only the plan, to
   headless Grok. Each round returns `VERDICT: APPROVED` or `REVISE` with
   critiques; the Architect takes the good ones and rejects the rest *with a
   logged reason*, then resumes the same Grok session. Bounded by
   `MAX_ROUNDS` (5); a flagged deadlock beats a fake approval. A first round can
   take 20 minutes; the Architect runs it in the background.
5. **You sign off.** The Architect shows the final plan and what the attack
   changed. Nothing is built before your sign-off.

## Phase 3 — `/to-goals`: the DAG and its oracles

```
/to-goals
```

The Architect cuts the plan into **goals** in `GOALS.md`: a YAML fence the
scripts read, then one section per goal for humans and the implementer.

```yaml
plan: PLAN.md
log: PLAN-REVIEW-LOG.md
journal: docs/journal/rate-limit.md
goals:
  - id: g1-bucket
    title: Token bucket per user
    blocked_by: []
    conflicts_with: []
    area: api/limits
    proof: pnpm test tests/acceptance/g1-bucket.test.ts
    oracle: tests/acceptance/g1-bucket.test.ts
    status: ready
  - id: g2-middleware
    title: Reject over-limit requests with 429
    blocked_by: [g1-bucket]
    conflicts_with: []
    area: api/http
    proof: pnpm test tests/acceptance/g2-middleware.test.ts
    oracle: tests/acceptance/g2-middleware.test.ts
    status: blocked
```

- `blocked_by` is a true gate; `conflicts_with` keeps two goals out of the same
  parallel wave; `proof` is the exact command that counts as done.
- Each goal gets an **oracle**: a red acceptance test under
  `tests/acceptance/` written by the Architect (or, with no test harness, an
  inline case table). The implementer may not edit it.
- Before anything is committed the Architect quizzes you on granularity and
  edges, proves the oracles can fail for the right reason (it runs each proof
  against stub code), and sends them to Grok for an **oracle review**
  (`grok-review.sh --oracle`, up to 3 rounds). Then one commit: `GOALS.md`, the
  oracles, the journal's `ARCHITECT decompose` record.

The full format is `skills/to-goals/GOAL-FORMAT.md`.

## Phase 4 — `/run-goal`: one goal

```
/run-goal g1-bucket
```

The skill runs `~/claude-coding-workflow/scripts/run-goal.sh g1-bucket` in the
background. The script is the whole hop:

1. **Implement.** A handoff (the goal, the frozen plan, the oracle) goes to the
   implementer: DeepSeek Flash in headless Claude Code, sandboxed (writes only
   inside the repo, no network unless allowed, `.git` and `.claude`
   protected). It works test-first and commits.
2. **Assess.** The script checks the commit: no edit to the oracle, the plan
   or `GOALS.md`, no tampering with `.git` or `.claude`, a non-empty diff.
3. **Prove.** It runs the goal's `proof` itself, under the proof sandbox. A red
   proof sends the failure back as a fix round.
4. **Review.** Claude Opus 5.5, in its own headless session with read-only
   tools, reads the diff against the goal and answers `DONE` or `FIX` with
   `FIX: <path>:<line> — <what>` findings. Findings go back to the
   implementer as the next round (up to `MAX_FIX_ROUNDS`, 3).
5. **Mutations** (after `DONE`). The reviewer writes up to three small bugs
   (`CW_MUTATIONS`); each is applied to a clone and the proof must catch it. A
   survivor is recorded as an oracle gap (or stops the walk with
   `CW_MUTATION_GAPS=stop`).
6. **Land.** The goal is marked `done` in `GOALS.md`, journaled and committed.

A goal takes up to about 40 minutes. When it lands the script exits 0.
Anything else is a **wake**: a nonzero exit whose last line is
`STOP_FILE: <path>`. The Architect reads that file and tells you what stopped
and what to do (see [Reading a stop](#reading-a-stop)).

## Phase 5 — `/run-goals`: the whole DAG

```
/run-goals            # one goal at a time, in the main checkout
/run-goals --jobs 3   # parallel waves of up to 3 goals, each in its own worktree
```

`run-goals.sh` walks the frontier (`scripts/goals.py GOALS.md frontier`),
running `run-goal.sh` for each ready goal until the DAG is done, a goal
bounces, or something stops it.

With `--jobs N` (2-4) each wave is up to N frontier goals that do not name
each other in `conflicts_with`, each on its own branch `cw/<goal>` in its own
worktree. At the join the walker **integrates** each finished goal one at a
time in a scratch worktree (merge, `worktree_setup`, the merged proofs of every
goal done so far) and moves the walk branch only when all of it is green. A
stopped goal is recut and runs fresh next time.

### Watching a walk

- **The task list** (ctrl+t): the `walk` mod keeps one task per goal of the
  walk this session launched, ticked as it runs; a stopped goal is titled
  `PAUSED:` or `BOUNCED: <reason>`.
- **`/walk-status [dir]`**: a pane with every goal of `GOALS.md` as a live git
  graph (state, round, phase, model, time, cost).
- From a shell: `scripts/events.py walks`, `scripts/events.py graph`,
  `scripts/logs.sh last | errors | warnings | goal <id> | since walk`.

## Reading a stop

A stop file (under `~/.cache/claude-coding-workflow/runs/`, kept until pruned
after 14 days) starts with:

```
# Stop: g2-middleware
- reason: max-fix-rounds
- detail: ...
- LOG: <the implementer's or reviewer's raw output>
- stderr: <its stderr>
```

and ends with the commands that unstick it. The Architect reads it for you.
Common reasons:

| Reason | Meaning | Usually |
|--------|---------|---------|
| `rate_limited`, `reviewer-rate-limited` | A provider limit | Wait, rerun |
| `implementer-error`, `reviewer-error`, `*-timeout` | An operational failure | Rerun |
| `max-fix-rounds`, `proof-red` | The goal did not converge | Rework the goal or the oracle, rerun |
| `bounced`, `implementer-blocked`, `oracle-gap` | A contract question | You decide: change the plan or the goal |
| `*-tamper`, `secrets-in-checkout`, `gate` | A safety check refused | Look before anything else |
| `wave-stop` | A parallel wave stopped; each goal is listed with its own stop | Read each |

The journal (`docs/journal/<slug>.md`) is the append-only record of every
dispatch, arbitration and verdict; commit your own notes before dispatching
(an uncommitted note stops a goal as `journal-tamper`). More in
[Troubleshooting](troubleshooting.md).

## The rules worth knowing

- **Nobody grades their own work.** Grok attacks the plan and the oracles;
  Opus reviews code it did not write; the Architect never reviews its own plan.
- **No feature code without a signed plan.** After Phase 2, `PLAN.md` is the
  contract; after Phase 3, `GOALS.md` plus the oracles are all an implementer
  may run against.
- **No model swaps on failure.** The implementer switches model only when the
  primary refuses, declines or (DeepSeek) is out of balance, once, journaled.
  The reviewer switches only when Opus 5.5's safeguards flag a review, to Opus
  4.8 for that one call. Never on a rate limit or an error.
- **Secrets stay out.** Never paste a key into a chat; keys live in `.env`
  files the launchers read.

## The skills at a glance

| Skill | When |
|-------|------|
| `/crucible` | Plan a feature: recon, interview, `PLAN.md`, Grok attack |
| `/to-goals` | Cut a signed plan into `GOALS.md` and acceptance tests; Grok oracle review |
| `/run-goal [id]` | One goal: implement, prove, review |
| `/run-goals [--jobs N]` | Walk the DAG |
| `/walk-status [dir]` | The walk as a live graph (the `walk` mod) |
| `/lessons` | Review the reminders the `lessons` mod drafted from repeated failures and your corrections |
| Borrowed: `/wayfinder`, `/research`, `/prototype`, `/tdd`, `/diagnosing-bugs`, `/improve-codebase-architecture` | Called during the phases, or on their own |

Going unattended: [Always-on](always-on.md).
