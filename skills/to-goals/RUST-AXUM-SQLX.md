# Rust with Axum and SQLx: Tier 1 and Tier 2

These rules add to [RUST.md](RUST.md) for a Rust project on **Axum** and
**SQLx with SQLite**. Every RUST.md rule still applies. They were measured on
axum 0.8.9, sqlx 0.9.0 (bundled SQLite 3.51.3), tower 0.5.3, tower-http
0.7.1 and tokio 1.54.1, with rustc 1.99.1, against planted oracle defects run
through the host's own proof sandbox
(`docs/features/rust-axum-sqlx-rules/EVIDENCE.md` on the house's main branch).

**Postgres is not covered yet.** Under the proof sandbox, `initdb` cannot look
up the current user (the `opendirectoryd.libinfo` lookup is denied), and past
that, the server always needs System V shared memory, which the sandbox
refuses. A Postgres the host starts per proof, outside the
sandbox, is its own item (FUTURE-WORK item 35). Until it lands, a Postgres
project's oracles cannot run in a walk.

## The project's shape

- **One package at the repository root,** as RUST.md assumes. The checks
  read `src/` and `tests/acceptance/` there.
- **No `.env` in the checkout.** SQLx's tooling usually keeps `DATABASE_URL`
  in a root `.env`. The host stops every goal on a live `.env` in a checkout
  (`secrets-in-checkout`). `DATABASE_URL` comes from the recipe instead.
- **Queries use SQLx's unchecked API:** `sqlx::query_as::<_, T>(sql).bind(…)`
  with `#[derive(sqlx::FromRow)]`, and `query`/`query_scalar` likewise. The
  `query!` family of macros (`query!`, `query_as!`, `query_scalar!`,
  `query_file!`, `query_file_as!`, `query_file_scalar!` and their
  `_unchecked` forms) need a database or a prepared `.sqlx/` at build time.
  Neither a proof nor the implementer has one. The check below rejects them in
  `src/` and `tests/acceptance/`.
- **The router is split in two:**
  - `router(state)` holds the routes and nothing else;
  - `app(state)` is `router` plus the production layers (`CatchPanicLayer`,
    tracing, …).

  Oracles test `router`, never `app`. Behind `CatchPanicLayer`, a stub's panic
  becomes a 500, so an oracle that expects a 500 for an error path passes on
  the trap. If the project names its layered constructor differently, the
  recipe's check names that function instead of `app`.
- **Error paths are pinned by their body, not their status alone.** The plan
  names an error code for each error the planned API returns, and the oracle
  asserts it, as in `b["error"] == "empty_title"`. Such a case fails on the
  stub through the trap, and passes only on the planned code path.
- **Stubs trap in handlers and functions; the routing is real.** Every planned
  handler and function body is `panic!("<feature>-trap")`, while `router`
  itself wires the routes for real. A request then reaches a trap inside a
  request, as the implementation's will. Give stub handlers a concrete return
  type (`(StatusCode, Json<Value>)`, `Response`). A `panic!` body behind
  `impl IntoResponse` may not compile (not measured; the fixture used concrete
  types).
- **Migrations are the Architect's.** Every migration (`migrations/NNNN_*.sql`)
  is committed in Phase 3 with a unique version, and no goal adds one.
  - Two goals each adding a `0002_*.sql` merge without a git conflict, since
    the names differ.
  - Then every test panics at setup (`UNIQUE constraint failed:
    _sqlx_migrations.version`) before any trap.
- **`build.rs` is committed in Phase 3 too.** It holds:

  ```rust
  fn main() {
      println!("cargo:rerun-if-changed=migrations");
  }
  ```

  Without it, a migration added while the test files stay unchanged does not
  rebuild a warm target: the old migration set stays embedded, and the case
  that needs the new one stays red.
- **Every database case is `#[sqlx::test(migrations = "./migrations")]`**,
  route cases included. Each test gets its own fresh database, so libtest's
  threads share no state.
  - With SQLite, the files land under `target/sqlx/test-dbs/`, which is
    gitignored build output under the recipe's `CARGO_TARGET_DIR`.
  - An oracle never opens its own pool: a `sqlite://file.db` in the checkout
    writes `file.db` there (tampering).

## The `proof`

The RUST.md recipe with SQLite's prefix and two more checks (one line in
GOALS.md, shown wrapped; `$CARGO` and `$RUSTC` as in RUST.md):

```bash
unset DATABASE_URL PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE; export DATABASE_URL=;
( "$RUSTC" --version | grep -qx 'rustc 1.99.1 (58cf8f9c3 2026-10-13)' ) &&
( grep -rqE 'should_panic|#\[ignore|catch_unwind\(.*\)\.is_(err|ok)\(\)|mockall|mock!|automock|insta::|assert_[a-z_]*snapshot!|set_hook|CatchPanicLayer|(^|[^A-Za-z0-9_])app\(|SqlitePool::connect|PoolOptions|connect_with|sqlite:[^:]' tests/acceptance; test $? -eq 1 ) &&
( f=$(grep -rl proptest tests/acceptance); test -z "$f" || ! grep -L 'failure_persistence: None' $f | grep -q . ) &&
( grep -rqE '(^|[^A-Za-z0-9_])query(_file)?(_as|_scalar)?(_unchecked)?!' src tests/acceptance; test $? -eq 1 ) &&
CARGO_TARGET_DIR="$PWD/target" CARGO_PROFILE_DEV_OVERFLOW_CHECKS=true CARGO_PROFILE_TEST_OVERFLOW_CHECKS=true RUSTC="$RUSTC" "$CARGO" test --offline --locked --test <id>
```

