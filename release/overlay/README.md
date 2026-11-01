# claude-coding-workflow

A coding workflow for [Claude Code](https://docs.claude.com/en/docs/claude-code)
in which **nobody grades their own work**. You and Claude Code plan a feature
together; a different model attacks the plan and the acceptance tests; cheap
models implement it goal by goal in a sandbox; and a separate Claude session
reviews every goal's diff before it lands.

| Role | Model | What it does |
|------|-------|--------------|
| **Architect** | Claude Code (your session) | Interviews you, writes and locks `PLAN.md`, cuts it into a goal DAG (`GOALS.md`) with acceptance tests, dispatches, reads every stop |
| **Attacker** | Grok (`grok-4.7`), headless, read-only | Attacks the locked plan, then the acceptance tests ("oracles"), round by round |
| **Implementer** | DeepSeek Flash through DeepSeek's Anthropic-compatible endpoint, in headless sandboxed Claude Code; Claude Haiku 5.5 when DeepSeek refuses, declines or runs out of balance | Implements one goal at a time, test-first |
| **Goal reviewer** | Claude Opus 5.5, headless, separate session | Judges each goal's diff against the goal; `DONE` or `FIX` |

The implement/review loop runs in host scripts, not in your session: a goal
lands only when its proof (the acceptance test) is green and the reviewer says
`DONE`. Anything else stops with a stop file that says why.

Optionally the workflow runs **unattended** ("always-on"): you sign a walk into a
queue and a macOS LaunchAgent walks it, waits through usage limits, retries
operational stops within fixed limits and messages you on iMessage for
everything else. See [docs/guides/always-on.md](docs/guides/always-on.md).

## The flow

```
/crucible    recon + interview → PLAN.md → Grok attacks it → you sign off
/to-goals    PLAN.md → GOALS.md (a DAG of goals) + red acceptance tests → Grok attacks the tests
/run-goal    one ready goal: implementer → proof → Opus review → (FIX rounds) → done
/run-goals   walk the whole DAG, one goal at a time or in parallel waves (--jobs 2-4)
```

Each step is a Claude Code skill this repo installs. The full walkthrough is
[docs/guides/using-with-claude-code.md](docs/guides/using-with-claude-code.md).

## Requirements

- **macOS** (the implementer and proof sandboxes use macOS's sandbox; the
  always-on mode uses launchd and Messages).
- **Claude Code** 2.1 or later, signed in (`claude login`) or with an
  `ANTHROPIC_API_KEY`.
- **Grok CLI** (xAI's command-line client), signed in (`grok login`): the
  attacker.
- **A DeepSeek API key** (`DEEPSEEK_API_KEY`) for the default implementer. With
  `IMPLEMENTER_PRIMARY=haiku`, Haiku implements first and DeepSeek is only the
  fallback.
- `git`, `bash`, `python3` (3.9 or later; the system one is fine), `curl`.
- A clone of [mattpocock/skills](https://github.com/mattpocock/skills) at
  `~/mattpocock-skills` for the borrowed helper skills (`install.sh` tells you
  the pinned commit).
- Optional: the Codex CLI, only for the legacy `IMPLEMENTER=codex` launcher.

## Install

```bash
git clone -b release <this repo's URL> ~/claude-coding-workflow
git clone https://github.com/mattpocock/skills ~/mattpocock-skills
cp ~/claude-coding-workflow/.env.example ~/claude-coding-workflow/.env   # then set DEEPSEEK_API_KEY
~/claude-coding-workflow/scripts/install.sh
```

`install.sh` links the four skills (`/crucible`, `/to-goals`, `/run-goal`,
`/run-goals`) and the borrowed ones into `~/.claude/skills`, installs the two
Claude Code mods (`walk`, `lessons`), runs the test suite and checks your
setup. Details and the expected output:
[docs/guides/getting-started.md](docs/guides/getting-started.md).

Clone it to exactly `~/claude-coding-workflow`: the skills call the scripts by
that path.

## Use it

In the repository you want to build in (the "target repo"), open Claude Code
and copy this repo's `CLAUDE.md` into it (or merge it into the target's own),
then:

```
/crucible add rate limiting to the public API
```

and follow the interview. After you sign off the plan, `/to-goals`, then
`/run-goals`. While a walk runs, the `walk` mod keeps one task per goal in
Claude Code's task list (ctrl+t) and `/walk-status` shows the DAG as a live
graph.

## Guides

| Guide | For |
|-------|-----|
| [Getting started](docs/guides/getting-started.md) | Installing, keys, `install.sh --check`, smoke tests |
| [Using it with Claude Code](docs/guides/using-with-claude-code.md) | The phases, each skill, a walk end to end, reading a stop |
| [Configuration](docs/guides/configuration.md) | Every environment variable, where files live |
| [Always-on](docs/guides/always-on.md) | Unattended walks on a Mac: setup, signing, day to day |
| [Troubleshooting](docs/guides/troubleshooting.md) | Stops, wakes, logs, common failures |

## What's in this branch

This is the **release** branch: the code needed to run the workflow and its
instructions. The design history (every plan, the adversarial review logs, the
build journals, evidence and research) lives on the `main` branch.

```
CLAUDE.md          the Architect's instructions: copy into a target repo
skills/            crucible, to-goals, run-goal, run-goals
scripts/           the host scripts (run-goal.sh, run-goals.sh, launchers, goals.py, ...) and tests/
mods/              Claude Code mods: walk (task list, /walk-status, always-on push), lessons
GOALS.example.md   a tiny goal DAG the install check and tests use
docs/guides/       the guides above
```

## Credits

Built on ideas from [chaseai-yt/crucible](https://github.com/chaseai-yt/crucible)
(MIT) and borrows helper skills from
[mattpocock/skills](https://github.com/mattpocock/skills).

## License

MIT — see [LICENSE](LICENSE).
