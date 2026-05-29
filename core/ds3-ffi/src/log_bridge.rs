//! Bridge Rust `tracing` events to a C function pointer (POL-01).
//!
//! The Windows shell (and any other native consumer) registers a
//! `DS3LogCallbackFn` via `ds3_set_log_callback`; every event emitted from
//! the workspace's `tracing` instrumentation is then forwarded across the
//! FFI boundary to that callback.
//!
//! **Re-entrancy contract:** `DS3LogCallbackFn` implementations MUST NOT
//! re-enter the Rust FFI surface on the same call stack. See
//! `.planning/phases/17-windows-shell/17-RESEARCH.md` §"Pitfall 5" — the
//! tokio runtime panics with "Cannot start a runtime from within a runtime"
//! if a Rust-invoked callback drives a tokio task that calls back through
//! `runtime().block_on(...)`. The C# side routes callbacks through a
//! `Channel<LogEvent>` + dedicated dispatcher thread for this reason.
//!
//! NOTE: Phase 17 Plan 01 Task 1 commits a minimal stub of this module
//! (type alias + no-op `set_callback`). Task 2 replaces the body with a
//! `tracing_subscriber::Layer` implementation backed by an `AtomicPtr` and
//! adds the unit tests.

/// C function pointer registered with `ds3_set_log_callback`.
///
/// `level` follows the `tracing::Level` ordering:
///   0 = TRACE, 1 = DEBUG, 2 = INFO, 3 = WARN, 4 = ERROR.
///
/// `target` / `message` are non-NUL-terminated UTF-8 byte slices borrowed
/// for the duration of the call only; the callee must copy them before
/// returning.
///
/// **Re-entrancy:** implementations MUST NOT call back into the Rust FFI
/// surface (`ds3_*`) on the same call stack. See Phase 17 RESEARCH
/// §"Pitfall 5".
pub type DS3LogCallbackFn = extern "C" fn(
    level: i32,
    target: *const u8,
    target_len: usize,
    message: *const u8,
    message_len: usize,
);

/// Registers (or, when `cb` is `None`, clears) the global log callback.
///
/// Idempotent — calling twice replaces the prior callback. Thread-safe.
///
/// NOTE: Plan 01 Task 1 ships this as a no-op so the C ABI surface compiles.
/// Plan 01 Task 2 swaps in the real `tracing-subscriber` layer + atomic
/// pointer storage.
pub fn set_callback(_cb: Option<DS3LogCallbackFn>) {
    // Intentionally empty — see module docs.
}

/// Clears any previously registered log callback.
pub fn clear_callback() {
    set_callback(None);
}
