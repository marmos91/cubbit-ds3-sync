//! S3 client layer for Cubbit DS3 object storage operations.
//!
//! Wraps the AWS SDK S3 client with a custom endpoint configuration for
//! Cubbit's S3-compatible storage. Provides listing, upload, download,
//! delete, copy, multipart upload, and folder marker operations.

pub mod cancel;
pub mod client;
pub mod crud;
pub mod list;
pub mod markers;
pub mod multipart;
pub mod transfer;

// Re-export primary types and constants.
pub use cancel::CancelToken;
pub use client::{
    decode_s3_key, normalize_etag, DS3S3Client, DELIMITER, LIST_BATCH_SIZE, MARKER_FILE_NAME,
    MAX_RETRIES, MULTIPART_CONCURRENCY, MULTIPART_PART_SIZE, MULTIPART_THRESHOLD, TIMEOUT_SECONDS,
};
pub use crud::is_not_found_error;
pub use markers::{is_ds3keep_marker_key, marker_key};
pub use multipart::{compute_parts, PartDescriptor};
