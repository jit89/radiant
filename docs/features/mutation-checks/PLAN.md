# Plan: mutation checks on the implementer's code (house item 8)
_Locked via crucible — by Claude + the user, 2026-10-24_

## Goal

After a goal's proof is green and Opus has said DONE, plant a few bugs in the
implementer's real code, aimed at the plan's riskiest rules, and require the
goal's own proof to turn red on each. A mutation the proof survives is an
oracle gap: the code is fine (reviewed, proven), the Architect's oracle does
not check that behaviour. Survivors are recorded, not a stop, unless the user
asks for a strict walk.

## Approach

1. **Who writes them (Q1), in a turn of their own.** The goal reviewer, after
   its DONE verdict, in a separate turn of the same session: the verdict reply
   is exactly today's (nothing added to it, `lib/verdict.py` and
   `lib/findings.sh` read it unchanged). When the route is DONE,
   `run-goal.sh` calls `claude-goal-review.sh --mutations N --resume
   <SESSION_ID>`, a mode that resumes the reviewer's session with a
   mutations-only prompt, writes the model's result text, exactly as returned
   (tabs and every line kept, read straight from the JSON result, not through
   `agent-result.py`, which turns tabs into spaces), to a file of its own, and
   prints `MUTATIONS_FILE: <that path>`: a result line holds one line, so the
   reply is never printed inline. It reads no verdict and never changes one. The prompt asks for up to N blocks,
   each:
   ```
   MUTATION: <the plan or goal rule it attacks, one line>
   ```diff
   <a unified diff against the goal's HEAD, touching only files the implementer changed>
   ```
   ```
   The reviewer keeps its read-only tools. A failure of that turn (a rate
   limit, an error, a timeout, an empty or over-64 KB reply) is a skip
   recorded with its reason; the goal is still done. Nothing the reviewer
   writes runs except through the sandboxed proof (step 4). (Five Grok rounds
   found holes in cutting the blocks out of the verdict reply; a turn of their
   own removes that cutting entirely.)

2. **How many, when (Q3).** On by default, `CW_MUTATIONS=3`; `CW_MUTATIONS=0`
   turns it off, at most 5. A value that is not an integer from 0 to 5 is
   refused at start, before any pass, as other settings are. Only after the
   final DONE verdict, never in a fix round. The mutations prompt names N;
   blocks beyond N are ignored.

