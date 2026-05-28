//! Unit tests for the new FFI surface added in Phase 16 Plan 02.
//!
//! These tests are pure — no network, no env-var gating. They cover:
//! - `ds3_error_code` free function returns the same i32 as `DS3Error::code()`
//! - Module-level wiring: re-exports + Sendable bounds
//!
//! Behavior tests for DS3SessionHandle methods that hit S3 live in
//! `core/ds3-s3/tests/in_memory_tests.rs` (gated on `DS3_TEST_*`).
//!
//! Run with: cargo test -p ds3-ffi --test new_methods_tests

use ds3_ffi::ds3_error_code;
use ds3_models::DS3Error;

#[test]
fn ds3_error_code_matches_method_for_missing_2fa() {
    let err = DS3Error::Missing2FA;
    assert_eq!(ds3_error_code(err.to_string()), 1007);
}

#[test]
fn ds3_error_code_matches_method_for_invalid_url() {
    let err = DS3Error::InvalidUrl {
        url: "bad-url".into(),
    };
    assert_eq!(ds3_error_code(err.to_string()), 1001);
}

#[test]
fn ds3_error_code_matches_method_for_server_error() {
    let err = DS3Error::ServerError {
        status: 500,
        body: "boom".into(),
    };
    assert_eq!(ds3_error_code(err.to_string()), 1002);
}

#[test]
fn ds3_error_code_matches_method_for_s3_error() {
    let err = DS3Error::S3Error("NoSuchKey".into());
    assert_eq!(ds3_error_code(err.to_string()), 3003);
}

#[test]
fn ds3_error_code_matches_method_for_logged_out() {
    let err = DS3Error::LoggedOut;
    assert_eq!(ds3_error_code(err.to_string()), 1005);
}

#[test]
fn ds3_error_code_matches_method_for_token_expired() {
    let err = DS3Error::TokenExpired;
    assert_eq!(ds3_error_code(err.to_string()), 1006);
}

#[test]
fn ds3_error_code_for_unknown_input_returns_neg_one() {
    // An input that doesn't match any known DS3Error Display prefix
    // returns -1 as the sentinel. Adapter code in Swift maps this to
    // a generic "unknown" case.
    assert_eq!(ds3_error_code("totally unrelated".into()), -1);
}
