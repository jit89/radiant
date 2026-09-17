# Security and Correctness Review of `claude-coding-workflow`

Review date: 2026-09-17  
Reviewed revision: `02ddaad` (`feat: fork to claude-coding-workflow — Claude architects, Grok attacks`)

## Scope and method

This review covers the workflow contract, phase skills, host orchestrators,
model launchers, DAG parser, result parsers, event logging, and installation
checks in the current repository.

No live model or provider API was called. Reproduction scripts use extracted
repository functions or temporary Git repositories. They do not modify the
reviewer's working tree. Findings marked **Reproduced** were executed during
the review. Findings marked **Reasoned** follow directly from the named code
path but were not exploited, generally because doing so would execute
untrusted code or expose credentials.

Severity convention:

- **P1:** fix before unattended use; can violate repository integrity,
  security boundaries, or the workflow's core contract.
- **P2:** significant reliability, recovery, or defense-in-depth defect.

## Executive assessment

The workflow has sound intentions: separate planning, implementation, and
review roles; host-run acceptance checks; immutable-looking oracles; and
explicit stop states. The implementation does not yet enforce all of those
boundaries. In particular, model-authored code can reach host execution,
orchestration commits can absorb user changes, malformed prose can be treated
as approval, resume state is incomplete, and the protected contract is only
partially frozen.

Passing the current checks does not establish end-to-end safety. The findings
parser test, event self-test, example DAG validation, shell syntax checks, and
mock walk all passed during this review. The mock walk changes statuses
directly and does not exercise implement, assess, review, repair, interruption,
or recovery behavior.

## Reproduction setup

Run snippets from the repository root. They assume Bash, Python 3, and Git.
All temporary repositories are created with `mktemp -d`. Inspect them after a
run or remove the printed path manually.

The following baseline checks passed:

```bash
bash scripts/tests/findings-test.sh
python3 scripts/events.py --self-test
python3 scripts/goals.py GOALS.example.md validate
bash scripts/mock-walk.sh --quick
for script in scripts/*.sh scripts/lib/*.sh scripts/tests/*.sh; do
  bash -n "$script" || exit
done
```

## Findings

### F-01 — P1 — Writable Git metadata lets implementer code reach host execution

**Status:** Reasoned security path  
**Locations:** `scripts/deepseek-code.sh:179-197`,
`scripts/run-goal.sh:138-141`, `scripts/run-goal.sh:214-224`

The Codex sandbox receives the complete per-worktree and common Git directories
as writable roots. These contain hooks and configuration, not just the index
needed for commits. The host orchestrator later invokes `git commit` with hooks
enabled. An implementer can therefore write `.git/hooks/pre-commit`, and the
trusted host process will execute it outside the model sandbox.

This is intentionally not demonstrated by executing a hook. Reviewers can
confirm the path without running attacker-controlled code:

```bash
nl -ba scripts/deepseek-code.sh | sed -n '179,197p'
rg -n 'git commit' scripts/run-goal.sh scripts/run-goals.sh
git rev-parse --absolute-git-dir
git rev-parse --git-common-dir
```

**Fix:** keep Git metadata outside model-writable roots. Have a trusted host
stage and commit a declared file manifest. Run automated Git commands with
hooks disabled and controlled configuration, for example a trusted empty hooks
directory plus `GIT_CONFIG_NOSYSTEM=1` and an explicit config allowlist.

### F-02 — P1 — Host proof executes implementation-controlled code with host authority

**Status:** Reasoned security path  
**Location:** `scripts/run-goal.sh:479-501`

The proof command runs as `bash -c "$PROOF"` in the host environment after the
DeepSeek key has been loaded. Although the command text comes from the frozen
goal, its test runner, imports, package scripts, and configuration are all
implementation-controlled code. It can read inherited credentials, alter the
repository after the integrity checks, access the network available to the
host, or hang indefinitely. Unlike model calls, proof execution has no timeout.

