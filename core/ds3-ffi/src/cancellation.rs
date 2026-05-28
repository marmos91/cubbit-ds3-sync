//! UniFFI `CancellationHandle` Object — cooperative cancellation for long-running
//! S3 operations (multipart upload + future chunked download).
//!
//! Swift creates a handle via the constructor, passes it into a long-running
//! FFI method (e.g. `download_object`), and calls `cancel()` to request abort.
//! The Rust side polls `is_cancelled()` between work units.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use ds3_s3::CancelToken;

/// Cooperative cancellation handle shared between Swift caller and Rust ops.
///
/// Backed by an `Arc<AtomicBool>` so the handle can be cloned and observed
/// from multiple threads with lock-free reads. Threat T-16-02-01 mitigation:
/// `Ordering::SeqCst` ensures cancel writes are immediately visible to all
/// readers.
#[derive(uniffi::Object)]
pub struct CancellationHandle {
    cancelled: Arc<AtomicBool>,
}

#[uniffi::export]
impl CancellationHandle {
    /// Creates a fresh handle in the "not cancelled" state.
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            cancelled: Arc::new(AtomicBool::new(false)),
        })
    }

    /// Requests cancellation. Idempotent and thread-safe.
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
    }

    /// Returns `true` once `cancel()` has been called.
    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }
}

impl CancelToken for CancellationHandle {
    fn is_cancelled(&self) -> bool {
        // Disambiguate from the inherent `is_cancelled` to avoid recursion.
        self.cancelled.load(Ordering::SeqCst)
    }
}
