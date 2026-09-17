# Second Follow-up Review: Remaining Actionable Gaps

Review date: 2026-09-18
Reviewed range: `00aa4d9...4b9de8d`
Parent audit: [`WORKFLOW-REVIEW.md`](WORKFLOW-REVIEW.md)
Prior fix brief: [`WORKFLOW-REVIEW-FOLLOWUP.md`](WORKFLOW-REVIEW-FOLLOWUP.md)

## Purpose

This is the second fix brief after implementation of the seven findings in
the first follow-up. It records five independently reproduced implementation
gaps. Every command below uses a temporary repository or temporary files and
does not invoke a real model.

The following remain outside this review by explicit product decision:

- F-08: predictable temporary/cache names.
- F-09: stale-lock race.
- F-10: log redaction.
- D-03: proof of which tests actually ran.
- Proof network and container isolation.
- Recovery when an acceptance pin was missed during a goal.

D-02, D-04, D-05, and D-06 remain excluded as not actionable.

## Baseline

All 14 `scripts/tests/*-test.sh` scripts passed at `4b9de8d`, as did
shell-syntax checks. The current tests do not cover the edge cases below, so
the green baseline is not evidence that these properties hold.

## F3-01 — P1 — Included Git configuration can change a host-executed filter without detection

### Impact

The metadata guard detects a direct edit to `.git/config`, but not a config
file included by it. An included file can define or replace a clean filter; the
next guarded `git add` runs that filter as the host user even though
`git_meta_verify` reports no change. This is host code execution from content
the workflow made writable.

### Evidence

`scripts/lib/git-meta.py` fingerprints only:

```python
NAMES = ("config", "config.worktree", "hooks", "info")
```

Git's `include.path` and `includeIf.*.path` can name another file, including
one below the writable Git directory. The manifest neither enumerates nor
hashes it. It records a symlink's link text, but not the contents of its
target. Meanwhile `scripts/lib/git-guard.sh` keeps clean filters enabled;
disabling hooks and fsmonitor does not disable them.

### Safe reproduction

Run from the workflow repository. The filter only creates a marker in a new
temporary directory.

```bash
house="$PWD"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cw-config-include-XXXXXX")"
export HOME="$tmp/home"
mkdir -p "$HOME" "$tmp/repo"
cd "$tmp/repo"

git init -q
git config user.name review
git config user.email review@example.invalid
printf 'content\n' >subject.txt
printf 'subject.txt filter=reviewfilter\n' >.gitattributes
git add subject.txt .gitattributes
git commit -qm base

# The directly fingerprinted config is benign; its included target is not.
git config include.path "$PWD/.git/local-extra.conf"
git config --file .git/local-extra.conf filter.reviewfilter.clean cat

source "$house/scripts/lib/git-guard.sh"
git_meta_init
git_meta_verify "$GIT_META_SAVED"

command git config --file .git/local-extra.conf filter.reviewfilter.clean \
  "touch '$tmp/FILTER_RAN'; cat"
git_meta_verify "$GIT_META_SAVED"
echo "verify exit: $? (incorrectly 0)"

printf 'new content\n' >subject.txt
git add subject.txt
test -e "$tmp/FILTER_RAN" && echo 'REPRODUCED: included config ran a host filter'
```

Observed: verification exits zero and the marker is created by the guarded
`git add`. The same bypass works when the included file is a symlink and its
target changes while the link text does not.

### Required fix

- Fingerprint the effective, recursively resolved configuration-include graph,
  including applicable `includeIf` paths.
- Fingerprint the canonical target of protected symlinks, not just their link
  text.
- Fail closed on an include that cannot be safely resolved, changes location,
  escapes the protected set, or cannot be read. Rejecting unprotectable
  includes is an acceptable alternative.
- Preserve no-Git verification: do not discover the graph by running
  unguarded Git after establishing the baseline.

### Regression test

Extend `scripts/tests/git-guard-test.sh` with the reproduction and a
symlink-target variant. After the included target changes, guarded `git add`
and `git status` must fail, and the filter marker must be absent.

## F3-02 — P1 — Ignored files under `tests/acceptance/` bypass proof and contract fences