Safe inspection:

```bash
nl -ba scripts/run-goal.sh | sed -n '422,505p'
rg -n 'DEEPSEEK_API_KEY|bash -c|run_timeout' scripts/run-goal.sh
```

**Fix:** execute proof in a restricted process/container with an environment
allowlist, network policy, read-only credentials, and a timeout. Recheck HEAD,
the index, worktree, oracle, acceptance tree, and contract after proof. Record
which tests actually ran rather than relying only on exit status and a single
`Ran 0 tests` string.

### F-03 — P1 — Plan approval can be inferred from quoted or contradictory prose

**Status:** Reproduced  
**Location:** `scripts/grok-review.sh:94-102`

The parser searches the whole response for the last occurrence of an approval
token. It does not require the verdict to be the final non-empty line.

Reproduction:

```bash
tmp="$(mktemp -d)"
sed -n '/^verdict_of() {/,/^}/p' scripts/grok-review.sh >"$tmp/fn.sh"
cat >"$tmp/verdict.md" <<'EOF'
The requested output includes VERDICT: APPROVED.
I found a critical flaw; do not implement this plan.
EOF
bash -c 'source "$1"; verdict_of "$2"' _ "$tmp/fn.sh" "$tmp/verdict.md"
# Observed: APPROVED
```

**Fix:** require exactly one schema-valid terminal verdict record. Prefer
structured JSON and reject extra, contradictory, or missing verdicts.

### F-04 — P2 — Goal review accepts a bare `DONE` without the required marker

**Status:** Reproduced  
**Location:** `scripts/claude-goal-review.sh:90-106`

`verdict_of` strips `VERDICT:` when present but never requires it. Any final
line beginning with `DONE`, `FIX`, or `BLOCKED` can be accepted.

Reproduction:

```bash
tmp="$(mktemp -d)"
sed -n '/^verdict_of() {/,/^}/p' scripts/claude-goal-review.sh >"$tmp/fn.sh"
printf '%s\n' 'DONE — merely a quoted example, not my verdict' >"$tmp/verdict.md"
bash -c 'source "$1"; verdict_of "$2"' _ "$tmp/fn.sh" "$tmp/verdict.md"
# Observed: DONE
```

**Fix:** require the complete terminal grammar, such as
`^VERDICT: (DONE|FIX|BLOCKED)( — .*)?$`, on the final non-empty line.

### F-05 — P2 — Review brief and findings parser specify incompatible formats

**Status:** Reproduced  
**Locations:** `scripts/run-goal.sh:506-518`, `scripts/lib/findings.sh:12-34`

The generated review brief asks for numbered findings of the form
`1. file:line — ...`. The parser accepts only lines beginning with `FIX:`.
A reviewer obeying the brief yields zero parsed findings and an avoidable
`fix-unparseable` wake.

Reproduction:

```bash
tmp="$(mktemp -d)"
cat >"$tmp/verdict.md" <<'EOF'
1. src/a.py:12 — off-by-one — adjust the upper bound
VERDICT: FIX
EOF
bash -c '
  source scripts/lib/findings.sh
  extract_findings "$1" "$2" "$3"
' _ "$tmp/verdict.md" "$tmp/findings" "$tmp/targets"
# Observed: 0
```

**Fix:** define one result schema used by the prompt, brief, parser, and tests.
Add an integration fixture produced from the exact generated brief.

### F-06 — P1 — TERM/INT can be converted into successful completion

**Status:** Reproduced  
**Location:** `scripts/run-goal.sh:71-83`, `scripts/run-goal.sh:252`

The same `on_exit` handler is registered for `EXIT`, `INT`, and `TERM`, and it
uses the previous command's `$?`. If a signal arrives after a successful
command, the handler can exit zero and omit the stop file. The walker treats
zero as success.

Minimal reproduction of the repository's trap pattern:

```bash
bash -c '
  on_exit() {
    local ec=$?
    trap - EXIT INT TERM
    exit "$ec"
  }
  trap on_exit EXIT INT TERM
  true
  kill -TERM $$
  exit 99
'
printf 'exit=%s\n' "$?"
# Observed: exit=0
```

**Fix:** use distinct signal handlers that terminate children and exit 130/143.
Keep the EXIT handler for ordinary nonzero exits only.

### F-07 — P2 — Missing protocol fields trigger `set -e` before error routing

**Status:** Reproduced  
**Locations:** `scripts/run-goal.sh:167-171`, `scripts/run-goal.sh:408-412`

`kv` returns the status of a `grep | tail | sed` pipeline. Under `pipefail`, a
missing optional field is nonzero. A command substitution assignment then
causes `set -e` to exit before the script reaches its explicit model-error
routing.

Reproduction:

```bash
tmp="$(mktemp -d)"
printf '%s\n' 'DEEPSEEK_RESULT: error' >"$tmp/out"
bash -c '
  set -euo pipefail
  kv() {
    local file="$1" key="$2"
    grep -E "^${key}:" "$file" | tail -n1 | sed -E "s/^${key}:[[:space:]]*//"
  }
  thread="$(kv "$1" THREAD_ID)"
  echo reached-explicit-error-handler
' _ "$tmp/out"
printf 'exit=%s\n' "$?"
# Observed: exit=1; marker is not printed
```

**Fix:** parse each launcher result once into a typed record. Explicitly
classify missing optional and required fields without relying on shell pipeline
status.

### F-08 — P2 — Predictable shared artifact names collide and can follow symlinks

**Status:** Reasoned  
**Location:** `scripts/deepseek-code.sh:395-397`

Return and report paths depend only on the handoff basename. Two repositories
using the same goal ID and round write the same files. The report is truncated
immediately; the return document may be stale. On systems with a shared temp
directory, pre-created symlinks create a clobbering path.

Safe derivation check:

```bash
handoff_a=/project-a/run-goal-g1-api/handoff-g1-api-r0.md
handoff_b=/project-b/run-goal-g1-api/handoff-g1-api-r0.md
printf '/tmp/deepseek-report-%s\n' "$(basename "$handoff_a")"
printf '/tmp/deepseek-report-%s\n' "$(basename "$handoff_b")"
# Both names are identical.
```

**Fix:** keep all files under a `0700` directory created with `mktemp -d`,
key caches by repository identity and run ID, and use exclusive creation.

### F-09 — P2 — Stale lock recovery can delete another waiter's new lock

**Status:** Reasoned race  
**Location:** `scripts/deepseek-code.sh:129-163`

Two waiters can read the same dead PID. Waiter A removes the stale directory
and acquires it; waiter B then executes its already-decided `rm -rf`, deleting
A's live lock. Both may proceed against shared Codex configuration.

Inspection:

```bash
nl -ba scripts/deepseek-code.sh | sed -n '123,166p'
```

**Fix:** use `flock` or an equivalent OS lock. A per-invocation configuration
directory also removes most shared mutable state.

### F-10 — P2 — Secret redaction is documented but unenforced

**Status:** Reasoned  
**Locations:** `CLAUDE.md:205`, `scripts/deepseek-code.sh:312-347`,
`scripts/deepseek-code.sh:380`, `scripts/deepseek-code.sh:482`

The contract says secrets are redacted from every handoff and log. Raw model
stdout/stderr is persisted, and error tails are printed verbatim. If a tool,
test, or provider response echoes a credential, it is stored and displayed.

Inspection:

```bash
rg -n 'redact|LAST_JSONL|stderr|tail -n' CLAUDE.md scripts
```

**Fix:** minimize inherited credentials, redact known secret values before
persistence/display, set restrictive permissions, and define artifact
retention. Do not treat filtering as a substitute for sandboxing proof code.

