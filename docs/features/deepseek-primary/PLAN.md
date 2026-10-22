# Plan: DeepSeek as the primary implementer, Haiku second (house item 22)
_Locked via crucible — by Claude + the user, 2026-10-22_

## Goal

`claude-implement.sh` gains a choice of which model implements first,
`IMPLEMENTER_PRIMARY=haiku|deepseek`, and a fallback rule that works in
either direction: the secondary runs once, on a fresh session, when the
primary's pass is refused, declined, or (DeepSeek only) stopped by an empty
balance. This commit keeps `haiku` as the default, so every run today is
unchanged. A second, one-line commit flips the default to `deepseek` only after an
rbtree `--jobs 3` comparison walk with DeepSeek primary, recorded against
the Haiku walk of 2026-10-22 (parallel-walker EVIDENCE step 12b), and the
user's OK.

## Approach

0. **Measure first** (recorded in `docs/features/deepseek-primary/EVIDENCE.md`
   before any code). Each probe goes through the launcher's own DeepSeek pass
   (`--smoke`, or a smoke-sized prompt through the same `run_pass`), with the
   key from the house `.env`, never printed.
   a. **The content filter.** Send one harmless prompt on a topic DeepSeek's
      moderation is known to refuse (for example, a one-line question about
      the events of 4 June 1989 in Beijing). Record:
      - the envelope's `api_error_status`, `terminal_reason`, `is_error` and `result`;
      - the start of the reply;
      - the KIND that today's `classify` assigns to it.
      Run it twice, to see whether the signature is stable. There are two possible shapes:
      - an API error;
      - an HTTP 200 reply that refuses. Today that classifies as `ok` with `STATUS=MISSING`, and the host would run fix rounds on it.
      Both are handled in step 4.
   b. **Effort.** A one-off command, not the launcher: the launcher's DeepSeek
      argv (`--bare --model deepseek-flash`, the same settings and key file),
      run on the same small reasoning prompt five times:
      - with no effort;
      - with `--effort low`;
      - with `--effort max`;
      - with `CLAUDE_CODE_EFFORT_LEVEL=low` in the environment, and no flag;
      - with `CLAUDE_CODE_EFFORT_LEVEL=max` in the environment, and no flag.

      The environment variable is how DeepSeek's Claude Code guide sets effort,
      and the launcher does not strip it. Record the exact argv and environment, and
      compare `modelUsage.<model>.thinkingTokens` and `usage.output_tokens`.
      This shows whether effort reaches DeepSeek, and whether thinking tokens are
      counted inside `output_tokens` or on top of them.
   c. **Cache and resume.** Two passes in one resumed thread, the second on a
      prompt long enough (over 1k tokens of shared prefix) for DeepSeek's cache
      to apply. Record `usage.cache_read_input_tokens` and
      `cache_creation_input_tokens` on each pass, and whether the second
      envelope's `usage` and `total_cost_usd` cover that pass alone or the whole
      thread. A zero cache-read here is inconclusive, not proof that cache hits
      go unreported. The cost formula (step 7) prices whatever the envelope
      reports.
   d. **402.** Cannot be provoked on a funded account. Its shape is
      inferred from the measured 401: `api_error_status: 401`,
      `terminal_reason: "api_error"`, `is_error: true`,
      `result: "… API Error: 401 …"`. The rule keys on `api_error_status == 402`
      only, which is DeepSeek's documented code for "Insufficient Balance".
      Tests use a fake envelope.
1. **`IMPLEMENTER_PRIMARY`** (`haiku` default in this commit; `deepseek`).
   - Only those two values are accepted. Anything else exits 1 with a message
     before any pass, so a typo never becomes a normal walk on the other model.
   - The new-goal pass runs on the primary.
   - `--smoke` tests the primary unless `IMPLEMENTER_SMOKE_PROVIDER` names one.
2. **A DeepSeek pass with no DeepSeek key fails closed.** The check is made for
   the provider of the pass about to run, not for the primary setting:
   - **a new pass with DeepSeek primary:** the launcher prints
     `IMPLEMENTER_RESULT: error (no DeepSeek key: set DEEPSEEK_API_KEY in <house>/.env)`
     and exits 1 before any pass. `run-goal.sh` stops on it, as on any implementer
     error. It never switches to Haiku for a missing key;
   - **a resumed `deepseek:` thread:** fails the same way (as today);
   - **a resumed `haiku:` thread:** needs no DeepSeek key, so it runs even when the
     primary is DeepSeek and the key is missing;
   - **Haiku as a pass:** has no required key (`claude login` serves it), so there
     is no Haiku key check;
   - **the fallback:** runs to DeepSeek only when a DeepSeek key is present.
     Without one, a Haiku refusal stops, as today. A fallback to Haiku is always available.
