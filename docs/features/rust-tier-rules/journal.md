# Journal: rust-tier-rules

## 2026-11-01T21:07:07Z — ARCHITECT start
House item: Rust rules for Tier 1 and Tier 2 (skills/to-goals/RUST.md), using the ts-tier-rules method. Research: RESEARCH.md (Haiku 5.5 agent, primary sources), with an Architect verification section run on rustc 1.99.1. Toolchain installed isolated in ~/.local/rust (rustup from Homebrew, keg-only; no shell profile edits).
Ledger confirmed by the user as presented (13 entries). Decisions:
- Q1: cargo test (libtest) only; nextest left out.
- Q2: plants for proptest, insta, mockall and tokio. rstest, test-case, trybuild, quickcheck and expect-test are left out, with the reasons in PLAN.md.
- Q3: warnings-as-errors is a measured candidate in two forms: the global RUSTFLAGS="-D warnings" and a narrow #![deny(unused_must_use, unreachable_code)] per oracle file.
Cosmetics accepted as recommended: one fixture crate "duration", trap panic!("duration-trap") with _-named stub parameters, edition 2024, toolchain pinned 1.99.1, plants as patches, MAX_ROUNDS=5.
PLAN.md locked. Next: Grok round 1.

## 2026-11-01T21:07:12Z — ARCHITECT dispatch
Grok round 1 (grok-4.7, fresh session) on docs/features/rust-tier-rules/PLAN.md.

## 2026-11-01T21:23:04Z — ATTACKER round 1
Grok REVISE, 8 points (session 6494d5fe-a2e7-49de-ba0f-5ae462b48f26).

## 2026-11-01T21:23:04Z — ARCHITECT arbitration round 1
All 8 taken (see PLAN-REVIEW-LOG.md): one proof_exec environment plus a version check; a single fail-closed grep; panic-pin form and pattern; forbid instead of deny, plus let _ and allow plants; [[test]] committed in Phase 3, two targets; overflow across profiles; trap read only on the panicked line; HashMap rule; denial listing for green runs.

## 2026-11-01T21:23:04Z — ARCHITECT dispatch
Grok round 2 (resume 6494d5fe-a2e7-49de-ba0f-5ae462b48f26).

## 2026-11-01T21:33:12Z — ATTACKER round 2
Grok REVISE, 3 points.

## 2026-11-01T21:33:12Z — ARCHITECT arbitration round 2
Taken: 1 (RUSTC bound to cargo, exact version line from the harness), 2 (sleep 3 plus the same log pipeline). Rejected: 3, on measurement. The default hook prints the trap's panicked block before catch_unwind takes the payload (RESEARCH.md); a set_hook row is added.

## 2026-11-01T21:33:12Z — ARCHITECT dispatch
Grok round 3 (resume).

## 2026-11-01T21:37:06Z — ATTACKER round 3
Grok APPROVED.

## 2026-11-01T21:37:06Z — ARCHITECT end (crucible)
Converged in 3 rounds (8 + 3 points: 10 taken, 1 rejected on measurement). Waiting for the user's sign-off; next is the build (fixture, plants, evidence, RUST.md).

## 2026-11-01T21:39:25Z — ARCHITECT sign-off
The user signed off PLAN.md (Grok APPROVED round 3). Build starts in-session: fixture, step 2b, plants, EVIDENCE.md, RUST.md and doc edits, Opus review, suite, commit on OK, release.

## 2026-11-02T21:06:46Z — ARCHITECT build: stopped at step 2b
The setup run (`cargo fetch --locked` through proof_exec with PROOF_SETUP=1) failed: cargo could not set the mtime of an unpacked file in the deps folder (EPERM; denial `file-write*` on the path). Reproduced without cargo, on macOS 27.0.1: under the generated profile, `touch` is denied in the root, tmp and deps trees alike. With `(deny file-write*)` plus every named write operation allowed (file-write-times included, also acl, finderinfo, mount, file-revoke), touch is still denied; only `(allow file-write*)` lets it through. `(deny default)` plus `(allow file-write-times)` also denies it. So on this macOS version, setting file times is checked under an operation that none of the profile's named allows match. Creating, writing, chmod, rename and unlink all work. Per the plan this is a sandbox profile change: the item stops, and the change is raised with the user as its own reviewed item. The operation name was not found (probed names; the dyld cache grep found nothing).

## 2026-11-02T22:35:23Z — ARCHITECT build: resume at step 2b
The sandbox fix landed (sandbox-write-times, 75840a2, released 8cc04de). The partial deps folder from the failed fetch was moved aside. Rerunning 2b, clean-g1 and clean-g2.

