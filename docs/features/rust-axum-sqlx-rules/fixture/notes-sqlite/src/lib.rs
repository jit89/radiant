//! The stub: the planned API. The route wiring is real; every handler and
//! function body is a trap, so a request reaches a trap inside a request.
use axum::{
    Json, Router,
    extract::{Path, State},
    http::StatusCode,
    routing::{get, post},
};
use serde::{Deserialize, Serialize};
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

pub async fn create_note(_pool: &SqlitePool, _title: &str) -> Result<Note, NoteError> {
    panic!("notes-trap")
}

pub async fn get_note(_pool: &SqlitePool, _id: i64) -> Result<Option<Note>, NoteError> {
    panic!("notes-trap")
}

pub async fn delete_note(_pool: &SqlitePool, _id: i64) -> Result<bool, NoteError> {
    panic!("notes-trap")
}

pub async fn title_matches(_pool: &SqlitePool, _pattern: &str) -> i64 {
    panic!("notes-trap")
}

pub async fn stored_type(_pool: &SqlitePool, _value: &str) -> String {
    panic!("notes-trap")
}

pub async fn int_ratio(_pool: &SqlitePool, _a: i64, _b: i64) -> i64 {
    panic!("notes-trap")
}

pub async fn text_before(_pool: &SqlitePool, _a: &str, _b: &str) -> bool {
    panic!("notes-trap")
}

pub async fn list_titles(_pool: &SqlitePool) -> Vec<String> {
    panic!("notes-trap")
}

pub async fn create_handler(
    State(_s): State<AppState>,
    Json(_n): Json<NewNote>,
) -> (StatusCode, Json<serde_json::Value>) {
    panic!("notes-trap")
}

pub async fn get_handler(
    State(_s): State<AppState>,
    Path(_id): Path<i64>,
) -> (StatusCode, Json<serde_json::Value>) {
    panic!("notes-trap")
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
