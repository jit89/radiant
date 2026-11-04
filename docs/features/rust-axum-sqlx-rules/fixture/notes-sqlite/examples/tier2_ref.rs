//! Tier 2 reference: the bundled SQLite itself, through sqlx, importing nothing
//! from the crate under test. Runs the fixture's migration, then the same SQL
//! the planned functions are specified to run.
use sqlx::sqlite::SqlitePoolOptions;

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let pool = SqlitePoolOptions::new().max_connections(1).connect("sqlite::memory:").await.unwrap();
    let mig = include_str!("../migrations/0001_notes.sql");
    sqlx::raw_sql(mig).execute(&pool).await.unwrap();
    let v: String = sqlx::query_scalar("SELECT sqlite_version()").fetch_one(&pool).await.unwrap();
    println!("sqlite_version = {v}");
    sqlx::query("INSERT INTO notes (title) VALUES ('Alpha')").execute(&pool).await.unwrap();
    let n: i64 = sqlx::query_scalar("SELECT count(*) FROM notes WHERE title LIKE ?").bind("alpha").fetch_one(&pool).await.unwrap();
    println!("LIKE 'alpha' matches 'Alpha': {n}");
    for s in ["12", "x", "1.5"] {
        sqlx::query("INSERT INTO scores (v) VALUES (?)").bind(s).execute(&pool).await.unwrap();
        let t: String = sqlx::query_scalar("SELECT typeof(v) FROM scores ORDER BY rowid DESC LIMIT 1").fetch_one(&pool).await.unwrap();
        println!("typeof '{s}' stored in INTEGER column: {t}");
    }
    for (a, b) in [(7i64, 2i64), (-7, 2)] {
        let r: i64 = sqlx::query_scalar("SELECT ? / ?").bind(a).bind(b).fetch_one(&pool).await.unwrap();
        println!("{a} / {b} = {r}");
    }
    let lt: bool = sqlx::query_scalar("SELECT ? < ?").bind("2026-1-5").bind("2026-01-10").fetch_one(&pool).await.unwrap();
    println!("'2026-1-5' < '2026-01-10': {lt}");
    sqlx::raw_sql("DELETE FROM notes; INSERT INTO notes (title) VALUES ('a'); INSERT INTO notes (title) VALUES ('b');").execute(&pool).await.unwrap();
    let ids: Vec<i64> = sqlx::query_scalar("SELECT id FROM notes ORDER BY id").fetch_all(&pool).await.unwrap();
    sqlx::query("DELETE FROM notes WHERE title = 'b'").execute(&pool).await.unwrap();
    let c: i64 = sqlx::query_scalar("INSERT INTO notes (title) VALUES ('c') RETURNING id").fetch_one(&pool).await.unwrap();
    println!("ids a,b = {ids:?}; after deleting b, c gets id {c}");
    sqlx::raw_sql("DELETE FROM notes; INSERT INTO notes (title) VALUES ('zeta'); INSERT INTO notes (title) VALUES ('alpha'); INSERT INTO notes (title) VALUES ('mid');").execute(&pool).await.unwrap();
    let t: Vec<String> = sqlx::query_scalar("SELECT title FROM notes").fetch_all(&pool).await.unwrap();
    println!("titles without ORDER BY: {t:?}");
}