The first line runs before the `&&` chain. `unset` cannot fail, and the chain
starts at the version check. The checks read text: a comment or string naming
a checked macro (`sqlx::query_as!`) or holding a `sqlite:` URL fails them
too, with no output. Write such text another way.

## Why each added piece is there

- **A guard, not a kept rule: `export DATABASE_URL=` (empty), not only
  `unset`.** sqlx reads `.env` from every ancestor folder of the crate, and a
  value the process does not hold is filled in from there.
  - A parent folder's `.env` sent a build with checked macros online to its
    URL: a compile error.
  - The exported empty value keeps every `.env` out, and selects `.sqlx/`
    when one exists.

  Under the full recipe it changes no verdict: the clean oracle passes either
  way, and the macro check already rejects macro code. It is in the recipe
  because the plan put it there, it costs nothing, and it keeps a stray
  `.env` from mattering if the macro ban is ever lifted.
- **Kept: the check's `CatchPanicLayer` and `app(` patterns.** A 500-expecting
  case built on `app()` passed on the stub beside trapping siblings, a hole a
  whole-proof result cannot show. The check turns that proof into a Tier 1
  failure.
- **Kept: the check's pool patterns** (`SqlitePool::connect`, `PoolOptions`,
  `connect_with`, and a `sqlite:` URL, written `sqlite:[^:]` so that
  `sqlx::sqlite::…` imports still pass). An oracle that opened
  `sqlite://notes.db` in the checkout passed Tier 1, and its implementation
  run wrote `notes.db`: tamper.
- **Kept: the checked-macro check** over `src/` and `tests/acceptance/`. With a
  matching `.sqlx/` committed, `query!` code built and passed without it.
  Without `.sqlx/` it is a compile error either way.
- **Kept: Architect-owned migrations and the `build.rs` line** (above).
- **A precondition: oracles test through `tower::ServiceExt::oneshot`.**
  - A real listener (`TcpListener::bind` plus `axum::serve`) cannot bind
    under the default no-network sandbox, so even the correct implementation
    fails.
  - It passes only with `proof_network: loopback` for the whole walk, which
    the plan must justify.
  - Nothing hangs: the stub's panic closes the connection, so no timeout is
    needed.
- **The trap reader needs no change.** Under the sandbox, `oneshot` and a
  spawned server on the test's own runtime print the trap on the line after a
  `panicked at` line. Unsandboxed in the prototype, so did `CatchPanicLayer`
  and a multi-thread runtime (`tokio-rt-worker`).

Measured and not needed:
- `CLANG_MODULE_CACHE_PATH` (the bundled SQLite C build is refused only lookups);
- `SQLX_OFFLINE=true` (the empty `DATABASE_URL` already selects the cache);
- a timeout around a listener read.

## Tier 2: the database is the reference

Compute every value a query returns with the same bundled SQLite, not by hand:
a small program using only sqlx (an `examples/` target that imports nothing
from the crate under test), run under the proof's recipe. Its output is
recorded with the oracle. Slips it caught:

- `LIKE` is case-insensitive for ASCII: `'Alpha' LIKE 'alpha'` matches;
- type affinity: `'12'` stored in an `INTEGER` column reads back as an
  integer (`'x'` stays text, `'1.5'` becomes real);
- integer division truncates toward zero: `-7 / 2` is `-3`, not `-4`;
- dates stored as text compare as text: `'2026-1-5' < '2026-01-10'` is false;
- without `AUTOINCREMENT`, deleting the highest row lets the next insert
  reuse its id.

## Look for (self-review and oracle review)

- **A case that never calls the planned API**, such as a hand-written
  `NoteRepo` fake asserted on directly. It passes on the stub, and nothing
  automatic sees it (planted; a gap).
- **Rows read without `ORDER BY`** and pinned in order. SQLite returned
  insertion order in every run, but SQL leaves it unspecified: sort, or add
  `ORDER BY`.
- **A status-only case for an extractor rejection.** Axum's extractors
  answer before the handler runs: malformed JSON gives 400, a JSON body of the
  wrong shape 422, a missing content type 415, a non-numeric `Path<i64>` 400.
  A case pinning only such a status passes on the stub without reaching the
  planned API. Malformed JSON was planted (a gap); the other statuses are
  from Axum's documentation. It tests Axum, not the feature.
- **The layered constructor called under another name,** or a layer that
  turns panics into responses other than `CatchPanicLayer`. The check knows
  only the names in its pattern.
- **A pool opened another way:** `SqliteConnection::connect`,
  `Pool::<Sqlite>::connect`, a bare filename, or a `sqlite::memory:` URL all
  pass the check. The tree snapshot still catches a file they write; an
  in-memory database writes none.
- **A migration, `build.rs` or `.sqlx/` in a goal's diff.** All are
  Architect-owned. Name `migrations/`, `build.rs`, `.sqlx/`, `vendor/` and
  `.cargo/` in every goal's Out of scope. (A checked macro renamed on import,
  `use sqlx::query_as as q;`, passes the macro check, and builds only with a
  committed `.sqlx/`.)

## After an upgrade

Pin the new versions in `fixture/notes-sqlite/` and in `run-plants.sh`, and
regenerate the lockfile. Then run
`docs/features/rust-axum-sqlx-rules/fixture/run-plants.sh all` (on the house's
main branch). It needs one `cargo fetch` with network. Every row should match
EVIDENCE.md.
