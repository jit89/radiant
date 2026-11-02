# Journal: sandbox-write-times

## 2026-11-02T21:22:31Z — ARCHITECT start
Found by the rust-tier-rules item at step 2b: on macOS 27.0.1 the proof sandbox refuses to set file times in every tree (named write operations don't cover it; only file-write* does). Measured: the precedence rows A-G, plus the reach (cargo fetch, tar -x, cp -p, shutil.copy2).
Ledger confirmed (10 entries). Q1, the user: the self-test gets both checks (touch in root succeeds; touch in the root's .git refused). Cosmetics as recommended. Follow-up recorded for FUTURE-WORK: Axum + SQLx rules after the core Rust rules.
PLAN.md locked.

## 2026-11-02T21:22:31Z — ARCHITECT dispatch
Grok round 1 (grok-4.7, fresh session) on docs/features/sandbox-write-times/PLAN.md.

## 2026-11-02T21:35:10Z — ATTACKER round 1
Grok REVISE, 5 points (session 74b1a58f-c637-452c-9bc5-f3f62f0d3da6).

## 2026-11-02T21:35:10Z — ARCHITECT arbitration round 1
All 5 taken (see PLAN-REVIEW-LOG.md): a named deny of acl/finderinfo/mount on allowed trees (ACL measured; FinderInfo via xattr is no widening; finderinfo and mount unproved); refused cases under the root; P5 and P6; plants on a copy of scripts/; os.utime with EPERM and unchanged stamps.

## 2026-11-02T21:35:10Z — ARCHITECT dispatch
Grok round 2 (resume).

## 2026-11-02T21:40:53Z — ATTACKER round 2
Grok REVISE, 2 points plus a P4 wording note.

## 2026-11-02T21:40:53Z — ARCHITECT arbitration round 2
All taken: the extra deny goes last (after the tmp re-allow), with the ACL probed in root and tmp; GOALS.example.md staged for the copied test; P4 wording.

## 2026-11-02T21:40:53Z — ARCHITECT dispatch
Grok round 3 (resume).

## 2026-11-02T21:44:28Z — ATTACKER round 3
Grok APPROVED.

## 2026-11-02T21:44:28Z — ARCHITECT end (crucible)
Converged in 3 rounds (5 + 2 points + 1 note, all taken). Waiting for the user's sign-off.

## 2026-11-02T21:49:15Z — ARCHITECT sign-off
The user signed off PLAN.md (Grok APPROVED round 3). Build in-session.

## 2026-11-02T21:52:07Z — ARCHITECT build
Built: WRITE carries file-write*; WRITE_EXTRA (acl, finderinfo, mount) denied by name on the allowed trees after the tmp re-allow; two self-test checks; 15 suite cases ("file times"); EVIDENCE correction; FUTURE-WORK items 32 and 33. proof-sandbox-test.sh passes. Plants on copies of scripts/: P0 clean passes; P1 5 red, P2 7, P3 5, P4 12, P5 5, P6 3, each where the plan predicted.

## 2026-11-02T21:52:07Z — ARCHITECT dispatch
Opus 5.5 review round 1 (fresh, read-only) of the diff (262 lines).

## 2026-11-02T21:56:16Z — REVIEWER round 1
Opus FIX, 1 finding plus 7 notes ($0.99). FIX taken: the self-test case compares the exit code and any printed reason; P1-P4 rerun and each names its reason. Notes taken: ACL cases require EPERM; file-write-unmount (probed: a real name) added to WRITE_EXTRA; the docstring and the FUTURE-WORK wording; the env-strip word list in item 33. Notes logged, no change: P4 planted as an equivalent order, with the outside control confirmed refused in its run; deps-outside-setup is a second control (deps under the root would be writable anyway); the pnpm lock folder has no ACL probe (a shared /private/tmp path), now stated in EVIDENCE.

## 2026-11-02T21:56:16Z — ARCHITECT dispatch
Opus round 2 (narrow, fresh): the r1-to-r2 delta.

## 2026-11-02T21:58:06Z — REVIEWER round 2
Opus DONE ($0.82). Notes taken after DONE (docs only): PLAN.md Amendment 1 (file-write-unmount, with the bogus-name control); an EVIDENCE line recording that control. Notes logged: the three named-only denies have no plant (recorded unproved); the stricter self-test case is intended.

## 2026-11-02T21:58:06Z — ARCHITECT dispatch
Opus round 3 (narrow): the post-DONE doc edits.

## 2026-11-02T21:59:24Z — REVIEWER round 3
Opus DONE on the post-DONE doc edits.

## 2026-11-02T21:59:24Z — ARCHITECT suite
Full suite started (run-all.sh).

## 2026-11-02T22:31:35Z — ARCHITECT suite
Full suite green: 44 test scripts, 0 failures. Waiting for the user's OK to commit.

## 2026-11-02T22:33:56Z — ARCHITECT commit
The user OKd the commit, with plants.sh included (the reviewed harness; only its header comment and the house path, now relative to the script, differ).
