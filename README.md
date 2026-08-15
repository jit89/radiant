# grok-coding-workflow

Grok-driven coding workflow. Grok is the Architect. Claude Opus 5
hardens the plan, then reviews each goal's code. DeepSeek V4 Flash
implements inside the Codex CLI harness.

Adapted from the house Claude/Kimi/Grok workflow in
`~/agentic-coding-workflow` and from
[chaseai-yt/crucible](https://github.com/chaseai-yt/crucible) (MIT).
Crucible's "Codex builds, Claude verifies" flip is absent: Codex is
only the DeepSeek harness, and Claude's *code* review uses a reviewer
prompt, not the plan-attacker prompt.

## Roles

| Role | Who | Status |
|------|-----|--------|
| Architect | Grok (main session) | shipped |
| Attacker | Claude Opus 5, read-only, plan only | shipped |
| Implementer | DeepSeek V4 Flash via Codex CLI | shipped |
| Goal reviewer | Claude Opus 5, reviewer prompt | shipped |

## What's here

- `AGENTS.md` — drop into a target repo (or merge). The contract.
- `skills/crucible/` — recon → interrogate → lock `PLAN.md` → Opus 5 attack.
- `skills/to-goals/` — cut a signed-off plan into `GOALS.md` + oracles.
- `skills/run-goal/` — one ready goal: DeepSeek then Claude review.
- `skills/run-goals/` — walk the DAG, one `run-goal` at a time.
- `scripts/goals.py` — read/update the `GOALS.md` YAML fence.
- `scripts/logs.sh` / `scripts/events.py` — machine event index (JSONL in cache).
- `scripts/claude-review.sh` — plan attacker. Resume with `--resume`.
- `scripts/claude-goal-review.sh` — code reviewer. Different prompt.
- `scripts/deepseek-code.sh` — implementer. Isolated `CODEX_HOME`.
- `scripts/install.sh` — symlink skills into `~/.grok/skills`.

## Install

```bash
~/grok-coding-workflow/scripts/install.sh
```

Puts `/crucible`, `/to-goals`, `/run-goal`, and `/run-goals` on the
skill list. `install.sh --check` prints claude/codex versions, runs
`goals.py` against `GOALS.example.md`, and warns if borrowed skills
are missing.

Copy `.env.example` to `.env` in this repo **or** the target repo and
set `DEEPSEEK_API_KEY`. Never commit `.env`. Never paste the key into
chat.

## Prerequisites

- Grok CLI (this session).
- Claude Code ≥ 2.1, authenticated (`claude login`, or a real
  `ANTHROPIC_API_KEY`). `claude-review.sh` / `claude-goal-review.sh`
  unset `ANTHROPIC_BASE_URL` so a leftover Kimi redirect cannot steal
  the call.
- Codex CLI ≥ 0.144 (`codex` on PATH, or under `~/.nvm/versions/node`).
  `deepseek-code.sh` finds it even if this shell has not been refreshed.
- `DEEPSEEK_API_KEY` from [platform.deepseek.com](https://platform.deepseek.com/api_keys).
  Base URL `https://api.deepseek.com/`, model `deepseek-v4-flash`.

The implementer uses an isolated `CODEX_HOME`
(`~/.cache/grok-coding-workflow/codex`) and does **not** rewrite
`~/.codex/config.toml`. Interactive Codex/ChatGPT is untouched.

## Smoke tests

```bash
# Plan attacker (no API call)
CLAUDE_REVIEW_DRY_RUN=1 ~/grok-coding-workflow/scripts/claude-review.sh --smoke

# Goal reviewer (no API call)
CLAUDE_REVIEW_DRY_RUN=1 ~/grok-coding-workflow/scripts/claude-goal-review.sh --smoke

# Implementer (no API call)
DEEPSEEK_DRY_RUN=1 ~/grok-coding-workflow/scripts/deepseek-code.sh --smoke

# Live pings
~/grok-coding-workflow/scripts/claude-review.sh --smoke
~/grok-coding-workflow/scripts/claude-goal-review.sh --smoke
~/grok-coding-workflow/scripts/deepseek-code.sh --smoke
```

Live DeepSeek smoke needs `DEEPSEEK_API_KEY`. Expect
`DEEPSEEK_RESULT: ok` and a `PONG deepseek-v4-flash` report.

## Flow

In the **target** repo:

```
/crucible          # plan + Opus 5 attack → sign off PLAN.md
/to-goals          # GOALS.md + red oracles
/run-goal          # one ready goal
/run-goals         # walk the DAG (sequential)
```

`/run-goal` and `/run-goals` exec the host scripts. Grok is not in
the implement/review hop:

```bash
~/grok-coding-workflow/scripts/run-goal.sh <id>
~/grok-coding-workflow/scripts/run-goals.sh
```

Timeouts live in the script (implementer 20 min, reviewer 10 min).
A nonzero exit is a wake — read `STOP_FILE:`.

`/run-goals` seeds the TUI todo badge from `goals.py todos` and
refreshes it on exit. The badge stays stale mid-walk.

## Quota / half-finished work

Canonical: `scripts/run-goal.sh` (prints `STOP_FILE:`). Short version:
exit 75 / `rate_limited` → stop, no hammer, no model swap.

## Tunables

| Env | Default | Meaning |
|-----|---------|---------|
| `CLAUDE_REVIEW_MODEL` | `claude-opus-5` | Attacker and goal reviewer |
| `CLAUDE_REVIEW_EFFORT` | `high` | Claude `--effort` |
| `CLAUDE_REVIEW_DRY_RUN=1` | off | Print Claude command only |
| `DEEPSEEK_MODEL` | `deepseek-v4-flash` | Implementer model |
| `DEEPSEEK_BASE_URL` | `https://api.deepseek.com/` | OpenAI-compatible endpoint |
| `DEEPSEEK_DRY_RUN=1` | off | Print Codex command only |
| `DEEPSEEK_CODEX_HOME` | `~/.cache/grok-coding-workflow/codex` | Isolated Codex state |
| `DEEPSEEK_REQUIRE_GIT` | `1` | Require a git repo (`0` to opt out) |
| `MAX_ROUNDS` | `5` | Plan-attack rounds (skill) |
| `MAX_FIX_ROUNDS` | `3` | Implement/review loops (skill) |

`deepseek-code.sh` keeps Codex in `workspace-write` (not
`danger-full-access`). Codex remounts `<repo>/.git` read-only inside
that sandbox; the launcher adds the gitdir to
`sandbox_workspace_write.writable_roots` so the implementer can
`git commit`. First exec and `--resume` both use `--approve-for-me`
so a leftover carve-out can still escalate. Do not pass
`approval_policy=never` on resume — that is what blocked the g2-fix
dogfood commit.

## Walk the DAG

```
/run-goals
```

`scripts/goals.py` validates, refreshes `blocked`→`ready` when
parents land, and prints the frontier. The Architect then runs
`/run-goal` on the first frontier id, loops until the frontier is
empty, a goal bounces, or quota stops the walk.

Independent goals still run **one at a time** (shared tree). Parallel
worktrees are not in this slice.

```bash
~/grok-coding-workflow/scripts/goals.py GOALS.md validate
~/grok-coding-workflow/scripts/goals.py GOALS.md graph
~/grok-coding-workflow/scripts/goals.py GOALS.md frontier
```