3. **Parsing (`lib/mutations.py`), a strict grammar.** Reviewer text is
   untrusted (an implementer can prompt-inject the reviewer). From
   `MUTATIONS_FILE`: each block's rule and diff, in order, at most N. A
   block's diff is the interior between a line that is exactly ```` ```diff ````
   and the next line that is exactly ```` ``` ```` (a fence inside a hunk always
   carries its diff marker, so it never ends the block); only that interior is
   parsed. A block
   is accepted only when its diff holds nothing but plain edits of existing
   regular files, in the shape `git diff` writes: per file, an optional
   `diff --git a/<p> b/<p>`, an optional `index <sha>..<sha> 100644`, then
   `--- a/<p>` and `+++ b/<p>` naming the same path, then hunks (`\ No newline
   at end of file` allowed). The `index` line may name mode 100644 or 100755
   (an executable left executable, as most of this house's shell is). Any
   `rename`, `copy`, `new file`, `deleted file`, `old mode`/`new mode` line,
   an `index` line with mode 120000 (symlink) or 160000 (gitlink), `Binary
   files`, a quoted or absolute path, or a `..` segment rejects the block. Every path, canonicalized, must be a file changed in
   `BASE_SHA..HEAD` that is not a contract path: the plan, the oracle,
   `tests/acceptance/`, the other goals' oracles (`PROOF_GUARDED_EXTRA`),
   `.claude/`, `.mcp.json`, the journal and `GOALS.md`. A rejected block is
   counted "skipped" with its reason.

4. **Running them (`run-goal.sh`, the DONE route, before the goal is marked
   done; best-effort).** In a temp folder (not under the house's run folders,
   which the proof sandbox refuses as a root):
   - **the clone:** a copy-on-write clone of the checkout (`cp -cR`, APFS: the
     ignored dependency folders come along, nothing is duplicated on disk), in
     a temp folder outside every work tree, then its `.git` replaced by a
     **private git dir**: the copied `.git` entry is removed first without
     following it (in `--jobs` it is a gitfile naming the live admin folder,
     which `git init` would reinitialize; serially it is the full repo), then
     `git init`, `git add -A` (the non-ignored files) and `git commit
     --allow-empty -m baseline` (a message given, so no editor opens). Every
     git call on the clone, the factored predicate's snapshot included, is
     `command git -c core.hooksPath=/dev/null -c commit.gpgSign=false -c
     core.fsmonitor=false -c user.name=mutation -c
     user.email=mutation@localhost` (the safeguards of the house's `git()`
     wrapper, without its pinning), with
     `GIT_DIR=<clone>/.git` and `GIT_WORK_TREE=<clone>` and no other `GIT_*`,
     in a subshell; nothing reaches the goal's gitdir;
   - **applying a diff:** that git's `apply`, no `--unsafe-paths`, after an
     `lstat` of every destination: one that is a symlink, or not a regular
     file, rejects the block;
   - **running the proof:** `proof_exec` with the clone as `PROOF_ROOT`, the
     command `cd <clone> && <the goal's proof>` (proof_exec does not change
     folder), the goal's `PROOF_NETWORK` and `PROOF_DEPS`, `PROOF_WALK` the
     clone's private git dir (the hard-link pre-check walks it), and a per-run
     `--tmp` that is a copy-on-write
     copy of the goal's own proof temp, so the caches its green proof filled
     (cargo, npm, uv, pip) are there with no network;
   - **scoring, by the host's own rule** (the predicate `run-goal.sh` uses on
     the goal's proof, factored into one function both call, taking the tree
     to judge, here the clone and its private git dir): green = exit 0, not
     `Ran 0 tests`, and the proof changed nothing in its tree (snapshot taken
     after the diff is applied, before the proof). A baseline that is not
     green: every mutation skipped ("baseline red in a copy"). A mutation, in
     this order: a sandbox stop (`PROOF_SANDBOX_REASON`) → skipped; the proof
     timed out → `timeout` (neither caught nor survived); exit status not 0,
     or `Ran 0 tests` (the host's own fake-green check) → caught; exit 0 but
     the tree changed → skipped ("changed its tree"); else → survived. A diff
     that does not apply → skipped;
   - each clone and temp is removed after its run; the goal's checkout,
     index and branch are never touched;
   - **best-effort:** any failure of the machinery (a clone, an apply, a
     parse) is a skip recorded with its reason, never a stop: the goal is
     still marked done.

5. **Outcome (Q2).** Recorded, not a stop:
   - a host record `ORCHESTRATOR mutations <g> caught=N survived=M
     timeout=T skipped=K` (through `journal_line`, so into the host ledger),
     committed with the done commit;
   - an event `mutations` (info, or warning when any survived), its payload
     each mutation's rule and outcome built with a JSON encoder (a `"` in a
     rule must not drop the payload), written before the goal's `done` (or
     `phase integrate`) event. `events.py` gains `mutations` in `EVENTS`, not
     in `TERMINAL`;
   - each mutation's diff and rule kept in the goal's artifact folder
     (`run-goal-<g>/mutation-<k>.diff`), so the Architect can strengthen the
     oracle later;
   - the walk-end output (serial `run-goals.sh` and the parallel walker) prints
     one line per goal of this walk with survivors, read from the committed
     journal records since the walk's `walk-start` (a parallel member's stdout
     is not the walker's).
   `CW_MUTATION_GAPS=stop` makes survivors stop the walk, not the goal: the
   goal is marked done and lands as usual; then the walker, reading the
   committed record (serial: after the goal; parallel: after the wave's
   integrations), stops the walk as `oracle-gap`, naming the goals, the
   survivors and the kept diffs. It counts only the records written in this
   invocation (after the journal's length when it started): a stopped walk
   keeps its walk id, so a rerun would otherwise see the same survivors and
   stop again. A rerun carries on from there; nothing is left in progress, so
   no resume has to know about it.

6. **Docs.** README's environment table (`CW_MUTATIONS`,
   `CW_MUTATION_GAPS`), the run-goal skill one line, GOAL-FORMAT one line
   (survivors are oracle gaps for the Architect), FUTURE-WORK item 8 DONE.

