# Getting started

This sets the workflow up once on a Mac. It takes about ten minutes, most of
it the test suite.

## 1. The tools

| Tool | Why | Check |
|------|-----|-------|
| Claude Code ≥ 2.1 | The Architect (your session), the implementer's harness, the reviewer | `claude --version`, then `claude login` (or set `ANTHROPIC_API_KEY`) |
| Grok CLI (xAI's command-line client; install it per xAI's instructions) | The attacker of plans and acceptance tests | `grok --version`, then `grok login` (found on `PATH` or at `~/.grok/bin/grok`; `GROK_BIN` overrides) |
| git, bash, python3 ≥ 3.9, curl | The host scripts | macOS ships all four (the Command Line Tools) |
| Codex CLI | Only for the legacy `IMPLEMENTER=codex` launcher | optional |

## 2. Clone

```bash
git clone -b release <this repo's URL> ~/claude-coding-workflow
git clone https://github.com/mattpocock/skills ~/mattpocock-skills
```

The workflow must live at `~/claude-coding-workflow`: the skills call its scripts
by that path. The borrowed helper skills (`research`, `prototype`, `tdd`,
`wayfinder`, ...) come from the second clone; `install.sh` prints the commit it
is pinned to and warns when the clone drifts from it:

```bash
git -C ~/mattpocock-skills checkout <the pinned commit install.sh prints>
```

## 3. Keys

```bash
cp ~/claude-coding-workflow/.env.example ~/claude-coding-workflow/.env
chmod 600 ~/claude-coding-workflow/.env
```

Set `DEEPSEEK_API_KEY` in it (from
[platform.deepseek.com](https://platform.deepseek.com/api_keys)). The
implementer runs DeepSeek Flash first; without the key every goal stops. With
`IMPLEMENTER_PRIMARY=haiku` in your environment, Claude Haiku 5.5 implements
first and DeepSeek is only the fallback.

Rules the scripts enforce and you should keep:

- Never commit `.env`; it is gitignored here. Never paste a key into a chat.
- A target repo with a live `.env` in its checkout stops the walk
  (`secrets-in-checkout`): the implementer and the proofs run in that
  checkout. Keep target-repo secrets elsewhere, or set `CW_ALLOW_DOTENV=1`
  knowingly.
- The launchers read keys from their files and pass them to the harness
  through a 0600 file the model's tools cannot read; every credential-like
  variable is stripped from the implementer's environment.

## 4. Install

```bash
~/claude-coding-workflow/scripts/install.sh
```

It links `/crucible`, `/to-goals`, `/run-goal` and `/run-goals` (and the
borrowed skills) into `~/.claude/skills`, installs the `walk` and `lessons`
mods from this repo's plugin marketplace, then runs `install.sh --check`:

- the test suite (`scripts/tests/run-all.sh`, four at a time, about three
  minutes);
- the versions of `claude`, `grok` and `codex`;
- `goals.py` on `GOALS.example.md`, a mock walk, the rate-limit and event
  checks, a real `run-goal.sh` wake on a scratch repo;
- the mods (installed and current), the borrowed skills, the pin.

No line should say `FAIL`, `MISSING`, `WARN` or `DRIFT`; `codex: not installed` is
fine unless you use the legacy Codex launcher (`IMPLEMENTER=codex`). Re-run `install.sh --check`
at any time.

Restart any open Claude Code session after installing, so it loads the skills
and the mods.

## 5. Smoke tests

Dry runs print the command and call no model:

```bash
GROK_REVIEW_DRY_RUN=1 ~/claude-coding-workflow/scripts/grok-review.sh --smoke
CLAUDE_REVIEW_DRY_RUN=1 ~/claude-coding-workflow/scripts/claude-goal-review.sh --smoke
IMPLEMENTER_DRY_RUN=1 ~/claude-coding-workflow/scripts/claude-implement.sh --smoke
```

Live pings (a few cents in all):

```bash
~/claude-coding-workflow/scripts/grok-review.sh --smoke
~/claude-coding-workflow/scripts/claude-goal-review.sh --smoke
~/claude-coding-workflow/scripts/claude-implement.sh --smoke
IMPLEMENTER_SMOKE_PROVIDER=haiku ~/claude-coding-workflow/scripts/claude-implement.sh --smoke   # the Haiku fallback
```

Expect `GROK_REVIEW_RESULT: ok`, `CLAUDE_REVIEW_RESULT: ok` and
`IMPLEMENTER_RESULT: ok`.

## 6. Next

[Using it with Claude Code](using-with-claude-code.md): your first feature,
end to end.

## Updating

```bash
git -C ~/claude-coding-workflow pull
~/claude-coding-workflow/scripts/install.sh
```

A mod is reinstalled only when its version changes; restart open sessions
afterwards.
