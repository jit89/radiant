# Follow-up Review: Remaining Actionable Gaps

Review date: 2026-09-17  
Reviewed range: `02ddaad...00aa4d9`  
Parent audit: [`WORKFLOW-REVIEW.md`](WORKFLOW-REVIEW.md)

## Purpose

This document is the fix brief for seven issues that remain after the first
audit's implementation series. Each finding includes evidence, a safe
reproduction or inspection procedure, the required behavior, and a regression
test. A fix is complete when its acceptance criteria and regression test both
pass without weakening an existing check.

The following are outside this review because they were explicitly deferred:

- F-08: predictable temporary/cache names.
- F-09: the stale-lock race.
- F-10: log redaction.
- D-03: proof that particular tests actually ran.
- Proof network and container isolation.
- Recovery when a missed acceptance pin appears mid-goal.

D-02, D-04, D-05, and D-06 are excluded by product decision.

## Baseline

All 13 existing `scripts/tests/*-test.sh` scripts passed at `00aa4d9`.
Shell syntax and `git diff --check 02ddaad...HEAD` also passed. Some tests
currently encode behavior identified below as defective, so a green baseline
does not resolve these findings.

## F2-01 — P1 — Walker and signal paths can execute a model-written Git filter

### Evidence

`scripts/run-goals.sh` sources `lib/git-guard.sh`, but it never calls
`git_meta_init` or `git_meta_verify`. It performs `git add` and `git commit`
from `commit_goals` and `commit_journal`. The wrapper disables hooks,
fsmonitor, and signing; it does not disable clean filters from `.git/config`.

There is a second path in `scripts/run-goal.sh`: if INT or TERM arrives while
the implementer is running, `on_signal` stops the child and calls `write_stop`.
`write_stop` calls `git rev-parse` and `git status` before the post-implementer
metadata verification could run. `git status` can invoke a configured filter.

### Safe reproduction: walker path

This creates a temporary repository and a harmless filter that touches a
marker file.

```bash
house="$PWD"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cw-filter-review-XXXXXX")"
export HOME="$tmp/home" EVENTS_CACHE="$tmp/cache"
export GIT_AUTHOR_NAME=review GIT_AUTHOR_EMAIL=review@example.invalid
export GIT_COMMITTER_NAME=review GIT_COMMITTER_EMAIL=review@example.invalid
mkdir -p "$HOME" "$tmp/repo/docs/journal"
cd "$tmp/repo"
git init -q
cp "$house/scripts/fixtures/GOALS.mock.md" GOALS.md
sed -i.bak 's/status: ready/status: done/g; s/status: blocked/status: done/g' GOALS.md
rm GOALS.md.bak
printf '# Journal: mock\n' >docs/journal/mock.md
printf 'docs/journal/mock.md filter=reviewevil\n' >.gitattributes
git add GOALS.md docs/journal/mock.md .gitattributes
git commit -qm base

cat >"$tmp/filter.sh" <<EOF
#!/usr/bin/env bash
touch "$tmp/FILTER_RAN"
cat
EOF
chmod +x "$tmp/filter.sh"
git config filter.reviewevil.clean "$tmp/filter.sh"

"$house/scripts/run-goals.sh"
test -e "$tmp/FILTER_RAN" && echo 'REPRODUCED: host filter ran'
```

Observed at `00aa4d9`: `REPRODUCED: host filter ran`.

### Required fix

- Initialize and verify the persisted Git metadata manifest before every
  walker Git mutation.
- After a child or proof has run, verify metadata without invoking Git before
  any Git-derived stop diagnostics.
- A mismatch taints the process before `git status`, `git add`, `git diff`, or
  `git commit` can run.
- The walker emits a nonzero stop that names the changed metadata without
  executing configured hooks, filters, diff drivers, pagers, or helpers.

### Regression test

Extend `scripts/tests/git-guard-test.sh` or add a walker-specific test:

