# Configuration

Everything is configured through environment variables, set in your shell or
for one command (`MAX_FIX_ROUNDS=2 ~/claude-coding-workflow/scripts/run-goal.sh g1`).
Keys go in the house's `~/claude-coding-workflow/.env` (0600), never in your
shell history: the launchers read `DEEPSEEK_API_KEY` (and, optionally,
`ANTHROPIC_API_KEY`) from it. Keep them out of target repos: a live `.env` in
a target checkout stops a walk (`secrets-in-checkout`), because the
implementer and the proofs run there.

## The workflow

| Env | Default | Meaning |
|-----|---------|---------|
| `GROK_REVIEW_MODEL` | `grok-4.7` | Plan attacker |
| `GROK_REVIEW_EFFORT` | `high` | Grok `--reasoning-effort` |
| `GROK_REVIEW_DRY_RUN=1` | off | Print Grok command only |
| `GROK_BIN` | auto | Grok binary path |
| `CLAUDE_REVIEW_MODEL` | `claude-opus-5-5` | Goal reviewer |
| `CLAUDE_REVIEW_FALLBACK_MODEL` | `claude-opus-4-8` | One retry when the reviewer's safeguards flag a review (`none` = off) |
| `CLAUDE_REVIEW_FALLBACK_EFFORT` | `xhigh` | The effort of that retry (the first review runs at `CLAUDE_REVIEW_EFFORT`) |
| `CLAUDE_REVIEW_EFFORT` | `high` | Claude `--effort` |
| `CLAUDE_REVIEW_DRY_RUN=1` | off | Print Claude command only |
| `IMPLEMENTER` | `claude` | `codex` selects the legacy `deepseek-code.sh` |
| `IMPLEMENTER_MODEL` | `claude-haiku-5-5` | The Haiku implementer |
| `IMPLEMENTER_EFFORT` | `xhigh` | Haiku `--effort` |
| `IMPLEMENTER_PRIMARY` | `deepseek` | `haiku` implements first instead, with DeepSeek as the fallback; any other value stops |
| `IMPLEMENTER_FALLBACK` | `on` | One rerun on the other model when the primary refuses, declines or (DeepSeek) is out of balance (`none` or empty = off; the old `deepseek` still means on) |
| `IMPLEMENTER_ALLOWED_DOMAINS` | empty | Comma list of hosts the sandbox may reach |
| `IMPLEMENTER_MAX_BUDGET_USD` | unset | `--max-budget-usd` per Haiku pass (not DeepSeek: Claude Code misprices it) |
| `IMPLEMENTER_DRY_RUN=1` | off | Print the Claude command only |
| `DEEPSEEK_MODEL` | `deepseek-flash` | The DeepSeek implementer (the Codex launcher keeps its own `deepseek-v4-flash` default) |
| `DEEPSEEK_EFFORT` | unset | DeepSeek `--effort` (unset: Claude Code sends `high`) |
| `DEEPSEEK_PRICE_MISS` / `_HIT` / `_OUT` | `0.30` / `0.006` / `1.20` | USD per 1M tokens for the DeepSeek cost line (the published peak prices) |
| `DEEPSEEK_ANTHROPIC_BASE_URL` | `https://api.deepseek.com/anthropic` | The DeepSeek implementer's endpoint |
| `DEEPSEEK_DRY_RUN=1` | off | Codex launcher only: print the command |
| `MAX_ROUNDS` | `5` | Plan-attack rounds (skill) |
| `MAX_FIX_ROUNDS` | `3` | Repair passes after the first implementation: `N` lets up to `N` FIX handoffs be implemented, review fixes and proof fix rounds alike (`0` wakes on the first FIX or red proof) |
| `IMPLEMENTER_TIMEOUT` | `1200` | Seconds per implementer pass (`DEEPSEEK_TIMEOUT` still honoured) |
| `CLAUDE_REVIEW_TIMEOUT` | `600` | Seconds per review (a flagged review and its retry share it) |
| `PROOF_TIMEOUT` | `600` | Seconds for the host proof |
| `CW_PROOF_SANDBOX` | (on) | `off` runs proofs, `worktree_setup` and merged proofs unsandboxed; journaled on the dispatch record |
| `CW_ALLOW_DOTENV` | (unset) | `1` walks a repo with a live `.env` in a checkout, knowingly; journaled on the dispatch record |
| `PROOF_ENV_KEEP` | empty | Space-separated variables the proof may still see that would be removed: those with a whole `_`-separated part `KEY`, `APIKEY`, `TOKEN`, `SECRET`, `PASSWORD`, `PASSWD` or `CREDENTIAL(S)` in any case (not git's `GIT_CONFIG_*`), and every `CW_*` setting |
| `KEEP_RUN_DIR=1` | off | Keep the run dir after a goal lands |
| `CW_OUT_DIR` | unset | Launchers write raw output, `.err` and verdict/report here and delete none; `run-goal.sh` sets it to its run dir |
| `CW_KEEP_RAW=1` | off | A standalone launcher keeps its raw output and `.err` after an `ok` result |
| `CW_MUTATIONS` | `3` | How many mutations the goal reviewer writes after a DONE review, each run against the goal's proof on a clone (`0` = off, at most 5) |
| `CW_MUTATION_GAPS` | unset | `stop`: a mutation the proof survives stops the walk after its goal lands (`oracle-gap`); unset, survivors are only recorded |
| `CW_PRUNE_DAYS` | `14` | Age past which `~/.cache/claude-coding-workflow/runs/`, `grok/` and `lessons/logs/` entries are deleted at the next run (`0` = never) |

## Tests and checks

| Env | Default | Meaning |
|-----|---------|---------|
| `CW_TEST_JOBS` | `4` | How many test scripts `run-all.sh` and `install.sh --check` run at once |
| `CW_CHECK_RERUN` | unset | `1`: `install.sh --check` reruns the suite instead of reusing the last full run of the same tree |
| `MATTPOCOCK_SKILLS_DIR` | `~/mattpocock-skills` | Where the borrowed skills' clone lives |
| `CLAUDE_SKILLS_DIR` | `~/.claude/skills` | Where `install.sh` links the skills |

## Always-on

The unattended loop takes no settings: its LaunchAgent passes only `PATH` and
the update switches, so the key file (`~/.config/cw-secrets/anthropic-decider.key`),
the decider's effort (`high`) and timeout (600 s), the ceilings ($10 in 24
hours, $20 per entry, $50 in 7 days), the counts and the paths are fixed (see
[Always-on](always-on.md)). `CLAUDE_DECIDE_KEY_FILE`, `CLAUDE_DECIDE_EFFORT`
and `CLAUDE_DECIDE_TIMEOUT` change only a hand run of `scripts/claude-decide.sh`.

