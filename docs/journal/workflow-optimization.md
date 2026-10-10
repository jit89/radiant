# Journal: workflow-optimization

## 2026-10-10T15:29:41Z — ARCHITECT start

In-session house work (no DeepSeek on the house). Evaluation done with the user; decisions locked:

- Implementer → Claude Haiku 5.5 (`claude-haiku-5-5`, effort xhigh) via headless `claude -p` from run-goal.sh. Not an in-session subagent, not /subtask (forks inherit the Architect's conversation).
- DeepSeek stays as the fallback, through the Claude Code harness (DeepSeek's Anthropic-compatible endpoint), not Codex.
- Fallback fires on refusal / safeguards flag / explicit decline only. Rate limits still stop with no swap; max-fix-rounds still stops.
- Grok oracle review (new Phase 3.5) resumes the plan-attack session on a fork, with a size guard; PLAN-REVIEW-LOG.md seeds a fresh session past the threshold.
- Parallel walker: `run-goals.sh --jobs N`, per-goal journal files, walker sole writer of GOALS.md. `--jobs 1` stays today's behaviour.
- Withdrawn: "allow refactor after green" (upstream tdd puts refactoring in review).

Order: 1 install/doc fixes → 2 Haiku launcher + fallback → 3 proof-red as fix round → 4 oracle review → 5 parallel (through /crucible first).

## 2026-10-10T15:29:41Z — ARCHITECT step 1

- Borrowed skills: pinned clone `~/mattpocock-skills` @ 49dd158; install.sh links them plus their deps (grilling, domain-modeling, codebase-design, setup-matt-pocock-skills); --check reports per-skill presence and pin drift. caveman dropped.
- Glossary: CONTEXT.md → GLOSSARY.md (house file, crucible format file, skills, prompts). Prompts still accept a legacy CONTEXT.md.
- Reviewer default claude-opus-5 → claude-opus-5-5 (fallback claude-opus-4-8 unchanged); tests updated.
- run-goal / run-goals skills: run in the background (a goal outlasts the 10-minute foreground ceiling).
- SETUP.md: old-home path guidance made generic.

## 2026-10-10T15:46:08Z — ARCHITECT decision

Walker visibility as a Claude Code mod, kept in the house repo (loaded user-wide, not per target repo). Footer label (SessionMode) shows the current goal; the status line stays untouched. `/walk` opens a pane drawing the DAG git-graph style (one lane per line of work, ├─╮ joins); lane tangling is ours to solve in code. Wake band dropped. Order: step 2 (Haiku launcher + DeepSeek fallback), then the footer label, then the `/walk` pane.

## 2026-10-10T16:07:04Z — ARCHITECT step 2

Implementer moved to `scripts/claude-implement.sh` (default `IMPLEMENTER=claude`; `IMPLEMENTER=codex` keeps the legacy launcher).

- Live smokes first: Haiku 5.5 headless with a tool call; DeepSeek through Claude Code (`--bare`, `ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic`, model `deepseek-v4-flash` accepted with an unrecognized-model warning, so its cost line is a Claude-priced estimate).
- Isolation, each verified live: Claude Code sandbox (`allowUnsandboxedCommands: false`, `failIfUnavailable`) under `--safe-mode`: commits work; writes to $HOME, .git/hooks and .claude/settings blocked; network blocked. Subprocesses inherit env, so the launcher strips credential-like vars and hands keys to the harness via `apiKeyHelper` reading a 0600 file whose dir is read-denied. `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` rejected: it made static-check refusals of ordinary loops. Bash allowed outright (`--allowedTools Bash`): auto-approval alone refused commands it cannot read statically; the OS sandbox still holds every command.
- Fallback: once, Haiku to DeepSeek, on a safety flag or `IMPLEMENTER_STATUS: DECLINED`; fresh session; journaled `FALLBACK=`. Thread ids carry the provider (`haiku:`/`deepseek:`). A resumed thread that was never saved restarts fresh on the same provider.
- run-goal.sh: new wakes `implementer-declined` (exit 76), `implementer-blocked` (status BLOCKED, before the dirty-tree check), `claude-config-tamper` (.claude/ or .mcp.json changed; baseline per repo+goal outlives a stop, so a resume is held to it); `ORCHESTRATOR implemented` record + `implemented` event with model, fallback, cost, tokens; proof snapshot also guards .claude/.mcp.json.
- Self-review fixes before tests: doc comment misplaced; .claude check moved after id capture; baseline made persistent; BLOCKED handled; status-line example made parseable; lost-thread resume.
- Known trade-off: an Architect "don't ask again" approval in the target repo mid-walk writes .claude/settings.local.json and trips claude-config-tamper.

## 2026-10-10T16:23:52Z — ARCHITECT footer label

Mod `mods/walk` (house repo, user-wide via the repo's local marketplace `claude-coding-workflow`, read in place). Adds one label to the prompt footer (SessionMode) while a goal runs: `walk <goal> r<n> · <phase> · <done>/<total>`. Status line untouched.

- Source of truth: new `events.py status --json` (walks up to GOALS.md, reads the repo's event index; running = last goal event not terminal and its pid alive).
- run-goal.sh now records its pid on dispatch and on new `phase` events (proof, review); run-goals.sh on walk events.
- Mod polls every 3 s in interactive sessions only; a failed poll keeps the label, five in a row clear it.
- Tests: walk-status-test.sh (15 checks), mod tests via `claude plugin test` (4, terminal + desktop). The failed-poll test caught a real bug (a non-zero exit cleared the label).
- Known limit: a reused pid could read as running until the next event.

## 2026-10-10T16:30:31Z — ARCHITECT footer label self-review

- Reused pid (the known limit): events now carry `pid_start` (`ps -o lstart=`) beside `pid`; `events.py status` counts a goal as running only while that pid is alive AND started at that time. Tested with a live pid given a wrong start time.
- Desktop app: sessions it hosts report `isInteractive: false`, so the mod never polled there though the desktop draws the footer. It now polls whenever `$.session.surfaces()` is non-empty; a plain `-p` run has none.
- A GOALS.md that does not parse (mid-write) made `status` answer idle, flashing the label off; it now exits 1, which the mod treats as a failed poll (label kept; five in a row clear it).
- `status --json` emits ASCII JSON: the poller may run without a UTF-8 locale.
- A real run-goal now verified to write pid + pid_start on dispatch and phase events.
- Remaining limits: the label drops briefly between goals of a walk (from a goal's `done` until the walker's next `walk` event); the mod finds events.py relative to its own folder, so it works only when read in place from this repo.

## 2026-10-10T20:10:28Z — ARCHITECT walk pane

- Found: `plugin install` copies a mod into `~/.claude/plugins/cache/...`; nothing reads it in place. The footer label's `$.plugin.root/../../scripts/events.py` therefore never resolved in a real session (the mod tests stub the process call, so they passed). The mod now runs events.py through `sh`, looking beside the mod (a `--plugin-dir` load), then `$CLAUDE_CODING_WORKFLOW`, then `~/claude-coding-workflow`. install.sh compares the installed copy with mods/walk, runs `plugin update` when they differ, and `--check` warns on a stale copy. A changed mod needs a version bump (now 0.2.1); open sessions need a restart.
- `/walk [dir]` opens pane `walk`. In the fullscreen layout it is a sidebar beside the transcript from 110 columns; otherwise it sits above the prompt. While the pane is open the mod polls `events.py graph --json --dir`, and the pane is drawn from that: header, git-graph rows, legend.
- `events.py graph`: `lay_out` draws the lanes (Kahn order, GOALS.md order where the edges allow; `├─┬─╮` forks, `●─┼─╯` joins). `goal_stats` gives each goal's round, model, fallback, time and cost from the event index. A goal's state is done, running, paused (`in_progress`, no live process), ready, waiting or bounced.
- The pane adapts to its width. Wide: id, title and detail on one row. Sidebar: id only, with a running, paused or bounced goal's detail wrapped onto the lines beneath. Too narrow for the graph: a flat list.
- Self-review fixes:
  - Cost counted a fresh thread costing more than the last as the same thread. The `implemented` payload now records `thread`; cost sums the last total of each thread, with the old drop rule for records without one.
  - `/walk` during a poll in flight left the pane empty. It now waits for that poll and reads again, and a read for a repo the pane has moved away from is dropped.
  - A malformed goal raised a traceback. It is now a clean exit 1.
  - The install message claimed "updated" without checking. It now re-checks the copy.
  - A detail line drew a forked lane before its fork row.
- Parallel walks: "running" was the goal named by the last event, so a second live goal would read as paused. `live_goals` now judges each goal by its own last event and live pid. The footer shows the newest goal plus `+N`, and the graph marks every live goal running. Tested with two live goals.
- Still open for step 5:
  - goals.py writes GOALS.md in place (not tmp + rename). The pane survives a torn read: it keeps the last graph and shows the error.
  - The event index keys on the cwd's path, so a worktree's events land in another index. Step 5 must key on the main checkout.
  - Per-goal journals must still feed one event index per feature, or the graph has to read them all.
- Tests: walk-status-test.sh adds parallel, graph, cost-per-thread and layout checks; mod tests 12 (pane on terminal and desktop, sidebar, wide, flat layouts).

## 2026-10-10T20:31:40Z — ARCHITECT walk pane final self-review

- `walk_graph` read its header (running goal, `+N`) through `walk_status`, which reads the last 400 events, while goal states came from its own 20,000. On a long log the header and the rows could disagree, and GOALS.md was parsed twice per poll. Both now come from one read: the newest live goal leads.
- After a fresh install, install.sh said `/reload-plugins`; an installed copy needs a restart, as an update does.
- Test added for the parallel header (`review +2`). Mod at 0.2.2, its installed copy verified identical to mods/walk.
- No TypeScript compiler on this machine: the mod is checked by `claude plugin validate` and its 13 tests on the engine.
