# Phase 4/5 happy path is a host script, not a Grok hop

Grok-in-the-loop was the v1 orchestrator because the launchers are one-shot. That hop is latency, not judgment. Judgment is required only when the tree or the spec is not reviewable.

**Decision:** a host Orchestrator runs implement → assess → review → FIX/DONE. DeepSeek and Opus never read each other's raw output. Grok wakes on a stop (BLOCKED, red host proof, oracle touch, dirty tree, quota, error, MAX_FIX_ROUNDS).

**Rejected:** DeepSeek finishes → Opus reviews implementer-authored output → DeepSeek reads the Opus essay. That lets both models grade their own work and turns BLOCKED into another implementer pass.

**Consequence:** dirty trees fail closed (wake) rather than auto-commit, because the shared working tree may hold Architect WIP.

**Amended:** red host proof — by [0002](0002-red-proof-fix-round.md): a red proof that clears the mechanical checks is a proof fix round; `proof-red` now wakes on a round that changed nothing.
