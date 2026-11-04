//! Goal g1: the repository functions. Clean oracle.
#![forbid(unused_must_use, unreachable_code)]
use notes::*;
use sqlx::SqlitePool;

#[sqlx::test(migrations = "./migrations")]
async fn creates_and_gets(pool: SqlitePool) {
    let n = create_note(&pool, "hi").await.unwrap();
    assert_eq!(get_note(&pool, n.id).await.unwrap(), Some(n));
}

#[sqlx::test(migrations = "./migrations")]
async fn rejects_empty_title(pool: SqlitePool) {
    assert_eq!(create_note(&pool, "  ").await, Err(NoteError::EmptyTitle));
}

#[sqlx::test(migrations = "./migrations")]
async fn missing_is_none(pool: SqlitePool) {
    assert_eq!(get_note(&pool, 42).await.unwrap(), None);
}