3. **The fallback rule**, one function:
   - the secondary is the other provider;
   - `IMPLEMENTER_FALLBACK` is on by default. `none` or empty turns it off;
     `on`, `deepseek` (the old default) and `haiku` mean on; any other value
     exits 1 before a pass;
   - it runs only when the pass that just ended ran on the **primary**, on a
     new or a resumed thread;
   - triggers: `flagged` (the existing Haiku safeguard detection, plus the
     DeepSeek content-filter signature from step 0a, if one was measured),
     `declined` (`IMPLEMENTER_STATUS: DECLINED`), and `balance` (a DeepSeek pass
     whose envelope has `api_error_status == 402`);
   - never on a rate limit (429, 503 and the existing `is_transport_rate_limit`,
     exit 75), on any other error, or on a resumed **secondary** thread. A goal
     that fell back stays on the secondary, and nothing switches back;
   - the secondary runs on a new session, from the current HEAD, journal and
     handoff, with the existing "a previous implementer declined this goal"
     preamble reworded to name the reason;
   - the result line becomes `IMPLEMENTER_FALLBACK: <primary> -> <secondary> (refusal|declined|balance)`.
     `run-goal.sh` journals it as today (`IMPL_FALLBACK`).
4. **The content-filter signature** (only if step 0a measured one) goes in a new
   `lib/deepseek-refusal.py`, used only on DeepSeek passes.
   `lib/flagged-refusal.py` is unchanged, because the Opus reviewer's launcher
   calls it with no provider. It matches exactly what 0a recorded:
   - **an API error:** that `api_error_status` with that message;
   - **a 200 refusal:** that refusal text at the start of the reply, with no
     `IMPLEMENTER_STATUS:` line. The narrow test follows `flagged-refusal.py`'s,
     so a reply that only quotes the text does not match.

   A match is `flagged (deepseek)`. `flagged-refusal.py` still runs on **every** pass
   of both providers, as today, so a DeepSeek envelope with
   `stop_reason: "refusal"` stays `flagged`. `deepseek-refusal.py` is only a
   further match. No signature measured: no new rule. An unmeasured 200
   refusal then stays `ok` / `STATUS=MISSING` (logged under Risks).
5. **The classification order** in `classify`, each step decided before the next:
   1. a flag: `flagged-refusal.py` on any pass, then, on a DeepSeek pass, the
      step 4 signature;
   2. **balance**: a DeepSeek envelope with `api_error_status` of `402` or
      `"402"` (the house already accepts both forms for 429), whatever the exit
      code and the `result` text. It is decided before the rate-limit
      check, because DeepSeek's balance error may carry `insufficient_quota`,
      which `is_transport_rate_limit` would read as a rate limit;
   3. **a rate limit**: `api_error_status` 429, `"429"`, 503 or `"503"`, then the existing
      `is_transport_rate_limit`. Exit 75;
   4. any other non-zero exit or `is_error`: `error`;
   5. `DECLINED`, else `ok`.

   With no fallback left, `balance` exits 76, as `declined` and `flagged` do.
   `run-goal.sh` stops with `implementer-declined`, and its message is reworded to
   "refused, declined or out of balance".
6. **Model id and effort.** `DEEPSEEK_MODEL` defaults to `deepseek-flash`.
   `deepseek-v4-flash` is retired, and DeepSeek serves it as an alias of
   DeepSeek-V4.1-Flash-1017.
   - **How effort is sent:** `DEEPSEEK_EFFORT` reaches DeepSeek passes by the
     **one** mechanism step 0b shows works. If both work, it uses `--effort`, the
     same mechanism Haiku's passes use, and `CLAUDE_CODE_EFFORT_LEVEL` stays
     unset. If neither works, it is not added.
   - **When unset:** DeepSeek runs at its server default, `high`. That is the
     level Haiku's `xhigh` maps to on DeepSeek's scale, which runs `low`, `high`,
     `max`.
   - **The house removes `CLAUDE_CODE_EFFORT_LEVEL` from every implementer
     pass's environment**, unless the launcher sets it itself. Otherwise a value
     left in the user's shell would change Haiku's or DeepSeek's effort unseen.
