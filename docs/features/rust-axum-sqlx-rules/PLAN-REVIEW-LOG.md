# Plan Review Log: Rust tier rules for Axum and SQLx
Phases 0-1 (recon + interrogation) complete — plan locked with the user. MAX_ROUNDS=5.

## Round 1 — Grok

I'll read the plan and the domain docs around it, then check the repo assumptions it depends on.The recipe that starts Postgres inside a proof is wrong on this machine, and two of the plant rules will be scored backwards. The keep-rule method can stay. These have to be fixed before any fixture is built.

1. **`pg_ctl start` survives the proof.** `pg_ctl start` daemonizes the postmaster with `setsid`. The sandbox reaper only kills the proof's own session (`docs/features/proof-sandbox/PLAN.md` known limit; `scripts/lib/proof.sh`). A separate `TMPDIR` hides the leak during an overlap run, so step 2b can go green while trust-auth servers and their shared-memory segments pile up. Fix: run the `postgres` binary in the foreground as a job of the proof shell, and fail the row if any `postgres` is alive after `proof_exec` returns.

2. **The socket path does not fit the real proof temp directory.** macOS `sun_path` is 104 bytes including the NUL; this repo already lost unix-socket checks to that limit (`docs/features/proof-sandbox/journal.md`). A real proof's temp directory is `$HOME/.cache/claude-coding-workflow/runs/run-goal-<id>-XXXXXX/tmp`, which is 84 characters before the goal id plus `/.s.PGSQL.5432`. A goal id of 20 characters makes `strlen == 104` and the bind fails. The copied harness uses `~/dogfood/rust-tiers/tmp/<row>` (about 60 bytes), so every plant can pass on a path `run-goal.sh` will never use. The checkout is not a fallback: sockets there are denied. Fix: measure `-k` on a directory of the real `run-goal` length, and if that cannot hold `.s.PGSQL.5432`, allow one short per-proof socket directory in the profile instead of publishing `-k "$TMPDIR"`.

3. **The candidate URL is a libpq URL, and sqlx is not libpq.** `postgres://postgres@localhost/postgres?host=$TMPDIR` puts `localhost` in the authority, which sqlx treats as TCP. `PGHOST` is never read by sqlx 0.9. Under the default sandbox the TCP attempt is `EPERM`. Under `proof_network: loopback` (a walk-wide key, `GOAL-FORMAT.md`) that same URL reaches whatever is already on `127.0.0.1:5432`. Default `sslmode=prefer` also drags in a TLS stack the throwaway cluster does not have. Fix: prove one socket-only URL, `postgres://postgres@/postgres?host=<dir>&sslmode=disable`, under `PROOF_NETWORK=none`, and drop `PGHOST`.

4. **A shared-memory denial is answered with an open-ended profile change.** `(deny default)` in `scripts/lib/proof-sandbox.py` leaves `ipc-sysv-shm` and `ipc-sysv-sem` denied, and those operations are not path-scoped. Homebrew Postgres on macOS still wants System V shared memory and semaphores. An allow here lets every proof attach to any of the user's System V segments. Fix: try `shared_memory_type=mmap` and a semaphore setting that stays inside the data directory first; a profile change may add only what that measurement still denies, and may not allow global System V IPC.

5. **The `CatchPanicLayer` body rule makes a bad oracle look proved.** The panic hook prints `notes-trap` before `catch_unwind` swallows it (`Assumption 4`). The harness counts that as Tier 1 (`run-plants.sh` `tier1()`: any `thread … panicked at` line, then the trap). A lone `status == 500` test exits 0, which the pass bar already rejects. Pinning the body turns that into a nonzero exit with the trap still in the log, so Tier 1 flips to pass. With a sibling test that still panics, both variants stay a Tier 1 pass, so the keep rule drops the body rule. The grep of `tests/acceptance/` does not see a layer that lives in `app()`. Fix: Tier 1 counts only an unwinding panic that aborts that test; build the oracle router with no `CatchPanicLayer`, and pattern-check the constructor the oracle actually calls.