### Impact

The artifact policy accepts every ignored file as permissible proof output.
That includes an ignored script added under `tests/acceptance/`, even though
the entire directory is contract. A proof can create it, reach review, and
leave it present. It is absent from the contract-drift check, proof snapshot,
and review patch.

### Evidence

`tree_snapshot` uses `git status --porcelain --untracked-files=all`, which
does not list ignored files. `contract_drift` uses
`git ls-files --others --exclude-standard`, which also excludes them. Neither
sees an ignored, untracked `tests/acceptance/extra.sh`.

### Safe reproduction

Run from the workflow repository. It copies launchers to a temporary house and
replaces them with local stubs. The proof writes one ignored acceptance file.

```bash
house="$PWD"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cw-ignored-acceptance-XXXXXX")"
export HOME="$tmp/home" EVENTS_CACHE="$tmp/cache" REVIEWED="$tmp/reviewed"
export DEEPSEEK_API_KEY=stub GIT_AUTHOR_NAME=review GIT_AUTHOR_EMAIL=review@example.invalid
export GIT_COMMITTER_NAME=review GIT_COMMITTER_EMAIL=review@example.invalid
mkdir -p "$HOME" "$tmp/house/scripts" "$tmp/repo/docs/journal" "$tmp/repo/tests/acceptance"
cp -R "$house/scripts/." "$tmp/house/scripts/"

cat >"$tmp/house/scripts/deepseek-code.sh" <<'SH'
#!/usr/bin/env bash
printf 'implementation\n' >impl.txt
git add impl.txt && git commit -qm 'wip(g1-store): implementation'
printf '%s\n' 'DEEPSEEK_RESULT: ok' 'THREAD_ID: stub-thread'
SH
cat >"$tmp/house/scripts/claude-goal-review.sh" <<'SH'
#!/usr/bin/env bash
touch "$REVIEWED"
printf '%s\n' 'CLAUDE_REVIEW_RESULT: ok' 'SESSION_ID: stub-session' \
  'VERDICT: BLOCKED' 'VERDICT_FILE: /dev/null'
SH
chmod +x "$tmp/house/scripts/deepseek-code.sh" "$tmp/house/scripts/claude-goal-review.sh"

cd "$tmp/repo"
sed -e '/id: g1-store/,/status:/{
s|proof: true|proof: bash tests/acceptance/g1-store.sh|
s|oracle: inline|oracle: tests/acceptance/g1-store.sh|
}' "$house/GOALS.example.md" >GOALS.md
printf '# Plan\n' >PLAN.md
printf 'printf "new acceptance script\\n" >tests/acceptance/extra.sh\n' >tests/acceptance/g1-store.sh
printf 'tests/acceptance/extra.sh\n' >.gitignore
printf '# Journal\n' >docs/journal/example.md
git init -q
git add -A && git commit -qm base

"$tmp/house/scripts/run-goal.sh" g1-store >/dev/null 2>&1 || true
test -e "$REVIEWED" && echo 'REPRODUCED: reviewer was reached'
test -f tests/acceptance/extra.sh && echo 'REPRODUCED: ignored acceptance file remains'
git status --ignored --short tests/acceptance/extra.sh
```

Observed: the reviewer stub is reached and status shows
`!! tests/acceptance/extra.sh`. The file was neither rejected nor shown to
the reviewer.

### Required fix

- Treat every change below `tests/acceptance/` as contract drift regardless
  of tracked or ignored status and regardless of `.gitignore`.
- Make the proof snapshot distinguish ignored artifacts from ignored paths
  inside protected contract paths. A separate
  `git status --ignored --porcelain` snapshot is sufficient only if it is
  parsed with path and file-type checks.
- Retain the narrow artifact policy outside protected paths. A general ignore
  rule must not override a contract fence.

### Regression test

Add two proof tests:

1. Ignore `tests/acceptance/extra.sh`, create it during proof, and require
   `proof-tamper` with no reviewer.
2. Ignore a report outside protected paths and retain the accepted-artifact
   behavior.

Also test an ignored acceptance addition on resume; it must stop before
dispatch.

