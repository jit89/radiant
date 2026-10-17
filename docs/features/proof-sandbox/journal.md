# Journal: proof-sandbox (house item 12)

## 2026-10-16T09:56:12Z — ARCHITECT start
Crucible for FUTURE-WORK item 12, on the user's order (item 12 before the rbtree re-run). Recon: proof_exec runs the host proof, worktree_setup and merged proofs unsandboxed; /usr/bin/sandbox-exec works on Darwin 27; the implementer sandbox denies three secret paths. Decisions (user): Q1 own SBPL profile under sandbox-exec (recommended); Q2 (b) deny known secret paths, not all of $HOME (user chose b over the recommended a); Q3 localhost only for proofs, proof_network opt-in, worktree_setup keeps the network; Q4 fail closed, CW_PROOF_SANDBOX=off from the host only; Q5 implementer folder out of the run folder, run folders denied whole (placed under handoffs/ so runs/ can be denied whole). Cosmetic batch accepted. PLAN.md locked; Grok round 1 next.

## 2026-10-16T10:09:17Z — ARCHITECT round 1
Grok round 1: REVISE, 11 findings, all taken (11 with a change: denials surfaced from the unified log for diagnosis, never a red signal). PLAN.md revised; round 2 resumes session 2099711b.

## 2026-10-16T10:16:01Z — ARCHITECT round 2
Grok round 2: REVISE, 5 findings (hard-link pre-check scope, link re-opened by the tmp allow, loopback bind/inbound, older handoff folders, trust-test oracles), all taken. Round 3 resumes.

## 2026-10-16T10:22:14Z — ARCHITECT round 3
Grok round 3: REVISE, 2 findings (hard-link plants in the worktree gitdirs and temp areas; the self-test contradicting the loopback rule), both taken; the first by the general rule that the implementer write set is either unreadable to the proof or walked. Round 4 resumes.

## 2026-10-16T10:33:20Z — ARCHITECT round 4
Grok round 4: REVISE, 1 finding (the implementer TMPDIR inherited from the launching shell) plus a stale sentence; both taken. Round 5, the last (MAX_ROUNDS=5), resumes.

## 2026-10-16T10:39:14Z — ARCHITECT round 5
Grok round 5: APPROVED. Plan converged in 5 rounds (findings 11, 5, 2, 1, 0). Awaiting user sign-off.

## 2026-10-16T10:42:22Z — ARCHITECT sign-off
User signed off PLAN.md after Grok APPROVED (round 5). Next: step 0 measurement (evidence only, no house code), recorded in EVIDENCE.md.

## 2026-10-16T10:59:46Z — ARCHITECT step 0
Step 0 measured on macOS 27.0.1 (EVIDENCE.md). Proofs pass under the draft profile: rbtree and uregex C (with ASan/UBSan, same times as unsandboxed), Vitest, node:test, pytest; setups npm ci, uv sync --frozen, pnpm install (copy mode). Escape probes refused: writes outside the checkout/tmp, secret paths, .git, symlink and hard-link tricks, public network (EPERM), Launch Services (CLI and compiled), AppleEvents, launchctl, securityd, ssh agent, nested sandbox. Three gaps found: the checkout's own .env; a 0.0.0.0 bind reachable from the LAN; any host loopback service reachable. SBPL cannot express own-ports or port ranges; no measured proof needs loopback. Within-intent profile fixes recorded (file-link both ends, parent metadata, output file, root under a denied path, pnpm setup needs). Two changes to locked decisions brought to the user: Q3 no network by default; Q2 deny .env inside the checkout.

## 2026-10-16T11:05:42Z — ARCHITECT amendment 1
User approved: Q3 changed to no network by default (proof_network: loopback | true); Q2 extended to the checkout's .env files; step 0's within-intent fixes; a per-walk dependency folder (setup writes, proofs read) for Rust/Go-style caches; a first-use smoke test per new language in to-goals. Written as Amendment 1; one Grok round on it (same session) before building.

## 2026-10-16T11:12:13Z — ARCHITECT round 6
Grok on Amendment 1: REVISE, 3 findings, all taken (link aliasing measured already refused, layer added anyway; the .env pattern extended to the main checkout and every worktree; step 7 and the loopback exposures). Round 7 resumes.

## 2026-10-16T13:56:55Z — ARCHITECT round 7 void
Round 7 returned error (host slept) (item 11.1 working live); rerun in the same session.

## 2026-10-16T13:59:05Z — ARCHITECT round 7
Grok: REVISE, 1 finding (the implementer can cp/ln .env to a new name before the proof), taken: literal --deny-read of existing .env files for the implementer, and a pre-check on multi-linked .env files. Round 8 resumes.

