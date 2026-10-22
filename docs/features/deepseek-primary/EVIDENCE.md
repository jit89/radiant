# Evidence: DeepSeek as the primary implementer (house item 22)

## Step 0: measurements before any code (2026-10-22)

Every probe ran the launcher's DeepSeek argv:
- `claude -p … --bare --model deepseek-flash --output-format json --permission-mode acceptEdits --tools Read`;
- the key comes from the house `.env` through an `apiKeyHelper` key file;
- credential variables are stripped;
- `ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic`.

The script was a scratch `probe.sh` outside the repo. The key was never printed. Claude Code
reports the model as `unrecognized_model` on stderr and works.

### 0a. The content filter

**A bare question on a topic DeepSeek moderates**, one line on 4 June 1989 in
Beijing, asked twice:

| Run | HTTP / envelope | Reply |
|---|---|---|
| 1 | 200; `is_error: false`, `api_error_status: null`, `stop_reason: end_turn` | "I can't help with that question, but I'm glad to assist with other topics." |
| 2 | the same | "I don't have any information about that, and I'm not able to help with this question. Is there something else I can assist you with?" |

- **The refusal is an ordinary 200 reply, not an API error.** Its wording differs from run to run, so there is no stable signature.
- **Today's `classify` reads it as `ok`, `STATUS=MISSING`.** `flagged-refusal.py` does not match.

**The same topic framed as an implementer task**, using the launcher's status rule ("End your reply with
one line … IMPLEMENTER_STATUS: DONE, BLOCKED or DECLINED"), three runs:
- DeepSeek wrote a factual summary each time and ended `IMPLEMENTER_STATUS: DONE`;
- it never refused and never declined.

**Outcome (plan step 4):** no signature was measured, so there is no new rule and no
`lib/deepseek-refusal.py`. `flagged-refusal.py` still runs on every pass. An
unmeasured 200 refusal stays `ok` / `MISSING`; the plan's Risks already cover
it. In the framing a goal actually uses, the model did the work.

### 0b. Effort

**Thinking tokens and output counts.**
- `modelUsage.<model>.thinkingTokens` is 0 on every DeepSeek run. Claude Code does not report DeepSeek's thinking separately, so it is counted in `output_tokens`.
- Output-token counts on a hard puzzle, three runs per setting, were noise:
  - none: 8035, 3388, 2785;
  - `--effort low`: 5659, 3420, 11714;
  - `--effort max`: 5200, 4873, 6397;
  - `CLAUDE_CODE_EFFORT_LEVEL=low`: 5119, 6050, 9143;
  - `CLAUDE_CODE_EFFORT_LEVEL=max`: 7625, 4724, 11075.

**The request bodies settle it.** Claude Code was pointed at a local capture server
(`ANTHROPIC_BASE_URL=http://127.0.0.1:…`, a dummy key, the request answered with
400, no headers logged), with the same argv. Each `/v1/messages` body read:

| Setting | `thinking` | `output_config` | `max_tokens` |
|---|---|---|---|
| no effort | `{"type": "adaptive", "display": "omitted"}` | `{"effort": "high"}` | 32000 |
| `--effort low` | the same | `{"effort": "low"}` | 32000 |
| `--effort max` | the same | `{"effort": "max"}` | 32000 |
| `--effort xhigh` | the same | `{"effort": "xhigh"}` | 32000 |
| `CLAUDE_CODE_EFFORT_LEVEL=max` | the same | `{"effort": "max"}` | 32000 |
| `--model claude-haiku-5-5 --effort max` (control) | the same | `{"effort": "max"}` | 128000 |

- **Both mechanisms reach DeepSeek**, as `output_config.effort`, the field DeepSeek's
  Anthropic guide lists as supported.
- **With no setting, Claude Code itself sends `high`.** That is the same as `DEEPSEEK_EFFORT=high`, and the same as
  DeepSeek's server default. DeepSeek maps `xhigh` to `high`.