7. **Tests** (stub reviewer writing mutation blocks; nothing calls a model):
   - a goal whose proof catches every mutation: the record `caught=3
     survived=0`, the goal done;
   - a mutation the proof does not catch: `survived=1`, a warning event naming
     its rule, the diff kept, the goal still done; the walk end names it;
   - `CW_MUTATION_GAPS=stop`: the goal is done, then the walk stops
     `oracle-gap` (serial and `--jobs`); a rerun carries on;
   - `--jobs`: the goal's worktree, index and branch are unchanged by the
     mutation runs (host git pinned there);
   - the verdict reply is untouched: a DONE review followed by a mutations
     turn whose diffs carry ` - VERDICT: FIX` lines and Markdown fences still
     reads DONE (the mutations reply never reaches `verdict.py`); the
     mutations turn runs after a DONE from the first review and after a DONE
     from a resumed fix-round review;
   - a mutations turn that fails, returns nothing, or returns over 64 KB:
     mutations skipped with the reason, the goal done;
   - the reply reaches the parser whole: a multi-line diff of a tab-indented
     file applies (tabs kept), and no line of it is read as a result key;
   - the prompted fenced form is accepted, including a hunk of a Markdown file
     whose lines contain ```` ``` ```` (each with its diff marker);
   - a real `git diff` block (with `diff --git` and `index … 100644`, and one
     of an executable with `100755`) is accepted; an `index … 120000` one is
     rejected; a destination that is a symlink is rejected;
   - in `--jobs` (a gitfile `.git`) and serially (a full `.git`) the live git
     dir is unchanged after the runs (its config, its index, no reinit);
   - the baseline commit needs no editor and no signing: a user config with
     `commit.gpgSign=true` and no terminal still runs the mutations;
   - a proof that needs git runs green in the clone (its private git dir);
   - `Ran 0 tests` counts as caught; a timeout that leaves the tree dirty is
     `timeout`, not skipped;
   - strict mode: a rerun after the oracle-gap stop carries on past the goal;
   - a rule with a `"` reaches the event payload intact;
   - the grammar: a rename, a mode line, a symlink mode, `..`, an absolute
     path, the journal and `GOALS.md` each reject the block;
   - a mutated proof that times out is `timeout`, not caught;
   - a mutation red only because its proof could not find its caches is not
     possible: the run's tmp is a copy of the goal's (one test with a cache);
   - an invalid `CW_MUTATIONS` is refused at start;
   - skipped: a diff that touches the oracle or `tests/acceptance/`, a path
     the implementer did not change, one that does not apply, a baseline
     that is red in the copy, and a clone that cannot be made (the goal still
     done);
   - `CW_MUTATIONS=0`: no mutation run, no record;
   - a FIX or BLOCKED verdict runs no mutations turn;
   - the goal's checkout and branch are byte-for-byte unchanged after the runs;
   - each new branch planted red (in parallel on copies of the house).

## Key decisions & tradeoffs

- **Q1 (user): the reviewer writes them.** It has read the plan, the goal and
  the diff; aiming at the riskiest rules needs that. Not a generic mutator
  (per language, hits trivia), not the Architect at planning time (no code
  yet), not the implementer (grading its own work). **In a turn of their own
  (user, after Grok round 6):** cutting them out of the verdict reply kept
  breaking the verdict in new ways for five rounds; a resumed turn costs one
  more cached Opus turn per DONE goal and leaves the verdict untouched.
- **Q2 (user): survivors are recorded, not a stop.** A survivor is an oracle
  gap, never wrong code, and some are equivalent mutants no test can catch;
  waking on them would stop walks for nothing. `CW_MUTATION_GAPS=stop` for a
  strict walk stops the walk after the goal lands (Grok round 1: a stop
  before done would leave the goal in progress, and a resume would dispatch
  the implementer again).
- **Q3 (user): on by default, 3 per goal.** It costs one baseline and three
  proof runs per goal after DONE (minutes on heavy builds); `CW_MUTATIONS=0`
  turns it off.
- **Copies, not worktrees.** A clone of the checkout carries the untracked
  dependencies a proof needs; a worktree or an export would not. The baseline
  run makes a copy that cannot pass unmutated an explicit skip, never a false
  "caught".
- **Reviewer text is untrusted input to a patch.** It is applied only to a
  throwaway clone, only to files the implementer changed and never to a
  contract path, and run only through the proof sandbox.

## Assumptions

1. The DONE route in `run-goal.sh` runs before the goal is marked done, in
   serial and `--jobs` (members run `run-goal.sh`). — `scripts/run-goal.sh`.
2. `proof_exec` runs a proof under the generated sandbox with a root and a
   private TMPDIR, does not change folder itself, and a root under a temp area
   is allowed; the run folders are denied as a root. In `--jobs`, host git is
   pinned to the member's worktree. — `scripts/lib/proof.sh`,
   `scripts/lib/proof-sandbox.py`, `scripts/lib/git-guard.sh`.
3. The oracle and `tests/acceptance/` are the Architect's; the implementer may
   not change them. — GOAL-FORMAT, `run-goal.sh` contract checks.
4. The reviewer's verdict is its last line, and `lib/verdict.py` calls a reply
   MISSING when an earlier line parses as another verdict; FIX lines are parsed
   by `lib/findings.sh`. So mutations never share the verdict reply: they come
   from a resumed turn of their own. `claude-goal-review.sh` already resumes a
   reviewer session (`--resume`). — `scripts/lib/verdict.py`,
   `scripts/lib/findings.sh`, `scripts/claude-goal-review.sh`.
5. `cp -c` clones on APFS (copy-on-write). — macOS `cp(1)`.

## Risks / open questions

- Equivalent mutants are recorded as survivors; the Architect judges them.
- A proof that is slow or flaky makes the baseline and the runs slow or noisy;
  the baseline turns a red copy into a skip, a flaky one may still mislead.
- Reviewer-written diffs that do not apply are skipped; if many are, the
  prompt needs work (the record counts them).

## Out of scope

- Fixing oracles automatically; the Architect does that.
- Mutations in fix rounds, or of the oracle itself.
- Running mutations for goals whose proof is not a command (inline case
  tables with `proof: inline`).