1. Install a clean-filter marker in `.git/config` after the saved baseline.
2. Run `run-goals.sh`; assert nonzero and marker absent.
3. Repeat by modifying the config inside a sleeping implementer, then signal
   `run-goal.sh`; assert marker absent and a metadata-tamper stop exists.

## F2-02 — P1 — The signed plan is not frozen or protected

### Evidence

`contract_drift` protects all of `GOALS.md`, `tests/acceptance/`, and the
file oracle. It does not include the path in the top-level `plan:` field.
Handoffs and review briefs tell both agents to read live `PLAN.md`.

An implementer can commit a plan edit. The host accepts the commit as an
implementation change, and the reviewer reads the edited plan while judging
that same diff. The original, user-signed contract is no longer the document
being applied.

### Safe inspection

```bash
rg -n 'CONTRACT_PATHS=|PLAN: PLAN.md|plan:' \
  scripts/run-goal.sh scripts/goals.py skills/to-goals/GOAL-FORMAT.md
```

At `00aa4d9`, `CONTRACT_PATHS` contains acceptance paths and the oracle but no
plan path. Both generated agent inputs name live `PLAN.md`.

### Required fix

- Read the plan path from `goals-base.md`, not from the current worktree.
- Require that path to exist in `BASE_SHA`.
- Export a frozen plan copy from `BASE_SHA` into the private run directory.
- Point both implementer and reviewer at that frozen copy.
- Treat committed, staged, unstaged, or untracked changes affecting the live
  plan as contract drift where applicable.
- Keep the plan path generic; do not assume the field always equals `PLAN.md`.

### Regression test

Add an integration case whose implementer commits a change to the configured
plan path. Assert:

- Review is never called.
- The stop reason is contract tampering.
- The original plan content is present in the frozen run artifact.
- A non-default `plan:` path receives the same protection.

## F2-03 — P1 — Proof-created untracked files bypass integrity checking

### Evidence

`tree_snapshot` uses:

```bash
git status --porcelain --untracked-files=no
```

The post-proof review patch is generated from `BASE_SHA..HEAD`, so it also
omits untracked files. A proof can create an untracked source file,
configuration file, executable, or symlink that affects the proof but never
appears in reviewer evidence. The file remains after DONE.

`scripts/tests/proof-test.sh` deliberately accepts `.cache-out/result.xml` and
`coverage.txt`. This broad allowance also conflicts with the next goal's fresh
tree gate, which rejects those same untracked files.

### Safe reproduction of the snapshot gap

```bash
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cw-proof-untracked-XXXXXX")"
cd "$tmp"
git init -q
git config user.name review
git config user.email review@example.invalid
printf 'tracked\n' >tracked.txt
git add tracked.txt && git commit -qm base

snapshot() {
  git rev-parse HEAD
  git status --porcelain --untracked-files=no
}

snapshot >before
printf 'unreviewed source\n' >generated.py
snapshot >after
cmp before after && echo 'REPRODUCED: snapshots are identical'
git status --short
```

Observed: snapshots are identical while `git status --short` reports
`?? generated.py`.

### Required fix

- Include untracked paths in the before/after proof snapshot.
- Define a narrow artifact policy. Preferred options are:
  - direct test artifacts to a private run directory outside the repository;
  - require project artifact directories to be ignored and remove newly
    created ignored artifacts after proof; or
  - use an explicit per-project allowlist with path and file-type checks.
- Treat new source, configuration, executable, symlink, and unknown file types
  as proof tampering.
- Leave the repository in a state accepted by the next goal's fresh-tree gate.

### Regression test

Extend `scripts/tests/proof-test.sh` with:

- untracked source file → `proof-tamper`, no review;
- untracked symlink → `proof-tamper`, no review;
- declared artifact → accepted, then cleaned or ignored so the next goal can
  start;
- undeclared coverage/cache output → deterministic stop rather than silent
  acceptance.

## F2-04 — P1 — Pre-existing GOALS and journal edits are committed as orchestrator work

### Evidence

