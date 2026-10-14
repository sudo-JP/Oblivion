use std::sync::Arc;
use crate::middleware::auth::auth_middleware;
use axum::{Router, middleware};

use crate::state::AppState;

mod files;

pub fn routes(state: Arc<AppState>) -> Router {
    Router::new()
        .nest("/api", files::routes(state.clone()))
        .layer(middleware::from_fn_with_state(state, auth_middleware))
}
