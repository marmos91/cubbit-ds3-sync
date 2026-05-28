//! Cancellation primitive shared between ds3-s3 long-running operations and
//! the FFI handle in ds3-ffi.
//!
//! Multipart upload (and any future chunked download) accept
//! `Option<Arc<dyn CancelToken>>`; the implementation in `ds3-ffi::cancellation`
//! exposes `CancellationHandle` to Swift via UniFFI.
//!
//! Keeping the trait in `ds3-s3` avoids a circular dependency: `ds3-ffi` already
//! depends on `ds3-s3`, so the FFI Object can implement this trait.

/// Trait for cooperative cancellation of long-running S3 operations.
///
/// Implementations are typically `Send + Sync` and use an atomic flag so
/// `is_cancelled()` is safe to call from any thread.
pub trait CancelToken: Send + Sync {
    /// Returns `true` once the operation should be aborted.
    fn is_cancelled(&self) -> bool;
}
