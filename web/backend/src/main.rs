use axum::{Router};
use backend::{routes::routes, state::AppState};
use tokio::sync::{Mutex, Notify, mpsc};
use std::{net::TcpListener, sync::Arc};

#[tokio::main]
async fn main() {
    dotenvy::dotenv().ok();

    let (tx, mut rx) = mpsc::channel(4);
    let state = Arc::new(AppState {
        token: std::env::var("AUTH_TOKEN").expect("AUTH_TOKEN not set"),
        pending_files: tx,
        receiver: Mutex::new(rx),
    });

    let app = routes::routes(state);
    let host = format!("0.0.0.0:{}", std::env::var("PORT").expect("AUTH_TOKEN not set"));

    let listener = TcpListener::bind(&host)
        .unwrap_or_else(|e| panic!("Failed to bind to {}: {}", host, e));

    axum::serve::serve(listener, app)
        .await
        .unwrap_or_else(|e| panic!("Server Error: {}", e));
}
