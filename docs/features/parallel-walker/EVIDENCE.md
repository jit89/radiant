# Evidence: parallel walker (house item 6)

## Step 0: measurements before any code (2026-10-15)

Setup: a throwaway repo, `~/dogfood/pw0`. The main checkout is on branch
`walk`, with two linked worktrees, `ga` on `cw/ga` and `gb` on `cw/gb`.
- **Versions:** git 2.54.0 (Apple Git-157), Claude Code 2.1.299, macOS
  Darwin 27.0.0.
- **How the probes ran:** each probe was one script, run once by Haiku 5.5
  (`claude -p --safe-mode`) from inside `ga`. The sandbox settings had the
  same shape as `claude-implement.sh`: `enabled`,
  `allowUnsandboxedCommands: false`, `failIfUnavailable`, no network, plus
  `sandbox.filesystem.denyWrite`.
- **Verification:** every result was checked again from outside the sandbox
  (`for-each-ref`, `ls -la`, file hashes).

### Recon (before the plan)

| Probe | Result |
|---|---|
| A commit from a sibling worktree and from a nested one, two passes at once, under the implementer sandbox | both committed |
| Writes from a worktree with no deny list | `.git/hooks`, `.git/config` and the main checkout's files refused; `.git/info`, `objects/`, `refs/heads/*`, another worktree's `worktrees/<name>/` allowed |
| `denyWrite` on a named file, a named folder, a path that does not exist | all refused |

### 0(a): the deny list against every bypass

The deny list, resolved from the main checkout:
- with `--git-path`: `HEAD`, `index`, `logs/HEAD`;
- under the common gitdir: `packed-refs`, `refs/heads/walk`,
  `logs/refs/heads/walk`, `refs/heads/cw/gb`, `logs/refs/heads/cw/gb`,
  `worktrees/gb`.

| # | Attempt from `ga` | Result |
|---|---|---|
| A01, A19, A22 | the goal's own commits on `cw/ga` | succeed |
| A02 | `git branch -f walk HEAD` | refused (by git: checked out in another worktree) |
| A03 | `git update-ref refs/heads/walk HEAD` | refused (EPERM on the reflog append) |
| A04 | `git update-ref refs/heads/cw/gb HEAD` | refused |
| A05 | `git update-ref -d refs/heads/walk` | refused |
| A06 | `git pack-refs --all` | refused ("error replacing packed-refs") |
| A07, A08 | overwrite the main `HEAD`, truncate the main `index` | refused |
| A09 | lock-and-rename by hand: write `walk.lock`, `mv` it onto `walk` | rename refused; **`walk.lock` was left behind** |
| A10, A11, A12 | `rm` the ref, `mv` it away, replace it with a symlink | refused |
| A13, A14 | rename the parent folders `refs/heads`, `refs` | refused |
| A15, A16, A17 | rename `worktrees/gb`, rename `worktrees`, write inside `worktrees/gb` | refused |
| A18 | rename the walk branch's reflog | refused |
| A20 | `git gc --auto` (forced with `gc.auto=1`) | rc 0; later commits fine |
| A21 | a full `git gc` | rc 0; it prints "failed to run pack-refs" and later commits are fine |
| A24 | commit in `gb`'s worktree | refused (`worktrees/gb/index.lock`) |

Every refs and admin file kept its hash, and `walk` and `cw/gb` stayed at
the base commit. **No bypass.**

### The `.lock` gap (A09)

A planted `<ref>.lock` is not a bypass. But a stray `walk.lock` makes the
walker's next update of `walk` fail with "File exists": a denial of
service, which stops the walk without merging anything wrongly.

**Second probe:** the deny list plus `<path>.lock` for every file in it.
- `walk.lock`, `cw/gb.lock`, `packed-refs.lock`, `HEAD.lock`, `index.lock`,
  `logs/refs/heads/walk.lock` and `worktrees/gb/index.lock` were all
  refused, and none was created.
- The goal's own commits still succeed.
- **But** with `packed-refs.lock` denied, **every** commit prints
  `error: Unable to create '…/packed-refs.lock': Operation not permitted`,
  even though it exits 0. In git 2.54 the ref transaction of a plain commit
  takes that lock.
- Turning off `maintenance.auto` and `gc.auto` (through `GIT_CONFIG_*`)
  does not silence it.
