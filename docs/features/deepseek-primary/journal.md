# Journal: deepseek-primary (house item 22)

## 2026-10-22T08:04:58Z — ARCHITECT start
Crucible for FUTURE-WORK item 22, on the user's order (after the rbtree --jobs 3 walk). Recon: claude-implement.sh runs Haiku first and DeepSeek once on a flag or decline; two probes through the launcher (2026-10-22): deepseek-flash answers, its envelope cost is Claude Code's default price (costBasis unknown, ~14x DeepSeek's list price); a bogus key returns api_error_status 401 with terminal_reason api_error. Decisions (user): Q1 a missing primary key fails closed; Q2 the fallback applies on new and resumed primary passes, one direction only; Q3 DeepSeek's content filter counts as a refusal only on a signature measured in step 0; Q4 the default stays haiku in the build commit and flips to deepseek only after an rbtree comparison walk and the user's OK. Earlier agreed: triggers refusal, decline and 402; 429/503 stop as a rate limit; every goal's code goes to DeepSeek once flipped. Cosmetic batch accepted. PLAN.md locked; Grok round 1 next.

## 2026-10-22T08:13:00Z — ARCHITECT round 1
Grok round 1: REVISE, 6 findings (402 classified after the rate-limit check, effort probe on an argv without --effort, cost formula and resume deltas, a 200 refusal reads ok, key and value rules, the comparison control and docs); all taken, one sub-point rejected (a separate key for the filter probe). PLAN.md revised; round 2 resumes session bef15b23.

## 2026-10-22T08:18:17Z — ARCHITECT round 2
Grok round 2: REVISE, 3 findings (DeepSeek stop_reason refusal must stay flagged, a cost delta with no baseline, 402 as a string); all taken. Added: step 0b probes CLAUDE_CODE_EFFORT_LEVEL, the launcher strips a stray one. Round 3 resumes session bef15b23.

## 2026-10-22T08:23:34Z — ARCHITECT round 3
Grok round 3: REVISE, 3 findings (cost rollup across cumulative and delta lines, cache field in input_tokens, one effort mechanism with a tested strip); all taken. Round 4 resumes session bef15b23.

## 2026-10-22T08:27:12Z — ARCHITECT round 4
Grok round 4: REVISE, 2 findings (a resumed Haiku cost counted twice and the basis lost with the run folder; a string 503); both taken. User decisions: the simpler cost design (thread total at peak price, COST_BASIS journaled) and DEEPSEEK_EFFORT=high for the comparison walk. Round 5 (the last under MAX_ROUNDS) resumes session bef15b23.

## 2026-10-22T08:30:28Z — ARCHITECT round 5
Grok round 5: REVISE, 2 findings (fix rounds have no ids line; a fallback's primary pass uncosted); both taken. MAX_ROUNDS reached; the two fixes are unattacked. Asked the user: sign off, or one narrow round 6 on the delta.

## 2026-10-22T08:34:20Z — ARCHITECT round 6
Grok round 6 (narrow, user-ordered): REVISE, 2 findings in the fallback cost (thread id prefix, a low fallback envelope replacing the total); both taken. Asked the user for sign-off.

## 2026-10-22T08:46:00Z — ARCHITECT step 0
Measured (EVIDENCE.md): 0a DeepSeek refuses a bare moderated question with a varying HTTP 200 reply (no API error, no stable signature: no deepseek-refusal.py), and in the implementer framing does the task and reports DONE; 0b Claude Code sends output_config.effort to DeepSeek from --effort or CLAUDE_CODE_EFFORT_LEVEL (default high), so DEEPSEEK_EFFORT uses --effort; it caps an unknown model at max_tokens 32000; 0c cache reads are reported, input_tokens excludes them, usage is per invocation and modelUsage is the thread total, so DeepSeek cost is priced from modelUsage with basis thread; 0d 402 not provokable, keyed on 402/"402" with fixtures.

## 2026-10-22T10:18:03Z — ARCHITECT build
Built per PLAN.md and step 0: claude-implement.sh (IMPLEMENTER_PRIMARY, validated settings, classify order flag/balance/rate/error, one fallback either way on new or resumed primary passes, DeepSeek key fail-closed per pass, DEEPSEEK_EFFORT as --effort, CLAUDE_CODE_EFFORT_LEVEL stripped, DeepSeek cost from modelUsage at peak with COST_BASIS and FALLBACK_FROM, budget on Haiku only); run-goal.sh journals COST_BASIS and FROM fields, the declined stop covers balance; new lib/cost-rollup.py (Haiku walk of 2026-10-22: $0.4349); docs. 19 plants, each red. Opus r1 FIX (tests for the Haiku basis and Haiku->DeepSeek FROM cost; README model id and key wording), both taken with most notes; r2 DONE. Recorded for the flip commit: a goal that fell back to deepseek and resumes after the default flips would treat its deepseek: thread as primary and could switch back once. Outside the plan: the /walk-status cost (events.py) ignores fallback_from.

## 2026-10-22T12:12:09Z — ARCHITECT comparison walk
rbtree --jobs 3 with IMPLEMENTER_PRIMARY=deepseek DEEPSEEK_EFFORT=high at d3f73c0 (EVIDENCE step 10): 7/7, all reviews DONE r0, 0 fix rounds, 0 fallbacks, 2 journal-tamper stops (g2, g3 first attempts: a guessed future time in a checkpoint heading, committed, then edited in place; recut reruns clean), cost about $0.17 at the off-peak list price (peak upper bound $0.34) against Haiku $0.43, 27m41s wall with no sleep. Before the flip: an implementer-prompt rule against editing committed records.
