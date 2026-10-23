# Plan Review Log: mutation checks on the implementer's code (house item 8)
Phases 0-1 (recon + interrogation) complete — plan locked with the user. MAX_ROUNDS=5.

## Round 1 — Grok

I'll review the plan skeptically against the domain docs and the code it depends on, looking for concrete breaks rather than style nits.The plan leans on several scripts and invariants. I'll check those claims against the repo before judging whether the design holds.The plan is not safe to implement as written. Six holes in the current host will make mutation checks either patch the live goal, score the wrong tree, or turn a real DONE into a walk-stopping MISSING.

1. In `--jobs`, `git()` in `scripts/lib/git-guard.sh` pins `GIT_WORK_TREE` to the live worktree, and a worktree `.git` is a gitfile pointing at that same shared gitdir. `git apply` as specified therefore patches the goal checkout the plan says is never touched. The journal is an implementer-changed path and is not on the contract skip list, so a diff can be committed by `orch_commit` (the done check only requires the commit to name the journal). A copy also shares the live gitdir, so apply can lock or refresh the real index. **Fix:** build the clone without `.git`, apply with `command git` and `GIT_DIR`/`GIT_WORK_TREE`/`GIT_COMMON_DIR` unset, in a subshell, and treat the journal, `GOALS.md`, and `PROOF_GUARDED_EXTRA` as contract paths.

2. `proof_exec` does not `cd` to `PROOF_ROOT` (`scripts/lib/proof.sh`). The caller's cwd stays the live checkout, so a clone whose root is only passed as `PROOF_ROOT` never runs the mutated tree: writes to the live tree are denied (baseline red, every mutation skipped) or the live tree is what gets proved (every mutation survives). Caches make this worse. `CARGO_HOME`, npm, uv, and pip sit in `PROOF_TMP` under `runs/`, which the profile denies except for this invocation's `--tmp`, and `proof_network` defaults to none, so a fresh temp cannot refill them. Step 4 also never passes `PROOF_DEPS`, `PROOF_NETWORK`, or `PROOF_WALK`. **Fix:** run `cd "$clone" && $PROOF` with the captured proof command, the goal's network and deps, and a per-run `--tmp` that is a copy-on-write copy of the original proof temp.

