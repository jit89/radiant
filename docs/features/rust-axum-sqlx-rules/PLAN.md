# Plan: Rust tier rules for Axum and SQLx (Postgres and SQLite)
_Locked via crucible — by Claude + cobalt, 2026-11-04. Revised after Grok round 1, with SQLite added at the user's request._

## Goal

`skills/to-goals/RUST.md` holds the core Rust rules for proving an oracle
(Tier 1: the goal's `proof` against trap stubs; Tier 2: computed
expectations), proved on a plain crate. The user's stack is Axum, Tokio and
SQLx (FUTURE-WORK item 33).

This item writes the extra rules that stack needs, for **Postgres** (the
production pairing, Q1) and **SQLite** (added by the user after Q1), in a new
`skills/to-goals/RUST-AXUM-SQLX.md`. The method is the core item's: each rule
is admitted only when a planted oracle defect, on a throwaway crate run
through `proof_exec` under the proof sandbox, shows the rule does one of three
things:
- changes a Tier 1 verdict;
- turns a tampering run clean;
- turns a red run of the correct implementation green.

It also proves that each database can run inside a proof (SKILL.md §4 step
0b):
- **Postgres:** a server started in the proof's temp folder, on a unix
  socket, with no network flag.
- **SQLite:** in-process, compiled from SQLx's bundled C source.

Research: `RESEARCH.md` (Haiku 5.5, primary sources), plus the Architect's
prototype measurements (Assumptions).

## Approach

0. **Verdicts, keep rules and the trap reader are the core item's**
   (`docs/features/rust-tier-rules/PLAN.md` step 0; RUST.md "Reading the
   trap"). Per-case defects are planted in the core item's shape (Grok
   rounds 1 and 2):
   - **The shape.** The planted case sits **beside a sibling case that
     still hits the trap**. Under the minus run the whole proof is a Tier 1
     pass while the planted case itself is `ok` on the stub. That is a
     hole: the case will go green on the implementation having tested
     nothing.
   - **What the harness reads.** Each plant names its case, and the
     harness records libtest's line for it (`test <name> ... ok|FAILED`)
     beside the whole-proof result.
   - **When a rule is kept.** Only from that shape, when the full run turns
     the whole proof from a Tier 1 pass into a failure (the core keep rule
     (d)).
   - **Laundering.** A rule that merely makes the planted case fail while
     the whole proof *becomes* a Tier 1 pass is a launder, and is not
     credited: under the minus run without a sibling, the proof would
     have exited 0, which the pass bar already rejects.
   - **The corrected form.** For example, an error case that pins the
     response body. It is the clean oracle's form, and must pass (a), (b)
     and (c) like any clean oracle.

   Every core RUST.md rule stays in the recipe: the version check, the
   `RUSTC` binding, the pattern check, proptest persistence, `forbid`,
   `--locked`, `CARGO_TARGET_DIR`, the overflow settings, vendored crates.

1. **Tools on the house machine.** `brew install postgresql@<N>`: the current
   stable major, keg-only, never linked onto `PATH`, called by absolute path
   like the Rust toolchain. SQLite needs nothing: sqlx's `sqlite` feature
   bundles and compiles `libsqlite3` (its C build runs in every cold proof).
   The versions go in EVIDENCE.md: Postgres, and the bundled SQLite from
   `select sqlite_version()`.