**Outcome (plan step 6):** both work, so `DEEPSEEK_EFFORT` uses `--effort`, and
`CLAUDE_CODE_EFFORT_LEVEL` is stripped.

**New fact:** Claude Code caps an unknown model at `max_tokens: 32000` per
response, where it gives Haiku 128000. DeepSeek's thinking counts against that cap.
The comparison walk shows whether any DeepSeek turn stops at `max_tokens`.

### 0c. Cache tokens and resume

One thread, a 2,500-word list in the first prompt, then two resumed passes:

| Pass | `usage` (input / cache_read / cache_creation / output) | `modelUsage` input / cache_read / output | `total_cost_usd` (Claude Code's price) | turns |
|---|---|---|---|---|
| 1 | 4270 / 32640 / 0 / 21529 | 4270 / 32640 / 21529 | 0.4542 | 6 |
| 2 (resume) | 134 / 25472 / 0 / 93 | 4404 / 58112 / 21622 | 0.4617 | 1 |
| 3 (resume) | 239 / 25472 / 0 / 195 | 4643 / 83584 / 21817 | 0.4716 | 1 |

- **Cache hits are reported** (`cache_read_input_tokens`), and `cache_creation_input_tokens`
  stays 0.
- **`input_tokens` excludes the cache-read tokens**, so the formula's terms are
  disjoint as written, with nothing subtracted.
- **`usage` covers this invocation only. `modelUsage.<model>` and `total_cost_usd` cover the
  whole thread across resumes.**

**Outcome (plan step 7):**
- the DeepSeek cost is priced from `modelUsage.<model>` (`inputTokens`, `cacheReadInputTokens`,
  `cacheCreationInputTokens`, `outputTokens`), with basis `thread`, the same as Haiku;
- thinking is not added separately.

At DeepSeek's peak price this thread cost about $0.028:

4643 × 0.30 + 83584 × 0.006 + 21817 × 1.20 = $0.0014 + $0.0005 + $0.0262 per 1M tokens.

Claude Code's figure was $0.47, about 17× higher.

### 0d. 402

Not provoked; the account is funded. A bogus key gave the shape a 402 is
expected to share: `api_error_status: 401`, `terminal_reason: "api_error"`,
`is_error: true`, `result: "Failed to authenticate. API Error: 401 Authentication Fails, …"`.
Plan steps 5 and 8 key on `402` / `"402"`, with fixtures.

## Step 10: the comparison walk (2026-10-22)

The same rbtree DAG as the Haiku walk (parallel-walker EVIDENCE step 12b):
- a fresh clone `~/dogfood/rbtree-ds` at `990e342`, the commit that walk started from;
- `IMPLEMENTER_PRIMARY=deepseek DEEPSEEK_EFFORT=high run-goals.sh --jobs 3` under `caffeinate -i`;
- house at `d3f73c0`;
- the proof sandbox on;
- Opus 5.5 reviewing.

**House control:** `git diff --stat c5297ca d3f73c0 -- scripts/ mods/` shows only this item's launcher, `run-goal.sh` journal fields, `lib/cost-rollup.py`, tests, and comment or message lines (the `/walk-status` rename, `install.sh`'s check text).

| | Haiku 5.5 (`xhigh`), step 12b | DeepSeek Flash (`high`) |
|---|---|---|
| Goals done | 7/7 | 7/7 |
| Review verdicts | 7 DONE in round 0 | 7 DONE in round 0 |
| Fix rounds | 0 | 0 |
| Fallbacks | 0 | 0 |
| Stops | 0 | 2, both `journal-tamper` (below) |
| Implementer passes | 7 | 9 (g2 and g3 were recut after their stops) |
| Implementer cost | $0.4349 (Claude Code's estimate at Haiku's price) | $0.3356 at peak price (rollup $0.2340, plus the two discarded attempts: g2 $0.0717, g3 $0.0299). The walk ran 10:37–11:05 UTC on a Thursday, which is off-peak, so the list cost was about **$0.168** |
| Wall time | 57m51s, of which 24m23s asleep; about 33.5 min awake | **27m41s**, no sleep. Includes both stops, both recuts and about 3 min of recovery between runs |
| Source lines (`src/`) | 539 | 568 |

