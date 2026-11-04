//! Goal g3: SQLite semantics. Every expected value is from examples/tier2_ref.rs.
#![forbid(unused_must_use, unreachable_code)]
use notes::*;
use sqlx::SqlitePool;

#[sqlx::test(migrations = "./migrations")]
async fn like_is_case_insensitive(pool: SqlitePool) {
    create_note(&pool, "Alpha").await.unwrap();
    assert_eq!(title_matches(&pool, "alpha").await, 1);
}

#[sqlx::test(migrations = "./migrations")]
async fn integer_affinity(pool: SqlitePool) {
    assert_eq!(stored_type(&pool, "12").await, "integer");
    assert_eq!(stored_type(&pool, "x").await, "text");
}

#[sqlx::test(migrations = "./migrations")]
async fn division_truncates(pool: SqlitePool) {
    assert_eq!(int_ratio(&pool, -7, 2).await, -3);
}

#[sqlx::test(migrations = "./migrations")]
async fn dates_compare_as_text(pool: SqlitePool) {
    assert!(!text_before(&pool, "2026-1-5", "2026-01-10").await);
}

#[sqlx::test(migrations = "./migrations")]
async fn top_rowid_is_reused(pool: SqlitePool) {
    create_note(&pool, "a").await.unwrap();
    let b = create_note(&pool, "b").await.unwrap();
    assert!(delete_note(&pool, b.id).await.unwrap());
    assert_eq!(create_note(&pool, "c").await.unwrap().id, b.id);
}

#[sqlx::test(migrations = "./migrations")]
async fn titles_in_order(pool: SqlitePool) {
    for t in ["zeta", "alpha", "mid"] {
        create_note(&pool, t).await.unwrap();
    }
    let mut got = list_titles(&pool).await;
    got.sort();
    assert_eq!(got, ["alpha", "mid", "zeta"]);
}
