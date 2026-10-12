use std::sync::Arc;

use axum::{Router, routing, middleware};

use crate::{middleware::auth::auth_middleware, state::AppState};

pub fn routes(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/files", routing::get(todo!()))
        .route("/files", routing::post(todo!()))
        .layer(middleware::from_fn_with_state(state.clone(), auth_middleware))
}
