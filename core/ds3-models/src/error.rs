//! Unified error type for the DS3 Rust core.
//!
//! All error variants carry a numeric code accessible via `code()` for FFI
//! mapping. The Display impl avoids leaking sensitive data (passwords, tokens).

use thiserror::Error;

/// Unified error type covering auth, S3, HTTP, IO, and FFI error domains.
#[derive(Error, Debug, uniffi::Error)]
#[uniffi(flat_error)]
pub enum DS3Error {
    // -----------------------------------------------------------------------
    // Auth errors (1001-1099)
    // -----------------------------------------------------------------------
    /// The provided URL is malformed.
    #[error("Invalid URL: {url}")]
    InvalidUrl { url: String },

    /// The server returned an unexpected HTTP status.
    #[error("Server error: HTTP {status}")]
    ServerError { status: u16, body: String },

    /// JSON serialization or deserialization failed.
    #[error("JSON error: {message}")]
    JsonError { message: String },

    /// Encoding failure (e.g. string to bytes).
    #[error("Encoding error")]
    Encoding,

    /// The user is not logged in.
    #[error("Not logged in")]
    LoggedOut,

    /// The access token has expired.
    #[error("Token expired")]
    TokenExpired,

    /// Two-factor authentication code is required.
    #[error("2FA code required")]
    Missing2FA,

    /// Cookie extraction or parsing failed.
    #[error("Cookie error")]
    CookieError,

    // -----------------------------------------------------------------------
    // S3 client errors (2001-2099)
    // -----------------------------------------------------------------------
    /// The multipart upload ID is missing from the response.
    #[error("Missing upload ID")]
    MissingUploadId,

    /// The file data provided for upload is empty.
    #[error("Empty file data")]
    EmptyFileData,

    /// The ETag is missing from the S3 response.
    #[error("Missing ETag")]
    MissingETag,

    /// Failed to parse an S3 response.
    #[error("Parse error")]
    ParseError,

    /// Unable to open the local file for reading.
    #[error("Unable to open file")]
    UnableToOpenFile,

    // -----------------------------------------------------------------------
    // Wrapped errors (3001-3099)
    // -----------------------------------------------------------------------
    /// An I/O error occurred.
    #[error("IO error: {0}")]
    IoError(String),

    /// An HTTP transport error occurred.
    #[error("HTTP error: {0}")]
    HttpError(String),

    /// An S3 operation failed.
    #[error("S3 error: {0}")]
    S3Error(String),

    /// An authentication operation failed.
    #[error("Auth error: {0}")]
    AuthError(String),
}

impl DS3Error {
    /// Returns a unique numeric error code for FFI mapping.
    ///
    /// Ranges:
    /// - 1001-1099: Auth errors
    /// - 2001-2099: S3 client errors
    /// - 3001-3099: Wrapped/transport errors
    pub fn code(&self) -> i32 {
        match self {
            DS3Error::InvalidUrl { .. } => 1001,
            DS3Error::ServerError { .. } => 1002,
            DS3Error::JsonError { .. } => 1003,
            DS3Error::Encoding => 1004,
            DS3Error::LoggedOut => 1005,
            DS3Error::TokenExpired => 1006,
            DS3Error::Missing2FA => 1007,
            DS3Error::CookieError => 1008,
            DS3Error::MissingUploadId => 2001,
            DS3Error::EmptyFileData => 2002,
            DS3Error::MissingETag => 2003,
            DS3Error::ParseError => 2004,
            DS3Error::UnableToOpenFile => 2005,
            DS3Error::IoError(_) => 3001,
            DS3Error::HttpError(_) => 3002,
            DS3Error::S3Error(_) => 3003,
            DS3Error::AuthError(_) => 3004,
        }
    }
}

impl From<std::io::Error> for DS3Error {
    fn from(err: std::io::Error) -> Self {
        DS3Error::IoError(err.to_string())
    }
}

impl From<serde_json::Error> for DS3Error {
    fn from(err: serde_json::Error) -> Self {
        DS3Error::JsonError {
            message: err.to_string(),
        }
    }
}

impl From<reqwest::Error> for DS3Error {
    fn from(err: reqwest::Error) -> Self {
        DS3Error::HttpError(err.to_string())
    }
}

impl From<reqwest_middleware::Error> for DS3Error {
    fn from(err: reqwest_middleware::Error) -> Self {
        match err {
            reqwest_middleware::Error::Middleware(e) => DS3Error::HttpError(e.to_string()),
            reqwest_middleware::Error::Reqwest(e) => DS3Error::HttpError(e.to_string()),
        }
    }
}