## 2026-10-16T14:07:33Z — ARCHITECT round 8
Grok: REVISE (mv and case-variant aliasing of .env). Third and fourth patch to one mechanism, so a structural option was offered; the user chose Option 2: no live .env in a walked checkout (secrets-in-checkout gate, CW_ALLOW_DOTENV=1 opt-out). Part B rewritten; round 9 resumes.

## 2026-10-16T14:10:36Z — ARCHITECT round 9
Grok: REVISE, 2 findings (scan order before worktree_setup; a .env symlink), taken; plus ~/.config/cw-secrets on the secret list as the denied home the stop message names. Round 10 resumes.

## 2026-10-16T14:13:27Z — ARCHITECT round 10
Grok: APPROVED Amendment 1. Next: commit the amendment and step 0 evidence (user OK), then build step 1.

## 2026-10-16T14:21:08Z — ARCHITECT build step 1
scripts/lib/proof-sandbox.py and scripts/lib/secret-paths.txt; scripts/tests/proof-sandbox-test.sh (rules against real sandbox-exec, secrets in a private HOME). Build measurements (EVIDENCE.md, correction): a rule naming an operation beats a wildcard rule whatever the order, so every write allow and deny names the same operations; the implicit default deny of file-link loses to named write allows, so an explicit (deny file-link) precedes the link allows; file-link is checked per end, so a link between two allowed trees is allowed (the step 0 root->tmp row was refused only because its source was the denied .env). Deviation from Amendment 1 C.4: a root under a temp area is allowed (its subtree is re-allowed for reads after the temp-area denial); only a root under a secret or house-state path is refused. Real proofs re-run under the generator: rbtree g1, npm ci, Vitest, uv sync, pytest all rc 0. Plants: 9 single red; secrets, state and run-goal need the temp-area layer removed too (the test HOME is inside the temp area) and then go red; exec+mach red; mach-only green by design (the exec layer holds); the explicit link deny is an equivalent mutant today (defence in depth).

## 2026-10-16T20:14:49Z — ARCHITECT build steps 2-4
proof_exec under the sandbox (lib/proof.sh; lib/proof-sandbox.sh: self-test, secrets-in-checkout scan; lib/hardlink-check.py), wired in run-goal.sh (gates before any proof or implementer pass, PROOF_ROOT/WALK/NETWORK/DEPS, proof-hardlink and proof-sandbox-path wakes, serial dependency folder) and the walker (gates once per walk before any worktree, a per-walk dependency folder, sandboxed worktree_setup and merged proofs, handoff folders made before spawn). goals.py: proof_network (loopback|true). claude-implement.sh: --deny-read, the shared secret list. The implementer folder is under handoffs/; the reviewer gets it as a second --add-dir. Step 6 measured with one Haiku pass ($0.009): run folders and other handoff folders refused, its own handoff folder read/write; Claude Code replaces TMPDIR with /tmp/claude-<uid> (under a prefix denied to proofs, as PLAN step 6 required), so the launcher's own TMPDIR setting was removed as dead. Deviations: (1) a root under a temp area is allowed, its subtree re-allowed for reads (test repos and /tmp clones); (2) the overrides ride on the dispatch record (a journal line at the gate dirtied the tree before the fresh-start gate); (3) the walker prints overrides, members journal them; (4) read-only files under a git objects folder are skipped by the hard-link pre-check (local clones hard-link objects). Tests: proof-sandbox-test (generator, rules, scan, pre-check, self-test), proof-test (env, commit oracle, proof-hardlink), proof-fix-test (marker inside the repo, handoff wording), plan-freeze/proof-fix/result-parse (handoff location, --resume anywhere in args), implement-test (deny-read), parallel walk tests (walker logic unsandboxed via the lib; a sandboxed block: plain walk, deps flow, secrets-in-checkout, CW_ALLOW_DOTENV, proof-sandbox-unavailable, commondir under the sandbox).

## 2026-10-16T20:44:26Z — ARCHITECT Opus review r1
Opus r1: FIX (10 FIX, 10 NOTE). Taken: setup/true network IP-only plus the mDNSResponder socket (measured: network* opened unix sockets); the root re-allow moved before the secret/state denials; tty ioctls denied and every proof in its own session; the hard-link objects exception limited to real gitdirs (--gitdir); the self-test checks exact errnos, a temp-area read, DNS, a secret only the secret rule can refuse, and fails against an unsandboxed fake; the serial dependency folder dropped; overrides journaled before a proof-first resume's proof; every goal's artifact folder denied up front; proof_network from the walker; the real profile built once at the gate; 11 credential paths added; tests: inside-root denials, unix socket, gitdir decoy, proof_network values, sandbox-off HEAD moved, override journaled, denial listing, a .env in another worktree. kern.procargs2 measured readable across same-user processes and not gateable by Seatbelt: accepted by the user as a documented known limit. Follow-ups logged in FUTURE-WORK.