## 2026-11-02T22:36:48Z — ARCHITECT build: step 2b passed
The fetch (setup) succeeded. Red proof on the stub: rc 101 with the trap on the panicked line, 10 s cold. Green proof on the implementation: rc 0. Warm red: 1 s. clean-g1 and clean-g2: (a)(b)(c) hold. Denials (sleep 3, then proof.sh's pipeline): the known harmless set (dirhelper, opendirectoryd, notification_center, logd, analyticsd), plus NEW ones that break nothing: during proofs, cargo's file-write-data on deps/cargo/.package-cache, .package-cache-mutate and .global-cache, an xattr write on deps/cargo/registry, and mach lookups (DiskArbitration, coreservicesd, configd, distributed_notifications); during the fetch, net.link.addr and system-socket. Cargo printed nothing and every verdict is right: it proceeds without the package-cache lock in a read-only CARGO_HOME. The plan says "no new denial" before Rust joins the proved list, so this goes to the user as a judgement. Running all plant rows.

## 2026-11-02T23:18:19Z — ARCHITECT build: plants done
Runs: run 1 found two harness defects (an insta env on cd; the RUSTC marker outside the sandbox trees), plus set_hook nondeterminism and proptest persistence. Fixed, with C_hook and the persistence check added. Run 2 covered every row; run 3 used the host shape (cd <checkout> && proof, CARGO_TARGET_DIR="$PWD/target"), verdicts identical to run 2. Kept: the version check, RUSTC binding, the check (should_panic, #[ignore, catch_unwind is_err/is_ok, mockall/mock!/automock, insta, set_hook), proptest persistence off, #![forbid(unused_must_use, unreachable_code)], --locked, CARGO_TARGET_DIR, both overflow-check env vars, and seven Tier 2 rules. Dropped: global -D warnings, deny, the zero-test guard, include-ignored, panic=abort. Gaps: let _ on a Result or a future. User decision: the new step-2b denials are harmless; Rust joins the proved list. Written: EVIDENCE.md, skills/to-goals/RUST.md (188 lines), GOAL-FORMAT row split (228 lines), SKILL.md 0b and two parentheticals (221), FUTURE-WORK row 306 and item 34.

## 2026-11-02T23:18:19Z — ARCHITECT dispatch
Opus 5.5 review round 1 (fresh, read-only).

## 2026-11-02T23:44:06Z — REVIEWER round 1
Opus FIX: 7 findings plus notes ($3.88). All 7 taken:
(1) crates never reach a serial proof (run-goal.sh clears PROOF_DEPS_DIR) or the implementer (claude-implement.sh sets no CARGO_HOME). Measured the alternative, vendor/ plus a source replacement with no deps folder: the stub passes Tier 1 and the impl exits 0. RUST.md now recommends vendoring; FUTURE-WORK 34 carries the implementer gap (unmeasured).
(2) The denial listing was cut at 40 lines: the pid is now stripped and the head dropped; 2b rerun, full listing in EVIDENCE (adds the metadata.mds lookup; cache-mutate and global-cache appear in red and green).
(3) secs included the denial query: cargo's Finished time is recorded now, M1 cited, PROOF_TIMEOUT named.
(4) include-ignored reworded as "not a candidate".
(5) The opening of RUST.md now names three kinds of kept rule, plus the RUSTC binding.
(6) RUST.md states the env vars that must be unset; the harness unsets CI, INSTA_*, PROPTEST_*, RUST_TEST_THREADS and records each proof's env.
(7) Reference output now verbatim (fixture/reference/output.txt, 5 runs, 5 distinct hashmap orders).
Notes taken: version check in parens (the YAML remark); look-fors for overflow overrides, cfg-gated cases, automock in the library, hostile .cargo/config, two proptest blocks, macro crates under forbid; harness: broken-run and compile-error verdicts, a fetch sentinel, 600 s timeout; GOAL-FORMAT "two checks"; the -0.0 wording; set_hook counts attributed; departures listed in EVIDENCE. Logged: row 28's 518 s in run 3 (a host sleep; cargo 6.5 s).
Run 4 (every row): same verdicts as run 3, apart from set_hook; its first pass had the new compile-error detector matching libtest's "error: test failed", fixed and T2 plus 08 rerun. set_hook now 9 of 20 through.

## 2026-11-02T23:45:01Z — ARCHITECT dispatch
The user chose not to add -j N to run-plants.sh. Opus round 2 (narrow, fresh): is each round-1 finding closed, did the fixes add a defect.

## 2026-11-02T23:50:20Z — REVIEWER round 2
Opus FIX: 1 finding plus 8 notes ($2.35). All seven round-1 findings closed; every number matches run 4.

## 2026-11-02T23:50:20Z — ARCHITECT arbitration round 2
Taken: the FIX (vendor/ and .cargo/config.toml are committed by the Architect in Phase 3 and no goal edits them; the look-for becomes "any goal diff under vendor/ or .cargo/"; FUTURE-WORK 34 adds it, noting the host does not guard them yet). Notes taken: the other-process denial line named in EVIDENCE; ENVSHOW matches digits; a broken run is flagged in run() for every row kind (sanity row 04 rerun: same verdict); RUST_BACKTRACE in RUST.md's list; "goals.py's subset of YAML" wording; vendor size line in item 34. Logged: stray unnumbered 08 logs in logs-run4 from run 1 (no claim depends on them); journal records kept separate from now on.

## 2026-11-02T23:50:20Z — ARCHITECT dispatch
Opus round 3 (narrow): the round-2 changes.

## 2026-11-02T23:51:46Z — REVIEWER round 3
Opus FIX: 1 ($0.50). Every round-2 note was done; the FIX: "the reviewer treats a diff under vendor/ or .cargo/ as a stop" is not backed, because claude-goal-review.sh reads the goal entry, not RUST.md.

## 2026-11-02T23:51:46Z — ARCHITECT arbitration round 3
Taken: every Rust goal's Out of scope names vendor/ and .cargo/ (the reviewer reads the goal entry, GOAL-FORMAT.md:57); the look-for becomes a Phase 3 check ("a Rust goal whose Out of scope does not name them"); FUTURE-WORK 34 names the channel.

## 2026-11-02T23:51:46Z — ARCHITECT dispatch
Opus round 4 (narrow): the round-3 change.

## 2026-11-02T23:52:27Z — REVIEWER round 4
Opus DONE ($0.31).

## 2026-11-02T23:52:27Z — ARCHITECT suite
Full suite started.

## 2026-11-03T00:24:16Z — ARCHITECT suite
Full suite green: 44 test scripts, 0 failures. Waiting for the user's OK to commit.

## 2026-11-03T00:27:19Z — ARCHITECT commit
The user OKd the commit and the release.