## F3-03 — P2 — Arbitrary appended journal text is accepted and committed as orchestrator work

### Impact

The first follow-up rejects edits that predate a run. Once a goal is live,
however, it accepts every appended byte in the journal. A concurrent user
edit, compromised child, or accidental note can be committed under an
orchestrator commit message. This loses journal provenance and permits
audit-record injection.

### Evidence

`scripts/lib/orch-files.py` defines `--append` as “HEAD, then anything” and
returns success for all appended content. `run-goal.sh` uses this mode in
`orch_commit` and `orch_commit_journal`, immediately before staging and
committing the journal.

### Safe reproduction

This calls the exact validator used by the commit path.

```bash
house="$PWD"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cw-journal-append-XXXXXX")"
printf '# Journal\n' >"$tmp/head.md"
cp "$tmp/head.md" "$tmp/work.md"
printf '\nUSER PRIVATE NOTE: do not commit this\n' >>"$tmp/work.md"

python3 "$house/scripts/lib/orch-files.py" \
  journal "$tmp/head.md" "$tmp/work.md" --append
echo "append validator exit: $? (incorrectly 0)"
```

Observed: the validator prints nothing and exits zero. The live path then
runs `git add -- "$JOURNAL"` and `git commit`, including the arbitrary
bytes in the orchestrator commit.

### Required fix

With a shared writable worktree, byte ownership cannot be proved after the
fact. A line grammar can improve validation but cannot prove provenance. The
design must establish a boundary:

- Prefer a private per-run event file for implementer output; the
  orchestrator copies only validated structured records into the tracked
  journal.
- Alternatively, keep the tracked journal orchestrator-only and put
  implementer notes in a hashed run artifact.
- At every commit, compare an exact expected journal transition, not merely a
  prefix. If implementer records remain tracked, bind their full structure to
  the goal, round, and lifecycle position.

### Regression test

Use a stub implementer that appends `USER PRIVATE NOTE` after dispatch and
otherwise returns a valid result. The run must stop before staging or
committing the journal, preserve its bytes and index, and not invoke review.
Include a positive case for the structured implementer journal protocol
chosen by the fix.

## F3-04 — P2 — A staged contract edit is hidden by restoring the worktree copy

### Impact

`contract_drift` claims to inspect staged and unstaged changes, but its
uncommitted comparison is only `git diff HEAD`. A child or user can stage a
replacement plan or acceptance file, then restore its worktree copy to
`HEAD`. Resume continues and dispatches an implementer although the index
still contains contract content that a later commit can publish.

### Evidence

```bash
CONTRACT_UNCOMMITTED="$(git diff --name-only HEAD -- "${CONTRACT_PATHS[@]}" || true)
$(git ls-files --others --exclude-standard -- "${CONTRACT_PATHS[@]}" || true)"
```

There is no `git diff --cached` (or explicit BASE_SHA-to-index) check. The
`GOALS.md` status check similarly compares only the worktree to the baseline.

### Safe reproduction

This builds the exact index/worktree state that the current calculation misses.

```bash
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cw-index-contract-XXXXXX")"
cd "$tmp"
git init -q
git config user.name review
git config user.email review@example.invalid
printf '# Signed plan\n' >PLAN.md
git add PLAN.md && git commit -qm base

printf '# Replacement plan\n' >PLAN.md
git add PLAN.md
git restore --worktree PLAN.md

echo 'what contract_drift currently asks:'
git diff --name-only HEAD -- PLAN.md
echo 'the staged contract edit it misses:'
git diff --cached --name-only HEAD -- PLAN.md
```

Observed: the first command prints nothing; the second prints `PLAN.md`.
A controlled resume with this state dispatched the second implementer call
instead of stopping for contract drift.

### Required fix

- Check all relevant states for every protected path: BASE_SHA → HEAD
  (committed), HEAD → index (staged), and index → worktree (unstaged).
- Compare `GOALS.md` status-only semantics against index and worktree, or
  reject any staged `GOALS.md` state not staged by this workflow.
- Name committed, staged, unstaged, untracked, and ignored-under-contract
  drift separately in the refusal so remediation preserves user work.

