# Axum and SQLx testing: research for the Tier 1 / Tier 2 rules

2026-11-04 · written by a Haiku 5.5 research agent (primary sources only; nothing installed or run)

Status legend: **confirmed** = read in a primary source this session; **UNVERIFIED** = not confirmed in a primary source (either not fetched, fetch failed, or only a secondary source said it).

## Key Takeaways

- **Offline query data is a directory of `query-<hash>.json` files in `.sqlx/`**, one file per `query!` invocation (since sqlx 0.7). `DATABASE_URL` set and non-empty takes precedence over `.sqlx`; `SQLX_OFFLINE=true` forces the cache. [README](https://github.com/launchbadge/sqlx/blob/main/sqlx-cli/README.md), [macros-core query/mod.rs](https://raw.githubusercontent.com/launchbadge/sqlx/main/sqlx-macros-core/src/query/mod.rs)
- **A missing or changed query has no cache entry** (the cache key is a hash of the SQL text), so the macro fails at compile time with the text "`SQLX_OFFLINE=true` but there is no cached data for this query, run `cargo sqlx prepare` to update the query cache" (offline) or "set `DATABASE_URL` to use query macros online, or run `cargo sqlx prepare` to update the query cache" (online without a URL). [macros-core query/mod.rs](https://raw.githubusercontent.com/launchbadge/sqlx/main/sqlx-macros-core/src/query/mod.rs)
- **`cargo sqlx prepare --check` exits nonzero when `.sqlx` is out of date** with the schema. [sqlx-cli README](https://github.com/launchbadge/sqlx/blob/main/sqlx-cli/README.md)
- **`.env` is read with `dotenvy`, and in 0.9.0 the loader walks every ancestor of `CARGO_MANIFEST_DIR`** (no early stop; higher-level files overwrite). A stray parent `.env` can therefore affect a build. Process environment variables win over `.env`. [sqlx-macros-core 0.9.0 metadata.rs](https://docs.rs/crate/sqlx-macros-core/0.9.0/source/src/query/metadata.rs). A 0.9.0 parse-failure report exists but was not read at its primary source: [sqlx issue #4276 (via search, UNVERIFIED)](https://github.com/launchbadge/sqlx/issues/4276)
- **`SQLX_OFFLINE_DIR` is checked first**, then the crate's `.sqlx`, then the workspace root's `.sqlx`. Since 0.9.0 the env var takes precedence over `.env`-set values in macros. [macros-core query/mod.rs](https://raw.githubusercontent.com/launchbadge/sqlx/main/sqlx-macros-core/src/query/mod.rs); [0.9.0 changelog](https://raw.githubusercontent.com/launchbadge/sqlx/main/CHANGELOG.md)
- **`#[sqlx::test]` creates a fresh database per annotated function** for PostgreSQL, MySQL and SQLite; only the server backends need `DATABASE_URL`. SQLite test DBs go to `target/sqlx/test-dbs/<path>.sqlite`, are deleted on success, kept on failure, and stale ones are deleted on the next run. [docs.rs sqlx::test](https://docs.rs/sqlx/latest/sqlx/attr.test.html)
- **`sqlx::migrate!` takes a path relative to the crate root (`Cargo.toml` directory)** and embeds the migrations at compile time. Adding a migration without touching Rust source may **not** trigger a rebuild; stable Rust needs `build.rs` with `cargo:rerun-if-changed=migrations`. [docs.rs migrate!](https://docs.rs/sqlx/latest/sqlx/macro.migrate.html)
- **Migration file names are `migrations/<timestamp>_<name>.sql`** (timestamp-prefixed by `sqlx migrate add`). The checksum-mismatch and version-ordering behaviour is UNVERIFIED (the Migrator docs do not state it). [sqlx-cli README](https://github.com/launchbadge/sqlx/blob/main/sqlx-cli/README.md); [Migrator docs](https://docs.rs/sqlx/latest/sqlx/migrate/struct.Migrator.html)
- **`tower::ServiceExt::oneshot` requires the `util` feature of `tower`**. axum's own testing example uses `oneshot` for in-process tests and a real `TcpListener` + `axum::serve` for one test. [docs.rs tower ServiceExt](https://docs.rs/tower/latest/tower/trait.ServiceExt.html); [axum examples/testing](https://raw.githubusercontent.com/tokio-rs/axum/main/examples/testing/src/main.rs)
- **`axum-test`'s `TestServer` defaults to a mocked (in-process) transport**; `.http_transport()` switches to real HTTP. Its docs do not say how handler panics surface. [docs.rs axum_test::TestServer](https://docs.rs/axum-test/latest/axum_test/struct.TestServer.html)
- **`CatchPanicLayer` (tower-http, feature `catch-panic`) turns a handler panic into a 500 response.** [docs.rs tower_http::catch_panic](https://docs.rs/tower-http/latest/tower_http/catch_panic/index.html)
- **`#[tokio::test]` defaults to a current-thread runtime**; `flavor = "multi_thread"` needs `rt-multi-thread`; `start_paused` needs `test-util`. [docs.rs tokio::test](https://docs.rs/tokio/latest/tokio/attr.test.html)
- **A panic in a `tokio::spawn`ed task does not stop the runtime**; it is delivered as `JoinError` with `is_panic() == true`, and `into_panic()` returns the payload. [docs.rs tokio Builder / JoinError](https://docs.rs/tokio/latest/tokio/runtime/struct.Builder.html); [docs.rs JoinError](https://docs.rs/tokio/latest/tokio/task/struct.JoinError.html)
- **libpq can connect to a Unix socket** via `host=/absolute/dir` or a percent-encoded host in the URI (`postgresql://%2Ftmp%2Fdir/db`). [PostgreSQL libpq docs](https://www.postgresql.org/docs/current/libpq-connect.html)
- **Versions (crates.io, read 2026-11-04):** sqlx 0.9.0, axum 0.8.9, tower 0.5.3, tower-http 0.7.1, axum-test 22.0.0-rc.1 (the API's `max_version`; the latest stable was not confirmed), tokio 1.54.1, hyper 1.12.0. [crates.io API](https://crates.io/api/v1/crates/sqlx)

---

## 1. SQLx compile-time checked macros

**How they connect at build time.** The macros read `DATABASE_URL` (env, falling back to `.env`) and, if it is set and non-empty, connect live and describe the query. [macros-core query/mod.rs](https://raw.githubusercontent.com/launchbadge/sqlx/main/sqlx-macros-core/src/query/mod.rs) (confirmed: `if !db_url.is_empty() => QueryDataSource::live(db_url)`).

**`.env` and parent directories.** The 0.9.0 source iterates `manifest_dir.ancestors()`, joins `.env` onto each, and calls `dotenvy::from_path_iter`; it does not stop at the first hit, so values from higher ancestors overwrite earlier ones. Process env wins over `.env` (`crate::env_opt(...).or(from_dotenv.database_url)`). [sqlx-macros-core 0.9.0 metadata.rs](https://docs.rs/crate/sqlx-macros-core/0.9.0/source/src/query/metadata.rs). The 0.8.x path used `dotenvy::dotenv()` (search-result summary of 0.8.1 source, UNVERIFIED against the file itself). The 0.9.0 changelog includes "fix(macros): smarter `.env` loading, caching, and invalidation" (#4053) and "Change reference to dotenvy" (#4233). [CHANGELOG 0.9.0](https://raw.githubusercontent.com/launchbadge/sqlx/main/CHANGELOG.md)

**Offline mode.**
- Layout: one `query-<hash>.json` per query invocation, in `.sqlx/` (crate-local, else workspace root). `cargo sqlx prepare` saves into `.sqlx` "in the current directory" and the README says it generates "a single `.sqlx` directory at the root of the workspace". [sqlx-cli README](https://github.com/launchbadge/sqlx/blob/main/sqlx-cli/README.md)
- Precedence: "The presence of a `DATABASE_URL` environment variable will take precedence over the presence of `.sqlx`". `SQLX_OFFLINE=true` forces cache use. [sqlx-cli README](https://github.com/launchbadge/sqlx/blob/main/sqlx-cli/README.md)
- `SQLX_OFFLINE` value: truthy if `"true"` (case-insensitive) or `"1"`. [metadata.rs 0.9.0](https://docs.rs/crate/sqlx-macros-core/0.9.0/source/src/query/metadata.rs)
- Missing entry: the hash of the SQL text is the lookup key, so an edited query has no entry. The compile error text is quoted in the Key Takeaways. There is no separate "stale" check in the macro: a changed query simply misses. [macros-core query/mod.rs](https://raw.githubusercontent.com/launchbadge/sqlx/main/sqlx-macros-core/src/query/mod.rs)
- `cargo sqlx prepare --check`: "Exits with a nonzero exit status if the data in `.sqlx` is out of date with the current database schema." [sqlx-cli README](https://github.com/launchbadge/sqlx/blob/main/sqlx-cli/README.md)
- `SQLX_OFFLINE_DIR`: read from process env, falling back to `.env`, and used as the first lookup directory. [metadata.rs 0.9.0](https://docs.rs/crate/sqlx-macros-core/0.9.0/source/src/query/metadata.rs); [macros-core query/mod.rs](https://raw.githubusercontent.com/launchbadge/sqlx/main/sqlx-macros-core/src/query/mod.rs)

**Version history (offline).**
- 0.7.0 (2023-06-30): "The offline mode for the queries has been changed to use a separate file per `query!()` invocation"; `--merged` removed. (#2363) [CHANGELOG](https://raw.githubusercontent.com/launchbadge/sqlx/main/CHANGELOG.md)
- 0.8.0 (2024-07-22): no offline-mode entry in the changelog (SQLite-only and migration-error changes). [CHANGELOG](https://raw.githubusercontent.com/launchbadge/sqlx/main/CHANGELOG.md)
- 0.9.0 (2026-05-06): "breaking: make `offline` optional to allow building without `serde`" (#4077); "Give SQLX_OFFLINE_DIR from environment precedence in macros" (#3962); `sqlx.toml` format (#3383, "Significant changes to the `Migrate` trait"); smarter `.env` loading (#4053). [CHANGELOG](https://raw.githubusercontent.com/launchbadge/sqlx/main/CHANGELOG.md)

**`query!` with SQLite in-memory URLs.** The macros need a database to describe queries against. Whether a `sqlite::memory:` URL at build time yields a useful schema (empty DB, so no tables) is UNVERIFIED for the macro path; the practical implication (no tables exist unless the build-time DB is a file with migrations applied) is UNVERIFIED. The URL forms are confirmed: `sqlite::memory:` is "Open an in-memory database." [sqlx-sqlite options](https://raw.githubusercontent.com/launchbadge/sqlx/main/sqlx-sqlite/src/options/mod.rs)

## 2. Unchecked API (`sqlx::query`, `query_as` with `FromRow`)

- `sqlx::query` / `query_as` run at runtime, need no build-time database, and produce no `.sqlx` entries. `#[derive(FromRow)]` maps columns to fields at runtime. The `FromRow` docs page was 404 at the fetched URL; the runtime-only property is UNVERIFIED from a primary page (it follows from `.sqlx` being used only by the macros, confirmed above).
- What a test pins: the SQL text and the column-name mapping, checked only when the query executes. A test that does not execute the query will not catch a bad column name. This is an inference, UNVERIFIED as a documented claim.

## 3. `#[sqlx::test]`

- **Per test:** "For every annotated function, a new test database is created", and tests are isolated from each other. [docs.rs sqlx::test](https://docs.rs/sqlx/latest/sqlx/attr.test.html) (confirmed)
- **Backends:** PostgreSQL, MySQL, SQLite. [same](https://docs.rs/sqlx/latest/sqlx/attr.test.html) (confirmed)
- **Env:** "Most of these will require you to set `DATABASE_URL` as an environment variable or in a `.env` file." SQLite does not need it. [same](https://docs.rs/sqlx/latest/sqlx/attr.test.html) (confirmed)
- **Migrations:** applied automatically if a `migrations` folder is found "in the same directory as `CARGO_MANIFEST_DIR`". Override with `migrations = "..."`, `migrator = "..."` (an existing `Migrator`), or disable with `migrations = false`. [same](https://docs.rs/sqlx/latest/sqlx/attr.test.html) (confirmed)
- **Fixtures:** SQL scripts applied in the order given; several `fixtures` attributes may be combined. [same](https://docs.rs/sqlx/latest/sqlx/attr.test.html) (confirmed)
- **SQLite files:** `target/sqlx/test-dbs/<path>.sqlite`. Cleanup: removed as tests succeed; failed tests leave theirs in place; previously created ones are deleted the next time a test binary using `#[sqlx::test]` runs. [same](https://docs.rs/sqlx/latest/sqlx/attr.test.html) (confirmed). Note the file is under `target/`, i.e. inside the checkout's build dir, which matters for the sandbox (the proof sandbox allows writes in the checkout).
- **Failure with no database reachable:** the server backends fail when the URL is missing or unreachable; the exact message and exit behaviour are UNVERIFIED (not in the fetched page).
- **Tie to proof sandbox:** a Postgres/MySQL `#[sqlx::test]` needs a live server, which the no-network sandbox forbids unless a unix socket inside TMPDIR is used (see Q6). SQLite does not need a server, so it is the only candidate for a Tier 1 proof under the sandbox, subject to the file location under `target/`.

## 4. `sqlx::migrate!`

- **Path:** "The directory must be relative to the project root (the directory containing `Cargo.toml`)." Unlike `include_str!`, which resolves relative to the invoking file. [docs.rs migrate!](https://docs.rs/sqlx/latest/sqlx/macro.migrate.html) (confirmed)
- **Embedding:** "Embeds migrations into the binary by expanding to a static instance of Migrator." [same](https://docs.rs/sqlx/latest/sqlx/macro.migrate.html) (confirmed)
- **Recompilation:** "The compiler by default only re-runs proc macros when one or more source files have changed." Adding a migration alone may not trigger rebuild; fix on stable is `build.rs` with `cargo:rerun-if-changed=migrations`; nightly uses `--cfg sqlx_macros_unstable`. [same](https://docs.rs/sqlx/latest/sqlx/macro.migrate.html) (confirmed)
- **Checksums:** the Migrator page says `run` "validate[s] previously applied migrations against the current migration source to detect accidental changes", but does not describe the checksum algorithm or the error on mismatch. The "`migrate` errors on a modified applied migration" claim is UNVERIFIED. The macro page notes hashes "may result in un-reproducible hashes across platforms unless taken into account" (line endings), with whitespace-ignoring as a `sqlx.toml` option. [docs.rs migrate!](https://docs.rs/sqlx/latest/sqlx/macro.migrate.html)
- **Ordering by version prefix:** UNVERIFIED (not stated in the fetched Migrator docs). The CLI names files `<timestamp>_<name>.sql`, which suggests timestamp-ordered versions. [sqlx-cli README](https://github.com/launchbadge/sqlx/blob/main/sqlx-cli/README.md)
- **Two branches adding migrations:** not documented; same-timestamp collisions are a file-name collision (UNVERIFIED for whether sqlx detects this). `set_ignore_missing` exists for applied migrations "missing from the resolved migrations", behaviour when false is UNVERIFIED. [Migrator docs](https://docs.rs/sqlx/latest/sqlx/migrate/struct.Migrator.html)
- **Reversible migrations:** `migrate add -r` produces `.up.sql` / `.down.sql`. [sqlx-cli README](https://github.com/launchbadge/sqlx/blob/main/sqlx-cli/README.md)

## 5. SQLite specifics

- **In-memory:** `sqlite::memory:` = "Open an in-memory database" (URL table). `in_memory()` sets `SQLITE_OPEN_MEMORY` and `shared_cache()` sets `SQLITE_OPEN_SHAREDCACHE`; both are off by default. The statement that a pool of more than one connection sees different in-memory databases is UNVERIFIED in the fetched source (no such doc comment found). It is the well-known SQLite behaviour for `:memory:` without shared cache; treat as UNVERIFIED for sqlx specifically. [sqlx-sqlite options](https://raw.githubusercontent.com/launchbadge/sqlx/main/sqlx-sqlite/src/options/mod.rs)
- **Files:** a file DB created in WAL mode produces `-wal` and `-shm`; a rollback journal produces `-journal`. Not checked in sqlx source (UNVERIFIED for sqlx defaults; SQLite's own default journal mode is DELETE, from sqlite.org, not fetched).
- **Bundled libsqlite3:** the 0.9.0 changelog says "`libsqlite3-sys` versioning, feature flags, safety changes" (#3928) and "relax libsqlite3-sys constraint to allow 0.36.x" (#4161), with a release-PR bullet "Increased max of `libsqlite3-sys` version range to `<0.38.0`". Whether `bundled` is the default feature, and what build.rs does, is UNVERIFIED (libsqlite3-sys source not fetched). [CHANGELOG 0.9.0](https://raw.githubusercontent.com/launchbadge/sqlx/main/CHANGELOG.md)
- **Compile-time checks on SQLite:** the 0.7.0 changelog states the SQLite driver's query analysis was revised; the description of how `query!` gets the SQLite schema at build time is UNVERIFIED beyond that.

## 6. Postgres without network

- **Unix socket via URL/params:** confirmed. "If a host name looks like an absolute path name, it specifies Unix-domain communication"; URI form `postgresql:///dbname?host=/var/lib/postgresql` or `postgresql://%2Fvar%2Flib%2Fpostgresql/dbname`. [PostgreSQL libpq docs](https://www.postgresql.org/docs/current/libpq-connect.html)
- **sqlx support for that URL form:** UNVERIFIED (the sqlx Postgres options page was not fetched). The libpq form is the same URL syntax sqlx passes through to its own parser, but this is not confirmed.
- **initdb / pg_ctl in a temp dir:** UNVERIFIED; no primary source fetched. Note that the proof sandbox allows unix sockets only inside TMPDIR, so the socket directory would need to be under TMPDIR, and the server binary must exist on the host.

## 7. Testing Axum

- **`tower::ServiceExt::oneshot`:** "Consume this `Service`, calling it with the provided request once it is ready." Requires the tower `util` feature. [docs.rs tower ServiceExt](https://docs.rs/tower/latest/tower/trait.ServiceExt.html) (confirmed). axum's testing example imports `use tower::{Service, ServiceExt}` and uses `.oneshot(Request::get("/").body(Body::empty()).unwrap())`. [axum examples/testing](https://raw.githubusercontent.com/tokio-rs/axum/main/examples/testing/src/main.rs) (confirmed)
- **Body collection:** the axum example does not use `axum::body::to_bytes`; it uses `response.into_body().collect().await.unwrap().to_bytes()` with `http_body_util::BodyExt`. [same](https://raw.githubusercontent.com/tokio-rs/axum/main/examples/testing/src/main.rs) (confirmed). The `axum::body::to_bytes` signature was not fetched (UNVERIFIED as to its exact signature).
- **`axum-test` TestServer:** default transport is mocked: "mocked (default when possible) or real http networking"; `TestServer::builder().http_transport().build(app)` gives real HTTP; `Transport::HttpRandomPort` / `HttpIpPort` also select real HTTP. `new` panics if the server cannot be built; `try_new` returns the error. [docs.rs axum_test](https://docs.rs/axum-test/latest/axum_test/struct.TestServer.html) (confirmed for these; the panic-propagation of handler panics under mock transport is UNVERIFIED).
- **`Router::with_state`:** not fetched (UNVERIFIED for this session; standard API).
- **Extractor rejection codes (Json):** the Json docs say a request is rejected with `JsonRejection` if there is no `Content-Type: application/json` (or similar), if the body is invalid JSON, or if it does not deserialize. The status codes (415/400/422) are UNVERIFIED: the page at the fetched URL gave no codes and the rejection-variant page was not fetched. [docs.rs axum Json](https://docs.rs/axum/latest/axum/struct.Json.html) (partial)
- **Handler panic surfacing:**
  - **`oneshot`:** whether the panic propagates to the test thread is UNVERIFIED (the axum middleware page did not document it). Expected from ordinary Rust unwinding within `oneshot`'s `await` on the test task, but not confirmed.
  - **Spawned server (`tokio::spawn` + `axum::serve`):** a panic in the task is delivered to the JoinHandle; the server task ends, and the client sees a connection error or reset. Exact client-visible behaviour is UNVERIFIED. [tokio Builder](https://docs.rs/tokio/latest/tokio/runtime/struct.Builder.html) (confirmed for the task-panic semantics)
  - **`CatchPanicLayer`:** converts a panic to a 500 (confirmed); needs crate feature `catch-panic` on tower-http. The default body is not documented on the fetched page (UNVERIFIED). [docs.rs tower_http catch_panic](https://docs.rs/tower-http/latest/tower_http/catch_panic/index.html)

## 8. Tokio test runtime

- `#[tokio::test]` default: single-threaded: "The default test runtime is single-threaded. Each test gets a separate current-thread runtime." [docs.rs tokio::test](https://docs.rs/tokio/latest/tokio/attr.test.html) (confirmed)
- `flavor = "multi_thread"`: requires `rt-multi-thread`; example `#[tokio::test(flavor = "multi_thread", worker_threads = 1)]`. [same](https://docs.rs/tokio/latest/tokio/attr.test.html) (confirmed)
- `start_paused = true`: requires `test-util`. [same](https://docs.rs/tokio/latest/tokio/attr.test.html) (confirmed)
- `tokio::time::timeout`: not fetched (UNVERIFIED for specifics; standard API).
- **Panic in spawned task:** "has no impact on the runtime's execution"; "The panic's error value is forwarded to the task's JoinHandle and all other spawned tasks continue running." [docs.rs tokio Builder](https://docs.rs/tokio/latest/tokio/runtime/struct.Builder.html) (confirmed). `JoinError::is_panic()` = "true if the error was caused by the task panicking"; `into_panic()` returns `Box<dyn Any + Send>`, and panics itself if the error is not a panic. [docs.rs JoinError](https://docs.rs/tokio/latest/tokio/task/struct.JoinError.html) (confirmed)
- **Default panic message and thread name:** the printing hook and the thread name (tokio worker threads) are UNVERIFIED in a primary source fetched here.

## 9. Mocking the database layer

- No mock or test pool in sqlx was found in the fetched primary sources. Claim "sqlx offers no mock pool" is UNVERIFIED as a negative.
- Repository-trait patterns (trait + mockall) are a general Rust pattern, not sourced here; the workflow's Rust rules already ban mockall in oracles, so this is noted only for completeness. UNVERIFIED as a sqlx-specific recommendation.

## 10. Versions and downloads (crates.io API, read 2026-11-04)

| crate | max_version | total downloads | recent (90 days) | last updated |
|---|---|---|---|---|
| sqlx | 0.9.0 | 180,981,598 | 53,857,444 | 2026-05-21 |
| sqlx-macros | 0.9.0 | 180,686,285 | 53,806,476 | 2026-05-21 |
| sqlx-core | 0.9.0 | 183,126,353 | 55,557,569 | 2026-05-21 |
| axum | 0.8.9 | 565,623,748 | 151,125,618 | 2026-04-14 |
| tower | 0.5.3 | 802,822,273 | 224,497,110 | 2026-01-12 |
| tower-http | 0.7.1 | 585,254,473 | 203,623,217 | 2026-08-31 |
| axum-test | 22.0.0-rc.1 | 17,371,792 | 5,116,592 | 2026-08-24 |
| tokio | 1.54.1 | 1,146,833,653 | 288,839,118 | 2026-10-21 |
| hyper | 1.12.0 | 1,084,846,124 | 265,046,234 | 2026-10-06 |

Source: [crates.io API](https://crates.io/api/v1/crates/sqlx) (and the same path for each crate). Note: `max_version` for axum-test is a release candidate; the latest stable was not confirmed.

---

## Candidate oracle hazards

| hazard | what happens in a test run (exit, output, files written) | source URL | confidence |
|---|---|---|---|
| `query!` with no `.sqlx` entry and no `DATABASE_URL` | Compile error (the test binary does not build; cargo exits nonzero). Message: "set `DATABASE_URL` to use query macros online, or run `cargo sqlx prepare` to update the query cache". The trap message is never reached. | https://raw.githubusercontent.com/launchbadge/sqlx/main/sqlx-macros-core/src/query/mod.rs | confirmed |
| Edited SQL text in `query!` with a stale `.sqlx` | Compile error (new hash misses the cache): "`SQLX_OFFLINE=true` but there is no cached data..." in offline mode. No trap run. | same | confirmed |
| `DATABASE_URL` set to a live DB while the sandbox forbids network | Compile-time macro connects; with no network it fails at build time, not as a test trap. | https://github.com/launchbadge/sqlx/blob/main/sqlx-cli/README.md | confirmed (precedence); network failure text UNVERIFIED |
| Stray parent `.env` with unparsable lines | Build fails in macro expansion while reading `.env` (parse error); cwd `.env` does not override. | https://docs.rs/crate/sqlx-macros-core/0.9.0/source/src/query/metadata.rs | confirmed (code path); exact error text UNVERIFIED |
| `cargo sqlx prepare --check` with out-of-date `.sqlx` | Exits nonzero; writes nothing. | https://github.com/launchbadge/sqlx/blob/main/sqlx-cli/README.md | confirmed |
| `#[sqlx::test]` on SQLite | Creates `target/sqlx/test-dbs/<path>.sqlite` under the target dir; removed on success, left on failure; old files deleted on next run. Files written inside the checkout's target dir. | https://docs.rs/sqlx/latest/sqlx/attr.test.html | confirmed |
| `#[sqlx::test]` on Postgres/MySQL with no reachable server | Fails at test setup (before the body runs); exact message and exit code UNVERIFIED. Not a trap. | https://docs.rs/sqlx/latest/sqlx/attr.test.html | unverified (message); confirmed that DATABASE_URL is needed |
| Adding a migration file without touching Rust source | No rebuild on stable, so `migrate!` embeds the old set; the new migration is absent from the test binary. Fix: `build.rs` with `cargo:rerun-if-changed=migrations`. | https://docs.rs/sqlx/latest/sqlx/macro.migrate.html | confirmed |
| Editing an already-applied migration | Runtime checksum validation on `run` is documented as a purpose; the error text/exit is UNVERIFIED. | https://docs.rs/sqlx/latest/sqlx/migrate/struct.Migrator.html | unverified |
| Panic inside a `tokio::spawn`ed server task | Task ends; panic is held in JoinHandle; runtime and other tasks continue. Panic message printed by the default hook (thread name UNVERIFIED). Client sees connection failure (UNVERIFIED). | https://docs.rs/tokio/latest/tokio/runtime/struct.Builder.html | confirmed (task semantics); client-side UNVERIFIED |
| Handler panic behind `CatchPanicLayer` | Converted to HTTP 500 response; test receives a 500 (feature `catch-panic`). Body UNVERIFIED. | https://docs.rs/tower-http/latest/tower_http/catch_panic/index.html | confirmed (500); body unverified |
| Handler panic under `oneshot` (no catch layer) | Expected to unwind into the test's future; whether it surfaces as a test panic (exit nonzero, libtest panicked line) | https://docs.rs/tower/latest/tower/trait.ServiceExt.html | unverified |
| `axum-test` TestServer with default (mock) transport and a panicking handler | Propagation not documented in fetched page | https://docs.rs/axum-test/latest/axum_test/struct.TestServer.html | unverified |
| `#[tokio::test]` default flavor | Current-thread runtime per test; a `spawn`ed task runs only when the test task yields. | https://docs.rs/tokio/latest/tokio/attr.test.html | confirmed |
| `multi_thread` flavor without `rt-multi-thread` feature | Compile error (feature gate); exit nonzero before any trap. | https://docs.rs/tokio/latest/tokio/attr.test.html | confirmed |
| `start_paused` without `test-util` | Compile error (feature gate). | https://docs.rs/tokio/latest/tokio/attr.test.html | confirmed |
| `tower::ServiceExt::oneshot` without `util` feature | Compile error (method not found). | https://docs.rs/tower/latest/tower/trait.ServiceExt.html | confirmed |
| Json extractor with missing `Content-Type: application/json` | Rejected with `JsonRejection`; the status code is UNVERIFIED (not in fetched text). | https://docs.rs/axum/latest/axum/struct.Json.html | unverified (status code) |
| Unix socket for a Postgres test (`host=/dir`) | libpq treats an absolute `host` as a socket directory; a server must exist there. sqlx support for this form UNVERIFIED. | https://www.postgresql.org/docs/current/libpq-connect.html | confirmed (libpq); unverified (sqlx) |
| `sqlite::memory:` in a multi-connection pool | Separate in-memory DBs per connection (SQLite default behaviour); sqlx-specific statement UNVERIFIED. | https://raw.githubusercontent.com/launchbadge/sqlx/main/sqlx-sqlite/src/options/mod.rs | unverified |
