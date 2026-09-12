# Plan: Host-loop Phase 4/5 (Grok off the happy path)
_Locked via crucible — by Grok + jit_

## Goal

Take Grok out of the implement → review hop. After `/run-goal` or `/run-goals` starts, a **host Orchestrator** dispatches DeepSeek, independently assesses the tree, starts Opus only if that assess passes, and routes `DONE` / `FIX` / `BLOCKED` without a Grok turn. Grok (and the user) are woken only on a stop. DeepSeek and Opus never talk in the clear. This is a change to `~/claude-coding-workflow` itself; house implementation is **in-session** (do not dispatch DeepSeek at the house).

## Approach

### Scripts and DAG helpers

1. Add `scripts/run-goal.sh` and `scripts/run-goals.sh`. Run from the **target** repo. `run-goals.sh` calls `run-goal.sh` as a subprocess (`rc=0; run-goal.sh "$id" || rc=$?`) — never `exec`. Walker keys on **exit code only**. Stop file is payload, not a signal. `trap … EXIT INT TERM` writes a stop file **only when the trap's `$?` is nonzero** (read `$?` as the trap's first statement; do not rely on a normal-path `rc` variable) and none exists yet. The walker echoes the child's `STOP_FILE:` as its own last line.
2. Call existing launchers; **do not fork their prompts**.
3. Extend `goals.py`: `body <id>`, `meta` (JSON: `plan`, `log`, `journal`). `validate` requires top-level `plan` and `journal`. `cmd_set` / `cmd_refresh` rewrite the matched `status:` line **in place** and do not re-render the YAML fence (preserves comments and key order). After any in-place write, re-parse and `SystemExit` if that goal's status is not the requested value. Existing DAGs without `journal:` fail the new validate — `/to-goals` adds the key; older files need it added by hand before the first walk.
4. `RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/run-goal-<id>-XXXXXX")"` mode `0700`. Artifacts `-r<n>`. Fail if a new `DIFF_FILE` is missing or empty. Print `STOP_FILE:` = `$RUN_DIR/stop.md`. No predictable copy.
5. Timeouts: prefer `gtimeout --kill-after=5`. Else own process group; `kill -TERM -$pgid` then `KILL`. Defaults 1200s / 600s.

### One goal (`run-goal.sh <id>`)

6. **Gate:**
   - `GOALS.md` exists; `validate` ok; `HEAD` exists.
   - File oracles referenced by the current `id` **and** the `journal:` path are tracked and present in HEAD. Missing journal → "commit GOALS.md, oracles, and the journal first."
   - `goals.py validate` requires top-level `plan` and `journal` keys (new check).
   - Working tree: **fresh start** requires porcelain empty except (i) `GOALS.md` if a **parsed** fence compare (`goals.py` on HEAD vs worktree) differs **only** in `status:` of **this** `id` — never a textual diff — and (ii) nothing else. Name every offending path in the failure message.
   - `cd "$(git rev-parse --show-toplevel)"` before any git pathspec.
   - **Resume** (`id` is already `in_progress`) does **not** require a clean tree. Print the current porcelain and, on a later wake, a tree-unstick line (`git restore -- <paths>` / commit / stash). Still refuse if a **file oracle** or `tests/acceptance/` is dirty.
   - `GOALS.md` + file oracles must be **tracked**. If `GOALS.md` is not in HEAD at all → "commit the DAG and oracles first."
   - `id` is `ready` or `in_progress`, or `blocked` with done blockers (`refresh` first). Any `refresh` inside `run-goal.sh` is followed by the same narrow `GOALS.md` commit as the walker (do not leave a dirty fence for the clean gate).
   - File oracle + non-command proof → stop at the gate.
   - Missing key → stop, no paste.
   - **`meta` is read from worktree GOALS.md at gate time only** (the gate has just constrained how dirty that file may be). That yields the journal path. Then, on resume, read the last `ORCHESTRATOR dispatch <id>` line for `BASE_SHA` / `THREAD_ID` / `SESSION_ID` / `r<n>`. Missing `BASE_SHA` on resume → stop. Before trusting it: `git merge-base --is-ancestor "$BASE_SHA" HEAD` and re-check contract files at that sha; mismatch → wake. Continue `fix_count` from `r<n>` (per-goal, not per-invocation).
7. **Always:** `git show "$BASE_SHA":GOALS.md > "$RUN_DIR/goals-base.md"` (`BASE_SHA` is HEAD on a fresh start, else the journaled sha). All later `show`/`body`/`meta`/`proof`/`oracle` reads use that file. Journal
   `## <UTC> — ORCHESTRATOR dispatch <id> r<n> BASE_SHA=<sha> THREAD_ID=<or-> SESSION_ID=<or->`.
   **Fresh only:** `BASE_SHA="$(git rev-parse HEAD)"` then set `in_progress`.
