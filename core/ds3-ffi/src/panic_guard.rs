//! Panic guard macro for C FFI exports.
//!
//! Every `extern "C"` function wraps its body in `catch_unwind` to prevent
//! panics from unwinding across the FFI boundary (undefined behavior).
//!
//! The guard also records the *detail* string of any returned error in a
//! thread-local slot (see [`set_last_error`]) so the host can retrieve
//! server-side context (e.g. an HTTP status + body for a non-2xx coordinator
//! response) via `ds3_last_error_message` and attach it to the typed exception
//! it raises from the bare numeric error code.

use std::cell::RefCell;

thread_local! {
    /// Detail string of the most recent error returned through [`ffi_guard`] on
    /// this thread. Consumed (cleared) by `ds3_last_error_message`.
    static LAST_ERROR: RefCell<Option<String>> = const { RefCell::new(None) };
}

/// Records the most recent error detail for the current thread (set by
/// [`ffi_guard`] on its error arm).
pub(crate) fn set_last_error(detail: String) {
    LAST_ERROR.with(|cell| *cell.borrow_mut() = Some(detail));
}

/// Takes (and clears) the most recent error detail for the current thread.
/// Returns `None` when no error has been recorded since the last take.
pub(crate) fn take_last_error() -> Option<String> {
    LAST_ERROR.with(|cell| cell.borrow_mut().take())
}

/// Wraps an FFI function body in `catch_unwind` for panic safety.
///
/// - `Ok(Ok(val))` -> returns `val` (success)
/// - `Ok(Err(e))` -> sets error code via `code()`, returns -1
/// - `Err(_panic)` -> returns -2 (panic caught)
///
/// # Usage
///
/// ```ignore
/// #[no_mangle]
/// pub extern "C" fn ds3_some_function(out_error: *mut i32) -> i32 {
///     ffi_guard!(out_error, {
///         // ... your code that returns Result<i32, DS3Error> ...
///         Ok(0)
///     })
/// }
/// ```
macro_rules! ffi_guard {
    ($out_error:expr, $body:expr) => {
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| $body)) {
            Ok(Ok(val)) => val,
            Ok(Err(e)) => {
                $crate::panic_guard::set_last_error(e.detail());
                if !$out_error.is_null() {
                    unsafe { *$out_error = e.code() };
                }
                -1
            }
            Err(_panic) => {
                if !$out_error.is_null() {
                    unsafe { *$out_error = -2 };
                }
                -2
            }
        }
    };
}

pub(crate) use ffi_guard;

#[cfg(test)]
#[allow(useless_ptr_null_checks)]
mod tests {
    use ds3_models::DS3Error;

    #[test]
    fn test_ffi_guard_success() {
        let mut err: i32 = 0;
        let result = ffi_guard!(&mut err as *mut i32, { Ok::<i32, DS3Error>(42) });
        assert_eq!(result, 42);
        assert_eq!(err, 0);
    }

    #[test]
    fn test_ffi_guard_error() {
        let mut err: i32 = 0;
        let result = ffi_guard!(&mut err as *mut i32, {
            Err::<i32, DS3Error>(DS3Error::LoggedOut)
        });
        assert_eq!(result, -1);
        assert_eq!(err, 1005); // LoggedOut error code
    }

    #[test]
    fn test_ffi_guard_panic() {
        let mut err: i32 = 0;
        let result = ffi_guard!(&mut err as *mut i32, {
            panic!("test panic");
            #[allow(unreachable_code)]
            Ok::<i32, DS3Error>(0)
        });
        assert_eq!(result, -2);
        assert_eq!(err, -2);
    }
}
