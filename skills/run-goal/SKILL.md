---
name: run-goal
description: Run one ready goal from GOALS.md — DeepSeek implements in Codex, Claude Opus 5 reviews until DONE. Use when the user says /run-goal, "implement this goal", "run the next goal", or after a signed-off DAG. Not for planning (/crucible), not for cutting the DAG (/to-goals), not for reviewing a plan (claude-review.sh).
---

# Run Goal — one slice, implement then review

Phase 4. One **ready** goal. DeepSeek (Codex harness) implements.
Claude Opus 5 **reviews** (not attacks) until `VERDICT: DONE` or a
bounce. The Architect (this session) orchestrates and never trusts a
reported green.

Launcher prompts are the rulebooks:
- `~/grok-coding-workflow/scripts/deepseek-code.sh`
- `~/grok-coding-workflow/scripts/claude-goal-review.sh`

Do not fork those prompts. Do not call `claude-review.sh` here — that
is the plan attacker.

## 1. Gate

- `GOALS.md` exists.
- The named goal exists and is `ready` (or the user named a `blocked`
  goal whose blockers are actually `done` — then flip it to `ready`).
- No goal id given → pick the first `ready` goal, confirm with the user.
- Implementer key: `DEEPSEEK_API_KEY` in the environment, target
  `.env`, or `~/grok-coding-workflow/.env`. Missing → stop and tell the
  user. Do not ask them to paste the key into chat.

Done when a single ready goal is chosen and the key is present.

## 2. Handoff

Write `/tmp/handoff-<goal-id>.md`. Reference by path; do not restate
PLAN.md or the goal body. Include:

- Goal id
- `PLAN.md`, `GOALS.md`, journal path
- Oracle path (or `inline`) — marked **read-only**
- Seams (copy the goal's Seams line — pre-agreed, headless)
- Proof command
- Out of scope
- `BASE_SHA` — `git rev-parse HEAD` **before** dispatch. Journal it.
- Suggested skills: `tdd` (rules are also in the launcher prompt)
- If this is a resume: Done = commits; Remaining = behaviors; resume
  from sha `<sha>`; do not redo passing tests

Redact secrets. Status via the DAG tool only:

```bash
~/grok-coding-workflow/scripts/goals.py GOALS.md set <id> in_progress
```

Done when the handoff file exists and `BASE_SHA` is in it.

## 3. Implement (DeepSeek in Codex)

From the **target repo**:

```bash
~/grok-coding-workflow/scripts/deepseek-code.sh /tmp/handoff-<id>.md
# later rounds, same Codex thread when you have it:
~/grok-coding-workflow/scripts/deepseek-code.sh --resume "$THREAD_ID" /tmp/handoff-<id>-fix.md
```

Foreground timeout **20 minutes** (1200000 ms).

Read `DEEPSEEK_RESULT:`:

- `ok` → assess (step 4), then review.
- `rate_limited` (exit 75) → recovery below. Do not hammer.
- `error` → inspect the printed LOG; decide resume vs. stop.

Capture `THREAD_ID` and `RETURN_HANDOFF`.

## 4. Assess (Architect, always)

Never treat a dispatch as successful without checking.

1. `git status`, `git log --oneline -15`, run the goal's `proof`
   yourself. Write the output to a file (e.g. `/tmp/proof-<id>.txt`).
2. Confirm the oracle is unmodified (`git diff` that path). A touch is
   a critical finding — restore it, do not review a gamed tree.
3. Salvage a dirty tail: read the (possibly partial) return handoff and
   `git diff`. Keep a sane partial or `git restore` to the last green
   commit. Never review a broken tree.

## 5. Review (Claude, reviewer prompt)

Write the diff the reviewer can actually Read (it has no `git`):

```bash
git diff "$BASE_SHA"..HEAD > /tmp/diff-<id>.patch
```

Write `/tmp/review-<id>.md`:

```
GOAL: <id>
PLAN: PLAN.md
GOALS: GOALS.md
ORACLE: <path|inline>
DIFF_FILE: /tmp/diff-<id>.patch
DIFF_RANGE: <BASE_SHA>..HEAD
PROOF_OUTPUT: /tmp/proof-<id>.txt
```

```bash
~/grok-coding-workflow/scripts/claude-goal-review.sh /tmp/review-<id>.md
# later rounds:
~/grok-coding-workflow/scripts/claude-goal-review.sh --resume "$SESSION_ID" /tmp/review-<id>.md
```

Timeout **10 minutes** (600000 ms). Same Claude session across review
rounds. Capture `SESSION_ID`.

Read `VERDICT:`:

- `DONE` — only accept if **your** proof is green and the oracle is
  untouched. Then:
  `goals.py GOALS.md set <id> done`. Journal. Stop for this goal.
- `FIX` — write a short fix handoff from the numbered findings.
  Re-dispatch DeepSeek (prefer `--resume THREAD_ID`). Increment the
  fix count. Leave status `in_progress`.
- `BLOCKED` — spec/oracle defect. Do **not** re-prompt DeepSeek.
  `goals.py GOALS.md set <id> bounced`. Journal. Stop.
- `MISSING` — treat as error; re-run or stop.

`MAX_FIX_ROUNDS` default **3**. After that, stop looping: the cut or
the spec is usually wrong. Escalate to the user.

## 6. Recovery (quota / mid-task death) — canonical

This section is the house recovery rulebook. AGENTS.md and README
point here; do not fork it there.

The implementer commits after every green test. Committed work is
intact. Only the in-flight (uncommitted) cycle is suspect.

1. **Assess** — `git status`, `git log`, proof. Do not assume.
2. **Salvage** — keep or restore the dirty tail. Never review broken.
3. **Wait** — exit 75 means the window has not cleared. Short retries
   already happened inside the script. Do not hammer. Tell the user
   (or schedule a wake) and keep the resume handoff.
4. **RESUME handoff** — you write it (the dead process can't): Done =
   commits; Remaining = behaviors; resume from sha; do not redo
   passing tests. Re-dispatch `deepseek-code.sh`. Prefer `--resume
   THREAD_ID` if you have one; otherwise a fresh exec with that
   handoff is enough (checkpoints live in git).
5. **Quota exhausted for the day** — stop and tell the user. Surface
   the block and the saved resume handoff. Do **not** fall back to
   another implementer model.

## Journal

```
## <UTC> — ARCHITECT dispatch|review|recover
## <UTC> — IMPLEMENTER start|end
## <UTC> — REVIEWER <DONE|FIX|BLOCKED>
```

## Hard rules

- One goal per invocation of this skill.
- Architect runs the proof. Claude's DONE is advice until then.
- Claude reviews code. Claude does not attack the plan here.
- DeepSeek implements. DeepSeek does not review itself.
- One goal per invocation. `/run-goals` walks the rest of the DAG.
- No provider fallback on quota death.