3. Assumption 4 is wrong. `lib/verdict.py` returns MISSING when any earlier line parses as a different token, and `verdict_of_line` strips a leading diff marker before matching. A context line such as ` - VERDICT: FIX — …` (this repo's reviewer prompt and tests) makes a genuine DONE or FIX become MISSING inside `claude-goal-review.sh`, before the DONE route exists. The resume prompt is a second string and never asks for blocks, so a DONE after a fix round, the common case, records nothing. **Fix:** strip a size-capped mutation region in the launcher before `verdict_of`, in both prompts, and keep raw diff bytes out of the file `verdict.py` scans.

4. Reviewer diffs are untrusted (an implementer can prompt-inject the reviewer) but the plan never defines the path grammar. A block is allowed to touch any `BASE_SHA..HEAD` path, which includes the journal. Checking only the `a/` path lets `rename to`, `+++`, an absolute path, or `..` write a contract file or leave the clone; mode `120000` turns an allowed path into a symlink so the proof reads the unmutated file and "survives". **Fix:** accept only regular-file hunks whose every `a/`, `b/`, rename, and `+++`/`---` path canonicalizes to an implementer-changed non-contract file inside the clone, and reject symlink and gitlink modes.

5. "Green" here is not the host's green. The host also treats output containing `Ran 0 tests` and any `proof_moved` change as failure (`run-goal.sh` around the proof exit check), while a timeout is a stop, not a catch. The plan folds timeout into `caught`, so a slow or empty run journals `caught=N` and the oracle looks fine. `mutations` is not in `EVENTS` in `scripts/events.py`, and `events_append` swallows the error, so the warning event never lands. **Fix:** score with the host predicate, record `timeout` outside `caught`, add `mutations` to `EVENTS` (not `TERMINAL`), and emit it before the `done` or `phase integrate` event.

6. `CW_MUTATION_GAPS=stop` wakes `oracle-gap` and leaves the goal `in_progress`. Resume ignores that wake and dispatches the implementer again (`resume-state.py` only special-cases `proof-red`). An Architect who edits the oracle first is refused by the contract-drift gate. A `cp -c` failure or a non-numeric `CW_MUTATIONS` under `set -e` takes the same path, and in `--jobs` a stop recuts the goal from the wave base. Walk-end also cannot learn survivors from member stdout. `check_result` only accepts `reviewed=` and `done=`. **Fix:** make mutation failure best-effort (skip and still done) except in stop mode, and make `oracle-gap` resume re-run only the kept diffs against an accepted oracle edit, with the parallel walker printing survivors from the committed journal line.

VERDICT: REVISE


### Architect's response

All six taken. (1) The clone has no .git; diffs applied by an unpinned git in a subshell, no --unsafe-paths; the journal, GOALS.md and PROOF_GUARDED_EXTRA are contract paths. (2) The command is cd <clone> && <proof>; the goal's PROOF_NETWORK and PROOF_DEPS, no PROOF_WALK, a per-run --tmp copied copy-on-write from the goal's proof temp. (3) The launcher cuts the MUTATION blocks into MUTATIONS_FILE (64 KB cap) before verdict_of and the FIX parsing; both prompts ask for them. (4) A strict diff grammar: plain edits of existing regular files only, the same path on --- and +++, no rename/copy/mode/new/deleted/binary/symlink/gitlink, no quoted or absolute paths or ..; every path a changed non-contract file. (5) Scoring by the host's predicate factored out; timeout its own count; a red only for tree changes or no tests is a skip; mutations added to EVENTS (not TERMINAL), written before done. (6) Best-effort: machinery failures are skips and the goal is still done; CW_MUTATIONS validated at start; CW_MUTATION_GAPS=stop now stops the walk after the goal lands (serial after the goal, parallel after the wave's integrations, from the committed record), so nothing is left in progress; walk-end reads the committed journal. This changes Q2's strict mode detail: reported to the user.

## Round 2 — Grok

I'll re-read the revised plan and check it against the host code the earlier findings depended on.The revision closes the last round’s holes on paper. I’ll check the ones that depend on how git, the proof sandbox, and walk-end actually behave.The revision closes the six earlier holes: the pinned work tree, `proof_exec`'s cwd and caches, the event allowlist, a FIX resume that never asked for mutations, and an `oracle-gap` stop that left the goal `in_progress`. Four of those closures still fail on the host as it is.

1. The grammar rejects the diff it asks for. A block may contain only `--- a/<p>`, `+++ b/<p>`, and hunks, and any `index … <mode>` line is rejected. The reviewer's `DIFF_FILE` is `git diff` (`run-goal.sh`), whose every file starts with `diff --git` and `index <sha>..<sha> 100644`, and often `\ No newline at end of file`. Those blocks are all skipped, so the check never runs. **Fix:** accept that ordinary `git diff` header, including `index … 100644`, and reject an index line only when the mode is not `100644`.

2. Deleting `.git` makes the host's green predicate measure the wrong tree. `tree_snapshot` calls `git()`, and in `--jobs` that pins `GIT_WORK_TREE` to the live worktree (`git-guard.sh`), so `git status` refreshes the live index while the clone is never what is compared. A proof that needs `git` is baseline-red and every mutation is skipped. `command git apply` with no `.git` still walks up to a parent repo and, inside one, applies paths against that work tree. **Fix:** put the clone outside every work tree, give it a private git dir (`command git` with `GIT_DIR` and `GIT_WORK_TREE` set to the clone only), point the factored predicate at that pair, and `lstat` each destination so an existing symlink is rejected before apply.

