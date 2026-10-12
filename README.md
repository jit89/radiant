# claude-coding-workflow

Claude-driven coding workflow. Claude Code is the Architect. Grok
hardens the plan as a headless adversary. Claude Haiku 5.5 implements in
headless, sandboxed Claude Code, with DeepSeek V4 Flash through the same
harness when Haiku refuses a goal. Claude Opus 5.5 reviews each goal's diff.

Forked from `~/grok-coding-workflow` (where Grok was the Architect and
Opus was the attacker) and, before that, from the house Claude/Kimi/Grok
workflow in `~/agentic-coding-workflow` and from
[chaseai-yt/crucible](https://github.com/chaseai-yt/crucible) (MIT).
Crucible's "Codex builds, Claude verifies" flip is absent, and the *code*
review uses a reviewer prompt, not the plan-attacker prompt.

## Roles

| Role | Who | Status |
|------|-----|--------|
| Architect | Claude Code (main session) | shipped |
| Attacker | Grok `grok-4.7`, headless, read-only, plans and oracles (never implementer diffs) | shipped |
| Implementer | Claude Haiku 5.5 (`xhigh`), headless and sandboxed; DeepSeek V4 Flash on a refusal, same harness | shipped |
| Goal reviewer | Claude Opus 5.5, headless, reviewer prompt | shipped |

Nobody grades their own work. The Architect writes the plan, so a
different model attacks it. Opus reviews code, but the code it judges was
written by the implementer in its own headless session, and the review
runs in another that never sees the Architect's conversation.

## What's here

- `CLAUDE.md` — drop into a target repo (or merge). The contract.
- `skills/crucible/` — recon → interrogate → lock `PLAN.md` → Grok attack.
- `skills/to-goals/` — cut a signed-off plan into `GOALS.md` + oracles.
- `skills/run-goal/` — one ready goal: implementer then Opus review.
- `skills/run-goals/` — walk the DAG, one `run-goal` at a time.
- `scripts/goals.py` — read/update the `GOALS.md` YAML fence.
- `scripts/logs.sh` / `scripts/events.py` — machine event index (JSONL in cache).
- `scripts/grok-review.sh` — plan attacker (resume with `--resume`), and with
  `--oracle` the Phase 3 oracle review: a fresh session over this DAG's
  oracles (`scripts/lib/oracle-files.py` lists them). A turn that does not end
  normally is reported as an error, never as a review.
- `scripts/claude-goal-review.sh` — code reviewer. Different prompt.
- `scripts/claude-implement.sh` — implementer: Haiku 5.5, DeepSeek fallback, sandboxed.
- `scripts/deepseek-code.sh` — legacy implementer in Codex (`IMPLEMENTER=codex`).
- `scripts/lib/findings.sh` — parses the reviewer verdict into findings.
- `scripts/tests/findings-test.sh` — self-test for that parser.
- `scripts/install.sh` — symlink skills into `~/.claude/skills`, install the `walk` and `lessons` mods.
- `mods/walk/` — Claude Code mod: the running goal as a prompt-footer label
  (`walk g4-ack r1 · review · 3/7`), and `/walk [dir]`, a pane with every goal
  of GOALS.md as a live git graph (state, round, phase, model, time, cost; a
  sidebar beside the transcript in the fullscreen layout). It polls
  `scripts/events.py status` and `graph`, found beside the mod, else in
  `$CLAUDE_CODING_WORKFLOW`, else `~/claude-coding-workflow`. Installed
  user-wide from this repo's marketplace (`.claude-plugin/marketplace.json`);
  `plugin install` copies it into the plugin cache, so after editing the mod
  bump its version and re-run `install.sh`, then restart open sessions.
- `mods/lessons/` + `scripts/lessons.py` — failures that repeat, and the
  person's corrections, become reminders in the system prompt, but only the
  ones approved with `/lessons` (docs/features/lessons-hook/PLAN.md). At
  compaction, session end and every 5th failed tool call, `lessons.py` reads
  the new transcript rows into an evidence queue (redacted), and Haiku 5.5
  (`claude -p --safe-mode --restricted --effort high`, no tools, 0.05 USD a call, 0.25 USD a
  day) words them as pending lessons. A second Haiku call checks each one;
  a lesson is **Recommended** when the check says correct and every piece of
  its evidence is your own typed correction or was seen in 2+ sessions.
  `/lessons` opens a checklist dialog: recommended lessons start ticked, the
  evidence (tool output marked untrusted) and a not-recommended lesson's
  check reason sit under each, one scope applies to all (project by
  default), and **Approve selected** / **Reject unselected** / **Keep for
  later** act only on your key press. A lesson drawn only from your own
  typed corrections, in a call that saw no tool output, and checked correct
  is approved without the dialog (project scope, 3 a day, a toast naming
  `/lessons forget ID`; `/lessons auto off` stops it). Typed verbs remain
  for `claude -p` and edits: `approve ID [global]`, `edit`, `reject`,
  `forget`, `list`, `recheck`, `auto on|off`, `off`/`on`. Approved lessons (10 lines at most, project
  first, expired after 30 days unseen) are one system-prompt section that
  changes only when the approved set does. Never writes CLAUDE.md, memory or
  any repo; lessons live in `~/.claude/lessons/` (0700).

## Install

```bash
~/claude-coding-workflow/scripts/install.sh
```

Puts `/crucible`, `/to-goals`, `/run-goal`, and `/run-goals` on the skill
list, and links the borrowed skills from a clone of
[mattpocock/skills](https://github.com/mattpocock/skills) at
`~/mattpocock-skills`, pinned to a reviewed commit. `install.sh --check`
prints claude/grok/codex versions, runs the findings self-test,
`goals.py` against `GOALS.example.md`, a mock walk, the rate-limit
envelope checks, and warns if a borrowed skill is missing or the clone
has drifted from its pin.

Copy `.env.example` to `.env` in this repo **or** the target repo and set
`DEEPSEEK_API_KEY` (the implementer's fallback; without it a refused goal
stops instead). Never commit `.env`. Never paste the key into chat.

## Prerequisites

- Claude Code ≥ 2.1, authenticated (`claude login`, or a real
  `ANTHROPIC_API_KEY`). The launchers unset `ANTHROPIC_BASE_URL` so a
  leftover Kimi redirect cannot steal the call.
- Grok CLI, signed in (`grok login`). `grok-review.sh` finds it on `PATH`
  or at `~/.grok/bin/grok`; override with `GROK_BIN`.
- `DEEPSEEK_API_KEY` from [platform.deepseek.com](https://platform.deepseek.com/api_keys),
  for the fallback. It runs through DeepSeek's Anthropic-compatible endpoint
  (`https://api.deepseek.com/anthropic`), model `deepseek-v4-flash`.
- Only for `IMPLEMENTER=codex`: Codex CLI ≥ 0.144.

The implementer runs with Claude Code's sandbox on (writes only inside the
repo; `.git/hooks`, `.git/config` and `.claude/` settings protected; network
off unless `IMPLEMENTER_ALLOWED_DOMAINS` names hosts), every credential-like
variable stripped from its environment, and keys handed to the harness
through `apiKeyHelper` from a 0600 file it cannot read.

## Smoke tests

```bash
# Plan attacker (no API call)
GROK_REVIEW_DRY_RUN=1 ~/claude-coding-workflow/scripts/grok-review.sh --smoke

# Goal reviewer (no API call)
CLAUDE_REVIEW_DRY_RUN=1 ~/claude-coding-workflow/scripts/claude-goal-review.sh --smoke

# Implementer (no API call)
IMPLEMENTER_DRY_RUN=1 ~/claude-coding-workflow/scripts/claude-implement.sh --smoke

# Live pings
~/claude-coding-workflow/scripts/grok-review.sh --smoke
~/claude-coding-workflow/scripts/claude-goal-review.sh --smoke
~/claude-coding-workflow/scripts/claude-implement.sh --smoke
IMPLEMENTER_SMOKE_PROVIDER=deepseek ~/claude-coding-workflow/scripts/claude-implement.sh --smoke
```

Expect `IMPLEMENTER_RESULT: ok` from both. The DeepSeek smoke needs
`DEEPSEEK_API_KEY`.

## Flow

In the **target** repo:

```
/crucible          # plan + Grok attack → sign off PLAN.md
/to-goals          # GOALS.md + red oracles
/run-goal          # one ready goal
/run-goals         # walk the DAG (sequential)
```

`/run-goal` and `/run-goals` exec the host scripts. The Architect is not
in the implement/review hop:

```bash
~/claude-coding-workflow/scripts/run-goal.sh <id>
~/claude-coding-workflow/scripts/run-goals.sh
```

Timeouts live in the script (implementer 20 min, reviewer 10 min).
The Architect runs both scripts in the background: a goal outlasts the
10-minute ceiling on a foreground tool call.
A nonzero exit is a wake — read `STOP_FILE:`.

## Quota / half-finished work

Canonical: `scripts/run-goal.sh` (prints `STOP_FILE:`). Short version:
exit 75 / `rate_limited` → stop, no hammer, no model swap.

## Tunables

| Env | Default | Meaning |
|-----|---------|---------|
| `GROK_REVIEW_MODEL` | `grok-4.7` | Plan attacker |
| `GROK_REVIEW_EFFORT` | `high` | Grok `--reasoning-effort` |
| `GROK_REVIEW_DRY_RUN=1` | off | Print Grok command only |
| `GROK_BIN` | auto | Grok binary path |
| `CLAUDE_REVIEW_MODEL` | `claude-opus-5-5` | Goal reviewer |
| `CLAUDE_REVIEW_FALLBACK_MODEL` | `claude-opus-4-8` | One retry when the reviewer's safeguards flag a review (`none` = off) |
| `CLAUDE_REVIEW_EFFORT` | `high` | Claude `--effort` |
| `CLAUDE_REVIEW_DRY_RUN=1` | off | Print Claude command only |
| `IMPLEMENTER` | `claude` | `codex` selects the legacy `deepseek-code.sh` |
| `IMPLEMENTER_MODEL` | `claude-haiku-5-5` | Implementer |
| `IMPLEMENTER_EFFORT` | `xhigh` | Implementer `--effort` |
| `IMPLEMENTER_FALLBACK` | `deepseek` | One rerun on DeepSeek when Haiku refuses or declines (`none` = off) |
| `IMPLEMENTER_ALLOWED_DOMAINS` | empty | Comma list of hosts the sandbox may reach |
| `IMPLEMENTER_MAX_BUDGET_USD` | unset | `--max-budget-usd` per pass |
| `IMPLEMENTER_DRY_RUN=1` | off | Print the Claude command only |
| `DEEPSEEK_MODEL` | `deepseek-v4-flash` | Fallback model (and the Codex launcher's) |
| `DEEPSEEK_ANTHROPIC_BASE_URL` | `https://api.deepseek.com/anthropic` | Fallback endpoint |
| `DEEPSEEK_BASE_URL` | `https://api.deepseek.com/` | Codex launcher only: OpenAI-compatible endpoint |
| `DEEPSEEK_DRY_RUN=1` | off | Codex launcher only: print the command |
| `DEEPSEEK_CODEX_HOME` | `~/.cache/claude-coding-workflow/codex` | Codex launcher only: isolated state |
| `DEEPSEEK_LOCK_WAIT` | `1800` | Codex launcher only: seconds to wait for its home lock |
| `DEEPSEEK_REQUIRE_GIT` | `1` | Codex launcher only: require a git repo |
| `MAX_ROUNDS` | `5` | Plan-attack rounds (skill) |
| `MAX_FIX_ROUNDS` | `3` | Repair passes after the first implementation: `N` lets up to `N` FIX handoffs be implemented and reviewed (`0` wakes on the first FIX) |
| `IMPLEMENTER_TIMEOUT` | `1200` | Seconds per implementer pass (`DEEPSEEK_TIMEOUT` still honoured) |
| `CLAUDE_REVIEW_TIMEOUT` | `600` | Seconds per review |
| `PROOF_TIMEOUT` | `600` | Seconds for the host proof |
| `PROOF_ENV_KEEP` | empty | Space-separated credential-like variables the proof may still see (others named `*KEY*`, `*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*CREDENTIAL*` are removed) |
| `KEEP_RUN_DIR=1` | off | Keep the run dir after a goal lands |
| `CW_OUT_DIR` | unset | Launchers write raw output, `.err` and verdict/report here and delete none; `run-goal.sh` sets it to its run dir |
| `CW_KEEP_RAW=1` | off | A standalone launcher keeps its raw output and `.err` after an `ok` result |
| `CW_PRUNE_DAYS` | `14` | Age past which `~/.cache/claude-coding-workflow/runs/`, `grok/` and `lessons/logs/` entries are deleted at the next run (`0` = never) |

Where files live: a goal's run dir (stop file, diff, proof output, the
launchers' output) is `~/.cache/claude-coding-workflow/runs/run-goal-<id>-*`,
removed when the goal lands and kept on a wake; Grok verdicts are in
`~/.cache/claude-coding-workflow/grok/`. Both folders are 0700 and pruned
past `CW_PRUNE_DAYS`. Run the tests with `scripts/tests/run-all.sh [-j N]`:
four at a time by default (`CW_TEST_JOBS`), each in its own `TMPDIR` and
`HOME`, failing any test that leaves something in either; `install.sh --check`
runs them the same way (~3 minutes at `-j4`, against ~7.5 one at a time).

The legacy `deepseek-code.sh` keeps Codex in `workspace-write` (not
`danger-full-access`). Codex remounts `<repo>/.git` read-only inside that
sandbox; the launcher adds the gitdir to
`sandbox_workspace_write.writable_roots` so the implementer can
`git commit`. First exec and `--resume` both use `--approve-for-me` so a
leftover carve-out can still escalate. Do not pass `approval_policy=never`
on resume — that is what blocked the g2-fix dogfood commit.

## Walk the DAG

```
/run-goals
```

`scripts/goals.py` validates, refreshes `blocked`→`ready` when parents
land, and prints the frontier. The Architect then runs `/run-goal` on the
first frontier id, loops until the frontier is empty, a goal bounces, or
quota stops the walk.

Independent goals still run **one at a time** (shared tree). Parallel
worktrees are not in this slice. (The legacy `deepseek-code.sh` takes an
exclusive lock on the Codex home, so a second concurrent run queues
instead of corrupting the first one's config.)

```bash
~/claude-coding-workflow/scripts/goals.py GOALS.md validate
~/claude-coding-workflow/scripts/goals.py GOALS.md graph
~/claude-coding-workflow/scripts/goals.py GOALS.md frontier
```

## Changes from grok-coding-workflow

Role swap aside, these are the behaviour fixes carried in at the fork:

1. **The goal reviewer could not read its own evidence.** The brief,
   `DIFF_FILE` and `PROOF_OUTPUT` live in a private run dir under
   `$TMPDIR`; headless Claude denies reads outside the repo and there is
   nobody to approve the prompt, so every review ran on no evidence.
   `run-goal.sh` now passes `--add-dir "$RUN_DIR"`.
2. **Clean reviews were bounced as oracle tampering.** Findings were
   scraped from any `N.` line, which swept up the reviewer's own six
   numbered analysis headings — and the `ORACLE` heading names the oracle,
   which tripped the tamper check. Findings are now `FIX: <path>:<line> —
   …` lines only, the tamper check looks at the target path of each
   finding rather than any mention of it, and
   `scripts/tests/findings-test.sh` pins the regression.
3. **Concurrent runs corrupted the Codex config.** `deepseek-code.sh`
   rewrites `config.toml` in a shared `CODEX_HOME` on every invocation.
   It now holds an exclusive lock for the run and reaps a lock whose
   owner died.
4. **The proof ran in a login shell.** `bash -lc` made the acceptance
   gate depend on the user's interactive profile. Now `bash -c`.
5. **`MAX_FIX_ROUNDS` counts repairs.** `N` allows exactly `N` FIX
   handoffs to be implemented; the first implementation is not one
   (a `>=` check once allowed only `N - 1`).
6. **Run dirs leaked.** They are removed when a goal lands and kept on a
   wake (they are the evidence the stop file points at). `KEEP_RUN_DIR=1`
   keeps them either way.
7. **One result parser for both harnesses.** `lib/agent-result.py`
   handles the Claude envelope (`session_id`/`result`) and the Grok one
   (`sessionId`/`text`); `is_transport_rate_limit` understands both.
