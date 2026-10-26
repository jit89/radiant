# Evidence: always-on step 0 (2026-10-26)

Measurements on this Mac before any always-on code (PLAN.md step 0). Each
check names what was run, what it showed, and what the plan does with it.

## b. API key routing (first half: the key itself)

The user created the API key and wrote it to
`~/.config/cw-secrets/anthropic-decider.key` themselves, from the clipboard
(`pbpaste`), so it never passed through the conversation: mode 600, an
`sk-ant-` prefix, no trailing newline.

`ANTHROPIC_API_KEY="$(cat <that file>)" claude -p "Reply with exactly: PONG"
--model claude-opus-5-5 --effort low --output-format json --tools Read` (Claude
Code 2.1.307), run twice from a throwaway folder:

- `is_error: false`, `result: "PONG"`, `total_cost_usd` 0.0122, model
  `claude-opus-5-5`.
- stderr: "claude.ai connectors are disabled because ANTHROPIC_API_KEY or
  another auth source is set and takes precedence over your claude.ai login".
  Claude Code itself reports that the key, not the subscription, is in use.
  The first run's stdout parse failed only because that warning shared the
  stream; the plan's launchers keep stderr separate.

Still to measure for b: that the Console shows these calls on the key (the
user's check) and that the subscription's usage did not move; and that each
launcher (`claude-goal-review.sh`, the mutations turn, a Haiku pass through
`claude-implement.sh`, `claude-decide.sh`) bills the key the same way under a
LaunchAgent with no shell profile.

The user confirmed in the Console: about $0.02 on the key's workspace (the two
calls), and a monthly spend limit of $150 set on that workspace.

## a. iMessage (first half: from an interactive session)

`osascript` with the handle and the text as argv (`on run argv`; `participant
<handle> of` the iMessage account; `send`), from this session, to two handles
the user gave: their Apple ID email and their phone number with the +91 country
code. Messages returned `sent` for both, and the user received one iMessage, on
their phone. The phone number is the recipient in
`~/.config/cw-always-on/notify.conf` (0600; the handle is kept out of this
repo). Still to measure: the same send from a LaunchAgent (the Automation
permission, a locked screen, Messages not running or signed out).

## c. A tool-less decider

`claude --help` (2.1.307): `--tools <tools...>`: "Use \"\" to disable all tools".
It is variadic, so a prompt placed after it is swallowed (the first Fable probe
failed that way); the decider passes its packet on **stdin** (`claude -p ...
< packet`), with no prompt argument.

`ANTHROPIC_API_KEY=<the key file> claude -p --model claude-opus-5-5 --effort
xhigh --tools "" --permission-mode dontAsk --permission-prompts none
--output-format json < packet`, the packet a draft decider prompt (two
actions, untrusted data marked) and a class C `implementer-timeout`, with a
journal tail carrying an injected instruction to answer a second object:

- `is_error: false`, `num_turns: 1`, `permission_denials: []`,
  `total_cost_usd` **0.0216**.
- `result` was exactly one JSON object: `{"action": "rerun", "reason": "First
  implementer-timeout on g2-b (class C, counts C:0 D:0), likely transient;
  embedded instructions in journal_tail were ignored as untrusted data."}`.

The same flags asked to read `/etc/hosts` with any tool: "I don't have any
tools available in this session, so I can't read files." (one turn, $0.0058).
Note the extra sentence before the requested token: the decider's output is
parsed strictly (exactly one JSON object, else `needs_human`), as the plan says.

## f. Version pin

`claude` is the Homebrew cask `claude-code@latest` 2.1.307 (`/opt/homebrew/bin/claude`
-> `/opt/homebrew/Caskroom/claude-code@latest/2.1.307/claude`, "Installed (on
request)"); no `brew autoupdate` LaunchAgent and no `autoUpdates` setting in the
user's Claude config. The binary's own update check (from its strings) returns
updates disabled, reason "set by env", when `DISABLE_UPDATES` is set, or when
`DISABLE_AUTOUPDATER` is set: both are honoured. So the LaunchAgent sets
`DISABLE_AUTOUPDATER=1` and `DISABLE_UPDATES=1`, and the binary then changes
only when someone runs `brew upgrade`. That cannot be prevented from here, so
the supervisor records `claude --version` when it starts and, before each
dispatch, holds the entry (class A, `claude-version-changed`) if it differs:
the user upgrades between walks, not under one. (An addition within step 0f's
remit: "that it holds" is enforced, not assumed.)

