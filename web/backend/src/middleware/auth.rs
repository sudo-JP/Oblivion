use axum::{
    extract::{Request, State}, 
    http::StatusCode, 
    middleware::Next, 
    response::Response
};
use std::sync::Arc;

use crate::state::AppState;


pub async fn auth_middleware(
    State(state): State<Arc<AppState>>,
    req: Request,
    next: Next,
) -> Result<Response, StatusCode> {
    let token = req
        .headers()
        .get("X-Auth-Token")
        .and_then(|v| v.to_str().ok())
        .ok_or(StatusCode::UNAUTHORIZED)?;

    let valid_token = state.token.as_str();

    if token != valid_token {
        return Err(StatusCode::UNAUTHORIZED);
    }

    Ok(next.run(req).await)
}
