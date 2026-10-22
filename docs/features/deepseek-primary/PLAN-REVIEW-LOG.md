# Plan Review Log: DeepSeek as the primary implementer, Haiku second (house item 22)
Phases 0-1 (recon + interrogation) complete — plan locked with the user. MAX_ROUNDS=5.

## Round 1 — Grok

I'll review the plan skeptically against the repo and domain docs, looking for concrete breaks rather than agreeing with its confidence.The plan names specific scripts and line ranges. I'll read those, plus the glossary and the existing fallback path, and check the claims against the code.The plan's fallback and cost rules disagree with the launcher that has to implement them. Six of those gaps would ship a switch that does not fire, a cost number the flip decision cannot trust, or a refusal the host treats as success.

1. **A 402 is classified too late, so the new trigger never wins.** `classify` in `scripts/claude-implement.sh` returns on `is_transport_rate_limit` before either generic-error return (non-zero exit at lines 345–352, and `is_error` at 362–365). `scripts/lib/dotenv.sh` treats any stderr or `result` containing `quota` as a rate limit (`insufficient.?quota` and a bare `quota`). DeepSeek's balance body uses the type `insufficient_quota`, so a real 402 becomes `rate_limited` (exit 75, no switch). A fixture that only sets `api_error_status: 402` stays green. The same hole makes the 503 test vacuous: status 503 is not special-cased (only 429 is), and "did not switch" is also true for a plain error.
   Fix: Decide `api_error_status == 402` before `is_transport_rate_limit`, on both error paths; fixture the `insufficient_quota` text; treat status 503 as exit 75 and assert that exit.

2. **The effort probe cannot show what the plan thinks it shows.** DeepSeek's `run_pass` argv is `--bare --model` only (`claude-implement.sh` lines 274–278). It never forwards `--effort`. Step 0b runs that pass "before any code" and, on no change in `thinkingTokens`, step 6 drops `--effort` for good.
   Fix: Probe with that same argv plus `--effort low` and `--effort max`, as a one-off command, and record those argv in `EVIDENCE.md`.

3. **The cost line the flip rests on is not defined, and it double-counts.** `journal_implemented` in `scripts/run-goal.sh` already records a resumed thread's envelope as the conversation's running total. Step 7 prices "the envelope's tokens" at the pass start and never says whether `input_tokens` excludes `cache_read` / `cache_creation`, whether cache-creation is a miss, or whether `modelUsage.*.thinkingTokens` (step 0b) sit outside `output_tokens`. Summing the journal then re-bills earlier rounds, and a short step 0c that sees a zero cache-read locks every later token at the miss price ($0.30 vs $0.006). The window is specified in UTC, but the clock source is not. `--max-budget-usd` still trips on Claude Code's unknown-model price, about 14×, and that death is an `error` with no fallback. Step 12b's $0.433 is one pass per goal, so the first DeepSeek fix round makes the two totals not comparable.
   Fix: Publish one formula (miss, hit, cache-write, output, thinking-tokens only if 0b shows they are extra), emit the per-pass delta on resume using `date -u`, and treat a zero cache-read on a smoke-sized prompt as inconclusive.

4. **A soft content-filter reply is `ok`, and the risk text says the opposite.** If the envelope is HTTP 200, `is_error` is false, and there is no `IMPLEMENTER_STATUS: DECLINED`, `classify` sets `KIND=ok` and `STATUS=MISSING` (the header states `ok` covers `MISSING`). The host then runs proof-fix rounds on the same model. Step 0a never records that KIND, and it sends the probe on the house key the comparison walk needs.
   Fix: In step 0a, record the KIND `classify` would assign today; a 200 refusal must become `flagged` or `declined`; run the probe on a key the walk will not use; keep the matcher in a sibling that takes the provider, because `claude-goal-review.sh` calls `flagged-refusal.py` with none.

5. **The key rule and the primary value do not match this launcher.** Haiku has no required API key (`ANTH_KEY` is optional; `claude login` is enough), so "a missing secondary key disables the fallback" is false when the secondary is Haiku, and the "for each primary" test cannot be written. A missing-key check that runs whenever `IMPLEMENTER_PRIMARY=deepseek`, before `--resume` is honored, also blocks a later `haiku:` resume, which does not need the key. Any primary other than `haiku` or `deepseek` is unspecified; `${VAR:-haiku}` turns a typo into a normal Haiku walk, which is the failure Q1 exists to prevent. `IMPLEMENTER_FALLBACK=haiku` is also unspecified, and today's code treats every value other than `deepseek` as off.
   Fix: Accept only `haiku|deepseek` (anything else exits 1 before a pass); require `DEEPSEEK_API_KEY` only when this pass's provider is DeepSeek; disable the fallback only with `none` or empty, treating legacy `deepseek` as on.

