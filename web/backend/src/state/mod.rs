use tokio::sync::{Mutex, Notify};

pub struct AppState {
    pub token: String,
    pub pending_files: Mutex<Option<Vec<u8>>>,
    pub notify: Notify,
}