7. **The cost line for DeepSeek** (simplified on the user's decision after
   round 4). Claude Code prices an unknown model at its own default
   (`costBasis: "unknown"`, about 14× DeepSeek's list price, measured), so the
   launcher computes `IMPLEMENTER_COST_USD` for a DeepSeek pass itself:
   - **Always the thread's total, always at the peak price.** No per-pass delta,
     no baseline file, no clock. Off-peak work is overstated by up to 2×. The
     estimate is an upper bound, never an under-estimate, so DeepSeek is never
     flattered in the comparison.
   - **One formula, in one place:**
     `cost = (input_tokens − any cache field 0c shows inside it
              + cache_creation_input_tokens) × $0.30
            + cache_read_input_tokens × $0.006
            + output_tokens × $1.20`
     per 1M tokens, the published `deepseek-flash` peak prices, with env
     overrides. `+ thinkingTokens × $1.20` applies only if step 0b shows thinking
     is not inside `output_tokens`.
   - **Which tokens:** if step 0c shows a resumed envelope's `usage` covers the
     whole thread, the formula prices it directly. If it covers only the pass,
     the line is that pass's cost, and the basis (below) says so.
   - **The basis is recorded where the scoring reads it.** The launcher prints
     `IMPLEMENTER_COST_BASIS: thread|pass`:
     - Haiku is `thread`, because its envelope cost on a resumed thread is the
       whole conversation, as `run-goal.sh` already documents;
     - DeepSeek is whichever step 0c shows.
     `run-goal.sh`'s `implemented` journal line gains `COST_BASIS=<basis>`, next to
     `COST_USD`. The run folder is gone after a success, so the journal is the
     record.
   - **A fallback's primary pass is costed too.** When the secondary runs, the
     launcher also prices the primary's envelope by the same rules and prints
     `IMPLEMENTER_FALLBACK_FROM: <THREAD_ID> COST_USD=<x> COST_BASIS=<b>`, where
     `<THREAD_ID>` is the primary's id exactly as the launcher already prints it
     (`deepseek:<uuid>` or `haiku:<uuid>`), with no second prefix.
     `run-goal.sh` adds `FROM=<THREAD_ID> FROM_COST_USD=<x> FROM_COST_BASIS=<b>` to
     that round's `implemented` line. The rollup counts it as a line of the
     primary's thread. A pass that stops with no fallback left (exit 76) is not
     journaled with a cost, as today. That is a known undercount, named in the
     evidence if it happens.
   - **Rolling up a goal's cost** (step 10): each `implemented` line belongs to
     the `THREAD_ID` on the latest `dispatch` or `ids` line above it, for that
     goal and attempt. That is the rule `lib/resume-state.py` already uses: a
     fix round that resumes a thread has a `dispatch` line, not an `ids` line.
     - A `thread` basis takes the **largest** of the thread's lines. A thread's
       running total only grows, but a refusal or 402 envelope may carry only
       its failed request, or no usage at all, so it can be lower than the
       round before.
     - A `pass` basis sums the thread's lines.
     - A goal's cost is the sum over its threads. A fallback is a new thread.
   - **`IMPLEMENTER_MAX_BUDGET_USD`** is passed on Haiku passes only. On a
     DeepSeek pass, Claude Code's 14× price would trip it early as an `error`,
     with no fallback.
8. **Tests** (`scripts/tests/implement-test.sh`, the fake `claude` binary), for each
   primary:
   - the order;
   - each trigger on a new and on a resumed primary pass;
   - 429 and 503 never switching;
   - a DeepSeek pass with no key failing closed with no pass run (new, and a
     resumed `deepseek:` thread);
   - a resumed `haiku:` thread running with DeepSeek primary and no key;
   - a missing DeepSeek key disabling only a fallback *to* DeepSeek;
   - no switch from a resumed secondary thread;
   - `IMPLEMENTER_FALLBACK=none`;
   - an unknown `IMPLEMENTER_PRIMARY` or `IMPLEMENTER_FALLBACK` value exiting 1
     with no pass run;
   - a 402 envelope whose `result` carries `insufficient_quota` switching
     (`balance`), not rate-limiting; the same with `api_error_status: "402"` as a
     string, and with a `result` of the measured 401 shape
     (`API Error: 402 …`, no `quota`);
   - a DeepSeek envelope with `stop_reason: "refusal"` staying `flagged` (exit 76
     with the fallback off);
   - the DeepSeek cost at the peak price from a fixed envelope, the
     `IMPLEMENTER_COST_BASIS` line for each provider, and `COST_BASIS=` on the
     `implemented` journal line (`run-goal.sh`, in its own test)
     the fallback line `IMPLEMENTER_FALLBACK_FROM: … COST_USD=` and its `FROM=` fields on
     the journal line; a rollup check over a fixture journal: a round-0 `ids` line,
     a resumed fix round that has only a `dispatch` line, and a fallback whose
     `FROM_COST_USD` is lower than the thread's earlier line (the earlier line
     is kept) and whose `FROM=` matches the earlier `dispatch` id exactly;
   - 429 and 503 envelopes exiting 75 with no switch (the exit is asserted, not
     only the absence of a switch);
   - a `"503"` string status whose `result` is `API Error: 503 …` with no
     `overloaded` word, exiting 75;
   - the result line's direction and reason;
   - no `--max-budget-usd` on a DeepSeek pass;
   - a `CLAUDE_CODE_EFFORT_LEVEL` exported in the launcher's own environment
     removed from a Haiku pass and from a DeepSeek pass with `DEEPSEEK_EFFORT`
     unset (the dry-run `CMD:` line shows `-u CLAUDE_CODE_EFFORT_LEVEL`). With
     `DEEPSEEK_EFFORT` set, only the one chosen mechanism carries it;
   - the content-filter signature (if any), plus near misses:
     - another 400 stays an `error`;
     - a reply that quotes the refusal text after its own prose, and ends with
       `IMPLEMENTER_STATUS: DONE`, stays `ok`.

   Each new branch is planted and shown red.