### F-11 — P1 — “Narrow” orchestrator commits absorb unrelated staged changes

**Status:** Reproduced  
**Locations:** `scripts/run-goals.sh:35-58`, `scripts/run-goal.sh:214-224`

The functions stage a named orchestration file but call unrestricted
`git commit`. Git commits every pre-existing staged path. This violates the
plan's requirements for narrow commits and no source auto-commit. It can occur
even when no goal needs to run, because walk-start is committed first.

Minimal reproduction of the faulty commit pattern:

```bash
tmp="$(mktemp -d)"
cd "$tmp"
git init -q
git config user.name reviewer
git config user.email reviewer@example.invalid
printf 'initial\n' >GOALS.md
printf 'original\n' >source.py
git add GOALS.md source.py
git commit -qm base

printf 'unrelated user work\n' >source.py
git add source.py
# Equivalent to commit_goals when refresh did not change GOALS.md:
git add -- GOALS.md
git diff --cached --quiet || git commit -qm 'chore: orchestrator refresh'
git show --pretty=format: --name-only HEAD
# Observed: source.py
```

The full walker was also tested in a temporary repository with all goals done;
its walk-start commit absorbed a pre-staged unrelated file.

**Fix:** fail before any mutation when the index or worktree contains
unapproved changes. Commit an explicit pathspec, and verify the staged diff is
exactly the expected orchestration mutation before committing.

### F-12 — P1 — Direct `/run-goal` can bypass unfinished blockers

**Status:** Code-path confirmed  
**Locations:** `scripts/run-goal.sh:288-299`, `scripts/goals.py:226-295`

The walker filters unfinished dependencies through `frontier`, but direct goal
execution trusts a goal marked `ready`. Validation checks reference existence
and cycles, not consistency between status and blockers. A stale or manually
edited `ready` status dispatches despite unfinished prerequisites.

Reproduction of the accepted inconsistent DAG:

```bash
tmp="$(mktemp -d)"
sed 's/status: blocked/status: ready/' GOALS.example.md >"$tmp/GOALS.md"
python3 scripts/goals.py "$tmp/GOALS.md" validate
python3 scripts/goals.py "$tmp/GOALS.md" show g2-ack
# Validation succeeds even though g2-ack can be ready with g1-store unfinished.
```

If fixture names change, make any blocked goal `ready` while leaving its
blocker unfinished and repeat the two commands.

**Fix:** independently verify every blocker is `done` at dispatch time.
Validation should reject status/edge inconsistencies as well.

### F-13 — P1 — Resume checks the frozen contract only after redispatch

**Status:** Code-path confirmed  
**Locations:** `scripts/run-goal.sh:339-367`, `scripts/run-goal.sh:422-457`

Resume rejects only unstaged oracle and acceptance changes before invoking the
implementer. It misses staged changes because `git diff --quiet` omits the
index. Committed drift from `BASE_SHA` is detected only during host assessment,
after another model invocation. The plan explicitly requires baseline
contract validation before trusting resumed state.

Safe Git behavior demonstration:

```bash
tmp="$(mktemp -d)"
cd "$tmp"
git init -q
git config user.name reviewer
git config user.email reviewer@example.invalid
printf 'oracle v1\n' >oracle.txt
git add oracle.txt && git commit -qm base
printf 'oracle v2\n' >oracle.txt
git add oracle.txt
git diff --quiet -- oracle.txt
printf 'worktree-check-exit=%s\n' "$?"
git diff --cached --quiet -- oracle.txt
printf 'index-check-exit=%s\n' "$?"
# Observed: worktree check 0, index check 1.
```

**Fix:** before dispatch compare `BASE_SHA`, HEAD, index, and worktree for the
entire frozen contract. Derive protected paths from the baseline snapshot.

### F-14 — P2 — Resume loses newly returned session IDs and pending fix state

