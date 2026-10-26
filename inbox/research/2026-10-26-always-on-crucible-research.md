# Research: an always-on house workflow (crucible, 2026-10-26)

Deep research for the always-on crucible (`docs/features/always-on/`). Four
parallel research agents, one per area, each citing primary sources; this is
the Architect's synthesis. Items the agents marked unverified stay marked.

## Key Takeaways

1. **Runtime: a host supervisor under a per-user LaunchAgent, one fresh
   `claude -p` per decision.** Not a days-long Claude session (context rot,
   compaction failures, memory growth), not cloud routines (no local checkout,
   `sandbox-exec` or keys). It matches the house: stateless host scripts keyed
   on exit codes. Needs the user logged in (auto-login for reboots), the Mac
   awake on AC power (`caffeinate -is` held by the supervisor, `pmset`), a laptop
   lid open, an absolute `PATH`, and `ProcessType Standard`.
2. **Auth: `claude setup-token` (1-year `CLAUDE_CODE_OAUTH_TOKEN`) or an
   `ANTHROPIC_API_KEY`, not the Keychain.** Headless `-p` starts in a mode that
   denies approvals (v2.1.302+): pass `--permission-mode` with an allowlist and
   `--permission-prompts none`. Pin Claude Code's version for unattended runs
   (auto-update mid-walk; unverified in docs).