### Regression test

Extend `scripts/tests/resume-contract-test.sh` for the configured plan, the
goal's file oracle, another acceptance file, and `GOALS.md`:

```bash
printf 'tampered\n' >"$path"
git add -- "$path"
git restore --worktree -- "$path"
```

Every case must stop before the second launcher invocation and leave index and
worktree untouched by the workflow.

## F3-05 — P2 — Required implementer journal entries prevent crash recovery

### Impact

The implementation prompt requires an `IMPLEMENTER start` entry and an end
entry. A crash after the start but before the host commits the journal leaves a
legitimate in-flight state. The next run rejects it as an unknown user edit
before it can resume, defeating quota/crash recovery at a common boundary.

### Evidence

On an `in_progress` resume, `run-goal.sh` calls:

```bash
orch_preflight "$GOAL_ID=*:in_progress" --orchestrator-lines
```

`--orchestrator-lines` permits only blank lines and headings matching
`## <utc> — ORCHESTRATOR ...`. The prompt in `deepseek-code.sh` requires
`## <utc> — IMPLEMENTER start`, so an uncommitted required entry cannot pass
the resume preflight.

### Safe reproduction

Run from the workflow repository. The failure occurs before model dispatch;
the placeholder API value only passes configuration validation.

```bash
house="$PWD"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cw-resume-journal-XXXXXX")"
export HOME="$tmp/home" EVENTS_CACHE="$tmp/cache" DEEPSEEK_API_KEY=stub
export GIT_AUTHOR_NAME=review GIT_AUTHOR_EMAIL=review@example.invalid
export GIT_COMMITTER_NAME=review GIT_COMMITTER_EMAIL=review@example.invalid
mkdir -p "$HOME" "$tmp/repo/docs/journal"
cd "$tmp/repo"

cp "$house/GOALS.example.md" GOALS.md
printf '# Plan\n' >PLAN.md
printf '# Journal\n' >docs/journal/example.md
git init -q
git add GOALS.md PLAN.md docs/journal/example.md
git commit -qm base

base="$(git rev-parse HEAD)"
python3 "$house/scripts/goals.py" GOALS.md set g1-store in_progress
cat >>docs/journal/example.md <<EOF

## 2026-09-18T00:00:00Z — ORCHESTRATOR dispatch g1-store r0 BASE_SHA=$base THREAD_ID=- SESSION_ID=-

## 2026-09-18T00:00:01Z — IMPLEMENTER start
g1-store: beginning the requested implementation
EOF

"$house/scripts/run-goal.sh" g1-store >"$tmp/out" 2>&1 || true
rg 'not ORCHESTRATOR records|GATE:' "$tmp/out"
```

Observed: the run stops with a gate refusal for additions that are not
`ORCHESTRATOR` records. No implementer is dispatched.

### Required fix

- Define one durable journal protocol for every legitimate crash boundary,
  including implementer start/end records.
- Accept only the exact in-flight state for the target goal and round; do not
  broaden recovery to arbitrary appended text (F3-03).
- Couple the recovery parser to the prompt: a required record must be either
  committed before the boundary or explicitly accepted at resume.
- Refuse malformed, cross-goal, stale-round, and user-injected records.

### Regression test

Test resume after: dispatch only; dispatch plus a valid implementer start; and
dispatch plus valid start/end. Each must resume correctly. Repeat each with an
arbitrary appended line and with a start for another goal or round; those cases
must refuse before a launcher runs.

## Completion gate

This follow-up is complete only when:

1. An included-config or included-symlink-target mutation taints the Git guard
   before host Git can invoke its filter.
2. Ignored protected-path changes are rejected after proof and before resume.
3. Orchestrator commits have a defined journal provenance boundary, not
   arbitrary appended bytes.
4. Contract drift distinguishes committed, staged, unstaged, untracked, and
   ignored protected-path changes.
5. A crash after every documented journal checkpoint can resume, while
   arbitrary and cross-goal journal content fails closed.
6. Every regression fails at `4b9de8d`, passes with the fix, and all prior
   test scripts remain green.
