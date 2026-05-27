//! FFI boundary layer for the DS3 Rust core.
//!
//! Exposes the DS3 core functionality to platform consumers via:
//! - UniFFI proc macros for Swift (XCFramework)
//! - extern "C" functions for C# (csbindgen / P/Invoke)
//!
//! All FFI functions are blocking. Async Rust code runs on an internal
//! tokio runtime. Panics are caught at the boundary to prevent unwinding
//! across FFI.