9. **Docs** for this commit:
   - CLAUDE.md's hard rule ("the implementer switches model in one case only")
     gains the 402 case and names the primary as configurable;
   - `GLOSSARY.md`'s **Implementer** and **Implementer fallback** entries (either
     direction, the three triggers);
   - the `run-goal` skill, where its text states the fallback rule or what
     `implementer-declined` means;
   - README's env table (`IMPLEMENTER_PRIMARY`, `DEEPSEEK_EFFORT`, the new
     `IMPLEMENTER_FALLBACK` meaning);
   - the launcher's header;
   - `install.sh`'s check message.

   The "who is primary" wording (CLAUDE.md roles table, README intro, the
   `run-goal` skill description) changes in the flip commit.
10. **The comparison walk** (after this commit, before the flip): a fresh clone of
    `~/dogfood/rbtree` at `02f35a4` plus `990e342`, `run-goals.sh --jobs 3` with
    `IMPLEMENTER_PRIMARY=deepseek` and `DEEPSEEK_EFFORT=high` (user, 2026-10-22: the
    level Haiku's `xhigh` maps to), the proof sandbox on, run under
    `caffeinate -i` (item 23 not yet built).
    - **House control:** step 12b ran at `c5297ca`. Before the walk,
      `git diff --stat c5297ca HEAD -- scripts/ mods/` must show only this
      item's launcher, its libs and tests, and test-only or comment-only
      changes (the `/walk-status` rename, the proof-fix test, the trust-test
      split). Anything else is named in the evidence, or the walk waits.
    - **Recorded against step 12b, per goal:**
      - fix rounds;
      - review verdicts;
      - stops by cause;
      - fallbacks;
      - cost rolled up as in step 7, DeepSeek's from the formula;
      - awake time, computed as in step 12b (pmset sleeps subtracted).
    - **Also recorded:** the DeepSeek effort the walk ran at, as `DEEPSEEK_EFFORT`
      or "server default (high)", and the mechanism that carried it.
    - The flip commit happens only on the user's OK.

## Key decisions & tradeoffs

- **Q1, a missing primary key fails closed.** The alternative, quietly running
  Haiku, would let a rotated key turn a DeepSeek walk into a Haiku walk logged as
  normal, and would hide that every goal's code was not going where the user
  expects.
- **Q2, the fallback applies on resumed primary passes too.** Most fix rounds
  resume the primary's thread, and a balance that runs out in round 2 should not
  stop a goal Haiku can finish. One direction only: a goal that fell back never
  returns to the primary, so no goal mixes two models' transcripts back and forth.
- **Q3, the content filter counts as a refusal only on a measured signature.**
  Matching any 400 would hand broken setups (a lost-thinking 400, a malformed
  request) quietly to Haiku.
- **Q4, the default flips only after a measured walk.** Haiku has done every live
  goal; DeepSeek through this harness has done none.
- **402 becomes a fallback trigger, which is an error-case switch.** This breaks
  the old rule "never on an error". It is accepted because an empty balance is
  account-wide and does not recover by itself within a walk, so stopping gains
  nothing that the fallback line does not already report.
- **Cost from list prices at the peak rate, as a thread total** (user, after
  round 4). Rounds 1–3 each found a hole in a per-pass, peak/off-peak delta
  scheme (baselines, rates, rollup). The simpler shape has no state and is an
  upper bound, up to 2× high off-peak. Rejected: leaving the envelope cost,
  which is about 14× too high and would wreck the comparison.
- **Every goal's code goes to DeepSeek** once the default flips. The user
  accepted this (2026-10-22). The proof sandbox and secret redaction apply to
  both providers unchanged.

## Assumptions

1. The work is in `scripts/claude-implement.sh` (the order, the rule, the result
   line). `run-goal.sh` reads the same lines; it changes the stop wording and adds
   `COST_BASIS=` to the `implemented` journal line.
   (`claude-implement.sh:576-618`, `run-goal.sh:997-1011`)
2. 429 and 503 are already a rate limit. 429 is caught by `api_error_status`, and
   503's "Server Overloaded" by `overloaded` (`lib/dotenv.sh`).
3. DeepSeek's HTTP status arrives in the envelope's `api_error_status`, as
   measured with a bogus key (401, 2026-10-22).
4. A fix round resumes the thread of the model that wrote it (`haiku:`/`deepseek:`).
5. The isolation is unchanged for both providers: the sandbox, the stripped
   environment, the key file, `--bare` for DeepSeek and `--safe-mode` for Haiku.
6. Out of scope: `lessons.py`'s Haiku calls, and the legacy `IMPLEMENTER=codex` path.
7. DeepSeek docs (api-docs.deepseek.com, read 2026-10-22):
   - the Anthropic endpoint is `https://api.deepseek.com/anthropic`;
   - `deepseek-flash` is DeepSeek-V4.1-Flash-1017;
   - thinking is on by default at `high`, and xhigh maps to high;
   - `reasoning_content` must be passed back on tool-call turns, or the API returns 400;
   - an account allows 2500 concurrent requests, with 429 beyond that;
   - 402 means insufficient balance and 503 means overloaded;
   - USD prices per 1M tokens are $0.30 input on a cache miss, $0.006 on a cache hit and $1.20 output at peak, with off-peak at half.

## Risks / open questions

- **The 402 shape is inferred, not measured.** If the 402 envelope lacks
  `api_error_status`, the pass falls through to the rate-limit check. Its
  `insufficient_quota` text may match there, and it stops with exit 75. That
  is a stop, never a quiet switch: safe, but wrongly named.
- **The filter probe uses the house DeepSeek key.** Two harmless questions are
  not grounds for DeepSeek to act against an account. A separate key for two
  probes is not worth the setup, and nothing in DeepSeek's docs suggests a risk.
- **A lost-thinking 400 on a long or compacted DeepSeek thread.** It stops as an
  `error` and is never switched. The comparison walk is where it would show.
- **The content filter may not be provokable** in step 0a. If so there is no new
  rule. A repo whose text trips it then stops each pass with `error` if the
  filter answers with an API error. If it answers with a 200 refusal, the pass
  reads as `ok` / `MISSING`, and the host spends proof-fix rounds on it until it
  stops (`proof-red`).
- **Claude Code's 200k context and 32k max output assumptions for an unknown
  model.** These match Haiku's working limits, and DeepSeek's are larger.
- **DeepSeek's prices change.** The table in one place, with overrides, is
  checked against the pricing page when the flip commit is made.

## Out of scope

- Any change to the Opus reviewer, Grok, or `lessons.py`.
- A per-repo opt-out of DeepSeek, beyond setting `IMPLEMENTER_PRIMARY=haiku` in the environment.
- Measuring a 402 against a real empty balance.
- `deepseek-v4-pro`, and a 1M-context `[1m]` model name.