**Status:** Code-path confirmed  
**Locations:** `scripts/run-goal.sh:234-247`, `scripts/run-goal.sh:369-410`,
`scripts/run-goal.sh:520-545`, `scripts/run-goal.sh:589-607`

Dispatch is journaled before launcher calls. Newly returned `THREAD_ID` and
`SESSION_ID` are not persisted until a later dispatch. A failure during the
first reviewer round therefore loses both available sessions. On process
restart, `FIX_HANDOFF` is initialized empty, so saved fix context is not
restored either.

Reproduction of what the current journal parser can recover:

```bash
tmp="$(mktemp -d)"
cat >"$tmp/journal.md" <<'EOF'
## 2026-09-17T00:00:00Z — ORCHESTRATOR dispatch g1-test r0 BASE_SHA=abc THREAD_ID=- SESSION_ID=-
EOF
sed -n '/^parse_last_dispatch() {/,/^}/p' scripts/run-goal.sh >"$tmp/fn.sh"
bash -c '
  source "$1"
  JOURNAL="$2"
  parse_last_dispatch g1-test
  printf "thread=%s session=%s round=%s\n" "$THREAD_ID" "$SESSION_ID" "$ROUND"
' _ "$tmp/fn.sh" "$tmp/journal.md"
# Observed: thread= session= round=0
```

**Fix:** atomically persist run state whenever an ID, verdict, or pending fix
becomes available. Use the journal as an audit trail rather than the sole state
database.

### F-15 — P1 — Contract comparison ignores most Markdown goal bodies

**Status:** Reproduced  
**Locations:** `scripts/goals.py:205-223`, `scripts/goals.py:433-450`,
`scripts/run-goal.sh:436-446`, `scripts/run-goal.sh:500-503`

`status-only-id` compares parsed YAML fences only. Markdown goal bodies can be
rewritten while it reports `OK`. The orchestrator separately checks the body
only for the current inline-oracle goal, while its review patch excludes all of
`GOALS.md`. Other goal bodies and file-oracle descriptions can drift without
appearing in reviewer evidence.

Reproduction:

```bash
tmp="$(mktemp -d)"
cat >"$tmp/base.md" <<'EOF'
# Goals
```yaml
plan: PLAN.md
journal: docs/journal/example.md
goals:
  - id: g1-store
    title: Store
    blocked_by: []
    conflicts_with: []
    area: store
    proof: true
    oracle: inline
    status: ready
```

## g1-store — Store
Original acceptance cases.
EOF
sed 's/Original acceptance cases/Rewritten acceptance cases/' \
  "$tmp/base.md" >"$tmp/changed.md"
python3 scripts/goals.py "$tmp/changed.md" status-only-id g1-store "$tmp/base.md"
# Observed: OK
```

**Fix:** freeze and hash the whole signed contract. Represent mutable status in
a separate state file, or compare the complete document while allowing only a
precisely located status field.

### F-16 — P2 — Goal-body lookup accepts identifier prefixes

**Status:** Reproduced  
**Location:** `scripts/goals.py:153-162`

The regular expression uses `\b` after the requested goal ID. A hyphen is a
non-word character, so requesting `g1-store` can match an earlier heading for
`g1-store-extra` and return the wrong contract body.

Reproduction:

```bash
python3 - <<'PY'
import runpy
g = runpy.run_path('scripts/goals.py')
text = '''## g1-store-extra — wrong
wrong cases

## g1-store — right
right cases
'''
print(g['goal_body'](text, 'g1-store').splitlines()[0])
PY
# Observed: ## g1-store-extra — wrong
```

**Fix:** require whitespace or end-of-line after the exact ID and reject
duplicate or missing body sections during validation.

## Design and reasoning weaknesses

These are workflow-level weaknesses. Some are faithfully implemented from the
current plan, so fixing code alone is insufficient.

### D-01 — Empty frontier is conflated with successful completion

