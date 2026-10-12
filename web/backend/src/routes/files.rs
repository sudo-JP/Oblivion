use axum::{Router, routing};

pub fn routes() -> Router {
    Router::new()
        .route("/files", routing::get(todo!()))
        .route("/files", routing::post())
}