3. Cutting on fences puts verdict lines back in front of `verdict.py`. The block format is a markdown fence, and a diff of a markdown file contains a ``` line, so the cutter stops early and a context line ` - VERDICT: FIX` still makes the reply MISSING. The 64 KB cap is described as cutting "the reply", which drops a verdict that sits past the cap and stops the walk. **Fix:** lift out the span from the first `^MUTATION:` line through the line before the last `^VERDICT:` line, cap only that span, and if it is over 64 KB discard the span and still verdict the rest.

4. `CW_MUTATION_GAPS=stop` cannot carry on. The walker is told to stop from mutation records since `walk-start`. `walk_stop` exits without `events_end_walk`, and `ensure_walk` reuses a walk id while the journal still mentions it (`events.py`). The next run sees the same survivors and stops again, so a strict walk never reaches a later goal. Separately, a mutation that is red only for `Ran 0 tests` is skipped, so the host's own fake-green check never counts as caught and never warns. A timed-out proof usually also leaves a dirty tree, and the tree rule is listed as a skip. **Fix:** stop only on survivors written after this invocation's start (or end the walk id so the rerun mints a new `walk-start`); treat `Ran 0 tests` as caught; classify sandbox-stop, then timeout, then exit status, before the tree check. Build the event payload with a JSON encoder: `events.py` drops a `--payload` that is not valid JSON, and a `"` in the rule drops the names.

VERDICT: REVISE


### Architect's response

All four taken. (1) The grammar accepts git diff's own header (diff --git, index <sha>..<sha> 100644, \ No newline) and rejects index lines with any other mode. (2) The clone gets a private git dir (git init + a baseline commit), every git on it is command git with GIT_DIR/GIT_WORK_TREE set to the clone only, in a temp folder outside every work tree; the host predicate is factored to take the tree to judge; each destination lstat-ed, a symlink rejected. (3) The cut is the span from the first ^MUTATION: line to the line before the last ^VERDICT: line; the 64 KB cap is on that span, dropped whole if larger, the verdict still read. (4) Strict mode counts only records written in this invocation; scoring order sandbox stop, timeout, exit status or Ran 0 tests (caught), tree change (skip), else survived; the event payload JSON-encoded. Tests added for each.

## Round 3 — Grok

I'll read the revised plan and check the four remaining holes against the host code.The last round’s cutter, the stop window, the timeout order, and the JSON payload are specified correctly. Three leftovers in the new clone procedure will still skip the check or touch the live repo.

1. `git init` on the copy is not a private git dir. In `--jobs` the copied `.git` is a gitfile pointing at the live admin directory, and `git init` reinitializes that existing directory instead of creating one. The next host `git()` then sees a changed git dir, taints itself, and the done commit never lands. On a serial checkout the copied `.git` is already a full repo, so the required extra commit exits with nothing to commit and every mutation is skipped as machinery failure. The proof bullet still says the clone has no gitdir, which contradicts the private dir the snapshot needs. **Fix:** unlink the copied `.git` entry without following a gitfile, then `git init`, `git add` the non-ignored files, and `git commit --allow-empty` with `command git -c core.hooksPath=/dev/null -c user.email=mutation@local -c user.name=mutation`, `GIT_DIR` and `GIT_WORK_TREE` set to the clone only.

2. The grammar allows only `index … 100644`. `git diff` writes `index <sha>..<sha> 100755` for every executable it leaves executable, and this house’s goals are mostly shell. Those blocks are rejected and the check does not run. **Fix:** allow `100644` and `100755`, and reject only `120000`, `160000`, and `old mode`/`new mode`.

3. The test list contradicts the scoring rule. The scoring section counts `Ran 0 tests` as caught and classifies a dirty timeout as `timeout`, but the tests still say “one that runs no tests is skipped.” A block placed after the verdict is also still in the reply: the lift only removes the span before the last `VERDICT:` line, so a trailing diff makes `verdict_of` return MISSING and the walk stops on a goal that was done. **Fix:** delete the stale “no tests → skipped” test, and also drop a `MUTATION:` span that sits after the verdict line.

VERDICT: REVISE


### Architect's response

All three taken. (1) The copied .git entry is removed without following it, then git init, add -A and commit --allow-empty with hooks off and a fixed identity, git pointed at the clone only; PROOF_WALK is the clone's private git dir; a test that the live git dir is unchanged, gitfile and full .git both. (2) index lines may name 100644 or 100755; 120000/160000 and mode lines rejected. (3) The stale "no tests -> skipped" test removed; a MUTATION: span after the verdict line is dropped, with a test.

