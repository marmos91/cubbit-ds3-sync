//! Progress callback interface for FFI consumers.
//!
//! Provides both a UniFFI callback interface (for Swift) and a C-compatible
//! function pointer type (for C#/P/Invoke).

/// UniFFI callback interface for reporting transfer progress.
///
/// Swift consumers implement this trait and pass an instance to upload/download
/// methods. UniFFI generates the necessary bridging code automatically.
#[uniffi::export(callback_interface)]
pub trait ProgressCallback: Send + Sync {
    /// Called periodically during a transfer with the current progress.
    ///
    /// - `bytes_transferred`: number of bytes transferred so far
    /// - `total_bytes`: total expected bytes (-1 if unknown)
    fn on_progress(&self, bytes_transferred: i64, total_bytes: i64);
}

/// C-compatible progress callback function pointer for csbindgen/P/Invoke.
///
/// The `context` pointer is an opaque user-data pointer passed through
/// unchanged -- the Rust side never dereferences it. The C# side uses
/// it to route the callback to the correct managed object.
pub type DS3ProgressCallbackFn = extern "C" fn(
    bytes_transferred: i64,
    total_bytes: i64,
    context: *mut std::ffi::c_void,
);
