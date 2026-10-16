# Journal: proof-sandbox (house item 12)

## 2026-10-16T09:56:12Z — ARCHITECT start
Crucible for FUTURE-WORK item 12, on the user's order (item 12 before the rbtree re-run). Recon: proof_exec runs the host proof, worktree_setup and merged proofs unsandboxed; /usr/bin/sandbox-exec works on Darwin 27; the implementer sandbox denies three secret paths. Decisions (user): Q1 own SBPL profile under sandbox-exec (recommended); Q2 (b) deny known secret paths, not all of $HOME (user chose b over the recommended a); Q3 localhost only for proofs, proof_network opt-in, worktree_setup keeps the network; Q4 fail closed, CW_PROOF_SANDBOX=off from the host only; Q5 implementer folder out of the run folder, run folders denied whole (placed under handoffs/ so runs/ can be denied whole). Cosmetic batch accepted. PLAN.md locked; Grok round 1 next.

## 2026-10-16T10:09:17Z — ARCHITECT round 1
Grok round 1: REVISE, 11 findings, all taken (11 with a change: denials surfaced from the unified log for diagnosis, never a red signal). PLAN.md revised; round 2 resumes session 2099711b.

## 2026-10-16T10:16:01Z — ARCHITECT round 2
Grok round 2: REVISE, 5 findings (hard-link pre-check scope, link re-opened by the tmp allow, loopback bind/inbound, older handoff folders, trust-test oracles), all taken. Round 3 resumes.

## 2026-10-16T10:22:14Z — ARCHITECT round 3
Grok round 3: REVISE, 2 findings (hard-link plants in the worktree gitdirs and temp areas; the self-test contradicting the loopback rule), both taken; the first by the general rule that the implementer write set is either unreadable to the proof or walked. Round 4 resumes.

## 2026-10-16T10:33:20Z — ARCHITECT round 4
Grok round 4: REVISE, 1 finding (the implementer TMPDIR inherited from the launching shell) plus a stale sentence; both taken. Round 5, the last (MAX_ROUNDS=5), resumes.

## 2026-10-16T10:39:14Z — ARCHITECT round 5
Grok round 5: APPROVED. Plan converged in 5 rounds (findings 11, 5, 2, 1, 0). Awaiting user sign-off.

## 2026-10-16T10:42:22Z — ARCHITECT sign-off
User signed off PLAN.md after Grok APPROVED (round 5). Next: step 0 measurement (evidence only, no house code), recorded in EVIDENCE.md.