- `git branch -D` inside the sandbox fails outright.

The first probe, without `packed-refs.lock` in the list, showed no such
noise.

### 0(b): the shared object store under concurrency (no sandbox)

At the same time:
- `ga` and `gb` each made 60 commits in a loop;
- the main checkout added and removed 8 worktrees (`worktree add -b`,
  `worktree remove`, `branch -D`) and ran 9 `merge --no-ff`s (8 of them
  reset away).

No command failed. `git fsck --full` is clean. The commit counts are exact:
`cw/ga` 64, `cw/gb` 61, `walk` 3.

### Outcome

0(a) and 0(b) pass, so `--jobs` above 1 is not blocked.

**Proposed change to step 6's deny list, for the user to approve:**
- add `<path>.lock` for every denied file except `packed-refs`
  (`HEAD.lock`, `index.lock`, `logs/HEAD.lock`, the walk ref and reflog
  locks, each other member's ref and reflog locks);
- leave `packed-refs.lock` writable: denying it puts a false `error:` on
  every implementer commit, which is a trap for a model reading its own
  output;
- the walker checks, before each of its own git writes, that no
  `packed-refs.lock` (and none of the denied `.lock` paths) exists. If one
  does, it stops `git-lock-stray`, naming the file, and deletes nothing.

## Step 12: the first live parallel walk (2026-10-16)

The rbtree DAG of 2026-10-13 replayed in `~/dogfood/rbtree-par`, cloned at
`02f35a4`, which is the signed plan, goals and oracles before the sequential
walk. It ran `run-goals.sh --jobs 3` with real Haiku 5.5 implementers and Opus
5.5 reviewers, at house commit `68069f4`. C11 with CMake; no
`worktree_setup`, because the proofs build from scratch.

| Wave | Goals | Start → integrated (UTC) | Notes |
|---|---|---|---|
| 1 | g1-scaffold | 20:30:24 → 20:35:13 | review DONE r0 |
| 2 | g2-validate | 20:35:15 → 20:41:56 | review DONE r0 |
| 3 | g3-insert | 20:41:58 → 20:47:15 | review DONE r0 |
| 4 | g4-walk, g5-search, g7-teardown | 20:47:18 → all three finished 20:51:21; g4 integrated 20:51:49 | g5 and g7 stopped `merge-conflict` |

- **Every goal reviewed DONE on its first pass.** No fix rounds, no
  fallback.
- **Haiku cost:** g1 0.055, g2 0.175, g3 0.055, g4 0.036, g5 0.033,
  g7 0.045 USD (client-side estimates).
- **Integrations** (merge, merged proofs of every goal done in the walk,
  fast-forward) took 8–28 s each. The walker's overhead per wave was about
  2 s.
- **`join_wait`, wave 4:** g4 waited 46 s, g5 37 s, g7 0 s (the slowest).
  Waves 1–3 had one goal each.
- **Against the sequential walk** (2026-10-13, 33 min for 7 goals): the
  linear part g1–g4 took 21m27s here against 20m25s there. Wave 4 ran three
  goals in 4m03s, where the sequential walk spent about 11 min on g4, g5 and
  g7. Had they integrated, this DAG would have saved about 7 min.

**The stop.** g4, g5 and g7 each put their code in a new file, but each also
appended that file to the one `add_library(rbtree STATIC …)` line in
`CMakeLists.txt` and registered its test at the same place. g4 integrated
first; g5 and g7 conflicted on that line. The walker behaved as designed:
- the merge was aborted in a scratch worktree, kept as evidence;
- the walk branch was not moved and nothing was reset;
- both goals stayed recorded `finished` (reviewed);
- one combined stop listed both.

Handing them back would recut them, but they would conflict with each other,
and later with g6, on the same line. Shipped from this:
- the planning rule in GOAL-FORMAT.md, "Registration points": a harness that
  picks goal files up itself, or `conflicts_with`;
- a to-goals quiz question.

Logged for later:
- FUTURE-WORK item 17: an automatic recut after a merge conflict;
- item 18: `/walk` with no argument outside the target repo. The task list
  followed the walk correctly; `/walk ~/dogfood/rbtree-par` worked.

Not yet measured: a full parallel walk to the end. That needs a harness that
globs its sources and tests, per the new rule.