6. **One cluster, many threads.** `g1` is ordinary `cargo test` against the proof's single database. Libtest parallelizes tests in one binary; the published recipe never passes `--test-threads=1`. Two inserts race, and the `BIGSERIAL` gap pin flakes. The copied harness also copies a warm `target/` into every row, so a `sqlx::migrate!` staleness result is confounded, and the plan never says whether migrations are `migrate!` (compile-time) or `Migrator` (runtime). Fix: isolate each test (`#[sqlx::test]` or `-- --test-threads=1`), pick one migration API and plant staleness only for that API, and skip the warm-target copy on that row.

7. **Trust auth does not close the item 33 password gap.** `proof_env_unsets` matches the variable name, and `DATABASE_URL` does not match, so a password already in the environment is still in the proof until the recipe overwrites it. The same walk can still read it from another process via `kern.procargs2` (accepted sandbox limit). Fix: `unset DATABASE_URL` at the start of the recipe, then set the socket URL, and leave the strip-list gap open in FUTURE-WORK.

VERDICT: REVISE

### Architect's response
All seven points were taken. The plan was also rewritten to add SQLite, at the user's request (journal, scope change), so round 2 attacks the combined plan.
1. Taken. postgres runs in the foreground as a job of the proof's shell, stopped by an EXIT trap; pg_ctl is not used. The harness fails any row that leaves a postgres alive whose data directory is under its TMPDIR.
2. Taken. The socket path is measured at the real run-goal TMPDIR length with goal ids of 2, 12 and 24 characters. The order: TMPDIR, then a relative socket directory, then a short per-proof directory, which is a profile change and stops the item. The harness's work paths are made the real length.
3. Taken. The socket-only sqlx URL postgres://postgres@/postgres?host=<dir>&sslmode=disable is proved under PROOF_NETWORK=none; PGHOST is dropped.
4. Taken. mmap for shared and dynamic shared memory first; a profile change may add only what is still denied, never global System V IPC, or the item stops.
5. Taken. Per-case scoring is added: the planted case's own libtest result on the stub. Oracles test router() (no layers); app() holds the production layers. The check rejects CatchPanicLayer and app( under tests/acceptance. The body rule is measured by the per-case result.
6. Taken. Every database case is #[sqlx::test] (a fresh database per test), with --test-threads=1 as the fallback. migrate! is chosen and its staleness planted on a row that builds warm from its own clean state.
7. Taken. The recipe unsets DATABASE_URL and the PG* variables first. The strip-list gap is carried to FUTURE-WORK.

## Round 2 — Grok

I'll re-read the revised plan and check it against the earlier findings.The foreground server, the socket-only URL, the `DATABASE_URL` unset, and the ban on global System V IPC are in the plan. Four of the earlier holes are still open, and the leftover-process check added for the first one does not work.

1. **The 5xx plant still launders Tier 1, and the new keep rule keeps the wrong candidate.** Step 5 plants one case that asserts status 500 on `app()`. On the stub that case is `ok` and `cargo test` exits 0, which the pass bar already rejects. Pinning the body turns it into `FAILED` while the panic hook still prints `notes-trap`, so the whole proof becomes a Tier 1 pass. Step 0 keeps a rule when the case goes from `ok` to failed, so candidate (b) is kept and candidate (a) is dropped: the pattern check never produces a libtest line, and the minus run was not a Tier 1 pass, so it matches neither keep clause. The sibling that would make the minus run a real Tier 1 pass is only in the "Why" sentence. The fake `NoteRepo` case is the same shape and is excluded from per-case scoring. Fix: both plants include a sibling that still panics, so the minus run is a whole-proof Tier 1 pass with the planted case `ok`; keep a rule only from that shape, and treat a plus run that newly creates a Tier 1 pass as a launder.

2. **`pgrep -f` matches the check that runs it.** The leftover check looks for a data directory under that row's `TMPDIR`. `pgrep -f` scans every argument list, including its own, so it always finds a hit and every Postgres row fails. Fix: read `postmaster.pid` and `ps -p` that pid for the data directory; the check's own command line must not be the pattern.