6. **The comparison that gates the default flip does not hold the house still.** Step 12b ran at house `c5297ca`, in `~/dogfood/rbtree-par2`, with the proof sandbox on, and 24m23s of idle sleep (no `caffeinate`, FUTURE-WORK item 23). Step 10 reruns "after this commit" on whatever HEAD is then and compares fix rounds, verdicts, stops, and awake time. This commit also changes behavior the glossary and `skills/run-goal/SKILL.md` still define ("reruns once on DeepSeek", "implementer-declined means both models refused"). Those files are not in the doc list.
   Fix: Run the walk from `c5297ca` plus this commit only, sandbox on, awake time computed as in step 12b, and update `GLOSSARY.md` and the run-goal skill in this commit.

VERDICT: REVISE

### Architect's response
All six taken; one sub-point rejected.
1. Taken. Checked: `classify` runs `is_transport_rate_limit` before the error returns and `dotenv.sh` matches `quota`. Step 5 now orders flag → balance (`api_error_status == 402`, any exit) → rate limit (429/503 by status, then the existing check, exit 75) → error; tests fixture `insufficient_quota` and assert exit 75 for 429/503.
2. Taken. Checked: the DeepSeek argv has no `--effort`. Step 0b is a one-off with the launcher's DeepSeek argv plus `--effort low|max`, argv recorded; it also settles whether thinking sits inside `output_tokens`.
3. Taken. Step 7 states one formula (miss for input + cache-creation, hit for cache-read, out for output, thinking only if 0b shows it extra), the rate by `date -u` at pass start, a per-pass delta on a resumed thread if 0c shows the envelope cumulative, no `--max-budget-usd` on DeepSeek passes; 0c treats a zero cache-read as inconclusive; step 10 compares per-goal sums of every pass.
4. Taken in part. 0a records today's KIND; a 200 refusal is matched by reply text at the start with no IMPLEMENTER_STATUS line (narrow, with a quoting near-miss test), in a new DeepSeek-only `lib/deepseek-refusal.py`, leaving `flagged-refusal.py` (the reviewer's) unchanged. Rejected: a separate key for the probe — two harmless questions are no account risk worth a second key (logged under Risks).
5. Taken. Checked: `ANTH_KEY` is optional. Only `haiku|deepseek` accepted for the primary, an unknown `IMPLEMENTER_FALLBACK` value exits 1, the DeepSeek key check is per pass provider (a resumed `haiku:` thread runs without it), and a missing DeepSeek key disables only a fallback to DeepSeek.
6. Taken. Step 10: walk under `caffeinate -i`, sandbox on, awake time as in 12b, and a house control — `git diff --stat c5297ca HEAD -- scripts/ mods/` limited to this item and test- or comment-only changes, else named or the walk waits. GLOSSARY.md and the run-goal skill join this commit's docs (both checked: they state the old rule).

## Round 2 — Grok

I'll re-read the revised plan and check each prior finding against the code it still depends on.The revision covers the classification order and the key check. I'll verify the cost-delta and DeepSeek flag paths against the launcher, because those still look underspecified.The six earlier findings are mostly fixed: the 402 check now precedes the rate-limit matcher, the effort probe is a one-off argv, the price formula and `date -u` window are explicit, the key check follows the pass's provider, and the walk is pinned to `c5297ca` with the glossary and the run-goal skill in this commit. The separate probe key was rejected with a reason. Three holes still change what the launcher does.

1. **A DeepSeek refusal becomes a successful pass.** Step 5 runs the existing safeguard only on a Haiku pass, and `lib/deepseek-refusal.py` only matches the signature measured in step 0a. Today `classify` runs `flagged-refusal.py` on every pass, including a DeepSeek one (`claude-implement.sh` lines 341–343), so a `stop_reason: "refusal"` stops with exit 76 and the host assesses nothing. Neither of step 4's shapes covers that `stop_reason`, and an empty 200 result with no `IMPLEMENTER_STATUS` line is `ok` / `MISSING`. The risk line still says an unmeasured filter "stops each pass with `error`". Step 0a already records that this reply is `ok`, and the host then spends fix rounds on it.
   Fix: Keep calling `flagged-refusal.py` on both providers, and add `deepseek-refusal.py` only as a further DeepSeek match; state that an unmeasured 200 refusal stays `ok` / `MISSING`.