**The two stops.** In g2's and g3's first attempts DeepSeek did the same thing:
- it wrote an `IMPLEMENTER checkpoint` heading with a time it had not taken from `date -u`. Both times were a few minutes in the future: `10:47:30Z` when the real time was `10:42:39Z`, and `10:52:40Z` against `10:50:30Z`;
- it committed that heading;
- it then rewrote the committed heading to the real time.

Editing committed journal text is `journal-tamper`, and the host stopped both goals before review. Everything else DeepSeek wrote to the journal was a proper append. Both goals' code and proofs had passed.

The Architect put the committed line back each time (the user's order, recovery A). That turned out to be moot: the walker recuts a stopped goal and reruns it fresh. The reruns did not repeat the edit, and nor did g4–g7. So the edit happened in 2 of 9 DeepSeek passes; Haiku did it in 0 of 7 passes this morning.

**Review notes (the SIMPLER heading).** The reviews asked for nothing. Two noted dead code:
- g2: a branch that cannot be taken;
- g6: four NULL guards in `delete_fixup` that a valid tree never needs.

**Not measured:** whether any DeepSeek reply stopped at Claude Code's 32000-token output cap. The run folders of goals that succeed are removed, and no pass failed.

**What this means for the flip.** On this DAG, DeepSeek matched Haiku on quality: every review passed first time, with no fix rounds. It cost roughly 40–60% less and took less wall time. Its one failure mode is editing a committed journal record. That stops a real walk at the first goal it touches, so it has to be fixed before the default flips. The fix is an implementer-prompt rule: take the time from `date -u` before writing a heading, and correct a committed record by appending, never by editing.

### Step 10b: the confirming walk, after the prompt rule (2026-10-22)

**Setup:**
- house `6f1feba`, which adds the implementer-prompt rule: run `date -u` for each heading, and correct a written record by appending;
- a fresh clone `~/dogfood/rbtree-ds2` at `990e342`;
- the same settings: `IMPLEMENTER_PRIMARY=deepseek DEEPSEEK_EFFORT=high --jobs 3` under `caffeinate -i`;
- no recovery loop.

| | Step 10 (before the rule) | Step 10b (after) |
|---|---|---|
| Goals done | 7/7 | 7/7, exit 0 |
| Stops | 2 `journal-tamper` | **0** |
| Review verdicts | 7 DONE in round 0 | 6 DONE in round 0; g2 FIX in round 0, then DONE in round 1 |
| Implementer passes | 9 | 8 (g2's fix round resumed its DeepSeek thread) |
| Cost (rollup) | $0.3356 at peak | $0.2876 at peak. The walk ran 12:20–12:42 UTC on a Thursday, off-peak, so about **$0.144** at list price |
| Wall time | 27m41s | **22m22s** |

**g2's fix round.** It was the first live fix round of the day.
- **The finding:** Opus's SIMPLER heading (house item 15) found that `rbtree_validate` still walked the tree when the root named a parent. PLAN 5 says it should report `RBTREE_ERR_PARENT` without walking. Two `!= root` guards existed only to keep that unneeded walk finite. The FIX was to skip the walk and drop the guards: smaller code that also matches the spec.
- **The fix round:** DeepSeek's resumed thread made exactly that change (`a2117b8`, "a root that names a parent is not walked"). The round-1 review passed.
- **What it confirms:** the item 3 fix handoff works live on a resumed DeepSeek thread, and the cost rollup reads the thread total for the fix round ($0.0951 against round 0's $0.0711, one thread).

**The prompt rule.** Across 8 DeepSeek passes the journal shows 16 IMPLEMENTER records and no edited record. That compares with 2 edits in 9 passes before the rule.
