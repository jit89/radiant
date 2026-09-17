# Third Follow-up Review: Remaining Actionable Gaps

Review date: 2026-09-18
Reviewed range: `4b9de8d...b1fdf45`
Parent audit: [`WORKFLOW-REVIEW.md`](WORKFLOW-REVIEW.md)
Prior fix briefs:
[`WORKFLOW-REVIEW-FOLLOWUP.md`](WORKFLOW-REVIEW-FOLLOWUP.md) and
[`WORKFLOW-REVIEW-FOLLOWUP-2.md`](WORKFLOW-REVIEW-FOLLOWUP-2.md)

## Purpose

This document records the remaining gaps after implementation of F3-01
through F3-05. It contains four behavioral findings and one maintainability
finding. Every behavioral reproduction uses temporary files or a disposable
repository and invokes no real model.

The following remain outside this review by explicit product decision:

- F-08: predictable temporary/cache names.
- F-09: stale-lock race.
- F-10: log redaction.
- D-03: proof of which tests actually ran.
- Proof network and container isolation.
- Recovery when an acceptance pin was missed during a goal.

D-02, D-04, D-05, and D-06 remain excluded as not actionable.

## Baseline

All 15 `scripts/tests/*-test.sh` scripts passed at `b1fdf45`. The Unix
socket case in `git-guard-test.sh` required execution outside the filesystem
sandbox so its socket fixture could be created. Shell syntax checks and
`git diff --check 4b9de8d...HEAD` also passed.

The existing tests do not cover the valid Git syntax and journal-state cases
below.

## F4-01 — P1 — A continued include path still bypasses the Git metadata guard

### Impact

The include graph is now fingerprinted for ordinary configuration syntax, but
Git accepts a value continued onto the next physical line. The handwritten
parser treats the first physical line as the complete path. Git and the guard
therefore resolve different include files.

An actor can mutate the real included config after the baseline, leave the
guard's invented missing path unchanged, and make the next guarded host
`git add` execute a changed clean filter.

### Evidence

`scripts/lib/git-meta.py:80-116` iterates over
`text.splitlines()`. It does not join a line ending in an unescaped
backslash with the next physical line before parsing `path = ...`.

For this valid configuration:

```ini
[include]
    path = extra\
.conf
```

Git reads `extra.conf`. The guard records a missing include named
`extra\`.

### Safe reproduction

Run with Bash from the workflow repository. The filter only creates a marker
inside a temporary directory.

```bash
set -euo pipefail
house="$PWD"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cw-config-continuation-XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME" "$tmp/repo"
cd "$tmp/repo"

command git init -q
command git config user.name review
command git config user.email review@example.invalid
printf 'subject.txt filter=probe\n' >.gitattributes
printf 'base\n' >subject.txt
command git add .gitattributes subject.txt
command git commit -qm base

printf '[filter "probe"]\n\tclean = cat\n' >.git/extra.conf
printf '\n[include]\n\tpath = extra\\\n.conf\n' >>.git/config
test "$(command git config --get filter.probe.clean)" = cat

source "$house/scripts/lib/git-guard.sh"
git_meta_init
git_meta_verify "$GIT_META_SAVED"

command git config --file .git/extra.conf filter.probe.clean \
  "touch '$tmp/FILTER_RAN'; cat"
git_meta_verify "$GIT_META_SAVED"
echo "verify exit: $? (incorrectly 0)"

printf 'changed\n' >subject.txt
git add subject.txt
test -e "$tmp/FILTER_RAN" &&
  echo 'REPRODUCED: continued include ran a changed host filter'
```

Observed: the second verification exits zero and guarded `git add` creates
the marker.

### Required fix

- Parse Git configuration as logical lines, including its exact backslash
  continuation rules, before extracting include values.
- Apply quote, escape, and comment handling after logical-line construction,
  in the same order Git does.
- Fail closed on a dangling continuation or syntax the guard cannot
  unambiguously interpret.
- Keep the verifier independent of Git execution.

### Regression test

Extend `scripts/tests/git-guard-test.sh` with:

1. a relative include split before the extension, as above;
2. an absolute included path split across lines;
3. a quoted continued value;
4. a dangling final backslash that fails closed.

For the valid cases, mutate the actual target after baseline and assert that
verification fails, guarded Git refuses, and the marker remains absent.

## F4-02 — P2 — Journal records are not bound to a complete goal/round lifecycle

### Impact

The new validator rejects loose text and explicitly foreign goal IDs, but it
does not require the expected goal to appear. It also recognizes roles rather
than valid state transitions. Consequently, malformed or fabricated records
can still be committed as workflow history and accepted during resume.

### Evidence

In `scripts/lib/orch-files.py:46-49`, the check is:

```python
named = set(GOAL_ID.findall(m.group(3) or ""))
if goal_id and named - {goal_id}:
    ...
