//! FFI boundary layer for the DS3 Rust core.
//!
//! Exposes the DS3 core functionality to platform consumers via:
//! - UniFFI proc macros for Swift (XCFramework)
//! - extern "C" functions for C# (csbindgen / P/Invoke)
//!
//! All FFI functions are blocking. Async Rust code runs on an internal
//! tokio runtime. Panics are caught at the boundary to prevent unwinding
//! across FFI.

uniffi::setup_scaffolding!();

pub mod c_exports;
pub mod cancellation;
pub mod handles;
pub mod log_bridge;
pub mod panic_guard;
pub mod progress;
pub mod uniffi_exports;

// Re-export the primary FFI handle type.
pub use cancellation::CancellationHandle;
pub use uniffi_exports::{ds3_error_code, DS3SessionHandle};
