//! Panic safety tests for FFI C exports.
//!
//! These tests verify that extern "C" functions never crash when given
//! invalid inputs (null pointers, invalid handles). They test the FFI
//! boundary guard behavior without needing network access.
//!
//! Run with: cargo test -p ds3-ffi --test panic_tests

use std::ptr;

use ds3_ffi::c_exports;

#[test]
fn test_authenticate_null_email_returns_error() {
    let mut handle: *mut ds3_auth::DS3Session = ptr::null_mut();
    let mut err: i32 = 0;

    let result = unsafe {
        c_exports::ds3_authenticate(
            ptr::null(),
            0,
            b"password".as_ptr(),
            8,
            ptr::null(),
            0,
            ptr::null(),
            0,
            &mut handle,
            &mut err,
        )
    };

    assert_ne!(result, 0, "null email should return error code");
    assert!(handle.is_null(), "handle should remain null on error");
}

#[test]
fn test_authenticate_null_password_returns_error() {
    let mut handle: *mut ds3_auth::DS3Session = ptr::null_mut();
    let mut err: i32 = 0;

    let result = unsafe {
        c_exports::ds3_authenticate(
            b"test@example.com".as_ptr(),
            17,
            ptr::null(),
            0,
            ptr::null(),
            0,
            ptr::null(),
            0,
            &mut handle,
            &mut err,
        )
    };

    assert_ne!(result, 0, "null password should return error code");
    assert!(handle.is_null(), "handle should remain null on error");
}

#[test]
fn test_session_destroy_null_is_noop() {
    unsafe {
        c_exports::ds3_session_destroy(ptr::null_mut());
    }
}

#[test]
fn test_list_objects_null_handle_returns_error() {
    let mut out_json: *mut u8 = ptr::null_mut();
    let mut out_json_len: usize = 0;
    let mut err: i32 = 0;

    let result = unsafe {
        c_exports::ds3_list_objects(
            ptr::null(),
            b"bucket".as_ptr(),
            6,
            ptr::null(),
            0,
            ptr::null(),
            0,
            10,
            ptr::null(),
            0,
            &mut out_json,
            &mut out_json_len,
            &mut err,
        )
    };

    assert_ne!(result, 0, "null handle should return error code");
    assert!(out_json.is_null(), "output should remain null on error");
}

#[test]
fn test_free_string_null_is_noop() {
    unsafe {
        c_exports::ds3_free_string(ptr::null_mut(), 0);
    }
}

#[test]
fn test_free_string_null_with_nonzero_len_is_noop() {
    unsafe {
        c_exports::ds3_free_string(ptr::null_mut(), 100);
    }
}

#[test]
fn test_refresh_token_null_handle_returns_error() {
    let mut err: i32 = 0;

    let result = unsafe { c_exports::ds3_refresh_token(ptr::null(), &mut err) };

    assert_ne!(result, 0, "null handle should return error code");
}

#[test]
fn test_account_info_null_handle_returns_error() {
    let mut out_json: *mut u8 = ptr::null_mut();
    let mut out_json_len: usize = 0;
    let mut err: i32 = 0;

    let result = unsafe {
        c_exports::ds3_account_info(ptr::null(), &mut out_json, &mut out_json_len, &mut err)
    };

    assert_ne!(result, 0, "null handle should return error code");
}

#[test]
fn test_head_object_null_handle_returns_error() {
    let mut out_json: *mut u8 = ptr::null_mut();
    let mut out_json_len: usize = 0;
    let mut err: i32 = 0;

    let result = unsafe {
        c_exports::ds3_head_object(
            ptr::null(),
            b"bucket".as_ptr(),
            6,
            b"key".as_ptr(),
            3,
            &mut out_json,
            &mut out_json_len,
            &mut err,
        )
    };

    assert_ne!(result, 0, "null handle should return error code");
}
