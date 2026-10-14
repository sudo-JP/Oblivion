use tokio::sync::{Mutex, Notify};

pub enum FileType {
    Pdf(Vec<u8>),
    Image(Vec<u8>, String),
}

impl FileType {
    pub fn content_type(&self) -> String {
        match self {
            Self::Pdf(_) => "application/pdf".to_string(),
            Self::Image(_, extension) => extension.to_string(),
        }
    }
}

pub struct AppState {
    pub token: String,
    pub pending_files: Mutex<Option<FileType>>,
    pub notify: Notify,
}
