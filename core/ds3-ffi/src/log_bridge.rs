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
//! Implementation overview:
//! - The C callback pointer lives in a `static AtomicPtr<()>` (the function
//!   pointer is stored as an opaque address so the atomic stays lock-free).
//! - A `CCallbackLayer` is installed as a `tracing_subscriber::Layer` on the
//!   global `Registry` exactly once via `Once`. After installation the
//!   subscriber is permanent; subsequent `set_callback` calls only swap the
//!   stored function pointer (idempotent replacement).
//! - On every event the layer extracts (level, target, message) and, if a
//!   callback is registered, invokes it with non-owning UTF-8 pointers +
//!   lengths borrowed from local stack allocations.

use std::sync::atomic::{AtomicPtr, Ordering};
use std::sync::Once;

use tracing::field::{Field, Visit};
use tracing::{Event, Subscriber};
use tracing_subscriber::layer::Context;
use tracing_subscriber::prelude::*;
use tracing_subscriber::Layer;

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

/// Stores the currently-registered callback as an opaque pointer.
///
/// We store the function pointer (which fits in a `usize`/raw pointer per
/// the Rust ABI) via `AtomicPtr<()>` so the hot path (`Layer::on_event`)
/// needs only a single acquire-ordering load.
static CALLBACK: AtomicPtr<()> = AtomicPtr::new(std::ptr::null_mut());

/// Ensures the global `CCallbackLayer` is installed exactly once.
static INSTALL: Once = Once::new();

/// Registers (or, when `cb` is `None`, clears) the global log callback.
///
/// Idempotent — calling twice replaces the previously registered callback.
/// Thread-safe (the underlying storage is an `AtomicPtr`).
///
/// The first call also installs the `CCallbackLayer` as a global
/// `tracing-subscriber` layer. Subsequent calls only swap the stored
/// callback pointer; they tolerate the subscriber already being set.
pub fn set_callback(cb: Option<DS3LogCallbackFn>) {
    INSTALL.call_once(|| {
        // `try_init` returns `Err` if a global subscriber was already set
        // by another caller. We intentionally swallow that error —
        // re-installing would panic, and the host process that owns the
        // FFI surface is documented to install nothing else.
        let _ = tracing_subscriber::registry()
            .with(CCallbackLayer)
            .try_init();
    });

    let ptr: *mut () = match cb {
        Some(f) => f as *mut (),
        None => std::ptr::null_mut(),
    };
    CALLBACK.store(ptr, Ordering::Release);
}

/// Clears any previously registered log callback.
pub fn clear_callback() {
    CALLBACK.store(std::ptr::null_mut(), Ordering::Release);
}

/// Returns the currently registered callback, if any.
fn current_callback() -> Option<DS3LogCallbackFn> {
    let raw = CALLBACK.load(Ordering::Acquire);
    if raw.is_null() {
        None
    } else {
        // SAFETY: `raw` was produced by casting a `DS3LogCallbackFn`
        // (an `extern "C" fn`) to `*mut ()`. We never store anything else
        // in `CALLBACK`, so the round-trip is sound.
        Some(unsafe { std::mem::transmute::<*mut (), DS3LogCallbackFn>(raw) })
    }
}

/// `tracing-subscriber` layer that forwards events to the registered C
/// callback. Stateless — all the per-event work happens on the stack.
struct CCallbackLayer;

impl<S> Layer<S> for CCallbackLayer
where
    S: Subscriber,
{
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let Some(cb) = current_callback() else {
            return;
        };

        let metadata = event.metadata();
        let level = level_to_code(metadata.level());
        let target = metadata.target();

        let mut visitor = MessageVisitor::default();
        event.record(&mut visitor);
        let message = visitor.message;

        // Borrow UTF-8 bytes on the stack — the callback is invoked
        // synchronously and is contractually required not to retain the
        // pointers after returning (see Pitfall 5 re-entrancy note).
        let target_bytes = target.as_bytes();
        let message_bytes = message.as_bytes();
        cb(
            level,
            target_bytes.as_ptr(),
            target_bytes.len(),
            message_bytes.as_ptr(),
            message_bytes.len(),
        );
    }
}

/// Maps a `tracing::Level` to the wire-format integer.
fn level_to_code(level: &tracing::Level) -> i32 {
    match *level {
        tracing::Level::TRACE => 0,
        tracing::Level::DEBUG => 1,
        tracing::Level::INFO => 2,
        tracing::Level::WARN => 3,
        tracing::Level::ERROR => 4,
    }
}

/// Visits a single `message` field. Other fields are ignored — the host
/// receives just the formatted text (matching the EventSource bridge spec
/// in 17-RESEARCH §"Bridging Rust tracing to C# EventSource").
#[derive(Default)]
struct MessageVisitor {
    message: String,
}

impl Visit for MessageVisitor {
    fn record_str(&mut self, field: &Field, value: &str) {
        if field.name() == "message" && self.message.is_empty() {
            self.message.push_str(value);
        }
    }

    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" && self.message.is_empty() {
            use std::fmt::Write as _;
            let _ = write!(self.message, "{value:?}");
            // Strings going through `record_debug` arrive quoted; strip a
            // single surrounding quote pair so consumers see `hello` not `"hello"`.
            if self.message.starts_with('"')
                && self.message.ends_with('"')
                && self.message.len() >= 2
            {
                self.message = self.message[1..self.message.len() - 1].to_string();
            }
        }
    }
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