```

An empty `named` set passes. There is no parsing of the round, action, or
previous record, and `REVIEWER` is accepted even though the reviewer does
not own this tracked journal protocol.

### Safe reproduction

```bash
set -euo pipefail
house="$PWD"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cw-journal-state-XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
printf '# Journal\n' >"$tmp/head"

check_case() {
  local name="$1" appended="$2"
  cp "$tmp/head" "$tmp/work"
  printf '%b' "$appended" >>"$tmp/work"
  if python3 "$house/scripts/lib/orch-files.py" \
      journal "$tmp/head" "$tmp/work" --records g1-store; then
    echo "REPRODUCED: $name was accepted"
  else
    echo "rejected: $name"
  fi
}

check_case missing-goal \
  '\n## 2026-09-18T00:00:00Z — IMPLEMENTER start\narbitrary injected body\n'
check_case end-before-start \
  '\n## 2026-09-18T00:00:00Z — IMPLEMENTER end g1-store\nnever started\n'
check_case fabricated-reviewer \
  '\n## 2026-09-18T00:00:00Z — REVIEWER invented g1-store\nuser-controlled note\n'
```

Observed: all three cases exit zero.

### Required fix

- Require every goal-scoped record to name exactly the expected goal.
- Define the complete allowed record grammar per role; do not accept an
  arbitrary action merely because its role is known.
- Bind records to the current round and validate lifecycle order, including
  duplicate, stale, and end-before-start transitions.
- At commit and resume boundaries, validate the expected transition from the
  committed journal state, not each heading independently.
- Remove `REVIEWER` from accepted tracked-journal roles unless a documented
  producer and lifecycle require it.
- If arbitrary implementer bodies must remain possible, store them in a
  private run artifact and commit only a structured record plus its hash.

### Regression test

Add negative cases for:

- missing goal ID;
- missing or stale round;
- unknown action;
- end before start;
- duplicate start/end;
- fabricated reviewer record; and
- a structurally valid record in the wrong lifecycle position.

Each must fail both direct validation and full resume before any launcher or
commit. Positive tests must cover the exact allowed sequence for initial and
repair rounds.

## F4-03 — P2 — Walker recovery can commit another goal's uncommitted record

### Impact

When any goal is `in_progress`, the walker changes its journal preflight to
`--records` without passing a goal ID. The validator then accepts records
for every goal. The walker copies that journal into `JOURNAL_EXPECT`, so its
next journal commit treats a foreign or future goal's record as baseline and
commits it.

This bypasses the stricter goal-scoped validation in `run-goal.sh`: by the
time the child starts, the foreign record is already in `HEAD`.

### Evidence

`scripts/run-goals.sh:78-85` checks only whether at least one goal is
`in_progress`, selects `--records`, and calls `orch_preflight` without
an expected goal. `scripts/tests/journal-records-test.sh` currently codifies
this as “walker mode takes any goal.”

### Safe reproduction

Run from the workflow repository. The copied `run-goal.sh` is replaced with
a stub, so no model is invoked.

```bash
set -euo pipefail
house="$PWD"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cw-walker-foreign-record-XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" EVENTS_CACHE="$tmp/cache"
export GIT_AUTHOR_NAME=review GIT_AUTHOR_EMAIL=review@example.invalid
export GIT_COMMITTER_NAME=review GIT_COMMITTER_EMAIL=review@example.invalid
mkdir -p "$HOME" "$tmp/house/scripts" "$tmp/repo/docs/journal"
cp -R "$house/scripts/." "$tmp/house/scripts/"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$tmp/house/scripts/run-goal.sh"
chmod +x "$tmp/house/scripts/run-goal.sh"

cd "$tmp/repo"
command git init -q
cp "$house/GOALS.example.md" GOALS.md
printf '# Plan\n' >PLAN.md
printf '# Journal\n' >docs/journal/example.md
command git add GOALS.md PLAN.md docs/journal/example.md
command git commit -qm base

base="$(command git rev-parse HEAD)"
python3 "$house/scripts/goals.py" GOALS.md set g1-store in_progress >/dev/null
printf '\n## 2026-09-18T00:00:00Z — ORCHESTRATOR dispatch g1-store r0 BASE_SHA=%s THREAD_ID=- SESSION_ID=-\n' \
  "$base" >>docs/journal/example.md
printf '\n## 2026-09-18T00:00:01Z — IMPLEMENTER start g2-ack\nforeign record\n' \
  >>docs/journal/example.md

