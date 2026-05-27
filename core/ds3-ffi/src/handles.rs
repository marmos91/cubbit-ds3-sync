//! Shared tokio runtime for FFI boundary functions.
//!
//! All FFI functions block the caller. Internally, async Rust code runs
//! on a shared `tokio::runtime::Runtime` managed via `OnceLock`. This
//! avoids the overhead of constructing a new runtime per FFI call.
//!
//! **Constraint:** FFI callers must NOT call from a tokio thread, or
//! `block_on` will panic. Platform callers (Swift main thread, C# .NET
//! thread) are always safe.

use std::sync::OnceLock;
use tokio::runtime::Runtime;

/// Returns a reference to the shared tokio runtime.
///
/// The runtime is lazily initialized on first use and lives for the
/// duration of the process. All FFI functions use this runtime to
/// execute async Rust code.
pub fn runtime() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| Runtime::new().expect("Failed to create tokio runtime"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_runtime_returns_same_instance() {
        let rt1 = runtime() as *const Runtime;
        let rt2 = runtime() as *const Runtime;
        assert_eq!(rt1, rt2, "runtime() should return the same instance");
    }

    #[test]
    fn test_runtime_can_block_on() {
        let result = runtime().block_on(async { 42 });
        assert_eq!(result, 42);
    }
}
