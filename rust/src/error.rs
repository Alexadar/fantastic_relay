//! Router error type. Kept deliberately small — the router does few things.
//!
//! The `tungstenite::Error` / `io::Error` payloads are BOXED so `RouterError`
//! (and every `Result<_, RouterError>`) stays pointer-small — otherwise the
//! 136-byte tungstenite variant bloats every fallible signature.

use thiserror::Error;

#[derive(Error, Debug)]
pub enum RouterError {
    #[error("config error: {0}")]
    Config(String),

    #[error("auth rejected: {0}")]
    Auth(String),

    #[error("pairing failed: {0}")]
    Pairing(String),

    // `#[from] tungstenite::Error` is version-coupled to tungstenite 0.23.
    #[error("websocket error: {0}")]
    Ws(Box<tokio_tungstenite::tungstenite::Error>),

    #[error("io error: {0}")]
    Io(Box<std::io::Error>),
}

impl From<tokio_tungstenite::tungstenite::Error> for RouterError {
    fn from(e: tokio_tungstenite::tungstenite::Error) -> Self {
        RouterError::Ws(Box::new(e))
    }
}

impl From<std::io::Error> for RouterError {
    fn from(e: std::io::Error) -> Self {
        RouterError::Io(Box::new(e))
    }
}