"$tmp/house/scripts/run-goals.sh" >/dev/null 2>&1 || true
command git show HEAD:docs/journal/example.md |
  grep 'IMPLEMENTER start g2-ack' &&
  echo 'REPRODUCED: walker committed another goal record'
```

Observed: the foreign `g2-ack` record is present in the committed journal
while `g1-store` was the in-progress goal.

### Required fix

- Resolve the exact in-progress goal before accepting uncommitted recovery
  records and pass that ID to the validator.
- In a sequential walker, fail closed if zero or more than one goal is
  `in_progress` when uncommitted recovery records exist.
- Validate that the dispatch/base/round represented in the journal agrees with
  the selected goal's recoverable state before copying it to
  `JOURNAL_EXPECT`.
- Remove the test expectation that walker mode accepts any goal; add a
  positive case for the one current goal and negative foreign/future cases.

### Regression test

Repeat the reproduction with records for:

1. the single in-progress goal — accepted;
2. a blocked, ready, done, or nonexistent goal — refused and uncommitted;
3. two goals marked in progress — deterministic refusal; and
4. the correct goal but wrong base or round — refused.

## F4-04 — P2 — Contract drift detection does not classify index and worktree states precisely

### Impact

The original staged-contract bypass is closed: a staged change is detected.
However, the implementation does not meet the required diagnostic split
between staged, unstaged, and untracked state.

`CONTRACT_UNCOMMITTED` combines `git diff HEAD` with untracked paths.
`git diff HEAD` compares HEAD with the final worktree content, not index with
worktree. A purely staged edit whose worktree equals the index is therefore
reported both as staged and uncommitted, while untracked files have no
separate classification.

This matters because the stop message recommends different recovery actions
for index state, worktree edits, and new files.

### Safe reproduction

```bash
set -euo pipefail
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cw-contract-classification-XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
command git init -q
command git config user.name review
command git config user.email review@example.invalid
printf 'signed\n' >PLAN.md
command git add PLAN.md
command git commit -qm base

printf 'staged replacement\n' >PLAN.md
command git add PLAN.md

echo 'staged calculation:'
command git diff --cached --name-only HEAD -- PLAN.md
echo 'current uncommitted calculation also reports the same path:'
command git diff --name-only HEAD -- PLAN.md
echo 'actual index-to-worktree unstaged calculation is empty:'
command git diff --name-only -- PLAN.md
```

Observed: both the staged and current “uncommitted” calculations print
`PLAN.md`, while the actual unstaged comparison prints nothing.

### Required fix

- Compute staged drift with `git diff --cached HEAD`.
- Compute unstaged drift with `git diff`, which compares index to worktree.
- Compute untracked drift with `git ls-files --others --exclude-standard`
  into its own field.
- Keep ignored-under-contract separate as implemented.
- Render each category once with category-specific remediation.

### Regression test

Add isolated and combined cases for:

- staged only;
- unstaged only;
- untracked only;
- staged plus different unstaged content on the same path; and
- ignored untracked content below a protected path.

Assert exact categories as well as pre-dispatch refusal.

## F4-05 — Low — Contract drift state is a duplicated data clump

### Evidence

These variables travel together through collection, normalization, resume
checks, post-implementation routing, and proof reporting:

```text
CONTRACT_COMMITTED
CONTRACT_STAGED
CONTRACT_UNCOMMITTED
CONTRACT_IGNORED
```

Adding the staged and ignored states required parallel edits throughout
`scripts/run-goal.sh`. The proof message already has dense conditional
concatenation that can omit separators or category labels during the next
change.

### Safe inspection

```bash
rg -n 'CONTRACT_(COMMITTED|STAGED|UNCOMMITTED|IGNORED)' scripts/run-goal.sh
```

### Suggested improvement

- Centralize drift collection, “any drift” evaluation, and rendering.
- Use a small structured representation, such as an associative array keyed
  by `committed`, `staged`, `unstaged`, `untracked`, and `ignored`.
- Give each state one formatter and remediation string.
- Keep stop routing policy separate from Git-state discovery so a new category
  does not require synchronized string concatenation in several branches.

### Regression test

Retain behavior-level assertions for each category. Add a table-driven test
for the shared renderer so combined categories retain labels, separators, and
the correct remediation.

## Completion gate

This follow-up is complete only when:

1. Git and the guard resolve every supported continued include path to the
   same canonical target, and post-baseline mutations taint the guard.
2. Every accepted journal record names the expected goal and valid round and
   occupies a valid lifecycle position.
3. Walker recovery accepts records only for the one recoverable in-progress
   goal and cannot commit a foreign or future record.
4. Contract drift reports committed, staged, unstaged, untracked, and ignored
   state independently and accurately.
5. Every behavioral regression fails at `b1fdf45`, passes on the fix, and
   all pre-existing test scripts remain green.