## Round 4 — Grok

I'll read the revised plan and check the three leftover holes against the host.The three leftovers from last round are closed: the copied `.git` is unlinked before `git init`, executable `100755` diffs are accepted, and a `MUTATION:` span after the verdict line is dropped. Two new holes in that procedure will stop or silently skip the check.

1. The baseline `git commit --allow-empty` has no message. With no `-m`, Git opens `core.editor` and the walk waits on `vi`, or the commit aborts when there is no terminal and every mutation is skipped. The clone's `command git` also omits the wrapper's `-c commit.gpgSign=false` and `-c core.fsmonitor=false` (`scripts/lib/git-guard.sh`), so a signing key hangs the same commit and a configured fsmonitor runs during `git add` and the snapshot. **Fix:** commit with `-m baseline` and pass those two `-c` flags on every clone `command git`, including the factored predicate.

2. The cutter anchors on a line that literally starts with `VERDICT:`, while `lib/verdict.py` accepts that line with emphasis, backticks, or a list marker. A final line `**VERDICT: DONE**` is a real DONE, the diff is left in the reply, and a context line ` - VERDICT: FIX` makes `verdict_of` return MISSING, which stops the walk. **Fix:** choose the span's end with the same line normalization `verdict.py` uses, then drop the mutation span.

VERDICT: REVISE


### Architect's response