## Where files live

Where files live: a goal's run dir (stop file, diff, proof output, the
launchers' output) is `~/.cache/claude-coding-workflow/runs/run-goal-<id>-*`,
removed when the goal lands and kept on a wake. The implementer's folder
(handoffs, return documents, the frozen plan) is
`~/.cache/claude-coding-workflow/handoffs/run-goal-<id>-*`, outside the run
folders: the implementer's sandbox denies it every run folder, Grok's
verdicts, the logs and every other goal's handoff folder, and its `TMPDIR` is
a private folder under `/private/tmp/cw-<uid>` (not Claude Code's shared
`/tmp/claude-<uid>`, which it cannot read). Nor can it read `/var/folders`
(the user's macOS temp tree), except xcrun's cache file. Every host proof,
`worktree_setup` and merged proof runs under the proof sandbox (`scripts/lib/proof-sandbox.py`): writes only to
the checkout and its own `TMPDIR`, no network unless the GOALS.md preamble
says `proof_network: loopback` or `true`, the secret list
(`scripts/lib/secret-paths.txt`) unreadable; a walk with a live `.env` in any
checkout stops (`secrets-in-checkout`). Grok verdicts are in
`~/.cache/claude-coding-workflow/grok/`. These folders are 0700 and pruned
past `CW_PRUNE_DAYS`. Run the tests with `scripts/tests/run-all.sh [-j N]`:
four at a time by default (`CW_TEST_JOBS`), each in its own `TMPDIR` and
`HOME`, failing any test that leaves something in either; `install.sh --check`
runs them the same way (~3 minutes at `-j4`, against ~7.5 one at a time), or
reuses the last full `run-all.sh` run when the tree is still the one it tested
(`~/.cache/claude-coding-workflow/tests/last/`; `CW_CHECK_RERUN=1` reruns).

Legacy: `IMPLEMENTER=codex` selects `scripts/deepseek-code.sh` (DeepSeek in
the Codex CLI), configured by `DEEPSEEK_BASE_URL`, `DEEPSEEK_CODEX_HOME`,
`DEEPSEEK_LOCK_WAIT` and `DEEPSEEK_REQUIRE_GIT`; the header of that script
documents them.