Pathspec commits now preserve unrelated staged source. They still commit all
content at the specified path. Both orchestrators mutate and commit the
journal before the fresh-tree gate. The walker refreshes and commits GOALS
before a child checks cleanliness.

### Safe reproduction: dirty journal

```bash
house="$PWD"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cw-dirty-journal-XXXXXX")"
export EVENTS_CACHE="$tmp/cache"
export GIT_AUTHOR_NAME=review GIT_AUTHOR_EMAIL=review@example.invalid
export GIT_COMMITTER_NAME=review GIT_COMMITTER_EMAIL=review@example.invalid
mkdir -p "$tmp/repo/docs/journal"
cd "$tmp/repo"
git init -q
cp "$house/scripts/fixtures/GOALS.mock.md" GOALS.md
sed -i.bak 's/status: ready/status: done/g; s/status: blocked/status: done/g' GOALS.md
rm GOALS.md.bak
printf '# Journal: mock\n' >docs/journal/mock.md
git add GOALS.md docs/journal/mock.md
git commit -qm base

printf '\nUSER PRIVATE NOTE\n' >>docs/journal/mock.md
"$house/scripts/run-goals.sh"
git show HEAD:docs/journal/mock.md | tail -n 8
```

Observed at `00aa4d9`: `USER PRIVATE NOTE` appears in the orchestrator commit.
A valid user edit to GOALS can similarly be absorbed by `commit_goals`.

### Required fix

- Before the first workflow mutation, record and validate HEAD, index, and
  worktree state for GOALS and the journal.
- Fresh runs refuse pre-existing edits to either orchestration file.
- Resume permits only explicitly recognized in-flight workflow state.
- Before every orchestrator commit, verify the exact staged patch:
  - GOALS: only the expected status transitions;
  - journal: only the exact lines appended by this process.
- Preserve unrelated staged paths and same-file user changes without
  committing or overwriting them.

### Regression test

Extend `scripts/tests/orch-commit-test.sh` with staged and unstaged edits to:

- the journal before walk-start;
- a GOALS title/body before refresh;
- a GOALS status other than the expected refresh transition.

Every case must stop before committing, and the user's bytes and index state
must remain unchanged.

## F2-05 — P2 — Git metadata verification can block on special files

### Evidence

`git_meta_manifest` treats anything that is not a directory or symlink as a
regular file and opens it for hashing. A FIFO under `.git/hooks` blocks the
read indefinitely. Verification itself is outside `run_step`, defeating the
model/proof timeouts it is meant to guard.

### Safe reproduction

The Python subprocess timeout prevents the demonstration from hanging the
review shell:

```bash
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cw-git-fifo-XXXXXX")"
house="$PWD"
mkdir -p "$tmp/repo" && cd "$tmp/repo"
git init -q
mkfifo .git/hooks/review-fifo
python3 - "$PWD" "$house" <<'PY'
import subprocess, sys
repo, house = sys.argv[1:]
cmd = f'''
  cd "{repo}"
  source "{house}/scripts/lib/git-guard.sh"
  git_meta_init
  git_meta_manifest /tmp/review-git-manifest.txt
'''
try:
    subprocess.run(["bash", "-c", cmd], timeout=2, check=False)
    print("unexpected: verifier returned")
except subprocess.TimeoutExpired:
    print("REPRODUCED: verifier blocked on FIFO")
PY
```

### Required fix

- Use `stat.S_ISREG` before opening a path.
- Hash regular files only.
- Record directories and symlinks as today.
- Record FIFOs, sockets, block/character devices, and unknown types without
  opening them, then treat their presence as tampering.
- Handle permission and concurrent-removal errors as a failed verification,
  not an uncaught exception or hang.

### Regression test

Add FIFO, Unix socket, unreadable file, and concurrently removed-file cases to
`scripts/tests/git-guard-test.sh`. Every case must terminate promptly and fail
closed.

## F2-06 — P2 — File-oracle goals can omit their goal body