## 2026-10-16T21:00:33Z — ARCHITECT plants r1
Plants for the r1 fixes, each red: network* back (2 unix-socket checks), the root re-allow after the secrets (4 inside-root checks), the objects exception wide (the gitdir decoy check), the self-test secret check dropped (the fake-sbx check). Not plantable here: the tty ioctl denial (no controlling terminal in this shell) and the proof-first resume journal line (no test drives that path). All touched tests pass on the final code.

## 2026-10-16T21:22:54Z — ARCHITECT Opus review r2
Opus r2: FIX (2 FIX, 5 NOTE), all r1 findings closed. Taken: sandboxed proofs always use run-timeout.py (RUN_STEP_SESSION=1: a session of its own, the whole session killed; GNU timeout only reached its own group, and the setsid wrapper is gone); the override journal line moved before the tree snapshot (a proof-first resume would have stopped proof-tamper); the denial-listing check names the denied path; PSB_SANDBOX_EXEC fixed in code (tests edit a copy); a proof's own unix sockets allowed inside root/tmp in every mode; npm ci, uv sync, pnpm re-run under the IP-only setup profile (pnpm needed metadata-only on /tmp and /private/tmp under --setup); a --deny-read of a folder made after launch measured refused (Haiku, $0.008). Tests: hang with a child, sandbox-off proof-first resume, own unix socket. Plants: own-socket rule removed (red), journal line after the snapshot (red).

## 2026-10-16T21:43:47Z — ARCHITECT Opus review r3
Opus r3: FIX (2 FIX, 2 NOTE), r2 fixes confirmed. Taken: run-timeout.py --reap (sandboxed runs): after a timeout, a signal or a normal exit, every process still in the session is KILLed (members found by os.getsid; macOS pkill has no -s), signal handlers installed before the child starts; without --reap unchanged. hardlink-check also covers sockets and FIFOs. A proof's own unix sockets allowed in its TMPDIR only (the checkout may hold sockets of unsandboxed processes). Tests: a TERM-ignoring child, a gtimeout stub on PATH never wrapping a proof (the launchers' own steps use it), a child left after exit 0, a linked outside socket, a symlink in TMPDIR to an outside socket, a socket in the checkout refused. Plants, all red: no --reap; the forced timer ignored; sockets unchecked; sockets in the checkout. Remaining limit: a child that makes its own session (setsid) is beyond reach.

## 2026-10-17T00:09:25Z — ARCHITECT Opus review r4
Opus r4: FIX (1 FIX, 5 NOTE), r3 fixes confirmed. Taken: a signal during Popen is held (pending) and acted on once p exists; with no time limit the wait polls (a signal can no longer land inside a blocking waitpid whose lock stop() needs); reap_session KILLs the leader's group first and survives a failed ps; the unix-socket rule split (bind/inbound by local address, outbound by remote); the git-object skip for regular files only; proof.sh comment and PLAN known limits name the setsid escape. Tests: a client bound in TMPDIR cannot reach an outside socket; a read-only FIFO under a gitdir's objects/ is checked. Plants: FIFO skip widened (red); socket rule merged back (green: measured that Seatbelt judges a connect by its remote address, so the merged form never let the client out; the split is a second layer, an equivalent mutant). Untested: the pending-signal window, no-limit polling, the group KILL before the ps scan (smoke: an unbounded --reap run with a TERM-ignoring child stops at once on TERM, child gone). Found while running the rest of the proof-driving tests: signal-test's proof marker moved inside the repo (ignored), resume-state-test matches --resume anywhere in the launcher's arguments; the eleven other proof-driving tests pass.

## 2026-10-17T06:11:37Z — ARCHITECT Opus review r5
Opus r5: DONE (the r4 FIX closed, no defect added, both new checks can fail). Its two NOTEs taken: the own-socket check now accepts and echoes a byte (passes under the split rule, so inbound needs no remote clause); the run-timeout comment says the lock window is "almost never" hit. Next: the full suite and install.sh --check, back to back on an unchanged tree.

## 2026-10-17T06:35:18Z — ARCHITECT gate 1
Full suite 27/28: proof-sandbox-test failed three unix-socket checks only under run-all (its deeper TMPDIR put the outside socket paths past the 104-byte limit; the connect raised "path too long" with no errno). The test now binds and reaches every socket by a short relative path; it passes under run-all. Gate rerun.

## 2026-10-17T07:24:44Z — ARCHITECT gate 2
Full suite 28/28 (49 min; parallel-walk-trust-test the long pole), install.sh --check OK in 11 s (reused the run). Ready for the user's commit OK.
