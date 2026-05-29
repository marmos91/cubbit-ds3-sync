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
//! NOTE: This file currently contains the RED-phase failing tests for the
//! Plan 01 Task 2 TDD flow. The `set_callback` body is intentionally a
//! no-op until the GREEN commit replaces it with the
//! `tracing-subscriber::Layer` implementation.

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
/// Idempotent — calling twice replaces the previously registered callback.
/// Thread-safe.
///
/// NOTE: RED-phase stub. Plan 01 Task 2 GREEN commit replaces this with the
/// `tracing-subscriber` layer implementation backed by `AtomicPtr`.
pub fn set_callback(_cb: Option<DS3LogCallbackFn>) {
    // Intentionally empty — see module docs.
}

/// Clears any previously registered log callback.
pub fn clear_callback() {
    set_callback(None);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering as TestOrdering};
    use std::sync::Mutex;
    use std::sync::OnceLock;

    /// Serializes the tests so they do not race for the single global
    /// callback slot. `cargo test` can otherwise run them in parallel.
    fn test_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    static EVENT_COUNT: AtomicUsize = AtomicUsize::new(0);
    static CAPTURED: OnceLock<Mutex<Vec<(i32, String, String)>>> = OnceLock::new();

    fn captured() -> &'static Mutex<Vec<(i32, String, String)>> {
        CAPTURED.get_or_init(|| Mutex::new(Vec::new()))
    }

    extern "C" fn capture_callback(
        level: i32,
        target: *const u8,
        target_len: usize,
        message: *const u8,
        message_len: usize,
    ) {
        EVENT_COUNT.fetch_add(1, TestOrdering::SeqCst);
        let target = unsafe { std::slice::from_raw_parts(target, target_len) };
        let message = unsafe { std::slice::from_raw_parts(message, message_len) };
        let target = std::str::from_utf8(target).unwrap_or_default().to_string();
        let message = std::str::from_utf8(message).unwrap_or_default().to_string();
        captured().lock().unwrap().push((level, target, message));
    }

    fn reset_capture() {
        EVENT_COUNT.store(0, TestOrdering::SeqCst);
        captured().lock().unwrap().clear();
    }

    #[test]
    fn test_dispatch_invokes_callback_with_level_target_message() {
        let _guard = test_lock().lock().unwrap();
        reset_capture();
        set_callback(Some(capture_callback));

        tracing::info!(target: "ds3_auth", "login complete");

        let events = captured().lock().unwrap();
        let found = events
            .iter()
            .find(|(_, t, _)| t == "ds3_auth")
            .expect("expected an event targeted at ds3_auth");
        assert_eq!(found.0, 2, "INFO should map to level=2");
        assert_eq!(found.1, "ds3_auth");
        assert_eq!(found.2, "login complete");

        drop(events);
        clear_callback();
    }

    #[test]
    fn test_clear_callback_stops_dispatch() {
        let _guard = test_lock().lock().unwrap();
        reset_capture();
        set_callback(Some(capture_callback));

        tracing::info!(target: "test_clear", "before");
        let before = EVENT_COUNT.load(TestOrdering::SeqCst);
        assert!(before > 0, "callback should have received the pre-clear event");

        set_callback(None);
        let baseline = EVENT_COUNT.load(TestOrdering::SeqCst);
        tracing::error!(target: "test_clear", "after");
        let after = EVENT_COUNT.load(TestOrdering::SeqCst);
        assert_eq!(after, baseline, "no events should fire after clear");
    }

    #[test]
    fn test_thread_safe_multi_emitter() {
        let _guard = test_lock().lock().unwrap();
        reset_capture();
        set_callback(Some(capture_callback));

        let mut handles = Vec::new();
        for _ in 0..8 {
            handles.push(std::thread::spawn(|| {
                for _ in 0..100 {
                    tracing::info!(target: "test_mt", "tick");
                }
            }));
        }
        for h in handles {
            h.join().expect("thread panicked");
        }

        let total = EVENT_COUNT.load(TestOrdering::SeqCst);
        assert!(
            total >= 800,
            "expected at least 800 events, got {total}"
        );

        clear_callback();
    }
}
