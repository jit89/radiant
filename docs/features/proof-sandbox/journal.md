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

## 2026-10-16T10:59:46Z — ARCHITECT step 0
Step 0 measured on macOS 27.0.1 (EVIDENCE.md). Proofs pass under the draft profile: rbtree and uregex C (with ASan/UBSan, same times as unsandboxed), Vitest, node:test, pytest; setups npm ci, uv sync --frozen, pnpm install (copy mode). Escape probes refused: writes outside the checkout/tmp, secret paths, .git, symlink and hard-link tricks, public network (EPERM), Launch Services (CLI and compiled), AppleEvents, launchctl, securityd, ssh agent, nested sandbox. Three gaps found: the checkout's own .env; a 0.0.0.0 bind reachable from the LAN; any host loopback service reachable. SBPL cannot express own-ports or port ranges; no measured proof needs loopback. Within-intent profile fixes recorded (file-link both ends, parent metadata, output file, root under a denied path, pnpm setup needs). Two changes to locked decisions brought to the user: Q3 no network by default; Q2 deny .env inside the checkout.

## 2026-10-16T11:05:42Z — ARCHITECT amendment 1
User approved: Q3 changed to no network by default (proof_network: loopback | true); Q2 extended to the checkout's .env files; step 0's within-intent fixes; a per-walk dependency folder (setup writes, proofs read) for Rust/Go-style caches; a first-use smoke test per new language in to-goals. Written as Amendment 1; one Grok round on it (same session) before building.

## 2026-10-16T11:12:13Z — ARCHITECT round 6
Grok on Amendment 1: REVISE, 3 findings, all taken (link aliasing measured already refused, layer added anyway; the .env pattern extended to the main checkout and every worktree; step 7 and the loopback exposures). Round 7 resumes.

## 2026-10-16T13:56:55Z — ARCHITECT round 7 void
Round 7 returned error (host slept) (item 11.1 working live); rerun in the same session.

## 2026-10-16T13:59:05Z — ARCHITECT round 7
Grok: REVISE, 1 finding (the implementer can cp/ln .env to a new name before the proof), taken: literal --deny-read of existing .env files for the implementer, and a pre-check on multi-linked .env files. Round 8 resumes.

## 2026-10-16T14:07:33Z — ARCHITECT round 8
Grok: REVISE (mv and case-variant aliasing of .env). Third and fourth patch to one mechanism, so a structural option was offered; the user chose Option 2: no live .env in a walked checkout (secrets-in-checkout gate, CW_ALLOW_DOTENV=1 opt-out). Part B rewritten; round 9 resumes.

## 2026-10-16T14:10:36Z — ARCHITECT round 9
Grok: REVISE, 2 findings (scan order before worktree_setup; a .env symlink), taken; plus ~/.config/cw-secrets on the secret list as the denied home the stop message names. Round 10 resumes.

## 2026-10-16T14:13:27Z — ARCHITECT round 10
Grok: APPROVED Amendment 1. Next: commit the amendment and step 0 evidence (user OK), then build step 1.