3. **A relative socket directory is not a way through the 104-byte cap.** The proof's cwd is the checkout, and the profile allows unix sockets only under `TMPDIR` (Assumption 3). A relative `-k` from that cwd is a checkout socket, which the sandbox denies and `tree_snapshot` records as tamper. Binding with a short relative path still leaves sqlx's `?host=` connect on the absolute directory, and that string is what has to fit in 103 bytes. Fix: drop option 2; the only paths that count are a `$TMPDIR` that fits, or the short per-proof directory that stops the item for its own profile review.

4. **The checked-macro plant cannot keep the ban.** The Postgres prefix exports `DATABASE_URL`, and a non-empty `DATABASE_URL` wins over `.sqlx` (RESEARCH.md). Both planted implementations then fail at compile time against an empty server, so the pattern check changes nothing and is dropped. "A `.sqlx/` the implementer could not have prepared" is a cache that does not match the query, which is the same compile error. On the SQLite fixture `DATABASE_URL` is unset, so a matching cache compiles with no `SQLX_OFFLINE`. Fix: plant a `.sqlx/` that matches the query, run it with `SQLX_OFFLINE=true` on Postgres, and keep the `src/` plus `tests/acceptance/` check only when that crate compiles and runs without the check. Write the regex as `query(_as|_scalar|_file(_as|_scalar)?)!`, not the glob `query_file*!`.

5. **Shared-database isolation still misses `g2`, and the inherited warm target still lands on every other row.** "Every database case" is not tied to `g2.rs`. Those route tests need a pool; if they are ordinary `#[tokio::test]` they share one database under libtest's default threads, which is the race the `BIGSERIAL` plant is there to catch. `run-plants.sh` copies `WARM` into every row it builds. Exempting the staleness row leaves every other row on a target compiled before the fixture's migrations. Fix: state that `g2`'s cases are `#[sqlx::test]` too, and key the shared warm target by lockfile and migrations hash.

6. **A SQLite C-build denial is not automatically a profile change.** `libsqlite3-sys`'s bundled build runs `xcrun` and clang, which write a module cache under `~/Library` or `/var/folders`, outside the trees the profile lets a proof write. The plan's only response to a new denial is to stop and raise a profile change. Fix: set `SDKROOT` and `CLANG_MODULE_CACHE_PATH=$TMPDIR/clang` in the SQLite recipe, then read the denial list.

VERDICT: REVISE

### Architect's response
All six points were taken.
1. Taken. Per-case defects are planted beside a sibling that still traps, so the minus run is a whole-proof Tier 1 pass with the planted case ok. A rule is kept only by turning that into a failure (core rule d). A rule that makes the proof become a Tier 1 pass is a launder and is not credited. The body pin is the corrected clean form, held to (a)(b)(c). The fake-repo plant gets the sibling too.
2. Taken. The leftover check reads postmaster.pid and runs ps -p on that pid; no pgrep pattern.
3. Taken. The relative socket option is dropped. The only outcomes are a TMPDIR path that fits (with a stated goal-id cap) or a short directory, which is a profile change and stops the item.
4. Taken. The plant is a matching .sqlx/ (prepared online with SQLX_OFFLINE_DIR, or sqlx-cli). It runs with SQLX_OFFLINE=true on Postgres and as is on SQLite. The check is kept only if that compiles and runs without it. The regex is query(_as|_scalar|_file(_as|_scalar)?)!.
5. Taken. g2's database cases are #[sqlx::test] too. The warm target is keyed by the lockfile and the migrations hash.
6. Taken. CLANG_MODULE_CACHE_PATH=$TMPDIR/clang and SDKROOT are candidates measured first; only a build-breaking denial is a profile change.

## Round 3 — Grok

I'll re-read the revised plan and check it against the last round of findings.The six earlier holes are closed: the sibling shape and the launder rule, the pid-file check, dropping the relative socket, a matching `.sqlx/` with `SQLX_OFFLINE=true`, `g2` on `#[sqlx::test]`, the migrations-hashed warm target, and the clang cache variables. Two new problems will make the measurements score the wrong way.

1. **The checked-macro regex does not match the plant.** The check is `query(_as|_scalar|_file(_as|_scalar)?)!`. The group is required, so `query!` never matches, and `sqlx::query!` does not either. The plant is an implementation that uses `query!`. With or without the check, that crate compiles and runs, keep rule (d) drops the ban, and Q2 is unenforced. Fix: make the suffix optional, `query(_as|_scalar|_file(_as|_scalar)?)?!`, and confirm the minus run’s grep hits `query!` before treating the row as evidence.

