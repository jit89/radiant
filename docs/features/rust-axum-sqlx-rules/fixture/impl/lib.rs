//! The correct implementation, written after the Tier 2 reference.
use axum::{
    Json, Router,
    extract::{Path, State},
    http::StatusCode,
    routing::{get, post},
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sqlx::SqlitePool;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, sqlx::FromRow)]
pub struct Note {
    pub id: i64,
    pub title: String,
}

#[derive(Debug, PartialEq, Eq)]
pub enum NoteError {
    EmptyTitle,
    Db(String),
}

#[derive(Deserialize)]
pub struct NewNote {
    pub title: String,
}

/// The seam a test double would implement.
pub trait NoteRepo {
    fn get(&self, id: i64) -> Option<Note>;
}

#[derive(Clone)]
pub struct AppState {
    pub pool: SqlitePool,
}

fn db(e: sqlx::Error) -> NoteError {
    NoteError::Db(e.to_string())
}

pub async fn create_note(pool: &SqlitePool, title: &str) -> Result<Note, NoteError> {
    if title.trim().is_empty() {
        return Err(NoteError::EmptyTitle);
    }
    sqlx::query_as::<_, Note>("INSERT INTO notes (title) VALUES (?) RETURNING id, title")
        .bind(title)
        .fetch_one(pool)
        .await
        .map_err(db)
}

pub async fn get_note(pool: &SqlitePool, id: i64) -> Result<Option<Note>, NoteError> {
    sqlx::query_as::<_, Note>("SELECT id, title FROM notes WHERE id = ?")
        .bind(id)
        .fetch_optional(pool)
        .await
        .map_err(db)
}

pub async fn delete_note(pool: &SqlitePool, id: i64) -> Result<bool, NoteError> {
    let r = sqlx::query("DELETE FROM notes WHERE id = ?").bind(id).execute(pool).await.map_err(db)?;
    Ok(r.rows_affected() > 0)
}

pub async fn title_matches(pool: &SqlitePool, pattern: &str) -> i64 {
    sqlx::query_scalar("SELECT count(*) FROM notes WHERE title LIKE ?")
        .bind(pattern)
        .fetch_one(pool)
        .await
        .unwrap()
}

pub async fn stored_type(pool: &SqlitePool, value: &str) -> String {
    sqlx::query("INSERT INTO scores (v) VALUES (?)").bind(value).execute(pool).await.unwrap();
    sqlx::query_scalar("SELECT typeof(v) FROM scores ORDER BY rowid DESC LIMIT 1")
        .fetch_one(pool)
        .await
        .unwrap()
}

pub async fn int_ratio(pool: &SqlitePool, a: i64, b: i64) -> i64 {
    sqlx::query_scalar("SELECT ? / ?").bind(a).bind(b).fetch_one(pool).await.unwrap()
}

pub async fn text_before(pool: &SqlitePool, a: &str, b: &str) -> bool {
    sqlx::query_scalar("SELECT ? < ?").bind(a).bind(b).fetch_one(pool).await.unwrap()
}

pub async fn list_titles(pool: &SqlitePool) -> Vec<String> {
    sqlx::query_scalar("SELECT title FROM notes").fetch_all(pool).await.unwrap()
}

pub async fn create_handler(
    State(s): State<AppState>,
    Json(n): Json<NewNote>,
) -> (StatusCode, Json<serde_json::Value>) {
    match create_note(&s.pool, &n.title).await {
        Ok(note) => (StatusCode::CREATED, Json(json!(note))),
        Err(NoteError::EmptyTitle) => (StatusCode::UNPROCESSABLE_ENTITY, Json(json!({"error": "empty_title"}))),
        Err(NoteError::Db(_)) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "db"}))),
    }
}

pub async fn get_handler(
    State(s): State<AppState>,
    Path(id): Path<i64>,
) -> (StatusCode, Json<serde_json::Value>) {
    match get_note(&s.pool, id).await {
        Ok(Some(note)) => (StatusCode::OK, Json(json!(note))),
        Ok(None) => (StatusCode::NOT_FOUND, Json(json!({"error": "not_found"}))),
        Err(_) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "db"}))),
    }
}

/// The routes, with no layers. Oracles test this.
pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/notes", post(create_handler))
        .route("/notes/{id}", get(get_handler))
        .with_state(state)
}

/// Production: the routes plus layers. Oracles never call this.
pub fn app(state: AppState) -> Router {
    router(state).layer(tower_http::catch_panic::CatchPanicLayer::new())
}