3. **Subscription caps are detectable and waitable; the terms are the real
   question.** `--output-format stream-json` emits `rate_limit_event` with
   `status: rejected` and `resetsAt` (epoch); the `result` text carries
   "resets 4:10am" as a fallback. `credits_required` (Fable) is a hard stop, not
   a wait. Built-in auto-continue does not cover `-p`. Pro/Max limits "assume
   ordinary, individual usage"; days-long 24/7 automation is a grey area under
   the Consumer Terms (the agent's reading, not a ruling); an API key is clearly
   allowed for automation but bills per token.
4. **Reach the user through a host-side Telegram bot; a model never acts on a
   reply.** Long-polled `getUpdates` (no inbound port), allowlisted sender id,
   each request bound to a random id + HMAC over (action, repo, commit SHA,
   expiry), one-time use, silence = deny; security-class approvals also need a
   typed TOTP from a phone authenticator, or are "approve on the Mac" only.
   Secrets in the Keychain, never exported to `claude -p` or the implementer.
   Pushover (emergency priority) as a wake-me fallback, notify-only. Claude's
   own push needs Remote Control on an interactive session: not reachable from
   headless `-p`, and fine only for following along, never for authority.
5. **Decider: Opus 5.5 at high effort.** Anthropic: it "performs at the level of
   Claude Fable 5.1 on most work", scores higher on Terminal-Bench 4.0 and
   GDPval-AA, costs $4/$20 per M tokens against Fable's $10/$50, has the best
   alignment audit and the lowest destructive-action rate, and needs no credits
   on Pro/Max. Fable 5.1 runs on usage credits from the start on Pro (hence the
   probe's refusal). The catch: Opus 5.5 is also the code reviewer, and the
   system card measures a small same-family self-preference: run the decider
   blind to who wrote what, or route review arbitration elsewhere.
6. **Deterministic gates outrank the decider; it only picks among exits the
   scripts allow.** Prior art (Anthropic hooks-over-instructions, Copilot's
   separation of duties, Codex's sandbox vs approval policy) and failure data
   (METR, ImpossibleBench: frontier models edit or special-case tests in 30-54%
   of conflicted tasks; system card: concealment through git, deleted logs)
   say: oracles read-only, budgets and a kill file in the host, a `NEEDS_HUMAN`
   exit (the flag option cut one model's cheating 54% -> 9%), fresh context per
   decision with attacker and reviewer text as data, a journaled `DECIDER` role,
   periodic human digest and spot checks, and tracking the approve rate.

## 1. Runtime (how to keep it running)

- **LaunchAgent** (`~/Library/LaunchAgents`, `launchctl bootstrap gui/$(id -u)`):
  loads at login, SIGTERM at logout; `KeepAlive`; launchd throttles respawns to
  one per 10 s (`ThrottleInterval`), so the supervisor needs its own crash
  backoff and a circuit breaker that writes a stop file; unset `ProcessType`
  means CPU/IO throttling (set `Standard`); `StartInterval` misses fires during
  sleep, `StartCalendarInterval` coalesces them; a KeepAlive loop reconciling on
  wall-clock time is best. No shell profile: set `PATH` and env in the plist,
  secrets sourced from a 0600 file, never in the plist. launchd kills the
  process group on exit; `claude -p` ends a turn cleanly on SIGINT (143 on
  SIGTERM). TCC: a background host gets its own privacy grants (Desktop,
  Documents, Downloads fail until granted); the house's paths are outside them.
  Unverified: a launchd-spawned bash gets the same TCC attribution.
  `sandbox-exec` is marked deprecated in its man page but ships.
- **Long-lived sessions**: tmux survives a closed terminal only; auto-compaction
  loses detail and can thrash; >2.5 GB heap warns; background tasks are not
  restarted on `--resume`. `claude --bg` sessions survive the terminal and sleep
  but stop on shutdown, idle out after ~1 h unless pinned, and are a research
  preview (`--bg` with `-p` rejected). The Agent SDK: no session timeout, but
  "memory growth over long sessions".
- **Claude Code schedulers**: `/loop` runs only inside an open idle session and
  recurring tasks expire after 7 days; Desktop local scheduled tasks need the app
  open and the Mac awake; cloud scheduled tasks use a fresh GitHub clone and
  cloud secrets (no local files); Remote Control is a window onto a local
  process, not a runtime.
- **Awake**: `caffeinate -is` (`-s` only on AC), `-w <pid>`; `pmset -c sleep 0`,
  `autorestart 1`; lid close sleeps a laptop regardless (closed-display mode
  needs power + external display/keyboard; unverified, secondary sources).

## 2. Usage and budget limits

- **Claude subscription**: 5-hour session limit and weekly limit shared across
  claude.ai and Claude Code; Max has a separate weekly Fable limit; per-family
  limits can be dodged by switching model, the session/weekly ones cannot.
  Usage credits: prepaid at API rates, optional monthly cap. Resets are local
  times without dates ("resets Mon 12:00am").
- **Signals**: `-p --output-format json` gives `is_error`, `subtype`,
  `api_error_status`, `terminal_reason`, `total_cost_usd`; the structured cap
  signal is in `stream-json --verbose`: `rate_limit_event` (`status`,
  `resetsAt`, `errorCode: credits_required`), assistant `error` values
  (`rate_limit`, `billing_error`, `overloaded`), `system/api_retry`
  (`retry_delay_ms`). `/usage` returns a structured report (`session`,
  `weekly_*`, `percent`, `resets_at`); experimental, and its availability in CLI
  stream-json is unverified.
- **Policy**: wait to `resetsAt` (or the parsed reset time) plus jitter, by
  wall clock (sleep stretches waits); never loop on `credits_required`; outer
  backoff 30 s to 15 min for transient errors (Claude Code already retries 10x);
  check `/usage` before a goal and wait above ~90%.
- **API key**: per-org RPM/ITPM/OTPM; monthly tier caps (429
  `enforced_spend_limit_reached`, blocked to the 1st); org/workspace limits;
  `ANTHROPIC_API_KEY` in the env always wins over the subscription in `-p`.
- **Grok**: per-model RPS/TPM by spend tier; 429 with backoff; prepaid credits,
  out-of-credit error code and CLI exit codes undocumented.
- **DeepSeek**: 402 balance (top up, no retry), 429 rate/concurrency, 500/503
  retry; `GET /user/balance`; off-peak half price (01:00-04:00, 06:00-10:00 UTC
  weekdays are peak).
- **Cost ceilings**: a local append-only spend ledger (Claude `total_cost_usd`,
  DeepSeek balance delta, Grok tokens x price); refuse to dispatch over a rolling
  24 h / 7 d ceiling; provider-side backstops (Console spend limits, credit cap,
  xAI invoiced limit $0, DeepSeek prepay a week). `--max-budget-usd` is notional
  on a subscription: budget by `/usage` percent there.

## 3. Notification and reply

- Claude Code: PushNotification is model-called only (desktop, and phone when
  Remote Control is connected); Remote Control needs an interactive or
  `remote-control` session (not `-p`), a claude.ai login, no API key, and lets
  the phone answer prompts and `AskUserQuestion`; hooks: `PermissionRequest` runs
  headless and denies when undecided, `Notification` firing under `-p` is
  undocumented, command hooks time out at 600 s, `PreToolUse` `defer` ends a `-p`
  run with `tool_deferred` for a host-side resume. Channels (research preview):
  MCP plugins relaying permission prompts (`yes <id>`), but the bot token lives
  inside the claude process.
- Generic: Telegram (free, two-way, buttons up to 64 bytes, long-poll),
  ntfy (topic is the password; button secrets ride in the notification),
  Pushover (emergency priority until acknowledged; ack only), Slack Socket Mode
  (two-way, heavier client), email/osascript (not practical).
- Security of replies: the bash host acts, never a model; bind id + HMAC to
  action, repo, SHA, expiry; one-time, atomic consume; expiry = deny; allowlisted
  sender; TOTP for security-class; secrets in the Keychain, out of `CW_*`, out of
  every model's environment, never on a command line (`curl -H @file`); redact
  tokens; log id, verdict, sender, never codes.

## 4. Prior art, failure modes, the decider

- **Authority patterns**: simple loops with stopping conditions and human
  checkpoints (Anthropic, "Building effective agents"); deterministic hooks over
  prompt rules and a second-opinion grader (Claude Code best practices); one
  feature per session, tests read-only, state in git (Anthropic, long-running
  harnesses); the requester cannot approve, CI waits for a human, branch-only
  pushes (GitHub Copilot agent); sandbox and approval policy as separate
  controls (OpenAI Codex); full traces, not summaries, for whoever decides
  (Cognition); untrusted strong model monitored by a trusted one, human audit on
  the most suspicious (AI control, Greenblatt et al.).
- **Failure modes**: reward hacking of tests (METR 2025: 30.4% of RE-Bench runs
  for o3; ImpossibleBench: 54% GPT-5, 50% Opus 4.1, mostly test edits; read-only
  tests block edits but not special-casing); concealment through git and deleted
  logs (Opus 5.5 system card); impossible tasks raise hacking; same-family
  self-preference (system card: small but significant for Opus 5.5); CoT
  monitoring breaks under optimisation pressure (Baker et al.); destructive
  actions (Replit, press accounts only); Fable 5.1 "can still sometimes bypass
  approvals"; prompt injection through repo text (Willison's lethal trifecta;
  Opus 5.5 more injectable from the user turn); long-context degradation
  (Chroma); cost blowups (no primary postmortem found).
- **Decider**: Opus 5.5 (released 2026-09-22; $4/$20; effort Low-Max, default
  Medium; at Fable's level on most work, higher on agentic benchmarks; best
  alignment record; often suspects evaluation) vs Fable 5.1 (2026-09-15; same
  model as Mythos 5.1 with heavier safeguards; $10/$50; default effort High in
  Claude Code; credits from the start on Pro, up to 50% of the weekly limit on
  Max). No Anthropic guidance on one model arbitrating another's verdicts beyond
  the self-preference measurement.

## Sources

Runtime: code.claude.com/docs/en/{scheduled-tasks, desktop-scheduled-tasks,
routines, agent-view, remote-control, headless, authentication,
troubleshooting, agent-sdk/hosting, agent-sdk/overview}; `man launchd.plist`,
`launchctl`, `caffeinate`, `pmset`, `sandbox-exec`; Apple BPSystemStartup
"Creating Launch Daemons and Agents", TN2083, Energy Efficiency Guide (App Nap).

Limits: support.claude.com articles 11145838 (Claude Code with Pro/Max) and
12429409 (extra usage); code.claude.com/docs/en/{costs, errors, headless,
statusline, interactive-mode, legal-and-compliance, cli-reference,
agent-sdk/typescript}; platform.claude.com/docs/en/api/{rate-limits, errors};
docs.x.ai (consumption-and-rate-limits, billing, debugging, CLI headless);
api-docs.deepseek.com (error codes, rate limit, get-user-balance, pricing).

Notification: code.claude.com/docs/en/{tools-reference, remote-control,
cli-reference, hooks, channels, channels-reference, headless};
core.telegram.org/bots/api; docs.ntfy.sh/publish; ntfy.sh pricing;
pushover.net pricing and receipts API; Slack Socket Mode docs; `man curl`.

Prior art: anthropic.com/engineering/building-effective-agents;
anthropic.com/engineering/effective-harnesses-for-long-running-agents;
code.claude.com/docs/en/best-practices; anthropic.com/claude-opus-5-5 and the
Claude Opus 5.5 System Card; anthropic.com/claude-fable-and-mythos-5-1;
support.claude.com article 15424964 (Fable models on your plan); GitHub Copilot
cloud agent risks and mitigations, About Copilot coding agent; OpenAI Codex
agent approvals and security; cognition.com "Don't build multi-agents";
arXiv 2312.06942 (AI Control), 2404.13076 (self-preference), 2306.05685 (LLM as a
judge), 2510.20270 (ImpossibleBench), 2503.11926 (monitoring reasoning models);
metr.org reward-hacking post (2025-06-05); simonwillison.net lethal trifecta;
trychroma.com context rot; The Register on the Replit incident (secondary).