8. Write the handoff from `goals-base.md` (fence + verbatim body + journal path + read-only oracle + `BASE_SHA` + "git add the journal path on checkpoints").
9. Dispatch DeepSeek. Capture result lines.
10. **Host assess:**
    1. porcelain + `git log --oneline -15`.
    2. Contract vs `goals-base.md` / `BASE_SHA`: this goal's file oracle + `tests/acceptance/`; non-`status:` fence drift; **`status:` drift only allowed for the current `id`** (any other goal's status change is a touch); inline body if `oracle: inline`.
       Worktree-only touch → checkout + unstage, wake. Committed touch → do not restore; wake with revert command.
    3. Unexpected dirty (not this-id status, not journal) → wake. No implementer-source auto-commit.
    4. Proof: non-command → `PROOF: none`, continue to review only. Else host-run. Red = nonzero or `Ran 0 tests`.
    5. Red proof after `ok` → wake. No Opus.
    6. Empty `git diff "$BASE_SHA"..HEAD -- . ':!GOALS.md' ':!<journal>'` → wake. (Orchestrator commits of those two files are not "the change.")
11. Write the patch with the **same pathspec** (`:!(GOALS.md)` and `:!(journal)`). Brief includes the numbered-finding format reminder.
12. Dispatch the goal reviewer. Same Claude session per goal.
13. Verdict: if `CLAUDE_REVIEW_RESULT` ≠ `ok` → `MISSING`. Else last non-empty line of `$OUT`. `verdict_of` takes the token after `VERDICT:` (DONE / FIX / BLOCKED); a trailing ` — comment` is still that verdict. Body quotes do not win.
14. Route:
    - **DONE** only after an **executed** green proof. `PROOF: none` → `done-refused` wake; stop file includes `goals.py set <id> done` and the review path.
    - **FIX** → numbered findings. Zero findings → wake, not bounced. Oracle-path edit → BLOCKED route. Else fix handoff; journal **count + short hash of the findings blob**, not finding text. Persist each round's `VERDICT_FILE` and fix handoff under `~/.cache/claude-coding-workflow/run-goal-<id>/` (outside the target repo). Mention that directory **only in the stop file**, never in the journal. Same `BASE_SHA` on the next dispatch line. `MAX_FIX_ROUNDS` then wake. Else loop.
    - **BLOCKED** → `bounced`, Orchestrator commit, wake.
    - **MISSING** / `error` / `rate_limited` → wake, leave `in_progress`, unstick commands for **status and tree**.
15. Stop file in `RUN_DIR` only. Print `STOP_FILE:`.
16. Narrow commit of `GOALS.md` + journal on `done` / `bounced` / wake that mutated them.

### Walk (`run-goals.sh`)

17. `validate` + `refresh` + **narrow Orchestrator commit of `GOALS.md` immediately after every `refresh` that dirties it** (status flips `blocked → ready`; in-place `status:` edit, no fence re-render). Then `graph` + `frontier`. Loop: refresh+commit, first frontier id, journal a walk line **and commit the journal**, then `run-goal.sh`. (The child's fresh-start gate fails closed on an uncommitted journal — same class of bug as an uncommitted refresh.) Nonzero exit → stop. Empty frontier → `walk-end` + journal commit, exit 0.
18. Thin skills. `/to-goals` ends with "commit GOALS.md, file oracles, **and** `docs/journal/<slug>.md` before `/run-goal`." Existing DAGs without a top-level `journal:` key must have it added by hand before the first walk.

## Key decisions & tradeoffs

- **Host loop, not DeepSeek↔Opus.** [docs/adr/0001-host-loop.md](docs/adr/0001-host-loop.md).
- **Host assess before Opus.** Clean-tree gate on **fresh** starts only; resume may be dirty (quota death leaves an in-flight cycle). (Round 3.)
- **`refresh` commits `GOALS.md` before the next gate.** Otherwise goal 2 always dies on the clean/unmodified check. (Round 3.)
- **Walker commits the journal walk line before `run-goal.sh`.** Otherwise every fresh `/run-goals` dies on the child's clean-tree gate. (Dogfood, 2026-08-15.)
- **Review diff excludes `GOALS.md` and the journal.** Those are Orchestrator records, not the implementer change. FIX text is not journaled — only a count + hash. (Round 3; keeps the "never talk in the clear" invariant.)
- **`status:` carve-out is per current `id` only.** (Round 3.)
- **Journaled `BASE_SHA` must be an ancestor of HEAD.** (Round 3.)
- **`PROOF: none` can review, cannot `done`.**
- **No per-goal worktree in v1.**
- **Launchers' prompts unforked.** House work in-session.

## Assumptions

1–13 as in the previous lock (house launchers, no worktrees, in-session house impl, etc.).
14. `goals.py refresh` writes the fence unconditionally — `goals.py:258-266`. Round 3: commit that write before the next gate.
15. The implementer is required to read the journal (`deepseek-code.sh:366`). Therefore the journal must not contain Opus finding text.

## Risks / open questions

- Resume-on-dirty still needs a human if the in-flight cycle is garbage. The stop file now says how to unstick the tree.
- Inline goals always `done-refused`. v1.
- `dump_yaml` / `write_fence` are unused by `set`/`refresh` after the in-place rewrite.

## Out of scope

- DeepSeek reading `VERDICT_FILE` or Opus reading the return handoff.
- Auto-commit of implementer sources.
- Grok on every FIX list.
- Parallel / per-goal worktrees.
- Prompt forks; daemon; `/crucible`/`/to-goals` replacement; model swap; Windows.