2. **`unset DATABASE_URL` lets an ancestor `.env` fill it back in.** sqlx 0.9 walks every ancestor of the manifest and lets a higher file overwrite a lower one; a variable that is unset loses to `.env`, and one that is set in the process wins (RESEARCH.md). `~/.env` is not on the secret list, and the sandbox still allows the read, so a crate under `/Users/cobalt` loads it. The Postgres prefix sets the socket URL afterward, so that recipe is safe. The SQLite prefix only unsets, so the offline `.sqlx/` plant can go online against whatever `~/.env` names, and the harness-parent `.env` plant can be masked by the home file. Assumption 6 makes this worse: toggling `SQLX_OFFLINE` or `DATABASE_URL` does not rebuild a warm `target/` keyed only by the lockfile and migrations. Fix: export `DATABASE_URL` (empty for SQLite, the socket URL for Postgres) rather than only unsetting it, and build the `.env` and `SQLX_OFFLINE` rows cold.

VERDICT: REVISE

### Architect's response
Both points were taken.
1. Taken. The regex is query(_as|_scalar|_file(_as|_scalar)?)?!, with the suffix group optional, so query! matches. The row counts only if the minus run's grep is shown to hit the plant.
2. Taken. The SQLite recipe exports DATABASE_URL= (empty) after the unset, with sqlx::test acceptance and .env exclusion measured, and sqlite::memory: plus SQLX_OFFLINE=true as the fallback. The .env and SQLX_OFFLINE rows build cold.

## Round 4 — Grok

I'll re-read the revised plan and check the two open findings against it.The regex now matches `query!`, and the SQLite recipe exports an empty `DATABASE_URL` with those rows built cold. Two operational lines still undo those fixes.

1. **The SQLite macro row still runs with no `DATABASE_URL`.** Step 5 says that plant runs "as is (no `DATABASE_URL`, so the cache is used)," and the `#[sqlx::test]` bullet still says SQLite runs "alone." An unset variable is filled from the highest ancestor `.env`, including `~/.env`, so that row goes online and the matching cache is never what compiles. The Postgres row cannot stand in for it: this is the row that is supposed to show the cache being used. Fix: run it under the step 4 export (`DATABASE_URL=` empty), and if an empty value does not select the cache, use that step's fallback (`SQLX_OFFLINE=true`) for this row too.

2. **The evidence condition puts the pattern check in the minus run.** The row counts only if "the minus run's grep" hits `query!`. The minus run is the proof without that check, so it has no grep; the check is the rule under test. Adding it there makes the minus proof fail before `cargo` as well, keep rule (d) sees no change, and the ban is dropped. Fix: a diagnostic grep outside the proof must match the plant's `query!`; the minus proof omits the check and must compile and run; the full proof fails on the check.

VERDICT: REVISE

### Architect's response
Both points were taken: they were inconsistencies left by the round-3 fixes.
1. Taken. The SQLite macro row and the #[sqlx::test] bullet now run under step 4's export (an empty DATABASE_URL, with SQLX_OFFLINE=true as the fallback).
2. Taken. A diagnostic grep outside the proof must match the plant, or the row is void; the minus proof omits the check and must compile and run; the full proof fails on the check.

## Round 5 — Grok

I'll re-read the revised plan and check the two open findings against the operational text.The two open findings are fixed in the steps that get implemented. The SQLite macro row and the `#[sqlx::test]` bullet both use step 4's exported `DATABASE_URL` (empty), and `SQLX_OFFLINE=true` is the fallback when an empty value does not select the cache. The macro-ban row's grep is a harness diagnostic outside the proof: the minus proof omits the check and must compile and run, and the full proof fails on the check.

The socket cap, the foreground server and pid-file check, the mmap-only IPC rule, the sibling shape for the 5xx and fake-repo plants, and the cold builds for `.env` and `SQLX_OFFLINE` rows are unchanged and still consistent with the keep rules.

VERDICT: APPROVED

### Architect's response
Converged: APPROVED in round 5 of 5.
