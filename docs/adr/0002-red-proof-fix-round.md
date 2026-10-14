# A red host proof is a fix round, not a stop

Amends ADR 0001's stop list: "red host proof" is no longer a stop by itself.

ADR 0001 woke the Architect on every red host proof. One implementer slip then halted an unattended walk until a person reran it, though the fix is usually the implementer's to make. Step 3 (`docs/features/proof-fix/`) turns a red proof that clears every mechanical check into a **proof fix round**: the host sends a bounded, redacted excerpt of the proof output back to the same implementer thread, inside the `MAX_FIX_ROUNDS` budget that review fixes also draw on, and proves again.

**Decision:** the host does not classify why a proof is red; it cannot see intent, and a heuristic over arbitrary test runners would be brittle. Causes leave through exits that already exist or are mechanical: the stops before the red check (timeout, git metadata, proof tamper, contract drift) stay stops; a wrong oracle is the implementer's BLOCKED (the fix handoff names it); a host/sandbox difference is a proof fix round that changes nothing outside the journal and `GOALS.md`, which wakes `proof-red`; everything else is bounded by the shared budget. A resume after that no-progress stop proves before it dispatches.

**Rejected:** classifying the failure from the proof output; a separate budget for proof fixes (a second counter through resume, and up to 3 + 3 rounds); sending the raw output (a key printed by a test would reach a model provider, DeepSeek's included).

**Consequence:** a printed secret is narrowed, not closed: the excerpt is redacted (`scripts/lib/redact.py`, `redact_proof`) and the implementer's handoffs live in their own folder, which confines its Read, Edit and Write tools but not its shell (the sandbox denies reads by path, and the run folder holds the handoff), and the host proof still runs implementer code unsandboxed with network. Sandboxing the host proof is the real fix and is parked in `docs/FUTURE-WORK.md`. Opus and the implementer still never read each other's raw output: the excerpt is host output.
