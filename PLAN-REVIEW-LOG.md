# Plan Review Log: Host-loop Phase 4/5
Phases 0-1 (recon + interrogation) complete — plan locked with the user (prior turn accepted the host-loop design; remaining defaults Architect-locked). MAX_ROUNDS=5.

## Round 1 — Opus 5

SESSION_ID: `b26b0d23-611f-40a2-93dc-d36c6a458852`
VERDICT_FILE: `/var/folders/mc/nc97kyv53svctvg55rz0bl_w0000gn/T//claude-review-b26b0d23-611f-40a2-93dc-d36c6a458852-20260815T082006Z.md`

(full critique in that file; 21 findings.)

VERDICT: REVISE

### Architect's response

Taken: 1–3, 5–21.

- Dirty gate is now a **delta vs pre-dispatch snapshot**, with allowlisted journal + `GOALS.md` status-only + a small untracked-ignore list. (1, 2, 3)
- Contract read from `git show $BASE_SHA:GOALS.md`; inline body protected; non-status fence drift is a touch. (5, 6, 7)
- Non-command proofs (`true`, `(case table)`, empty, `inline`) are not exec'd. (8)
- `goals.py body` / `meta`; handoff includes verbatim body; journal named for implementer add. (9, 10)
- `in_progress` set after BASE_SHA. (11)
- Process-group timeouts in-script. (12)
- Subprocess + EXIT trap; no `exec`. (13)
- Verdict = last non-empty line; tighten `verdict_of`. (14)
- Unparseable FIX wakes, does not `bounced`. (15)
- Restore is checkout + `restore --staged`; record tamper sha. (16)
- `mktemp -d` 0700; per-round artifact names; fail on empty diff file. (17, 18)
- Narrow Orchestrator commit of `GOALS.md` + journal only. (19)
- Stop file + journal line richer. (20)
- Zero-commit repo fails the gate. (21)

Rejected: **#4 as the v1 vehicle** (per-goal disposable worktree). Parallel/disposable worktrees stay deferred in AGENTS.md. Delta-snapshot + "do not edit the target during a walk" is the cheaper fix. A worktree re-enters later as its own crucible.

## Round 2 — Opus 5

SESSION_ID: `b26b0d23-611f-40a2-93dc-d36c6a458852`
VERDICT_FILE: `/var/folders/mc/nc97kyv53svctvg55rz0bl_w0000gn/T//claude-review-b26b0d23-611f-40a2-93dc-d36c6a458852-20260815T082530Z.md`

VERDICT: REVISE (N1–N15)

### Architect's response

Taken: all of N1–N15.

- EXIT trap only on `rc != 0`; walker keys on exit code; stop file is payload. (N1)
- Gate: GOALS.md + file oracles tracked and clean vs HEAD. (N2)
- `PROOF: none` may review, never auto-`done` (`done-refused` wake). (N3)
- File oracle + non-command proof rejected at the gate. (N4)
- Journal `BASE_SHA`/`THREAD_ID`/`SESSION_ID`; resume reuses `BASE_SHA`. (N5)
- Clean tree at the gate (drop delta-snapshot). (N6)
- Drop hardcoded untracked-ignore list. (N7)
- Re-parse verdict only when `CLAUDE_REVIEW_RESULT: ok`. (N8)
- Process-group kill, not `perl alarm; exec`. (N9)
- `goals.py` reads `$RUN_DIR/goals-base.md` from `git show BASE_SHA`. (N10)
- No predictable stop-file copy; print `STOP_FILE:`. (N11)
- Finding format in the host brief. (N12)
- Committed tamper: do not restore; wake with revert command. (N13)
- Unstick command in the stop file. (N14)
- Journal each FIX finding's first line. (N15)

## Round 3 — Opus 5

SESSION_ID: `b26b0d23-611f-40a2-93dc-d36c6a458852`
VERDICT_FILE: `/var/folders/mc/nc97kyv53svctvg55rz0bl_w0000gn/T//claude-review-b26b0d23-611f-40a2-93dc-d36c6a458852-20260815T082931Z.md`

VERDICT: REVISE (R1–R9)

### Architect's response

Taken: all of R1–R9.

- `refresh` followed by a narrow GOALS.md commit before the next gate. (R1)
- Always materialize `goals-base.md` + journal a dispatch line; fresh-only captures BASE_SHA and sets `in_progress`. (R2)
- Clean-tree gate is fresh-start only; resume prints tree-unstick. (R3)
- `status:` carve-out only for the current id. (R4)
- Journaled BASE_SHA must be an ancestor of HEAD. (R5)
- `meta` from worktree at gate time only. (R6)
- Review diff pathspec excludes GOALS.md + journal; journal FIX as count+hash, not text. (R7)
- `done-refused` stop file includes `set <id> done`. (R8)
- Gate names every offending path. (R9)

## Round 4 — Opus 5

SESSION_ID: `b26b0d23-611f-40a2-93dc-d36c6a458852`
VERDICT_FILE: `/var/folders/mc/nc97kyv53svctvg55rz0bl_w0000gn/T//claude-review-b26b0d23-611f-40a2-93dc-d36c6a458852-20260815T083253Z.md`

VERDICT: REVISE (S1–S9; attacker: no remaining structural blocker)

### Architect's response

Taken: all of S1–S9.

- Journal path in the committed-files gate and in `/to-goals` stop text. (S1)
- `validate` requires `plan` + `journal`. (S2)
- `run-goal.sh` commits after its own `refresh`. (S3)
- Status-only compare is parsed fences, not file text. (S4)
- `set`/`refresh` rewrite `status:` in place (keep comments). (S5)
- Persist round artifacts under `.grok/run-goal-<id>/`. (S6)
- Resume continues `fix_count` from journaled `r<n>`. (S7)
- `cd` to toplevel before pathspecs. (S8)
- `trap EXIT INT TERM`; walker echoes `STOP_FILE:`. (S9)

## Round 5 — Opus 5

SESSION_ID: `b26b0d23-611f-40a2-93dc-d36c6a458852`
VERDICT_FILE: `/var/folders/mc/nc97kyv53svctvg55rz0bl_w0000gn/T//claude-review-b26b0d23-611f-40a2-93dc-d36c6a458852-20260815T083559Z.md`

VERDICT: REVISE (T1–T6). **MAX_ROUNDS reached. Not APPROVED.**

Architect would take all six (folded into PLAN.md after the cap; not a fake APPROVED):

- T1/T2: persist artifacts under `~/.cache/grok-coding-workflow/run-goal-<id>/`, mention only in the stop file
- T3: re-parse after in-place `status:` write; `SystemExit` on mismatch
- T4: drop stale `dump_yaml` reformats language
- T5: existing DAGs need a `journal:` key by hand
- T6: trap reads `$?` first

User breaks the tie: treat the folded plan as signed, or keep attacking.




