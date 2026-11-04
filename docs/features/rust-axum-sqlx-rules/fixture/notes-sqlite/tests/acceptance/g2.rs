//! Goal g2: the HTTP routes, through oneshot on router (no layers). Clean oracle.
#![forbid(unused_must_use, unreachable_code)]
use axum::body::Body;
use axum::http::{Request, StatusCode};
use notes::*;
use sqlx::SqlitePool;
use tower::ServiceExt;

async fn call(app: axum::Router, req: Request<Body>) -> (StatusCode, serde_json::Value) {
    let res = app.oneshot(req).await.unwrap();
    let status = res.status();
    let bytes = axum::body::to_bytes(res.into_body(), 1 << 20).await.unwrap();
    (status, serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null))
}

fn post_json(body: &str) -> Request<Body> {
    Request::post("/notes").header("content-type", "application/json").body(Body::from(body.to_string())).unwrap()
}

#[sqlx::test(migrations = "./migrations")]
async fn post_creates(pool: SqlitePool) {
    let (s, b) = call(router(AppState { pool }), post_json(r#"{"title":"hi"}"#)).await;
    assert_eq!(s, StatusCode::CREATED);
    assert_eq!(b["title"], "hi");
}

#[sqlx::test(migrations = "./migrations")]
async fn empty_title_is_422_with_code(pool: SqlitePool) {
    let (s, b) = call(router(AppState { pool }), post_json(r#"{"title":""}"#)).await;
    assert_eq!(s, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(b["error"], "empty_title");
}

#[sqlx::test(migrations = "./migrations")]
async fn missing_is_404_with_code(pool: SqlitePool) {
    let (s, b) = call(router(AppState { pool }), Request::get("/notes/42").body(Body::empty()).unwrap()).await;
    assert_eq!(s, StatusCode::NOT_FOUND);
    assert_eq!(b["error"], "not_found");
}
