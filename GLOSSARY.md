# claude-coding-workflow

House workflow for Claude-driven planning and multi-model implementation.

## Terms

**Architect**
The main Claude Code session. Plans, interrogates, arbitrates, decomposes, authors oracles. Does not write target-product feature code. Wakes on a Phase 4/5 stop. Does not sit in the implement/review hop. May not attack its own plan.
Not: "Orchestrator"

**Orchestrator**
A host script (`scripts/run-goal.sh`, `scripts/run-goals.sh`) that walks one goal or the DAG: dispatch implementer, host-assess, dispatch goal reviewer, route the verdict. Not a model.
Not: "Architect", "implementer"

**Host assess**
The Orchestrator's independent check after the implementer exits: git state, proof command run on the host, oracle-untouched, then a host-written `DIFF_FILE` + `PROOF_OUTPUT`. Opus does not start until this passes.
Not: "the implementer's test log", "return handoff"

**Attacker**
Headless Grok. Read-only critic of a locked plan (Phase 2) and of the Architect's acceptance oracles (Phase 3, the oracle review), and a different model from the Architect on purpose. Never reviews implementer diffs. Advises; does not command.
Not: "reviewer" (that word is reserved for the goal reviewer)

**Implementer**
The primary model (`IMPLEMENTER_PRIMARY`: DeepSeek Flash by default, or Claude Haiku 5.5) in headless, sandboxed Claude Code (`claude-implement.sh`). Executes one goal under TDD. See **Implementer fallback** for the one switch to the other model.

**Goal reviewer**
Headless Claude Opus 5.5 judging an implementer diff until the goal is done. A separate session with no access to the Architect's conversation; it needs `--add-dir` for the run dir or it cannot read the diff and proof it is judging.
Not: "Attacker" (that role attacks the plan and the oracles, never an implementer diff)

**Goal**
One shippable vertical slice of a hardened plan. Identity is `g<n>-<slug>`.
Not: "ticket", "issue"

**GOALS.md**
The DAG for a signed-off plan: YAML preamble plus per-goal bodies and oracles.

**blocked_by**
A true gate — the blocked goal is a lie until those ids are done.

**conflicts_with**
A merge hazard, not a gate. A parallel walk never puts two goals in one
**wave** when either names the other; the one-at-a-time walk ignores it.

**Wave**
In a parallel walk (`run-goals.sh --jobs N`), the up-to-N frontier goals
started together, each in its own worktree on `cw/<goal>`, and waited for
together (fork-join) before the next wave is planned.

**Integration**
The walker landing one finished goal of a wave on the walk branch. In a
scratch worktree: journal check, `merge --no-ff` of the commit the goal
reported after its review, `worktree_setup`, the merged proofs of every goal
done in the walk, then `done`; only when all of it is green does the walk
branch fast-forward to the result. Nothing is ever reset. A goal is done only
once integrated.

**frontier**
The goals that may start now: `ready` or `in_progress`, every
`blocked_by` id already `done`. File order.

**Assumptions Ledger**
The single batch of things recon resolved without asking. Confirmed or corrected in one pass.

**Decision map**
The visible tree of still-open choices, split into load-bearing and cosmetic.

**Oracle review**
The Phase 3 attack on the Architect's acceptance oracles: `grok-review.sh --oracle`, a fresh Grok session seeded with the plan and its review log, over this DAG's oracle files only. Capped at 3 counted rounds; gates the commit of GOALS.md and the oracles. A finding that is a plan defect starts `PLAN:` and bounces to the crucible.
Not: "goal review" (Opus, on implementer diffs), "plan attack" (Phase 2)

**Trap stub**
A stand-in for API the plan adds (in the scratchpad, or in the worktree for one run only), every body a trap with a unique message (`abort()` after a flushed print, `raise NotImplementedError("<feature>-trap")`, `panic!`), so an oracle builds and its `proof` fails for the right reason. Never committed, never shown to Grok or the implementer.
Not: a mock or a fake (those return values; a trap only proves the call is reached)

**Satisfiability tier**
How an oracle is shown passable before commit, cheapest first: Tier 1 runs the goal's `proof` against trap stubs and must fail for the right reason; Tier 2 checks computed expected values against a reference or a brute-force model; Tier 3, a full scratch implementation, is a last resort, announced and boxed.
Not: "scratch run" (that is Tier 3 alone)

**Finding**
One defect the goal reviewer wants fixed, emitted as a `FIX: <path>:<line> — <defect> — <what to change>` line. The path it opens with is the file the implementer must change; naming the oracle there bounces the goal.
Not: a numbered analysis heading in the reviewer's prose

**Proof fix round**
A fix round whose findings are the host proof's output (redacted, the first 40 and last 160 lines, at most 16 KiB), not a reviewer's: issued when the proof is red after an implementer pass and clears every mechanical check, inside the shared `MAX_FIX_ROUNDS`. One that changes nothing outside the journal and `GOALS.md` stops as `proof-red`.
Not: a review FIX; "retry"

**Implementer fallback**
The one model switch the implementer makes, primary to secondary, on a new or a resumed primary pass: a safety flag on the pass, `IMPLEMENTER_STATUS: DECLINED`, or DeepSeek's empty balance (HTTP 402). The launcher reruns it once on the other model in a fresh session, journaled as `FALLBACK=(<from> -> <to> (refusal|declined|balance))`, with the primary's thread and cost as `FROM=`. Nothing switches back. Never on a rate limit (429, 503), another error, or a missing key.
Not: "retry", "quota fallback"

**Codex home lock**
The exclusive lock the legacy `deepseek-code.sh` (`IMPLEMENTER=codex`) holds on the shared `CODEX_HOME` while it rewrites `config.toml` and runs. Makes concurrent runs queue rather than read each other's config.