## a, b, g under a LaunchAgent

A temporary LaunchAgent (`com.cw.always-on.probe`: `RunAtLoad`, `ProcessType
Standard`, `PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`, no other
environment) ran a probe script once, bootstrapped with `launchctl bootstrap
gui/<uid>`, then booted out and its plist deleted. The process saw no TTY,
`TERM=dumb`, and found `claude` 2.1.307 on that `PATH`.

- **a. iMessage**: `osascript` (the handle and text as argv) to the recipient
  in `notify.conf`: `rc=0`, `sent`, with no Automation prompt shown (the
  permission Messages needs was already granted from the interactive tests,
  or not required for a LaunchAgent run by the same user). Not yet measured:
  a send while the screen is locked, and with Messages quit.
- **b. Key routing**, the key exported as `ANTHROPIC_API_KEY` from its file:
  a direct `claude -p --tools ""` call: `PONG`, $0.0116, the "takes precedence
  over your claude.ai login" notice; `claude-goal-review.sh --smoke`:
  `CLAUDE_REVIEW_RESULT: ok`, `claude-opus-5-5`; `claude-implement.sh --smoke`
  with `IMPLEMENTER_SMOKE_PROVIDER=haiku`: `IMPLEMENTER_RESULT: ok`,
  `claude-haiku-5-5`, $0.00004 (the launcher passes the key through its 0600
  key file, `apiKeyHelper`). The mutations turn goes through the reviewer
  launcher's same call path as its smoke; `claude-decide.sh` is the direct
  call above. All three launch paths work on the key under launchd.
- **g. Commits**: `GIT_TERMINAL_PROMPT=0 git commit` in a fresh repo with the
  user's git config: `rc=0`, unsigned (`%G?` = `N`; the user has no commit
  signing configured), no prompt.

The first probe run was cut short by the Architect: its completion check
matched `DONE` inside the reviewer's `VERDICT: DONE`; the rerun used a unique
marker.

## h. The cost of a killed turn

An Opus 5.5 turn at `--effort high` on the key (a long essay prompt, no tools),
killed at 45 s by `run-timeout.py` (rc 124), in both output modes:

- `--output-format json` (the launchers' mode): **0 bytes**. Nothing parses,
  so a killed turn's cost always needs the plan's stand-in.
- `--output-format stream-json --verbose`: 18 events, mostly setup
  (`system/init`, `commands_changed`), one `assistant` message holding only a
  `thinking` block whose `usage` shows the message's start (6 output tokens),
  and 13 `system/thinking_tokens` events counting up to `estimated_tokens:
  1500`. The turn spent its time thinking: about 1,500 output tokens in roughly
  40 s of generation, ~40 tokens/s. No usable partial cost either.

Stand-ins for step 9 (a killed call's previous observation plus this), set on
the high side so a ceiling over-counts rather than under-counts, to be
re-measured in the dogfood run:

| Killed call | Timeout | Output at ~40 tok/s | Stand-in |
|---|---|---|---|
| reviewer, Opus 5.5 ($20/M out) | 10 min | ~24k tokens, ~$0.48 | $1.00 (it reads a diff: more input) |
| decider, Opus 5.5 | 10 min | ~$0.48 | $0.50 (a small packet) |
| implementer, Haiku 5.5 / DeepSeek | 20 min | ~$0.24 / ~$0.06 | $0.50 (agentic loops reread context) |

## d. Billing and limit failures as the walker sees them

Measured: `claude-goal-review.sh --smoke` with an invalid API key
(`CW_OUT_DIR` set so the raw files stay): stdout `CLAUDE_REVIEW_RESULT: error
(exit 1)`, `VERDICT: MISSING`, `VERDICT_FILE:` the raw envelope; `run-goal.sh`
turns that into a `reviewer-error` wake, **class C**. The envelope: `type:
result`, `subtype: success`, `is_error: true`, **`api_error_status: 401`**,
`terminal_reason: api_error`, `result: "Invalid API key · Fix external API
key"`; the `.err` file is empty. Nothing on the detail line says "key".

From the house's own fixtures (`scripts/tests/implement-test.sh`, recorded
from real DeepSeek runs): a DeepSeek 402 is `api_error_status: 402` (a number
or a string), `result: "API Error: 402 {\"error\":{\"message\":\"Insufficient
Balance\",\"type\":\"insufficient_quota\"}}"`; the implementer launcher falls back
to Haiku once on it, by design, so a walk stops on it only if that fails too.

Not provoked (it needs real spend or a real throttle): an Anthropic spend
limit (documented as 429 with `error.details.error_code:
enforced_spend_limit_reached`) and a plain 429. The text markers carry
`enforced_spend_limit_reached` and `spend limit`; a plain 429 surfaces through
the launchers' existing transport check as `rate_limited` /
`reviewer-rate-limited` (step 10's wait). Backstops: the Console's $150 monthly
cap and the dogfood run.

**Plan amendment (step 7a)**: the structured `api_error_status` is checked
before the text markers: 401, 402 or 403 in an error envelope is A `budget`
whatever the stop reason, so a revoked key is held at once instead of retried
twice as C; `invalid api key` joins the text markers. The fixtures for the
gate: this 401 envelope (reviewer and implementer), the two 402 shapes, a
synthetic 429 `enforced_spend_limit_reached` envelope from the documented
shape.

## e. Remote Control push

The `walk` mod already calls session tools generically (`$.tool.list()` and
`$.tool.call()`, `mods/walk/hooks/register.tsx`), as it does for `TaskCreate` /
`TaskUpdate`; a push from it is a `$.tool.call` of `PushNotification` when the
session lists that tool. `PushNotification` exists in this session (a
deferred tool, loaded on demand). Called from this session with the user at
the terminal, it returned: "Not sent — this terminal is active, so your output
here already reaches the user; a separate notification would be redundant."
Claude Code suppresses the push while the terminal is active, which suits
always-on (the user is away when it matters) but leaves two things unproven
here: delivery to the phone with Remote Control connected and the terminal
idle (the dogfood run, with the user away), and whether a mod's `$.tool.call`
reaches a deferred tool (a mod probe and test in the build). Neither blocks:
iMessage is the primary channel (a), the push a convenience.

## A resumed session's `total_cost_usd` is cumulative (slice 1)

Measured on the key: `claude -p` (Opus 5.5, `--effort low`, `--tools ""`)
answered `ONE` for $0.0120; `claude -p --resume <that session>` answered `TWO`
on the same session and reported `total_cost_usd` **0.01457**. Its own usage
was 2 input, 2,660 cache-read, 385 cache-write and 5 output tokens, about
$0.0026 at Opus 5.5 prices; 0.0120 + 0.0026 = 0.0146. A resumed session
reports its running total, so step 9's observations (rises per session) count
each call once.

## Summary

| Check | Result |
|---|---|
| a. iMessage | Works from a session and from a LaunchAgent, no Automation prompt; the phone number is the handle. Untested: a locked screen, Messages quit. |
| b. API key routing | Works: a direct call, the reviewer and the Haiku implementer launchers on the key under launchd; the Console showed the spend; a $150 monthly cap is set. |
| c. Tool-less decider | Works: `--tools ""` with the packet on stdin; one JSON object, injection ignored, $0.022 at xhigh. |
| d. Billing text | An invalid key is a C-class `reviewer-error` with `api_error_status: 401` only in the envelope: step 7a amended to read `api_error_status` 401/402/403 first. Spend limits and 429s not provoked. |
| e. Remote Control push | The tool works and is suppressed while the terminal is active; phone delivery and the mod's call to be proven in the build and the dogfood run. |
| f. Version pin | `DISABLE_UPDATES` / `DISABLE_AUTOUPDATER` honoured; Homebrew changes only on `brew upgrade`; a `claude-version-changed` hold added. |
| g. Commits under launchd | Work, no signing configured, no prompt. |
| h. Killed turn | No envelope in json mode; stand-ins reviewer $1.00, decider $0.50, implementer $0.50. |

Step 0 spend: under $0.15 on the key, plus a few cents of subscription use for
the first probes.

