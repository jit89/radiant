# Journal: rust-axum-sqlx-rules

## 2026-11-04T09:38:54Z — ARCHITECT start
House item (FUTURE-WORK 33), done before the Python/C rules at the user's request. Research: web, via a Haiku 5.5 agent (RESEARCH.md). Prototype measurements in ~/dogfood/axum-proto (unsandboxed): the trap prints after the panicked line in every Axum shape; CatchPanicLayer turns the trap into a 500; query! with no DB and no .sqlx is a compile error; a parent .env switches query! online; SQLX_OFFLINE toggles don't trigger a rebuild; two pooled sqlite::memory: connections share one DB in sqlx 0.9.
Ledger confirmed (13 entries). Q1 (user): Postgres, matching production; a real Postgres started inside each proof on a unix socket; SQLite out of scope. Q2 (user): the unchecked SQLx API; checked macros banned (a candidate). Cosmetics as recommended: a new RUST-AXUM-SQLX.md, axum-test out of scope, a "notes" fixture, Homebrew postgresql keg-only, MAX_ROUNDS=5.
PLAN.md locked.

## 2026-11-04T09:38:54Z — ARCHITECT dispatch
Grok round 1 (grok-4.7, fresh session).

## 2026-11-04T09:41:36Z — ARCHITECT scope change (user)
The user asked to add SQLite rules to this item (Q1 had put SQLite out of scope). It is folded into PLAN.md together with the Grok round-1 arbitration; round 2 attacks the combined plan.

## 2026-11-04T09:49:55Z — ATTACKER round 1
Grok REVISE, 7 points (session 8e4221e0-e6b9-4e06-a25e-e51c20461040).

## 2026-11-04T09:49:55Z — ARCHITECT arbitration round 1
All 7 taken (see PLAN-REVIEW-LOG.md): foreground postgres with a leftover check; the socket path measured at the real length, a profile change stopping the item; the sqlx socket URL; mmap and no global SysV IPC; per-case scoring with router/app split; #[sqlx::test] isolation and migrate! staleness; DATABASE_URL unset. SQLite folded in (user): two fixtures, SQLite plants and Tier 2, separate step-0b entries.

## 2026-11-04T09:49:55Z — ARCHITECT dispatch
Grok round 2 (resume).

## 2026-11-04T09:58:48Z — ATTACKER round 2
Grok REVISE, 6 points.

## 2026-11-04T09:58:48Z — ARCHITECT arbitration round 2
All 6 taken (see PLAN-REVIEW-LOG.md): a sibling-trap shape for per-case plants and the launder rule; a postmaster.pid leftover check; the relative socket dropped; a matching .sqlx plant; g2 isolation and a migrations-keyed warm target; clang module cache candidates.

## 2026-11-04T09:58:48Z — ARCHITECT dispatch
Grok round 3 (resume).

## 2026-11-04T10:04:11Z — ATTACKER round 3
Grok REVISE, 2 points.

## 2026-11-04T10:04:11Z — ARCHITECT arbitration round 3
Both taken: the optional regex suffix, with the minus grep shown to hit; DATABASE_URL exported (empty for SQLite) and cold builds for the env rows.

## 2026-11-04T10:04:11Z — ARCHITECT dispatch
Grok round 4 (resume).

## 2026-11-04T10:11:00Z — ATTACKER round 4
Grok REVISE, 2 points.

## 2026-11-04T10:11:00Z — ARCHITECT arbitration round 4
Both taken (wording left by the round-3 fixes): the SQLite rows use the exported DATABASE_URL; a diagnostic grep outside the proof decides whether the macro row counts.

## 2026-11-04T10:11:00Z — ARCHITECT dispatch
Grok round 5 of 5 (resume).

## 2026-11-04T10:13:11Z — ATTACKER round 5
Grok APPROVED.

## 2026-11-04T10:13:11Z — ARCHITECT end (crucible)
Converged in round 5 of 5 (7 + 6 + 2 + 2 points, all taken). Waiting for the user's sign-off.

## 2026-11-04T10:22:30Z — ARCHITECT sign-off
The user signed off PLAN.md (Grok APPROVED round 5). Build in-session.

