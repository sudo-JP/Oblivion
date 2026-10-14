use std::sync::Arc;

use axum::{Router, routing};

use crate::state::AppState;
use crate::handler::files_handler;

pub fn routes(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/file", routing::get(files_handler::get_file))
        .route("/file", routing::post(files_handler::post_file))
        .with_state(state)
}