2. **Two fixtures on one harness,**
   `docs/features/rust-axum-sqlx-rules/fixture/`.
   - **`notes-pg/`** and **`notes-sqlite/`** have the same planned API,
     routes, oracles and Axum plants. Each has its own `Cargo.toml` (only its
     sqlx backend feature) and its own database layer, SQL (`$1` against
     `?`) and migrations.
   - **The harness:** `run-plants.sh` is extended from the core item's, not
     rewritten, keeping `proof_exec`, the tree snapshots, the trap reader,
     the complete denial listings and the env recording. Each row names its
     fixture.
   - **Crates:** axum 0.8.9; sqlx 0.9.0 (`postgres` or `sqlite`,
     `runtime-tokio`, `migrate`, `macros` for `#[sqlx::test]`); tower 0.5.3
     (`util`); tower-http 0.7.1 (`catch-panic`); tokio 1.54.1. Crates are
     vendored per RUST.md, with the toolchain pinned at 1.99.1.
   - **Planned API:**
     - `create_note(&Pool, &str) -> Result<Note, NoteError>`;
     - `get_note(&Pool, i64) -> Result<Option<Note>, NoteError>`;
     - a `NoteRepo` trait (the mocking seam);
     - `router(AppState) -> Router`: the routes `POST /notes` and
       `GET /notes/{id}`, with **no layers**;
     - `app(AppState) -> Router`: `router` plus production layers,
       `CatchPanicLayer` included.

     Oracles test `router`, never `app` (step 4).
   - **Queries** use the unchecked API (`sqlx::query_as::<_, Note>(…)` with
     `#[derive(FromRow)]`), per Q2.
   - **Migrations** use `sqlx::migrate!("./migrations")`, the compile-time
     macro, chosen as the common one. Its staleness is the one planted
     (Grok round 1, point 6).
   - **Stub:** every planned function body is `panic!("notes-trap")`. The
     correct implementation is in `impl/`.
   - **Oracles:**
     - `g1.rs`: the repository functions against the database;
     - `g2.rs`: the HTTP routes through `tower::ServiceExt::oneshot` on
       `router`.

     Each has its `[[test]]` block. Every case in **both** `g1.rs` and
     `g2.rs` that touches a database (the route tests build their router
     state from the pool it hands them) is a
     `#[sqlx::test(migrations = "./migrations")]`. Each test gets a fresh
     database, with no shared state across libtest's threads (Grok rounds
     1 and 2). `-- --test-threads=1` is the measured fallback if
     `#[sqlx::test]` cannot run under the sandbox.
   - **The warm `target/`** copied into rows is keyed by the lockfile
     **and** the migrations folder's hash. A row whose migrations differ
     builds cold. The `migrate!` staleness row builds warm only from its
     own clean state.

