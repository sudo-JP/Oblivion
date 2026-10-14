use std::sync::Arc;

use axum::{body::{to_bytes}, extract::{Request, State}, http::{StatusCode, header}, response::IntoResponse};

use crate::state::{AppState, FileType};

pub async fn get_file(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let file_type = loop {
        state.notify.notified().await;
        let mut file_guard = state.pending_files.lock().await;
        if let Some(bytes) = file_guard.take() {
            break bytes;
        } 
    };

    let content_type = file_type.content_type();
    let file_bytes = match file_type {
        FileType::Pdf(bytes)
        | FileType::Image(bytes, _) => bytes,
    };
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, content_type)], 
        file_bytes,
    )
}

pub async fn post_file(
    State(state): State<Arc<AppState>>,
    req: Request
) -> Result<impl IntoResponse, StatusCode> {
    let file_type = req
        .headers()
        .get("Content-Type")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string())
        .ok_or(StatusCode::UNSUPPORTED_MEDIA_TYPE)?;

    let file = to_bytes(req.into_body(), usize::MAX)
        .await
        .map_err(|_| StatusCode::UNSUPPORTED_MEDIA_TYPE)?;

    let mut file_guard = state.pending_files.lock().await;
    let file_type = match file_type.as_str() {
        "application/pdf" => FileType::Pdf(file.to_vec()),
        "image/png" | "image/jpeg" | "image/jpg" => FileType::Image(file.to_vec(), file_type.to_string()),
        _ => { return Err(StatusCode::UNSUPPORTED_MEDIA_TYPE); }
    };
    *file_guard = Some(file_type);

    state.notify.notify_one();

    Ok(StatusCode::OK)
}