## 2026-11-04T10:27:03Z — ARCHITECT build: Postgres half stopped (plan step 3)
Installed postgresql@18 18.6 (Homebrew linked it despite keg-only; unlinked, called by absolute path). Probes through proof_exec at real run-goal TMPDIR lengths:
- socket path: 85 bytes for a 2-char goal id, 95 for 12, 106 for 23 (over the 104 cap): TMPDIR fits for goal ids up to 20 chars;
- initdb under the sandbox fails: "could not look up effective user ID 501" (mach-lookup com.apple.system.opendirectoryd.libinfo denied; getpwuid);
- initdb outside, then the server inside: "FATAL: shmat(...) failed: Operation not permitted" (deny ipc-sysv-shm), even with shared_memory_type=mmap and dynamic_shared_memory_type=mmap (Postgres always attaches a small System V interlock segment).
The plan forbids global System V IPC, so the Postgres half stops here and is raised with the user. No leftover servers.

## 2026-11-04T10:28:07Z — ARCHITECT decision (user)
The user chose: finish the SQLite half and the shared Axum rules in this item; Postgres becomes a separate item, a throwaway Postgres started per proof by the host outside the sandbox, with its socket in the proof's TMPDIR, under its own crucible and security review. Its inputs: the probe results above, and the 20-char goal-id socket cap.

## 2026-11-04T10:38:53Z — ARCHITECT build: SQLite step 2b
The fetch succeeded. Red cold on the stub: rc 101 + trap (cargo 16.6 s, including the bundled SQLite C build); green: rc 0; warm: 2.6 s; vendored with no deps folder: passes. Clean g1, g2, g3: (a)(b)(c) hold. #[sqlx::test] SQLite files land under $PWD/target/sqlx/test-dbs/ (gitignored, no tamper). Without CLANG_MODULE_CACHE_PATH, the denials are the same lookup-only cc/ld/ar/xcrun set and no write is refused, so X_clang is dropped. That run took 215 s against cargo's 16.4 s, unexplained (probably a host stall; the extra listing lines are unrelated system daemons in the longer window). Reference ran in a proof (SQLite 3.51.3).

## 2026-11-04T10:46:15Z — ARCHITECT build: plants done (SQLite)
- a1 5xx via app(): the planted case is ok on the stub under minus (the hole); C_layer catches it. Kept.
- a2 listener: with no network the correct implementation fails (precondition: oneshot, or loopback for the walk); with loopback it passes; no hang without a timeout.
- a3 fake repo: a gap, as expected.
- s2 query! with a matching .sqlx: minus (DATABASE_URL empty) compiles and passes, and so does minus + SQLX_OFFLINE; with no .sqlx it is a compile error; full fails on C_macro. Kept. (The first prep failed because SQLX_OFFLINE_DIR must exist; a harness fix.)
- s3 parent .env: the clean oracle is unaffected; macro code with only an unset goes online and fails to compile, while an empty export uses the cache. X_db kept.
- s4a duplicate migration versions: every test panics at setup (UNIQUE constraint on _sqlx_migrations.version), no trap. Rule: the Architect owns migrations (Phase 3).
- s4b: a migration together with a test change: no staleness (the macro re-expands).
- s4c: a migration only, warm, test unchanged: stale without build.rs, green with build.rs rerun-if-changed. Kept.
- s5 file DB in the checkout: the implementation writes notes.db (tamper); C_pool catches it. Kept.
- Tier 2: like, affinity, division, dates-as-text and rowid reuse are red; order without ORDER BY is green 5/5 (deterministic here), recorded as a look-for.
- X_clang dropped (no verdict change).

## 2026-11-04T10:48:21Z — ARCHITECT dispatch
Opus 5.5 review round 1 (fresh, read-only).

## 2026-11-04T11:02:55Z — REVIEWER round 1
Opus FIX: 12 findings plus notes ($3.15). Every measured row matched its log; the defects were in what was published, the scoring, and item 35.

## 2026-11-04T11:02:55Z — ARCHITECT arbitration round 1
All 12 taken:
(1) FULL dropped X_clang (the published recipe never ran); full rerun (run 2), with a 2b-clang comparison row.
(2) X_db relabelled a guard, not a kept rule (no verdict change under the full recipe).
(3) The macro regex covers the _unchecked forms: query(_file)?(_as|_scalar)?(_unchecked)?!.
(4) The pool pattern is sqlite:[^:], so sqlx::sqlite:: imports pass.
(5) The corrected form is published (error paths pinned by a body code); an extractor-rejection plant (a3b) and look-for added.
(6) row_case requires the case to be ok for a per-case keep, scores tamper separately, and errors on a broken full run.
(7) The .sqlx cache is keyed by the lockfile, the plant and the migrations.
(8) row_env prints a verdict on a prep failure.
(9) Item 35 states a byte budget per proof_exec path (the merged-proof path is longer).
(10) Item 35 no longer says the harness is ready for Postgres; the sqlx socket URL is labelled research-only.
(11) The probes are kept as fixture/postgres-probe.sh with a transcript. The leaked System V segment from the first probe (id 589824, cpid 5932, 56 bytes, nattch 0) was confirmed as ours and removed (ipcrm -m 589824); the probe now reaps its own by creator pid. The rerun did not log the opendirectoryd denial again (repeat suppression); the failure message is identical.
(12) The shape names no .env in the checkout.
Notes taken: C_pool other spellings, the single-package assumption, the trap-reader measured scope, a concrete stub return type (unmeasured), GOAL-FORMAT "checks", SDKROOT seen in the proofs (EVIDENCE). Logged: row_t2 scores the whole proof (each plant failed only its own case); s4a warm copy harmless; the s4a no-git-conflict claim is git behaviour and fails closed in a --jobs walk.