3. **Postgres inside the proof** (Grok round 1, points 1 to 4 and 7). The
   candidate recipe prefix, every path by absolute binary:

   ```
   unset DATABASE_URL PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE &&
   "$PG/initdb" -D "$TMPDIR/pg" -U postgres -A trust --no-sync --locale=C --encoding=UTF8 >/dev/null &&
   { "$PG/postgres" -D "$TMPDIR/pg" -k "$SOCK" -c listen_addresses='' -c shared_memory_type=mmap -c dynamic_shared_memory_type=mmap -F & PGPID=$!; } &&
   trap 'kill $PGPID; wait $PGPID' EXIT &&
   <bounded wait for "$SOCK/.s.PGSQL.5432"> &&
   DATABASE_URL="postgres://postgres@/postgres?host=$SOCK&sslmode=disable" <the core recipe>
   ```

   - **The server.** `postgres` runs in the foreground as a job of the
     proof's own shell, not via `pg_ctl start`, which daemonizes with
     `setsid` and would escape `proof_exec`'s session reaper. The harness
     fails any row after which that row's server is still alive. It reads
     the pid from `$TMPDIR/pg/postmaster.pid` (first line) and checks it
     with `ps -p <pid> -o command=` for that data directory. A pattern
     search is not used: `pgrep -f` matches its own command line (Grok
     round 2).
   - **The URL** is sqlx's socket-only form: an empty host,
     `?host=<dir>`, `sslmode=disable`. It is proved under
     `PROOF_NETWORK=none`. `PGHOST` is not used: sqlx does not read it. The
     recipe unsets `DATABASE_URL` and the libpq variables before setting
     its own, because `proof_env_unsets` strips by name and an inherited
     `DATABASE_URL` is kept. The strip-list gap stays open in FUTURE-WORK.
   - **The socket path.** macOS caps a socket path at 104 bytes. A real
     proof's `TMPDIR` is
     `$HOME/.cache/claude-coding-workflow/runs/run-goal-<id>-XXXXXX/tmp`,
     and `/.s.PGSQL.5432` added to it overflows for any goal id longer than
     a few characters. Step 2b measures `-k` on a directory of exactly
     that length, with goal ids of 2, 12 and 24 characters. There are only
     two outcomes:
     1. `$SOCK="$TMPDIR"` when the full socket path fits in 103 bytes for
        the goal ids a walk uses (RUST-AXUM-SQLX.md then states the
        goal-id length cap);
     2. otherwise a **short per-proof socket directory**. That is a sandbox
        profile change, so the item **stops and raises it** with its own
        review.

     A relative socket directory is no way out (Grok round 2). The proof's
     working directory is the checkout, where the sandbox denies sockets
     and a socket file is tamper. sqlx also connects through the absolute
     `?host=` string, which must fit the same 103 bytes.

     The harness's own work paths are made the real length, so no row
     passes on a path `run-goal.sh` never uses.
   - **Shared memory and semaphores.** The profile's `(deny default)`
     leaves `ipc-sysv-shm` and `ipc-sysv-sem` denied, and they are not
     path-scoped. The measurement order:
     1. `shared_memory_type=mmap` and `dynamic_shared_memory_type=mmap`
        (memory inside the data directory);
     2. then whatever the denial listing still names.

     A profile change may add only what that leaves denied, and **may not
     allow global System V IPC**: that would let every proof attach to any
     of the user's segments. If Homebrew's Postgres needs System V
     semaphores and nothing narrower works, the item stops and raises it.
   - **Concurrency.** Two proofs run at once (a `--jobs` walk) each with
     their own `TMPDIR`, data directory and socket, measured once.

   Measured too: the time the cluster adds to a proof, and the complete
   denial listings for the red and green proofs.

   **Where the prefix lives** is a measured candidate:
   - inline in every goal's `proof`;
   - a helper script committed by the Architect in Phase 3 (owned like
     `vendor/`, named in every goal's Out of scope).

4. **SQLite inside the proof.** The candidates, each measured:
   - **The database:** `#[sqlx::test]`'s own per-test SQLite database, or
     `sqlite::memory:` (in sqlx 0.9 a pool's connections share it,
     measured), or a file under `$TMPDIR`. Never a file in the checkout:
     `-wal`, `-shm` and journal files there are new untracked files
     (tamper), and the plant shows it.
   - **Where `#[sqlx::test]` writes its per-test files** under the recipe's
     `CARGO_TARGET_DIR="$PWD/target"`. The prototype found
     `target/sqlx/test-dbs/` by default, kept after a failure. Under
     `target/` they are gitignored build output; anywhere else they are
     tamper. Measured, and pinned if needed.
   - **The bundled C build** of `libsqlite3-sys` under the sandbox. It runs
     `xcrun` and clang, which may write a module cache under `~/Library` or
     `/var/folders`, outside the trees a proof may write. The candidates
     are `CLANG_MODULE_CACHE_PATH="$TMPDIR/clang"` and a fixed `SDKROOT` in
     the SQLite recipe, measured first. A denial left after them goes to
     step 2b's judgement. Only one that breaks the build is a profile
     change, which stops the SQLite half and is raised.
   - **`DATABASE_URL` is exported, not just unset** (Grok round 3). sqlx
     0.9 loads `.env` from every ancestor of the manifest, and a value the
     process does not hold is filled in from there (a `~/.env`, say), while
     one the process holds wins. So the SQLite recipe exports
     `DATABASE_URL=` (empty) after the `unset`. Measured: that an empty
     value keeps `.env` out, at build time and at run time, and that
     `#[sqlx::test]` on SQLite accepts it. If it does not, the candidate is
     a harmless explicit value such as `sqlite::memory:` with
     `SQLX_OFFLINE=true`.

5. **Plants, one per candidate,** scored by step 0. **Axum**, for both
   fixtures:
   - **5xx behind `CatchPanicLayer`.** An oracle case asserting status 500
     for an error path, with the router built by `app` (the layer
     included). The case passes on the stub (the panic becomes a 500), so
     per-case scoring reads it as a hole. Candidates:
     - **(a)** oracles call `router`, which has no layers, and the pattern
       check rejects `CatchPanicLayer` and calls to `app(` under
       `tests/acceptance/`;
     - **(b)** error-path cases also pin the response body, an error code
       the plan names.

     The plant includes a sibling case that still traps (step 0's shape).
     Candidate (a) is kept if it turns the minus run's whole-proof Tier 1
     pass into a failure. Candidate (b) is the corrected clean form: it
     must pass (a), (b) and (c), and is not credited as a catch.
   - **A real listener** (`TcpListener::bind` plus `axum::serve`) in an
     oracle. Under the default no-network sandbox, the bind is refused and
     the correct oracle fails without the trap, which makes it a
     precondition: test through `oneshot`. A listener under
     `proof_network: loopback` is also planted, with and without a
     `tokio::time::timeout`, to measure a hang.
   - **A case that never calls the planned API:** a hand-written fake
     `NoteRepo` asserted on directly, beside a sibling that traps. No grep
     sees it; expected to be a **gap** (the case is `ok` on the stub under
     both runs), written as a look-for.

   **SQLx**, for both fixtures unless noted:
   - **`#[sqlx::test]`:** whether it works with the recipe's
     `DATABASE_URL`: the socket URL on Postgres, step 4's exported value on
     SQLite. Also what it creates and
     removes; whether it writes anywhere outside `target/`.
   - **The checked-macro ban (Q2).** The pattern check, extended over
     `src/` and `tests/acceptance/`, rejects
     `query(_as|_scalar|_file(_as|_scalar)?)?!`: an ERE whose suffix group
     is optional, so plain `query!` and `sqlx::query!` match (Grok round 3).
     The row is scored this way (Grok round 4):
     - a diagnostic grep, run by the harness **outside** the proof, must
       match the plant's `query!`, or the row is void;
     - the minus proof omits the check, and must compile and run;
     - the full proof fails on the check.

     Its
     plant is an implementation using `query!` **with a `.sqlx/` that
     matches the query**. The cache is prepared by the harness with an
     online build against a scratch database and `SQLX_OFFLINE_DIR`, or
     sqlx-cli's `cargo sqlx prepare` if that is what works (measured). It
     is run:
     - on Postgres with `SQLX_OFFLINE=true`, since otherwise the recipe's
       `DATABASE_URL` wins over `.sqlx/` and the build goes online against
       the empty server;
     - on SQLite under step 4's export (`DATABASE_URL=` empty). If an empty
       value does not select the cache, step 4's fallback
       (`SQLX_OFFLINE=true`) applies to this row as well (Grok round 4).
       An unset variable would be filled from an ancestor `.env`, and the
       row would go online.

     The check is kept only if that crate compiles and runs without it, on
     either fixture. A cache that does not match the query is the same
     compile error as no cache at all (Grok round 2), so it is not
     planted.
   - **A parent-directory `.env`** with another `DATABASE_URL`, at build
     time and at run time. Candidates: the recipe exporting its own
     `DATABASE_URL` (the Postgres socket URL, or SQLite's explicit value),
     and `SQLX_OFFLINE=true`. These rows, and every `SQLX_OFFLINE` row,
     **build cold**. Changing those variables alone does not make cargo
     rebuild (Assumption 6), so a warm `target/` would score a stale build.
   - **Migrations:**
     - two goals adding a migration with the same version prefix (a merge
       conflict);
     - a migration added after a warm build, on a row that builds warm
       from its own clean state, with no copied target: does
       `migrate!` see it without a `build.rs` `rerun-if-changed`?

     Candidates: every migration committed by the Architect in Phase 3;
     a committed `build.rs` with `cargo:rerun-if-changed=migrations`.
   - **SQLite only:** a file database in the checkout (tamper), and
     `#[sqlx::test]`'s files if they land outside `target/`.

   **Tier 2: the database is the reference.** Expected values come from the
   same database version, queried directly in the scratchpad before the
   implementation exists (`psql` on a throwaway cluster; the bundled SQLite
   through a scratch sqlx program, since the system `sqlite3` may be another
   version). Plants:
   - **Postgres:**
     - integer division (`7 / 2` is `3`);
     - text order under the pinned `C` collation;
     - rows pinned in order without `ORDER BY` (flaky check);
     - a `timestamptz` round trip (microseconds);
     - a `BIGSERIAL` id after a failed insert (a gap).
   - **SQLite:**
     - type affinity (`'12'` stored in an `INTEGER` column reads back as
       `12`; `'x'` stays text);
     - `LIKE` is case-insensitive for ASCII;
     - integer division;
     - rows without `ORDER BY`;
     - a reused `rowid` after a delete, without `AUTOINCREMENT`;
     - dates stored as text and compared as text.

6. **Evidence:** `EVIDENCE.md`, as in the core item:
   - step 2b per database: the runs, the complete denial listings, the
     socket-path measurement, the leftover-process check and the times;
   - per row: the plant, the minus and full results, the planted case's own
     result, and the verdict;
   - the versions;
   - the run history.

7. **The rulebook.**
   - **`skills/to-goals/RUST-AXUM-SQLX.md`** (new) has three sections:
     - an Axum section shared by both databases;
     - a Postgres section (the recipe prefix, its rules, Tier 2);
     - a SQLite section (its rules, Tier 2).

     Plus the look-fors, and how to rerun the plants.
   - **`RUST.md`:** one line linking it.
   - **SKILL.md §4 step 0b:** "Rust with cargo and Postgres" and "Rust with
     cargo and SQLite" join the proved list **separately**. Each requires
     its own step 2b with no new denial, or the user judging the new ones
     harmless.
   - **GOAL-FORMAT.md:** the Rust row's link list, with no new row; it
     stays at or under 228 lines.

8. **Carried inputs** go to FUTURE-WORK, addressed to the first Axum + SQLx
   project:
   - the implementer's sandbox may not be able to start Postgres or reach a
     database (unmeasured);
   - checked macros stay off until it can;
   - the `DATABASE_URL` strip-list gap;
   - the Postgres install and version;
   - cold proof times.

9. **Review and release** per the house recipe:
   - a fresh Opus review, then narrow rounds until DONE;
   - the full suite;
   - one commit on the user's OK;
   - `install.sh`;
   - `make-release.sh` and a push of both branches;
   - delete the throwaway work area.

## Key decisions & tradeoffs

- **Postgres first, matching production (Q1, user); SQLite added (user).**
  Both are proved, sharing the Axum plants. Cost: two fixtures, and a
  Postgres per proof.
- **The unchecked SQLx API (Q2, user).** No database at build time, so the
  implementer can always compile. Cost: SQL errors surface only when the
  oracles run, which is always against a real database.
- **Postgres in the foreground of the proof's shell, not `pg_ctl`.** Only a
  job of the proof's own session is reaped. Cost: the recipe owns startup,
  the wait and shutdown.
- **No global System V IPC, ever.** If Postgres cannot run on mmap shared
  memory plus a narrower allowance, this item stops rather than open every
  user segment to every proof.
- **Per-case scoring alongside the whole-proof bar.** A case that is green on
  the stub is a hole whatever its siblings do. Without it, the 5xx defect
  could not be measured at all.
- **Oracles test `router`, never `app`.** The production layers (the panic
  catcher above all) stay out of the oracle's path.
- **The database is the Tier 2 reference.** The same version, queried
  directly, never a hand-computed SQL result.
- **One new file.** RUST.md is already 251 lines.

## Assumptions

1. The method, keep rules and trap reader are the core item's —
   `docs/features/rust-tier-rules/PLAN.md`; `skills/to-goals/RUST.md`.
2. Versions (crates.io, 2026-11-04): axum 0.8.9, sqlx 0.9.0, tower 0.5.3,
   tower-http 0.7.1, hyper 1.12.0, tokio 1.54.1 — the prototype's
   `Cargo.lock`; RESEARCH.md.
3. The proof sandbox allows unix sockets only inside the proof's private
   `TMPDIR`, and denies them in the checkout — `scripts/lib/proof-sandbox.py`.
   `proof_exec` kills what is left in the proof's own session; a process that
   starts its own session escapes (a known limit) — `scripts/lib/proof.sh`,
   proof-sandbox PLAN.
4. Measured, prototype, unsandboxed: a handler's trap prints on the line after
   `panicked at` in every case:
   - through `oneshot`;
   - behind `CatchPanicLayer` (then the 500 fails a 200 assertion);
   - from a server spawned on `current_thread` (the test's thread);
   - from a server spawned on `multi_thread` (`tokio-rt-worker`).

   With a spawned server, the client reads 0 bytes.
5. Measured: behind `CatchPanicLayer` the stub's panic becomes status 500.
6. Measured: `query!` with no `DATABASE_URL` and no `.sqlx/` is a compile
   error, and so is `SQLX_OFFLINE=true` with no cache entry. Toggling
   `SQLX_OFFLINE` alone does not make cargo rebuild.
7. Measured: a parent-directory `.env` with `DATABASE_URL` switches `query!` to
   online mode — prototype; RESEARCH.md (sqlx-macros-core 0.9 walks every
   ancestor).
8. Measured: in sqlx 0.9, two pooled `sqlite::memory:` connections share one
   database.
9. `#[sqlx::test]` for SQLite kept a file under `target/sqlx/test-dbs/` after a
   failure (prototype, default target dir); its location under a moved target
   dir was not found, so it is measured in step 4.
10. `sqlx::migrate!` embeds `./migrations` at compile time; a new file may not
    trigger a rebuild without `build.rs` — RESEARCH.md (docs.rs).
11. No Postgres server and no Docker on this machine — `command -v`.
12. macOS caps a unix socket path (`sun_path`) at 104 bytes, NUL included; the
    house hit it before — `docs/features/proof-sandbox/journal.md`.
13. `proof_env_unsets` strips variables by name (KEY, TOKEN, SECRET, PASSWORD,
    PASSWD, CREDENTIAL(S), CW_*); `DATABASE_URL` is not stripped —
    `scripts/lib/proof.sh`.
14. Carried from the core item: vendoring is measured for host proofs, not the
    implementer; `vendor/` and `.cargo/` are Architect-owned — RUST.md,
    FUTURE-WORK item 34.

## Risks / open questions

- **The sandbox may refuse Postgres:**
  - the socket path is too long (step 3);
  - System V semaphores are needed;
  - something else `initdb` probes.

  Each one that needs a profile change stops this item and is raised for
  its own review. The SQLite half can still finish on its own if the user
  chooses.
- **Proof time.** `initdb` and a server start per proof, measured. One
  cluster per walk would be a launcher change, out of scope.
- **The implementer** may not be able to run either database's oracles itself
  (carried).
- **Version drift.** sqlx 0.x and axum 0.x change across minors; pinned, with
  rerun instructions.
- **Network for the one-time crate and Homebrew downloads.** If either is
  unreachable, stop and tell the user.

## Out of scope

- MySQL; checked macros (`query!`, `.sqlx/`).
- `axum-test`; real-listener oracles beyond step 5's measurement.
- Changes to `run-goal.sh`, the launchers or the sandbox profile (a needed
  profile change stops the affected half and is raised).
- How the implementer reaches a database (carried).
- The Python and C/C++ rules (the next items).