2. **The per-pass cost delta has no baseline it can actually subtract.** Raw files in `CW_OUT_DIR` are `mktemp` names, and one round writes more than one (the unsaved-thread retry at lines 596–603, plus a fallback). `run-goal.sh` creates a new `RUN_DIR` per process and deletes it on success, so a later resume of the same thread finds no earlier envelope. "The envelope less the previous pass's" can also subtract two costs priced at different peak rates. Step 0c never checks that `input_tokens` is disjoint from the cache fields the formula adds on top.
   Fix: Subtract token counts of the latest earlier envelope in this `CW_OUT_DIR` with the same `session_id`, then price that delta at this pass's rate; if no baseline exists, print the cumulative total and `IMPLEMENTER_COST_BASIS: cumulative`. If step 0c shows `input_tokens` already includes a cache field, drop that field from the miss term.

3. **`api_error_status == 402` misses the string form this harness already had to accept.** `is_transport_rate_limit` matches `429` and `"429"` (`dotenv.sh` line 73). The inferred 402 body is "API Error: 402 …", the same shape as the measured 401, which does not contain `quota`. A string `"402"` then fails the balance check and also fails the rate-limit needles, so the pass is a plain `error` and never falls back. The new test can still pass with a numeric `402`.
   Fix: Treat `402` and `"402"` as balance, and fixture the string.

VERDICT: REVISE

### Architect's response
All three taken; one Architect addition.
1. Taken. Checked: `classify` runs `flagged-refusal.py` on every pass today. It keeps doing so on both providers; `deepseek-refusal.py` is a further DeepSeek-only match; an unmeasured 200 refusal is stated as `ok` / `MISSING` (Risks corrected: it spends proof-fix rounds until `proof-red`). Test: a DeepSeek `stop_reason: "refusal"` stays flagged.
2. Taken. Checked: run folders are per round and removed on success. The delta subtracts token counts of the latest earlier envelope with the same `session_id` in the same `CW_OUT_DIR` and prices them at this pass's rate; with no baseline it prints the cumulative cost and `IMPLEMENTER_COST_BASIS: cumulative`, journaled, and step 10 counts that goal's latest cumulative value. The miss term drops any cache field 0c shows inside `input_tokens`.
3. Taken. `402` and `"402"` both mean balance; tests fixture the string and a 401-shaped `API Error: 402 …` result with no `quota`.
Addition (from DeepSeek's Claude Code guide, read 2026-10-22): step 0b also probes `CLAUDE_CODE_EFFORT_LEVEL` (the guide's mechanism, `max`); `DEEPSEEK_EFFORT` uses whichever mechanism reaches DeepSeek; the launcher strips `CLAUDE_CODE_EFFORT_LEVEL` from the implementer's environment unless it sets it, so a stray shell value cannot change effort unseen. The comparison walk's DeepSeek effort (high vs max) is with the user.

## Round 3 — Grok

I'll re-read the revised plan and check the three remaining holes against the launcher.The three round-2 holes are closed: `flagged-refusal.py` still runs on both providers, the cost delta is token counts against the same `session_id`, and `402` and `"402"` both count as balance. The new effort probe and the cost rollup still disagree with the launcher.

1. **The comparison can add the same tokens twice, or drop a later pass.** Step 7 says a missing baseline prints `IMPLEMENTER_COST_BASIS: cumulative` and that step 10 then uses that goal's latest cumulative value. Step 10 still says the cost is the sum of every pass. Neither rule is right once a resumed process journals a cumulative line and a later round in that same process journals a delta: the sum counts the earlier passes twice, and "latest cumulative" stops before the delta. The reason given is also false. `run-goal.sh` creates one `RUN_DIR` per process (line 635) and passes that same `CW_OUT_DIR` on every round (lines 983–985). It is removed only when the goal succeeds. A fix round in that process has a baseline; the baseline is missing only when a new process resumes the thread.
   Fix: A `cumulative` line replaces every earlier cost for that thread; add only passes journaled after it. State that the shared run folder is why an in-process fix round has a baseline.

2. **"Drop that field from the miss term" prices cache hits at the miss rate.** The miss term is `input_tokens + cache_creation_input_tokens`. `cache_read_input_tokens` is not in it. If step 0c shows `input_tokens` already includes the cache-read tokens, dropping nothing from the miss term bills those tokens at $0.30 and again at $0.006. Dropping the hit term instead bills them only at the miss price.
   Fix: If `input_tokens` contains a cache field, subtract that field from `input_tokens` before the miss multiply, and keep the hit term for cache-read tokens.