## 2026-11-04T11:11:28Z — ARCHITECT dispatch
Run 2 done (the published recipe exactly; verdicts match run 1, plus a3b, a gap). EVIDENCE.md rewritten from run 2. Opus round 2 (narrow).

## 2026-11-04T11:24:41Z — ARCHITECT decision (user)
For FUTURE-WORK item 35, the user chose the recommended socket option: the host gives every Postgres proof a short TMPDIR (no sandbox profile change). Item 35 is the next item, after this one is committed and released.

## 2026-11-04T11:27:24Z — REVIEWER round 2
Opus FIX: 3 findings plus notes ($2.02). All 12 round-1 findings closed; every number matched run 2.

## 2026-11-04T11:27:24Z — ARCHITECT arbitration round 2
All 3 taken: (1) the macro regex left-anchored, with a rules line that comments or strings naming a macro, or a sqlite: URL, fail the check; (2) the initdb cause confirmed by experiment (fixture/postgres-initdb-cause.sh: with only the libinfo lookup allowed, initdb reaches the shared-memory failure); the empty listing recorded as unexplained; a second leaked segment (983040, from that diagnostic, cpid 44849, 56 bytes) removed and the script now cleans up; (3) item 35 states the socket choice, which the user then made: a short TMPDIR per Postgres proof. Notes taken: row_case tamper needs an unchanged tree under full; the ref row without the clang redirect; prep_sqlx applies every migration; sqlite::memory: noted; .sqlx/ in Out of scope; a3b labelled; the denial list completed; the CI=1 example removed; the s4a reason grep; plants-gen header, gpgsign and atomic writes; the stale log removed by clearing the logs before run 3. Run 3: verdicts identical to run 2.

## 2026-11-04T11:27:24Z — ARCHITECT dispatch
Opus round 3 (narrow).

## 2026-11-04T11:30:18Z — REVIEWER round 3
Opus DONE ($0.97), with wording notes.

## 2026-11-04T11:30:18Z — ARCHITECT arbitration round 3
Wording notes taken after DONE: the two leaked segments failed at different steps; run 3 reused the .sqlx cache; the initdb diagnostic used sandbox-exec, not proof_exec; a comment on .down.sql in prep_sqlx. Narrow round 4 on these.

## 2026-11-04T11:32:12Z — REVIEWER round 4
Opus DONE ($0.58). Notes logged without change: pid 44849 is the creator of segment 983040 (a postgres child of initdb); 983040 had nattch 0 (shown by ipcs -m -a during the build, not journaled until now); the first diagnostic run has no kept transcript (the rerun printed the same message).

## 2026-11-04T11:32:12Z — ARCHITECT suite
Full suite started.

## 2026-11-04T12:00:49Z — ARCHITECT suite
Full suite green: 44 test scripts, 0 failures. Waiting for the user's OK to commit.

## 2026-11-04T12:00:55Z — ARCHITECT correction
The previous record is wrong: it was written before the result was read. The suite FAILED: 44 test scripts, 1 failure. Investigating; no commit.

## 2026-11-04T12:36:00Z — ARCHITECT suite (rerun)
The first full run failed one test, proof-test.sh, under 4-way load. run-all.sh printed only its tail and removed the per-test output, so the failing assertion is not recoverable. proof-test.sh passed alone twice (directly and through run-all). A second full run: 44 test scripts, 0 failures. This item touches no code proof-test.sh runs (docs, skills and fixture files only). Read as a load-dependent failure, which is inferred, not observed. Raised with the user: run-all.sh should keep a failing test's full output.

## 2026-11-04T12:36:40Z — ARCHITECT commit
The user OKd commit and release (the green rerun); the run-all.sh gap is FUTURE-WORK item 36.