`scripts/run-goals.sh:76-83` exits zero whenever the frontier is empty. That
state can also mean goals are bounced or permanently blocked. Report distinct
terminal states: completed, blocked, bounced, and invalid/deadlocked.

### D-02 — Model diversity is treated as independence

Different models can still share the same flawed plan, weak oracle, incomplete
diff, or misleading proof. Independent verification comes from separately
derived acceptance criteria and deterministic evidence, not model identity
alone. Retain role separation, but do not present it as proof of correctness.

### D-03 — An unchanged oracle file is treated as an unchanged test

Test discovery configuration, fixtures, imported helpers, environment, and
runner behavior can alter or suppress an acceptance test without editing its
file. `grep 'Ran 0 tests'` recognizes one framework-specific symptom only.
Require test enumeration or structured runner output proving that named cases
executed.

### D-04 — The acceptance oracle has no independent quality gate

The plan attacker runs before decomposition, while the Architect authors the
oracle afterward. A sound plan can become incomplete tests with no independent
mapping from requirements to cases. Add a review that traces every goal
requirement and risk to concrete positive and negative cases before dispatch.

### D-05 — Silence turns assumptions into contractual facts

`skills/crucible/SKILL.md:56-67` says unmarked assumptions are confirmed.
Silence is weak evidence for expensive or security-sensitive decisions. Use
implicit defaults only for cheap, reversible choices; require explicit consent
for load-bearing assumptions.

### D-06 — Strict TDD omits the refactor step

`scripts/deepseek-code.sh:430-437` mandates red/green work while forbidding
refactoring. This encourages duplication and brittle minimal patches. Permit
bounded refactoring after green, with the proof and full suite remaining green.

### D-07 — Deviation and blocker instructions conflict

`scripts/deepseek-code.sh:441` says deviations should be noted while work
continues. Lines 444-449 require stopping on ambiguity and unknowns. Define
which low-risk deviations are permissible and which require a bounce; otherwise
the implementer must interpret a contradictory policy.

### D-08 — `to-goals` never says who edits *existing* acceptance files

**Source:** observed in a live walk, not in the `02ddaad` code review above —
`~/prompt-tools` Week 4, 2026-09-17 (journal `docs/journal/week4-mock-tools.md`).  
**Locations:** `skills/to-goals/SKILL.md:50-66`, `skills/to-goals/GOAL-FORMAT.md:83-85`,
`scripts/run-goal.sh:426-456`

The skill and the format state the rule per goal: the Architect authors *the
goal's* oracle and the implementer does not edit *it*. The host enforces something
wider. `run-goal.sh:426-428` protects the goal's oracle **and the whole
`tests/acceptance/` directory**, and any committed change there since `BASE_SHA`
wakes `contract-tamper-committed` before review (`:449`).

The gap appears when a plan changes behaviour that **earlier goals' or earlier
weeks' acceptance files already pin**: a count, a field list, a signature, a
single-row query, a package list. Those edits are owed, but no step in `to-goals`
says who makes them or when. In Week 4 the Architect listed 24 of them in the plan
and assigned each to the implementing goal as "edits owned". The implementer made
them faithfully, and the host stopped the goal, correctly, as tampering.

Consequences observed:

- **Three of four wakes traced to this gap.** g4 was stopped as tampering after a
  correct implementation. g3 and g5 were BLOCKED by Opus on pinned lines no goal
  owned (a `pyproject.toml` package list, a whole-library count).
- **The "exhaustive" edit list was wrong five times** (24 → 27 edits, plus three
  single-row assumptions and a token width). Nothing in the skill requires a sweep
  of existing acceptance files, and the Architect's own sweep excluded a file by
  name.
- **Recovery is expensive and review-hostile.** After the Architect commits the
  edits, resuming the goal trips the same tamper guard, and a fresh dispatch
  reviews an empty diff. g4 had to be reset to `BASE_SHA` and re-implemented so its
  diff could be reviewed at all. g5 was marked `done` by hand on the reviewer's
  conditional DONE. Both are documented workarounds, not supported paths.

