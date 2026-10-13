use std::sync::Arc;

use axum::{body::Bytes, extract::State, http::{StatusCode, header}, response::IntoResponse};

use crate::state::AppState;

pub async fn get_file(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    state.notify.notified().await;
    let file_guard = state.pending_files.lock().await;
    let Some(file_bytes) = &*file_guard else {
        panic!("Incorrect notify logic")
    };

    // TODO: change match on file type for this
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "application/pdf")], 
        file_bytes,
    )
}

pub async fn post_file(
    State(state): State<Arc<AppState>>,
    file: Bytes
    ) -> impl IntoResponse {

    let mut file_guard = state.pending_files.lock().await;
    *file_guard = Some(file.to_vec());

    state.notify.notify_one();

    (
        StatusCode::OK,
    )
}
