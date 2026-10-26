# Journal: always-on (house)

## 2026-10-26T07:23:17Z — ARCHITECT start
Crucible for the always-on house (user, 2026-10-26). Deep research (four agents: runtime, limits, notification, prior art and the decider), synthesis at inbox/research/2026-10-26-always-on-crucible-research.md. Assumptions ledger confirmed (18 items). Decisions (user): Q1 the unattended loop's Claude calls on a separate API key with a hard monthly cap (Pro stays for interactive work); the decider Opus 5.5 at xhigh (high if Fable 5.1; Fable needs credits on Pro, probed twice); Q2 routing only; Q3 a queue of signed walks only; Q4 notify-only, iMessage primary and Remote Control push through the walk mod; Q5 the four-class wake table, unknown reasons to the user. Cosmetic batch accepted with ceilings changed by the user to $10/day and $20/walk ($75/week kept), to be re-measured in a dogfood run. PLAN.md locked; Grok round 1 next.

## 2026-10-26T07:25:46Z — ARCHITECT ceilings
The user lowered the weekly ceiling to $50 (it was $75, which seven days at the $10 daily ceiling could never reach); daily $10 and per walk $20 kept. PLAN.md step 9 updated while Grok round 1 runs (it sees the old number).

## 2026-10-26T07:35:27Z — ARCHITECT round 1
Grok round 1: REVISE, 12 findings (real wake tokens and billing text; model text in the journal; resume vs re-signing; the sign-off artefact; the signed plan path; no mid-walk spend writer; restarts and STOP mid-walk; wave-stop parsing; queue format and counts; commits under launchd; osascript injection; the heartbeat). All taken (rate limits without a reset back off before holding). PLAN.md revised; round 2 resumes session 05bffed8.

## 2026-10-26T07:42:39Z — ARCHITECT round 2
Grok round 2: REVISE, 5 findings (the spend ledger double-counted and summed the account balance, a sticky halt, the overshoot is a wave, CW_ALWAYS_ON_LEDGER stripped; billing text in the envelope not the detail, a bare 402 matching shas, rate limits through the decider; the heartbeat during waits; resume livelocks; sign could queue the house). All taken. PLAN.md revised; round 3 resumes session 05bffed8.

## 2026-10-26T07:47:31Z — ARCHITECT round 3
Grok round 3: REVISE, 4 findings (reviewer billing text not on LOG:/stderr:; cumulative review and fallback costs double-counted; the heartbeat vs a reaped child; resume refilling the cap and an unbounded decider call). All taken; the spend ledger redesigned to observations with amounts derived at read time (second consecutive round on it). PLAN.md revised; round 4 resumes session 05bffed8.

## 2026-10-26T07:54:56Z — ARCHITECT round 4
Grok round 4: REVISE, 3 findings (the $20 had no entry to sum by; the billing scan read successful transcripts; no flock binary on this Mac). All taken. PLAN.md revised; round 5 (MAX_ROUNDS) resumes session 05bffed8.

## 2026-10-26T08:01:08Z — ARCHITECT round 5
Grok round 5: REVISE, 4 findings (a restart orphans a live child and STOP misses it; a stale copied stop replays after a crash; the rate-limit ladder is not durable; killed turns record no cost). MAX_ROUNDS reached without APPROVED; the restart path drew holes in rounds 1 and 5, so a reconcile-style redesign of the run state is proposed. The user decides: a sixth round or sign-off.

## 2026-10-26T08:02:37Z — ARCHITECT round 5 decision
The user chose a redesign and a sixth round. PLAN.md revised: run state derived from a per-attempt wrapper's lock and attempt-numbered result (adoption, no stale replay), a durable wait, killed-turn costs (step 0h). Round 6 resumes session 05bffed8.

## 2026-10-26T08:06:53Z — ARCHITECT round 6
Grok round 6: REVISE, 4 findings in the new run-state design (a completed walk read as an empty reason; a result acted on every poll; a killed turn counted twice on resume; a dead wrapper leaving its walker). All taken; the user chose a seventh round. Round 7 resumes session 05bffed8.

## 2026-10-26T08:10:45Z — ARCHITECT round 7
Grok round 7: REVISE, 3 findings (acted_attempt and the outcome in separate writes; a recycled pgid read as the walker; the billing scan reading pruned paths). All taken. Put to the user: an eighth round or sign-off.

## 2026-10-26T08:14:37Z — ARCHITECT round 8
Grok round 8: REVISE, 2 findings (the walker check required the repo on argv; a wave-stop's per-goal stop paths not rewritten to the copies). Both taken. Put to the user: a ninth round or sign-off.

## 2026-10-26T08:17:37Z — ARCHITECT round 9
Grok round 9: REVISE, 3 findings (run states keyed on the whole group; the rename before/after the decider stated both ways; killing the group misses the model sessions). All taken, one residual recorded as a risk. Put to the user: a tenth round or sign-off.

## 2026-10-26T08:21:25Z — ARCHITECT round 10
Grok round 10: REVISE, 1 finding (the key decision and the reboot risk still stated the lock-and-result-only rule). Taken: both aligned with step 5. Put to the user: an eleventh round or sign-off.

## 2026-10-26T08:23:06Z — ARCHITECT round 11 / end
Grok round 11: APPROVED (session 05bffed8). One wording fix in step 5 taken. Crucible converged after 11 rounds (MAX_ROUNDS 5, extended by the user); two redesigns (the observation ledger, the run state from the world). Awaiting the user's sign-off; the build is in-session, starting with step 0's evidence.

## 2026-10-26T08:30:28Z — ARCHITECT sign-off
The user signed off PLAN.md (Grok APPROVED in round 11). Build next, in-session, starting with step 0's evidence.

## 2026-10-26T09:18:29Z — ARCHITECT step 0 amendment
Step 0d: an invalid key reaches the walker as reviewer-error (class C) with api_error_status 401 only in the envelope. PLAN.md step 7a amended: api_error_status 401/402/403 in an error envelope is A budget before the text markers; "invalid api key" added. Step 0f adds a pinned-version check (claude-version-changed, A) to the supervisor; step 0h sets the killed-turn stand-ins (reviewer $1.00, decider $0.50, implementer $0.50).

## 2026-10-26T09:19:48Z — ARCHITECT step 0
Step 0 done (EVIDENCE.md): a, b, c, f, g, h measured and working or set; d amended step 7a (api_error_status 401/402/403 first); e partly unproven (the push is suppressed while the terminal is active; phone delivery and the mod call go to the build and the dogfood run). No step failed; the build can start.

## 2026-10-26T09:27:36Z — ARCHITECT decider and dogfood
The user set the decider to Opus 5.5 at high effort (xhigh buys nothing for one binary judgment on structured data; DeepSeek rejected, the implementer deciding on reruns of its own failed work; Grok left for later) and dropped the Fable 5.1 route entirely. The dogfood run uses a new project the user chooses, not a past dogfood DAG. PLAN.md updated.
