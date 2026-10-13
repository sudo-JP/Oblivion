use std::sync::Arc;

use axum::{Router, routing, middleware};

use crate::{middleware::auth::auth_middleware, state::AppState};
use crate::handler::files_handler;

pub fn routes(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/file", routing::get(files_handler::get_file))
        .route("/file", routing::post(files_handler::post_file))
        .layer(middleware::from_fn_with_state(state.clone(), auth_middleware))
}