### Evidence

`skills/to-goals/GOAL-FORMAT.md` says each goal has exactly one
`## <id> — <title>` section. `validate_bodies` reports a missing section only
when `oracle: inline`. `scripts/tests/goals-body-test.sh` explicitly treats a
bodyless file-oracle goal as valid.

That goal's generated handoff lacks its deliverable, seams, case table,
out-of-scope limits, acceptance edits, and owned files.

### Safe reproduction

```bash
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cw-bodyless-goal-XXXXXX")"
cat >"$tmp/GOALS.md" <<'EOF'
# Goals
```yaml
plan: PLAN.md
journal: docs/journal/x.md
goals:
  - id: g1-file
    title: File oracle without body
    blocked_by: []
    conflicts_with: []
    area: core
    proof: true
    oracle: tests/acceptance/g1-file.sh
    status: ready
```
EOF
python3 scripts/goals.py "$tmp/GOALS.md" validate
```

Observed at `00aa4d9`: `OK 1 goals`.

### Required fix

- Require exactly one Markdown body for every goal, regardless of oracle type.
- Continue requiring an inline goal's body to contain its case-table oracle.
- Validate required labeled sections if the handoff depends on them:
  deliverable, seams, case table, acceptance edits, edits owned, out of scope,
  oracle, and proof.

### Regression test

Change the bodyless file-oracle fixture to expect `INVALID`. Add one valid
file-oracle fixture and one duplicate-body fixture.

## F2-07 — P2 — `MAX_FIX_ROUNDS` permits one fewer repair pass than documented

### Evidence

README defines `MAX_FIX_ROUNDS` as the number of implement/review fix rounds.
When review returns FIX, `run-goal.sh` increments `ROUND` and immediately wakes
when `ROUND >= MAX_FIX_ROUNDS`.

Therefore:

- `MAX_FIX_ROUNDS=1` permits zero repair implementations.
- The default `MAX_FIX_ROUNDS=3` permits repair rounds 1 and 2, then stops
  before repair round 3.

Pending-FIX resume repeats the same accounting. The current resume-state test
codifies the defect by requiring the cap to rise from 1 to 2 before repair
round 1 dispatches.

### Safe reproduction

```bash
rg -n 'MAX_FIX_ROUNDS|ROUND=\$\(\(ROUND \+ 1\)\)' \
  README.md scripts/run-goal.sh scripts/tests/resume-state-test.sh
scripts/tests/resume-state-test.sh
```

Observe test case 4: cap 1 wakes with a FIX still pending; cap 2 is required to
dispatch the first repair.

### Required fix

Define the counter as completed repair implementations:

- Initial implementation/review is not a fix round.
- `MAX_FIX_ROUNDS=1` permits exactly one FIX handoff to be implemented and
  reviewed.
- A further FIX then wakes before a second repair implementation.
- Resume at a pending handoff preserves the same count.
- Raising the cap permits exactly the newly available number of passes.

The implementation can check the cap before incrementing/dispatching, or keep
a separate repair-pass count. Main-loop and resume checks must use the same
definition.

### Regression test

Update `scripts/tests/resume-state-test.sh` and add a normal-loop case:

| cap | expected repair implementations |
|---:|---:|
| 0 | 0 |
| 1 | 1 |
| 2 | 2 |
| 3 | 3 |

Exercise uninterrupted execution, interruption before repair, interruption
after repair implementation, and restart at the cap.

## Completion gate

The follow-up is complete only when:

1. Every finding above has a regression that goes red on `00aa4d9` and green
   on the fix.
2. All pre-existing tests still pass.
3. The two host-execution reproductions create no marker files.
4. The dirty GOALS/journal reproductions make no commits and preserve bytes and
   index state.
5. Both agents read the frozen plan artifact.
6. Proof-created repository files are either rejected or handled by an
   explicit artifact policy that leaves the next goal runnable.
7. `MAX_FIX_ROUNDS=N` executes exactly N repair implementations.
