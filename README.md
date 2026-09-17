# claude-coding-workflow

Claude-driven coding workflow. Claude Code is the Architect. Grok
hardens the plan as a headless adversary. DeepSeek V4 Flash implements
inside the Codex CLI harness. Claude Opus 5 reviews each goal's diff.

Forked from `~/grok-coding-workflow` (where Grok was the Architect and
Opus was the attacker) and, before that, from the house Claude/Kimi/Grok
workflow in `~/agentic-coding-workflow` and from
[chaseai-yt/crucible](https://github.com/chaseai-yt/crucible) (MIT).
Crucible's "Codex builds, Claude verifies" flip is absent: Codex is only
the DeepSeek harness, and the *code* review uses a reviewer prompt, not
the plan-attacker prompt.

## Roles

| Role | Who | Status |
|------|-----|--------|
| Architect | Claude Code (main session) | shipped |
| Attacker | Grok `grok-4.6`, headless, read-only, plan only | shipped |
| Implementer | DeepSeek V4 Flash via Codex CLI | shipped |
| Goal reviewer | Claude Opus 5, headless, reviewer prompt | shipped |

Nobody grades their own work. The Architect writes the plan, so a
different model attacks it. Opus reviews code, but the code it judges was
written by DeepSeek — and it runs in its own headless session that never
sees the Architect's conversation.

## What's here

- `CLAUDE.md` — drop into a target repo (or merge). The contract.
- `skills/crucible/` — recon → interrogate → lock `PLAN.md` → Grok attack.
- `skills/to-goals/` — cut a signed-off plan into `GOALS.md` + oracles.
- `skills/run-goal/` — one ready goal: DeepSeek then Opus review.
- `skills/run-goals/` — walk the DAG, one `run-goal` at a time.
- `scripts/goals.py` — read/update the `GOALS.md` YAML fence.
- `scripts/logs.sh` / `scripts/events.py` — machine event index (JSONL in cache).
- `scripts/grok-review.sh` — plan attacker. Resume with `--resume`.
- `scripts/claude-goal-review.sh` — code reviewer. Different prompt.
- `scripts/deepseek-code.sh` — implementer. Isolated `CODEX_HOME`.
- `scripts/lib/findings.sh` — parses the reviewer verdict into findings.
- `scripts/tests/findings-test.sh` — self-test for that parser.
- `scripts/install.sh` — symlink skills into `~/.claude/skills`.

## Install

```bash
~/claude-coding-workflow/scripts/install.sh
```

Puts `/crucible`, `/to-goals`, `/run-goal`, and `/run-goals` on the skill
list. `install.sh --check` prints claude/grok/codex versions, runs the
findings self-test, `goals.py` against `GOALS.example.md`, a mock walk,
the rate-limit envelope checks, and warns if borrowed skills are missing.

Copy `.env.example` to `.env` in this repo **or** the target repo and set
`DEEPSEEK_API_KEY`. Never commit `.env`. Never paste the key into chat.

## Prerequisites

- Claude Code ≥ 2.1, authenticated (`claude login`, or a real
  `ANTHROPIC_API_KEY`). The launchers unset `ANTHROPIC_BASE_URL` so a
  leftover Kimi redirect cannot steal the call.
- Grok CLI, signed in (`grok login`). `grok-review.sh` finds it on `PATH`
  or at `~/.grok/bin/grok`; override with `GROK_BIN`.
- Codex CLI ≥ 0.144 (`codex` on PATH, or under `~/.nvm/versions/node`).
- `DEEPSEEK_API_KEY` from [platform.deepseek.com](https://platform.deepseek.com/api_keys).
  Base URL `https://api.deepseek.com/`, model `deepseek-v4-flash`.

The implementer uses an isolated `CODEX_HOME`
(`~/.cache/claude-coding-workflow/codex`) and does **not** rewrite
`~/.codex/config.toml`. Interactive Codex/ChatGPT is untouched.

## Smoke tests

```bash
# Plan attacker (no API call)
GROK_REVIEW_DRY_RUN=1 ~/claude-coding-workflow/scripts/grok-review.sh --smoke

# Goal reviewer (no API call)
CLAUDE_REVIEW_DRY_RUN=1 ~/claude-coding-workflow/scripts/claude-goal-review.sh --smoke

# Implementer (no API call)
DEEPSEEK_DRY_RUN=1 ~/claude-coding-workflow/scripts/deepseek-code.sh --smoke

# Live pings
~/claude-coding-workflow/scripts/grok-review.sh --smoke
~/claude-coding-workflow/scripts/claude-goal-review.sh --smoke
~/claude-coding-workflow/scripts/deepseek-code.sh --smoke
```

Live DeepSeek smoke needs `DEEPSEEK_API_KEY`. Expect
`DEEPSEEK_RESULT: ok` and a `PONG deepseek-v4-flash` report.

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
A nonzero exit is a wake — read `STOP_FILE:`.

## Quota / half-finished work

Canonical: `scripts/run-goal.sh` (prints `STOP_FILE:`). Short version:
exit 75 / `rate_limited` → stop, no hammer, no model swap.

## Tunables

| Env | Default | Meaning |
|-----|---------|---------|
| `GROK_REVIEW_MODEL` | `grok-4.6` | Plan attacker |
| `GROK_REVIEW_EFFORT` | `high` | Grok `--reasoning-effort` |
| `GROK_REVIEW_DRY_RUN=1` | off | Print Grok command only |
| `GROK_BIN` | auto | Grok binary path |
| `CLAUDE_REVIEW_MODEL` | `claude-opus-5` | Goal reviewer |
| `CLAUDE_REVIEW_EFFORT` | `high` | Claude `--effort` |
| `CLAUDE_REVIEW_DRY_RUN=1` | off | Print Claude command only |
| `DEEPSEEK_MODEL` | `deepseek-v4-flash` | Implementer model |
| `DEEPSEEK_BASE_URL` | `https://api.deepseek.com/` | OpenAI-compatible endpoint |
| `DEEPSEEK_DRY_RUN=1` | off | Print Codex command only |
| `DEEPSEEK_CODEX_HOME` | `~/.cache/claude-coding-workflow/codex` | Isolated Codex state |
| `DEEPSEEK_LOCK_WAIT` | `1800` | Seconds to wait for the Codex home lock |
| `DEEPSEEK_REQUIRE_GIT` | `1` | Require a git repo (`0` to opt out) |
| `MAX_ROUNDS` | `5` | Plan-attack rounds (skill) |
| `MAX_FIX_ROUNDS` | `3` | Implement/review fix rounds |
| `DEEPSEEK_TIMEOUT` | `1200` | Seconds per implementer pass |
| `CLAUDE_REVIEW_TIMEOUT` | `600` | Seconds per review |
| `PROOF_TIMEOUT` | `600` | Seconds for the host proof |
| `PROOF_ENV_KEEP` | empty | Space-separated credential-like variables the proof may still see (others named `*KEY*`, `*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*CREDENTIAL*` are removed) |
| `KEEP_RUN_DIR=1` | off | Keep the run dir after a goal lands |

`deepseek-code.sh` keeps Codex in `workspace-write` (not
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
worktrees are not in this slice, and `deepseek-code.sh` now takes an
exclusive lock on the Codex home so a second concurrent run queues
instead of corrupting the first one's config.

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
5. **`MAX_FIX_ROUNDS` was off by one** — `>` allowed one extra
   implementer pass. Now `>=`.
6. **Run dirs leaked.** They are removed when a goal lands and kept on a
   wake (they are the evidence the stop file points at). `KEEP_RUN_DIR=1`
   keeps them either way.
7. **One result parser for both harnesses.** `lib/agent-result.py`
   handles the Claude envelope (`session_id`/`result`) and the Grok one
   (`sessionId`/`text`); `is_transport_rate_limit` understands both.