**Fix:**

1. **State the host's rule where the Architect reads it.** `SKILL.md` §4 and
   `GOAL-FORMAT.md`'s Oracle rules: the implementer may not change **any** file under
   `tests/acceptance/` — earlier goals' and earlier weeks' included — because the
   host guards the directory, not just the goal's oracle.
2. **Add a sweep step to §4.** Before writing `GOALS.md`, grep every existing
   acceptance file, with none excluded, for assertions the plan invalidates: exact
   counts, field and parameter lists, pinned lists or sets, `[0]` / `fetchone()`
   row picks, docstrings that say "until goal X". Apply every such edit **in Phase
   3, red, in the same commit as `GOALS.md` and the new oracles.**
3. **Goal bodies say "already applied — do not edit", never "owned",** for anything
   under `tests/acceptance/`. Only edits outside that directory (unit tests, config)
   are listed as the implementer's.
4. **Require a satisfiability note per pre-applied edit.** Where code exists that
   can satisfy it, run it against a scratch fix. Where it cannot exist yet, record
   what was measured (for example the loaded inventory) and that the rest is
   inferred.
5. **Optional host check:** `goals.py validate` warns when a goal body names a
   `tests/acceptance/` path under an ownership heading.

This is a narrower, evidenced instance of D-04: the oracle set has no gate, and
the *pre-existing* oracles a plan invalidates are not even in the Architect's
checklist.

## Recommended remediation sequence

1. **Close host execution boundaries:** remove model access to Git metadata,
   sandbox proof execution, control credentials, disable hooks, and add target
   repository locking.
2. **Protect repository state:** inspect dirt before any mutation, commit exact
   pathsets only, validate dependency gates, and freeze the complete contract.
3. **Make protocols typed and fail-closed:** one structured result format for
   verdicts/findings, strict terminal parsing, and explicit malformed-output
   handling.
4. **Make recovery transactional:** persist sessions and pending work at each
   transition; handle signals with nonzero statuses and process-group cleanup.
5. **Build realistic integration tests:** use fake launchers to cover staged
   user work, signals, timeouts, malformed output, oracle/index/HEAD drift,
   resume at every transition, blocked DAGs, empty test discovery, and
   concurrent runs.

## Suggested regression-test matrix

| Scenario | Required result |
|---|---|
| Unrelated staged source before walk | Refuse before any commit |
| `ready` goal with unfinished blocker | Refuse dispatch |
| Oracle changed in index, worktree, or HEAD | Refuse before model call |
| Quoted or bare verdict token | `MISSING` / protocol error |
| Numbered finding without `FIX:` | Contract test prevents format drift |
| TERM during each phase | Nonzero exit plus durable stop record |
| Missing launcher result field | Classified protocol error, not shell abort |
| Reviewer failure after new session ID | Resume same session |
| Process restart after FIX | Resume exact pending fix handoff |
| All remaining goals blocked/bounced | Nonzero/non-complete terminal state |
| Proof hangs | Timeout and process-group cleanup |
| Proof mutates repository | Post-proof integrity failure |
| Acceptance file unchanged but test undiscovered | Refuse DONE |
| Two concurrent repositories with same goal ID | No artifact/config collision |
| Goal IDs sharing a prefix | Exact body returned |
| Plan changes a count pinned by an earlier goal's acceptance file | Edit applied by the Architect before dispatch; implementer diff touches no `tests/acceptance/` path |

## Review totals

- 16 implementation/security/correctness findings: 8 P1 and 8 P2.
- 8 design and reasoning weaknesses (D-08 added from a live walk, not the code review).
- 11 implementation findings have an executable safe reproduction or direct
  behavioral demonstration in this document; potentially harmful exploit paths
  are documented for inspection without executing them.