3. **The new effort control has no single outcome and no test.** Step 0b can show that both `--effort` and `CLAUDE_CODE_EFFORT_LEVEL` change `thinkingTokens`. Step 6 does not say which one `DEEPSEEK_EFFORT` uses, so both can be set and disagree. Step 8 never plants the strip of a stray `CLAUDE_CODE_EFFORT_LEVEL`, which is the case step 6 exists for (`env_unsets` does not remove it today). Step 10 does not record the effort the walk ran, so the flip is compared at an unstated setting. Unset means server default `high`.
   Fix: If both work, send `DEEPSEEK_EFFORT` through one and leave the other unset; test that a Haiku pass and an unset DeepSeek pass have the variable removed; write the value used in the step 10 evidence.

VERDICT: REVISE

### Architect's response
All three taken.
1. Taken. Checked: `run-goal.sh` makes one `RUN_DIR` per process (line 635) and passes it as `CW_OUT_DIR` on every round (983-985), so my stated reason was wrong; the baseline is missing only when a new process resumes the thread. The rollup rule is now: a `cumulative` line replaces every earlier cost of that thread, later passes add on top, a fallback is a new thread.
2. Taken. A cache field found inside `input_tokens` is subtracted from `input_tokens` before the miss multiply; cache-read keeps the hit term.
3. Taken. If both mechanisms work, `DEEPSEEK_EFFORT` uses `--effort` only; the strip of a stray `CLAUDE_CODE_EFFORT_LEVEL` is tested on Haiku and unset-DeepSeek passes via the dry-run `CMD:` line; step 10 records the effort and mechanism.

## Round 4 — Grok

I'll re-read the revised plan and check the cost rollup, the cache formula, and the effort rule against the launcher.The three round-3 holes are closed. The rollup matches a shared run folder, cache-read tokens stay on the hit price, and `DEEPSEEK_EFFORT` uses `--effort` when both mechanisms work, with the stray variable stripped and the walk's effort recorded. Two gaps still throw off the comparison.

1. **A resumed Haiku pass is still added as if it were only that pass.** The rollup replaces earlier cost only when a line is marked `cumulative`. Haiku never emits that marker: step 7 leaves its envelope cost as the running total, which `journal_implemented` already describes as the whole conversation (`run-goal.sh` lines 540–546). After the fallback Q2 is about, the next fix round resumes Haiku, and that line is added on top of the fallback pass it already includes. The basis also never reaches the record step 10 reads. Assumption 1 still says `run-goal.sh` changes only the stop wording, and the implemented heading has no basis field. `succeed` deletes the run folder, so a marker that exists only on the launcher's stdout is gone before the walk is scored.
   Fix: Put `IMPLEMENTER_COST_BASIS` on the implemented journal line, and treat a resumed Haiku cost as `cumulative` for that thread in the same rollup.

2. **The new 503 check does not accept the string form this harness already sees.** Step 5 keys `api_error_status` 429 or 503 as a rate limit. `is_transport_rate_limit` matches `429` and `"429"` only (`dotenv.sh` line 73). A `"503"` whose `result` is `API Error: 503`, the same wrapper as the measured 401, matches neither the status tuple nor the `overloaded` needles, so the stop is `implementer-error`. Step 10 records stops by cause.
   Fix: Treat `503` and `"503"` as exit 75, and fixture the string with no `overloaded` word.

VERDICT: REVISE

