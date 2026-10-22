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