Both taken. (1) The baseline commit has -m baseline; every clone git (the predicate's snapshot included) carries the wrapper's commit.gpgSign=false and core.fsmonitor=false besides hooksPath and the identity; a test with gpgSign on and no terminal. (2) The cut finds the verdict line with verdict.py's own normalization, so **VERDICT: DONE** ends the span; a test.

Correction (2026-10-23T21:02:28Z): the plan edit for round 4 failed on an anchor when the response above was logged, so the round-5 launch reviewed the unchanged plan and was stopped before it reported. The edits are now made as described; round 5 is relaunched on the revised plan.

## Round 5 — Grok

The last review left two holes: the baseline commit can hang, and the verdict cutter is stricter than `verdict.py`. I'll read the revised plan and check both.The last round’s two holes are closed. The baseline commit is `git commit --allow-empty -m baseline` with signing and fsmonitor turned off, and a final `**VERDICT: DONE**` counts as the verdict line.

One hole remains in how that line is chosen. `verdict_of_line` in `lib/verdict.py` strips emphasis and then a list marker, so a unified-diff context line ` - VERDICT: FIX — …` is a verdict. The cutter now finds the verdict with that same normalization. A block placed after the real verdict, whose diff includes that context line, makes the context line the last match. The real `**VERDICT: DONE**` is not the anchor, the diff stays in the reply, and `verdict_of` returns MISSING. The new tests cover a bold last line and a trailing block separately, so this combination still stops a finished goal.

**Fix:** drop any suffix that starts with a `MUTATION:` line before choosing the verdict, and never treat a diff line (first character space, `+`, `-`, `\`, or `@`) as the verdict line even after normalization.

VERDICT: REVISE


### Architect's response

Taken: a MUTATION: suffix after the last non-diff verdict line is dropped first, and a line starting with a diff marker is never the verdict line; a test for the combination (bold verdict, a trailing block with a context line). MAX_ROUNDS reached without APPROVED: this last change has not been reviewed by Grok. To the user.

## Round 6 — Grok (extra round, the user's choice)

I'll re-read the revised plan and check the verdict-anchor fix against the host code.The prior hole is closed for a bold final line. A trailing mutation whose only verdict-shaped lines are diff context lines is dropped, and the new test covers that combination. Two anchors still make `verdict.py` return MISSING, and `run-goal.sh` then wakes `missing-verdict`, so a finished goal stays in progress.

`verdict_of_line` deletes `*` and backticks, strips, then strips one leading `[-*+]\s+` marker. A final `- VERDICT: DONE` or `+ VERDICT: DONE` is therefore a real verdict. The plan says a list marker counts, and also says a line whose first character is `-` or `+` is never the verdict line. Those two rules cannot both be applied. With a mutation diff that contains a context line ` - VERDICT: FIX`, the cutter finds no verdict line, the diff stays in the reply, the earlier line parses as FIX, and the last line parses as DONE.

A trailing `MUTATION:` suffix is dropped only after the last non-diff verdict line. A plain `VERDICT: FIX` or `**VERDICT: FIX**` inside that suffix is that line, so the suffix is kept and the real verdict is no longer the reply's last line.

**Fix:** Before any verdict scan, delete a tail that starts at a `MUTATION:` line whenever the last line `verdict_of_line` accepts lies in that tail and an earlier accepted line lies above it, and repeat. The verdict is the last accepted line that remains, including `- VERDICT: DONE` and `+ VERDICT: DONE`. Ignore a diff-marker line only inside a mutation span. Test both triggers together: a final `- VERDICT: DONE`, a diff context line ` - VERDICT: FIX`, and a trailing block that itself contains a line `VERDICT: FIX`.

VERDICT: REVISE


### Architect's response

Not patched again: rounds 2 to 6 each found a new hole in cutting the mutation blocks out of the verdict reply. Redesigned with the user: after a DONE verdict, run-goal.sh calls claude-goal-review.sh --mutations N --resume <SESSION_ID>, a turn of its own that returns only mutation blocks; the verdict reply is exactly today's, and the mutations reply never reaches verdict.py. A failure of that turn is a recorded skip, the goal still done. The cutter and its rules are removed from the plan; tests adjusted.

## Round 7 — Grok (checking the redesign)

I'll re-read the revised plan and check the verdict-anchor rules against the host parser.The cutter is gone; mutations are a second turn. I'll check that resume path against the reviewer script and the DONE route.The verdict-anchor hole is gone. The DONE reply is left as it is today, `verdict.py` and `findings.sh` read that reply only, and a later mutations turn covers both a first DONE and a DONE after a fix-round resume.

Two holes in the new turn will drop every real mutation.

The mode prints `MUTATIONS_FILE: <its raw reply>`. Launcher results are one line per key (`kv()` keeps the last `^KEY:` line). A unified diff spans many lines, so the value stops at the first newline and the patch never arrives. A later line of that reply shaped as `VERDICT:` or `CLAUDE_REVIEW_RESULT:` is parsed as a result key. The script's text path is `agent-result.py`, which replaces every tab with a space; `git apply` then misses tab-indented context and the block is skipped.

**Fix:** write the model's result text to its own file with tabs preserved, and print `MUTATIONS_FILE` as that path.

The prompt requires a ` ```diff ` fence around each diff. The grammar accepts a block only when the diff is nothing but `git diff` lines, and a fence line is not one of those. The new test checks that fences leave the verdict DONE, and never checks that a fenced block is accepted. A markdown hunk also contains fence lines, each prefixed by a diff marker.

**Fix:** treat a line that is exactly ` ```diff ` / ` ``` ` as the delimiter, parse only the interior, and test that prompted fenced form, including a hunk whose text contains a fence.

VERDICT: REVISE


### Architect's response

Both taken, both in the new turn's plumbing: (1) the mutations mode writes the raw result text (tabs kept, from the JSON result, not agent-result.py) to its own file and prints MUTATIONS_FILE as that path; (2) a block's diff is the interior between lines exactly ```diff and ```, a fence inside a hunk carrying its marker never ends it. Tests for both.

## Round 8 — Grok

I'll re-read the revised plan and check the mutations-file and fence rules against the host parser.The prior findings are addressed. The mutations turn writes the model's JSON `result` text to its own file with tabs intact and prints `MUTATIONS_FILE` as that path, and a block's diff is only the interior of a ` ```diff ` fence, so a hunk line that carries a diff marker does not close it. The tests cover a tab-indented apply, result-key isolation, and a fenced Markdown hunk.

The verdict reply stays on today's path. Clone setup, scoring order, the journal and event records, and the strict-walk offset are unchanged and still match the host scripts. The plan is sound enough to implement.

VERDICT: APPROVED


### Resolution

APPROVED in round 8 (5 rounds, one extra round chosen by the user, then a redesign the user chose after round 6 and two rounds checking it). To the user for sign-off.