### Architect's response
Both taken; step 7 rewritten on the user's decision.
User decision (after round 4, on the Architect's offer — three rounds in a row found holes in the per-pass delta scheme): the DeepSeek cost is always the thread's total at the peak price, from one formula; no per-pass delta, baseline file or clock; an upper bound, up to 2× high off-peak.
1. Taken in that shape. The launcher prints `IMPLEMENTER_COST_BASIS: thread|pass` (Haiku `thread`, as `run-goal.sh` already documents its resumed cost; DeepSeek per step 0c); `run-goal.sh`'s `implemented` journal line gains `COST_BASIS=`, since the run folder is gone after a success; the rollup groups a goal's lines by thread (`ids` line `THREAD_ID`): `thread` takes the latest, `pass` sums, threads add. Assumption 1 updated.
2. Taken. 503 and `"503"` (with 429 and `"429"`) are a rate limit, exit 75; a `"503"` fixture with no `overloaded` word.
Also recorded: the comparison walk runs `DEEPSEEK_EFFORT=high` (user, 2026-10-22).

## Round 5 — Grok

I'll re-read the revised plan and check the Haiku cost rollup and the 503 status check against the launcher.The round-4 holes are closed. Haiku is basis `thread`, the journal line carries `COST_BASIS`, and `503` and `"503"` both exit 75. The simplified rollup still mis-reads the journal on the common path.

1. **A fix round has no `ids` line to group it by.** `journal_ids` writes `ORCHESTRATOR ids` only when the id changes (`run-goal.sh` lines 567–571). Round 0 gets one, after the pass. A later round that resumes the same thread journals `THREAD_ID` on the `dispatch` line and then skips `journal_ids`. Step 7 groups implemented lines by "each round's `ids` line". Those rounds do not have one. Basis `thread` is the likely DeepSeek result and is what Haiku always uses, and that rule takes the latest line of the thread. A line that is not grouped is dropped, or added as a second thread on top of a cumulative total.
   Fix: Attach each `implemented` line to the `THREAD_ID` on the latest `dispatch` or `ids` line above it, which is the rule `resume-state.py` already uses.

2. **The pass that triggers a fallback is missing from the thread total.** `journal_implemented` runs only after the launcher returns `ok`, and the emitted cost is the secondary's envelope. The primary's raw file stays in the run folder until `succeed` deletes it, and nothing prices it. On the balance path from Q2 the DeepSeek envelope is the whole thread so far. The rollup's "latest" line for that thread is the previous successful round, so those tokens never appear. Peak pricing does not cover the gap, and the total is then lower than the real spend.
   Fix: On a fallback, journal the primary envelope's priced cost under its own `THREAD_ID` before the secondary's line.

VERDICT: REVISE

### Architect's response
Both taken. Checked: `journal_ids` writes only when the ids change (`run-goal.sh` 564-571), and `resume-state.py` reads THREAD_ID from the latest dispatch or ids line.
1. The rollup assigns each `implemented` line to the THREAD_ID on the latest `dispatch` or `ids` line above it (resume-state.py's rule); a fixture journal with a dispatch-only fix round is tested.
2. On a fallback the launcher also prices the primary's envelope and prints `IMPLEMENTER_FALLBACK_FROM: <provider>:<thread> COST_USD= COST_BASIS=`; `run-goal.sh` adds `FROM=`, `FROM_COST_USD=`, `FROM_COST_BASIS=` to that round's `implemented` line, counted under the primary's thread. A pass that stops with no fallback left (exit 76) stays uncosted, as today; named as a known undercount.
MAX_ROUNDS reached without APPROVED. These two fixes were never attacked; the user decides between sign-off and one more narrow round.

## Round 6 — Grok (narrow, on the user's order)

I'll re-read the revised plan and check the thread grouping and the fallback cost against the journal code.The round-5 fixes are in the plan. An `implemented` line takes the `THREAD_ID` on the latest `dispatch` or `ids` line above it, and a fallback prices the primary envelope onto that round. Those two rules undo each other on the balance path.

1. **`FROM=` does not join the primary thread.** A journal `THREAD_ID` is already `deepseek:<uuid>` or `haiku:<uuid>` (`claude-implement.sh` lines 34 and the `THREAD_ID: ${PROVIDER}:${SESSION}` emit). The launcher line is `IMPLEMENTER_FALLBACK_FROM: <provider>:<thread>`, and the journal field is `FROM=<thread>`. One of those adds a second provider prefix, so the fallback spend does not match the earlier `dispatch` id. The rollup then adds it as its own thread, on top of the earlier total.
   Fix: Write the primary's existing `THREAD_ID` string, unchanged, in both `IMPLEMENTER_FALLBACK_FROM` and `FROM=`.

2. **Basis `thread` keeps the later line, and the fallback envelope is the later line.** A refusal or a 402 often has no `usage`, or only the failed request. The formula then prices that envelope at 0 or at one call. Step 7 still takes the thread's latest line, so the new `FROM_COST_USD` replaces the previous round's full total. Peak pricing does not repair that. The fixture lists "a fallback" and never a `FROM` cost lower than the earlier line.
   Fix: For basis `thread`, the thread's cost is the max of its lines, and the fixture must include a lower `FROM_COST_USD`.

VERDICT: REVISE

### Architect's response
Both taken.
1. `IMPLEMENTER_FALLBACK_FROM` and the journal's `FROM=` carry the primary's THREAD_ID exactly as printed (`deepseek:<uuid>` / `haiku:<uuid>`); the fixture checks it matches the earlier dispatch id.
2. A `thread` basis takes the largest of the thread's lines, not the latest; the fixture has a fallback `FROM_COST_USD` lower than the earlier line.
