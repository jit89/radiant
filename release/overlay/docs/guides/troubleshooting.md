# Troubleshooting

## First: where to look

| What | Where |
|------|-------|
| Why a goal or walk stopped | the `STOP_FILE:` the script printed last (under `~/.cache/claude-coding-workflow/runs/`); the Architect reads it for you |
| What happened, in order | the feature's journal, `docs/journal/<slug>.md` in the target repo |
| The machine index of events | `scripts/logs.sh errors`, `warnings`, `last`, `goal <id>`, `since 5m` or `since walk` |
| The walk as a graph | `/walk-status` in Claude Code, or `scripts/events.py graph` |
| Raw model output | the `LOG:` and `stderr:` files a stop file names |

Run the scripts from the target repo. Run folders and Grok verdicts are pruned
after 14 days (`CW_PRUNE_DAYS`).

## `install.sh --check`

| Line | Fix |
|------|-----|
| `codex: MISSING` | Only with `IMPLEMENTER=codex`: install the Codex CLI or unset `IMPLEMENTER` (without it, `codex: not installed` is just a note) |
| `grok: MISSING` | Install the Grok CLI and `grok login`, or set `GROK_BIN` |
| `borrowed <skill>: MISSING` | Clone [mattpocock/skills](https://github.com/mattpocock/skills) to `~/mattpocock-skills` and re-run `install.sh` |
| `mattpocock-skills pin: DRIFT` | `git -C ~/mattpocock-skills checkout <pin>` (the line prints it) |
| `walk mod: WARN installed copy differs` | The mod changed without a version bump; bump `mods/<mod>/.claude-plugin/plugin.json`'s version and re-run `install.sh` |
| `implementer key: WARN` | Set `DEEPSEEK_API_KEY` in `~/claude-coding-workflow/.env` |
| `tests: FAIL` | The failing test's output follows; a test that fails only under load (a timing check) passes on a rerun: `CW_CHECK_RERUN=1 install.sh --check` |

## Common stops

| Reason | What it means | What to do |
|--------|---------------|------------|
| `rate_limited`, `reviewer-rate-limited` | A provider's usage limit | Wait for the reset, then rerun; the scripts never hammer or swap models |
| `implementer-error`, `reviewer-error` | A launcher failed (the stop names its output) | Read the `LOG:`; an invalid key shows `api_error_status: 401` there. Fix and rerun |
| `implementer-timeout`, `reviewer-timeout`, `proof-timeout` | A step ran past its timeout | Rerun; raise `IMPLEMENTER_TIMEOUT`, `CLAUDE_REVIEW_TIMEOUT` or `PROOF_TIMEOUT` if it keeps happening |
| `implementer-declined` | Both models refused or declined the goal (or DeepSeek is out of balance with no fallback left) | Read the report it names; rework the goal |
| `max-fix-rounds` | Review and proof did not converge in `MAX_FIX_ROUNDS` repairs | Read the last review; split the goal or sharpen the oracle, then rerun |
| `proof-red`, `missing-verdict`, `fix-unparseable`, `empty-diff` | The goal produced nothing the gate accepts | Rerun; if it repeats, rework the goal |
| `done-refused` | The reviewer said DONE but the proof is not an executable test (an inline case table) | Check the goal by hand, then `goals.py GOALS.md set <id> done` |
| `bounced`, `implementer-blocked`, `blocked`, `oracle-gap` | A contract question: the goal, the oracle or the plan needs a decision | Decide with the Architect; change the plan or the goal (re-sign under always-on) |
| `walk-stuck` | Nothing left to run, but goals are bounced or blocked behind one | The stop lists each; unblock or bounce them |
| `dirty-tree`, `orchestration-files-dirty`, `orchestration-files-changed` | Edits the workflow did not make, in the tree or in `GOALS.md` / the journal | Commit or restore them, then rerun |
| `journal-tamper` | An uncommitted or foreign record in the journal | Commit your own notes before dispatching; restore anything else |
| `contract-tamper-*`, `proof-tamper` | The oracle, the plan or an ignored file under `tests/acceptance/` changed during the goal | Inspect the diff; the implementer may not touch the contract |
| `git-metadata-tamper`, `claude-config-tamper` | `.git` or `.claude` changed during a model's turn | Inspect before opening Claude Code in that repo again; the stop says how to re-baseline |
| `secrets-in-checkout` | A live `.env` in a checkout of the target repo | Move the secrets out of the repo (or `CW_ALLOW_DOTENV=1`, knowingly) |
| `proof-sandbox-unavailable`, `proof-sandbox-path` | The proof sandbox could not run (or the repo is under a denied path such as `~/.claude`) | Move the repo, or `CW_PROOF_SANDBOX=off` knowingly |
| `gate` | A precondition refused before dispatch (the detail says which) | Fix what it names |
| `wave-stop` | A parallel wave stopped; each goal is listed with its own reason and stop file | Read each; rerun with the same `--jobs` |
| `merge-conflict`, `integration-red` | A parallel goal conflicted twice, or the merged proofs went red | Fix the walk branch and rerun, or `goals.py GOALS.md set <id> ready` to recut it |
| `serial-goal-in-progress` | A `--jobs` walk found a goal a serial run left mid-way | Finish it with `run-goals.sh` (no `--jobs`), then rerun with `--jobs` |

After fixing, rerun the same command (`/run-goal <id>` or `/run-goals`): a
serial run resumes a goal from its base; a parallel walk recuts a stopped goal
and runs it fresh.

## Proof problems

- **A proof needs the network.** Proofs have none, loopback included. Add
  `proof_network: loopback` (or `true`) to the `GOALS.md` preamble, and say why
  in the plan.
- **A fresh worktree cannot run the proofs** (no `node_modules`, no `.venv`).
  Add `worktree_setup: npm ci` (or `uv sync --frozen`, ...) to the preamble;
  parallel walks run it in each goal's worktree.
- **A proof leaves files behind.** Everything a proof writes must match
  `.gitignore`, and nothing may be written under `tests/acceptance/`
  (`PYTHONDONTWRITEBYTECODE=1` is set for Python).
- **Two proofs collide in a parallel wave** (a fixed port or path). Declare
  `conflicts_with` between the goals.

## Leftovers after a parallel walk

A stopped parallel walk keeps each goal's `cw/<goal>` branch and its worktree
under `~/.cache/claude-coding-workflow/worktrees/` as evidence; a rerun with
`--jobs` re-attaches them. To discard one by hand:
`git worktree remove -f -f <path>` and `git branch -D cw/<goal>`.

## Always-on

See [Always-on](always-on.md) for holds and `cw-decide.sh`. Quick checks:
`cw-decide.sh status` (the queue and each hold), `cw-decide.sh doctor` (the
Mac's readiness), and the supervisor's log at
`~/.cache/claude-coding-workflow/always-on/supervisor.log`.
