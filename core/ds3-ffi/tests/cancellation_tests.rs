//! Unit tests for the `CancellationHandle` UniFFI Object.
//!
//! These tests don't require network access — they verify the atomic flag
//! semantics that downstream multipart-loop checks depend on.
//!
//! Run with: cargo test -p ds3-ffi --test cancellation_tests

use std::sync::Arc;
use std::thread;

use ds3_ffi::cancellation::CancellationHandle;

#[test]
fn new_handle_is_not_cancelled() {
    let h = CancellationHandle::new();
    assert!(!h.is_cancelled());
}

#[test]
fn cancel_flips_is_cancelled() {
    let h = CancellationHandle::new();
    assert!(!h.is_cancelled());
    h.cancel();
    assert!(h.is_cancelled());
}

#[test]
fn cancel_is_idempotent() {
    let h = CancellationHandle::new();
    h.cancel();
    h.cancel();
    h.cancel();
    assert!(h.is_cancelled());
}

#[test]
fn handle_is_shareable_across_threads() {
    let h: Arc<CancellationHandle> = CancellationHandle::new();
    let h2 = Arc::clone(&h);

    let join = thread::spawn(move || {
        h2.cancel();
    });

    join.join().unwrap();

    assert!(
        h.is_cancelled(),
        "cancel from another thread must be visible"
    );
}

#[test]
fn multiple_reads_after_cancel_all_return_true() {
    let h = CancellationHandle::new();
    h.cancel();

    for _ in 0..10 {
        assert!(h.is_cancelled());
    }
}

#[test]
fn implements_cancel_token_trait() {
    // Compile-only: ensure CancellationHandle implements the trait the
    // multipart loop checks against.
    fn _accepts<T: ds3_s3::CancelToken>(_t: &T) {}
    let h = CancellationHandle::new();
    _accepts(&*h);
}
