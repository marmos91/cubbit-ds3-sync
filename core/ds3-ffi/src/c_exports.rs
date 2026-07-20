//! C-compatible extern "C" exports for csbindgen/P/Invoke.
//!
//! # Safety
//!
//! All `extern "C"` functions in this module accept raw pointers from the
//! foreign caller. The caller must ensure:
//! - `*const u8` + `usize` pairs point to valid UTF-8 of the given length
//! - Output `*mut *mut u8` / `*mut usize` pointers are writable
//! - Handle pointers (`*const DS3Session`, `*const DS3S3Client`) are valid
//!   and obtained from this module's constructor functions
//! - Allocated strings are freed exactly once with `ds3_free_string`
//!
//! Each function uses the `ffi_guard!` macro to catch panics at the FFI boundary.

#![allow(clippy::missing_safety_doc)]

use crate::cancellation::CancellationHandle;
use crate::handles::block_on;
use crate::log_bridge::{self, DS3LogCallbackFn};
use crate::panic_guard::ffi_guard;
use crate::progress::DS3ProgressCallbackFn;
use ds3_auth::DS3Session;
use ds3_models::DS3Error;
use ds3_s3::DS3S3Client;
use std::collections::HashMap;

// ---------------------------------------------------------------------------
// String helpers
// ---------------------------------------------------------------------------

/// Converts a raw FFI byte slice into a Rust `&str`.
///
/// # Safety
/// Caller must ensure `ptr` points to `len` valid UTF-8 bytes.
unsafe fn ffi_str<'a>(ptr: *const u8, len: usize) -> Result<&'a str, DS3Error> {
    if ptr.is_null() {
        return Err(DS3Error::Encoding);
    }
    let slice = unsafe { std::slice::from_raw_parts(ptr, len) };
    std::str::from_utf8(slice).map_err(|_| DS3Error::Encoding)
}

/// Converts a raw FFI byte slice into an `Option<&str>`. Returns `None` if
/// `ptr` is null or `len` is 0.
///
/// # Safety
/// Same as `ffi_str`.
unsafe fn ffi_opt_str<'a>(ptr: *const u8, len: usize) -> Result<Option<&'a str>, DS3Error> {
    if ptr.is_null() || len == 0 {
        return Ok(None);
    }
    unsafe { ffi_str(ptr, len).map(Some) }
}

/// Writes a Rust string into FFI out-pointers. The caller must later free
/// the allocation with `ds3_free_string`.
///
/// # Safety
/// `out_ptr` and `out_len` must be valid writable pointers.
unsafe fn write_ffi_string(s: &str, out_ptr: *mut *mut u8, out_len: *mut usize) {
    unsafe { write_ffi_bytes(s.as_bytes().to_vec(), out_ptr, out_len) };
}

/// Diagnostic: writes the *detail* string of the most recent error that occurred
/// on THIS thread (set by `ffi_guard!`) into `out_json` as UTF-8, then clears it.
/// For a server error this includes the HTTP status + response body
/// (`DS3Error::detail`), which the bare `out_error` code cannot carry. Writes an
/// empty string when no error has been recorded; a second call returns empty.
///
/// The host attaches this to the typed exception it raises from the numeric code
/// so the local debug log can show *why* a coordinator/keyvault call failed; it is
/// never surfaced as user-facing copy. Always returns 0.
///
/// # Safety
/// `out_json` and `out_json_len` must be valid writable pointers. The returned
/// buffer is owned by the caller and MUST be freed once via `ds3_free_string`.
#[no_mangle]
pub unsafe extern "C" fn ds3_last_error_message(
    out_json: *mut *mut u8,
    out_json_len: *mut usize,
) -> i32 {
    let msg = crate::panic_guard::take_last_error().unwrap_or_default();
    unsafe { write_ffi_string(&msg, out_json, out_json_len) };
    0
}

/// Writes an owned byte buffer into FFI out-pointers. The caller must later
/// free the allocation with `ds3_free_bytes` (or `ds3_free_string`).
///
/// # Safety
/// `out_ptr` and `out_len` must be valid writable pointers.
unsafe fn write_ffi_bytes(bytes: Vec<u8>, out_ptr: *mut *mut u8, out_len: *mut usize) {
    let len = bytes.len();
    let raw = Box::into_raw(bytes.into_boxed_slice()) as *mut u8;
    unsafe {
        *out_ptr = raw;
        *out_len = len;
    }
}

/// Wraps a C progress callback and opaque context pointer into a Rust closure.
///
/// # Safety
/// `ctx` is passed through opaquely -- the caller (C#/Swift side) owns its lifetime.
fn wrap_c_progress_callback(
    cb: Option<DS3ProgressCallbackFn>,
    ctx: *mut std::ffi::c_void,
) -> Option<Box<dyn Fn(i64, i64) + Send + Sync>> {
    cb.map(|cb| {
        let ctx = ctx as usize; // make it Send + Sync
        Box::new(move |transferred, total| {
            cb(transferred, total, ctx as *mut std::ffi::c_void);
        }) as Box<dyn Fn(i64, i64) + Send + Sync>
    })
}

// ---------------------------------------------------------------------------
// Memory management
// ---------------------------------------------------------------------------

/// Frees a string previously allocated by the Rust FFI layer.
///
/// # Safety
/// `ptr` must have been allocated by `write_ffi_string` with the given `len`.
/// Must not be called twice for the same pointer.
#[no_mangle]
pub unsafe extern "C" fn ds3_free_string(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len > 0 {
        let _ = unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) };
    }
}

/// Frees a byte buffer previously allocated by the Rust FFI layer.
///
/// # Safety
/// Same constraints as `ds3_free_string`.
#[no_mangle]
pub unsafe extern "C" fn ds3_free_bytes(ptr: *mut u8, len: usize) {
    unsafe { ds3_free_string(ptr, len) }
}

// ---------------------------------------------------------------------------
// Auth exports
// ---------------------------------------------------------------------------

/// Authenticates and returns an opaque session handle.
///
/// Returns 0 on success, -1 on error (code in `*out_error`), -2 on panic.
#[no_mangle]
pub unsafe extern "C" fn ds3_authenticate(
    email: *const u8,
    email_len: usize,
    password: *const u8,
    password_len: usize,
    tenant_id: *const u8,
    tenant_id_len: usize,
    coordinator_url: *const u8,
    coordinator_url_len: usize,
    out_handle: *mut *mut DS3Session,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        let email = unsafe { ffi_str(email, email_len)? };
        let password = unsafe { ffi_str(password, password_len)? };
        let tenant = unsafe { ffi_opt_str(tenant_id, tenant_id_len)? };
        let coordinator = unsafe { ffi_opt_str(coordinator_url, coordinator_url_len)? };

        let session = block_on(DS3Session::authenticate(
            email,
            password,
            tenant,
            coordinator,
        ))?;

        unsafe { *out_handle = Box::into_raw(Box::new(session)) };
        Ok::<i32, DS3Error>(0)
    })
}

/// Authenticates with a 2FA code and returns an opaque session handle.
#[no_mangle]
pub unsafe extern "C" fn ds3_authenticate_2fa(
    email: *const u8,
    email_len: usize,
    password: *const u8,
    password_len: usize,
    tfa_code: *const u8,
    tfa_code_len: usize,
    tenant_id: *const u8,
    tenant_id_len: usize,
    coordinator_url: *const u8,
    coordinator_url_len: usize,
    out_handle: *mut *mut DS3Session,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        let email = unsafe { ffi_str(email, email_len)? };
        let password = unsafe { ffi_str(password, password_len)? };
        let tfa = unsafe { ffi_str(tfa_code, tfa_code_len)? };
        let tenant = unsafe { ffi_opt_str(tenant_id, tenant_id_len)? };
        let coordinator = unsafe { ffi_opt_str(coordinator_url, coordinator_url_len)? };

        let session = block_on(DS3Session::authenticate_with_2fa(
            email,
            password,
            tfa,
            tenant,
            coordinator,
        ))?;

        unsafe { *out_handle = Box::into_raw(Box::new(session)) };
        Ok::<i32, DS3Error>(0)
    })
}

/// Restores a session from a persisted refresh token and returns an opaque session handle.
///
/// Exchanges the saved refresh token for a live access token (no email/password). This is the
/// cross-platform "stay logged in" path; the platform persists the refresh token in OS-native
/// secure storage and passes it back here at startup. Returns 0 on success, -1 on error (a
/// revoked/expired token surfaces here so the caller can fall back to login), -2 on panic.
#[no_mangle]
pub unsafe extern "C" fn ds3_session_restore(
    refresh_token: *const u8,
    refresh_token_len: usize,
    coordinator_url: *const u8,
    coordinator_url_len: usize,
    out_handle: *mut *mut DS3Session,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        let refresh = unsafe { ffi_str(refresh_token, refresh_token_len)? };
        let coordinator = unsafe { ffi_opt_str(coordinator_url, coordinator_url_len)? };

        let session = block_on(DS3Session::restore_from_refresh_token(refresh, coordinator))?;

        unsafe { *out_handle = Box::into_raw(Box::new(session)) };
        Ok::<i32, DS3Error>(0)
    })
}

/// Destroys a session handle, freeing its resources.
///
/// After this call, the handle pointer is invalid. The caller must not use it.
///
/// # Safety
/// `handle` must be a valid pointer returned by `ds3_authenticate` or
/// `ds3_authenticate_2fa`. Must not be called twice for the same handle.
#[no_mangle]
pub unsafe extern "C" fn ds3_session_destroy(handle: *mut DS3Session) {
    if !handle.is_null() {
        unsafe { drop(Box::from_raw(handle)) };
    }
}

/// Refreshes the access token if expired.
#[no_mangle]
pub unsafe extern "C" fn ds3_refresh_token(handle: *const DS3Session, out_error: *mut i32) -> i32 {
    ffi_guard!(out_error, {
        if handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let session = unsafe { &*handle };
        block_on(session.refresh_if_needed())?;
        Ok(0)
    })
}

/// Returns account info as a JSON string.
#[no_mangle]
pub unsafe extern "C" fn ds3_account_info(
    handle: *const DS3Session,
    out_json: *mut *mut u8,
    out_json_len: *mut usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let session = unsafe { &*handle };
        let json = serde_json::to_string(&session.account)?;
        unsafe { write_ffi_string(&json, out_json, out_json_len) };
        Ok(0)
    })
}

/// Forges an IAM token for the given user ID. Returns the token as JSON.
#[no_mangle]
pub unsafe extern "C" fn ds3_forge_iam_token(
    handle: *const DS3Session,
    user_id: *const u8,
    user_id_len: usize,
    out_json: *mut *mut u8,
    out_json_len: *mut usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let session = unsafe { &*handle };
        let user_id = unsafe { ffi_str(user_id, user_id_len)? };
        let token = block_on(session.forge_iam_token(user_id))?;
        let json = serde_json::to_string(&token)?;
        unsafe { write_ffi_string(&json, out_json, out_json_len) };
        Ok(0)
    })
}

// ---------------------------------------------------------------------------
// Projects/Keys exports
// ---------------------------------------------------------------------------

/// Gets projects as JSON array.
#[no_mangle]
pub unsafe extern "C" fn ds3_get_projects(
    handle: *const DS3Session,
    out_json: *mut *mut u8,
    out_json_len: *mut usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let session = unsafe { &*handle };
        block_on(session.refresh_if_needed())?;
        let token = block_on(session.session.lock()).token.token.clone();
        let projects = block_on(ds3_http::projects::get_projects(
            &session.http,
            &session.urls,
            &token,
        ))?;
        let json = serde_json::to_string(&projects)?;
        unsafe { write_ffi_string(&json, out_json, out_json_len) };
        Ok(0)
    })
}

/// Loads API keys as JSON array.
#[no_mangle]
pub unsafe extern "C" fn ds3_load_api_keys(
    handle: *const DS3Session,
    user_id: *const u8,
    user_id_len: usize,
    iam_token: *const u8,
    iam_token_len: usize,
    out_json: *mut *mut u8,
    out_json_len: *mut usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let session = unsafe { &*handle };
        let user_id = unsafe { ffi_str(user_id, user_id_len)? };
        let iam_token = unsafe { ffi_str(iam_token, iam_token_len)? };
        let keys = block_on(ds3_http::keys::load_api_keys(
            &session.http,
            &session.urls,
            iam_token,
            user_id,
        ))?;
        let json = serde_json::to_string(&keys)?;
        unsafe { write_ffi_string(&json, out_json, out_json_len) };
        Ok(0)
    })
}

/// Creates an API key. Returns the created key as JSON.
#[no_mangle]
pub unsafe extern "C" fn ds3_create_api_key(
    handle: *const DS3Session,
    user_id: *const u8,
    user_id_len: usize,
    key_name: *const u8,
    key_name_len: usize,
    iam_token: *const u8,
    iam_token_len: usize,
    out_json: *mut *mut u8,
    out_json_len: *mut usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let session = unsafe { &*handle };
        let user_id = unsafe { ffi_str(user_id, user_id_len)? };
        let key_name = unsafe { ffi_str(key_name, key_name_len)? };
        let iam_token = unsafe { ffi_str(iam_token, iam_token_len)? };
        let key = block_on(ds3_http::keys::create_api_key(
            &session.http,
            &session.urls,
            iam_token,
            user_id,
            key_name,
        ))?;
        let json = serde_json::to_string(&key)?;
        unsafe { write_ffi_string(&json, out_json, out_json_len) };
        Ok(0)
    })
}

/// Deletes an API key.
#[no_mangle]
pub unsafe extern "C" fn ds3_delete_api_key(
    handle: *const DS3Session,
    user_id: *const u8,
    user_id_len: usize,
    api_key_id: *const u8,
    api_key_id_len: usize,
    iam_token: *const u8,
    iam_token_len: usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let session = unsafe { &*handle };
        let user_id = unsafe { ffi_str(user_id, user_id_len)? };
        let api_key_id = unsafe { ffi_str(api_key_id, api_key_id_len)? };
        let iam_token = unsafe { ffi_str(iam_token, iam_token_len)? };
        block_on(ds3_http::keys::delete_api_key(
            &session.http,
            &session.urls,
            iam_token,
            user_id,
            api_key_id,
        ))?;
        Ok(0)
    })
}

// ---------------------------------------------------------------------------
// S3 exports
// ---------------------------------------------------------------------------

/// Mints an opaque `DS3S3Client` handle from S3 credentials.
///
/// `endpoint`, `access_key`, and `secret_key` are required UTF-8 buffers.
/// `region` is optional: pass a null pointer or `region_len == 0` to default
/// to `us-east-1` (`DS3S3Client::new` applies the default), matching macOS
/// which supplies no region.
///
/// The constructor performs NO network I/O (it only builds the AWS SDK client
/// config), so there is no `block_on` call; the only fallible step is the
/// UTF-8 decode of the input buffers.
///
/// Returns 0 on success (handle written to `*out_handle`), -1 on error (code in
/// `*out_error`), -2 on panic.
///
/// # Safety
/// Each `*const u8` + `usize` pair must point to valid UTF-8 of the given
/// length (or be null/0 for `region`). `out_handle` and `out_error` must be
/// writable. The returned handle must be freed exactly once with
/// `ds3_s3_client_destroy`.
#[no_mangle]
pub unsafe extern "C" fn ds3_s3_client_new(
    endpoint: *const u8,
    endpoint_len: usize,
    access_key: *const u8,
    access_key_len: usize,
    secret_key: *const u8,
    secret_key_len: usize,
    region: *const u8,
    region_len: usize,
    out_handle: *mut *mut DS3S3Client,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        let endpoint = unsafe { ffi_str(endpoint, endpoint_len)? };
        let access_key = unsafe { ffi_str(access_key, access_key_len)? };
        let secret_key = unsafe { ffi_str(secret_key, secret_key_len)? };
        let region = unsafe { ffi_opt_str(region, region_len)? };

        let client = DS3S3Client::new(endpoint, access_key, secret_key, region);

        unsafe { *out_handle = Box::into_raw(Box::new(client)) };
        Ok::<i32, DS3Error>(0)
    })
}

/// Destroys an S3 client handle, freeing its resources.
///
/// After this call, the handle pointer is invalid. The caller must not use it.
///
/// # Safety
/// `handle` must be a valid pointer returned by `ds3_s3_client_new`. Must not
/// be called twice for the same handle.
#[no_mangle]
pub unsafe extern "C" fn ds3_s3_client_destroy(handle: *mut DS3S3Client) {
    if !handle.is_null() {
        unsafe { drop(Box::from_raw(handle)) };
    }
}

/// Lists S3 objects. Returns the result as JSON.
#[no_mangle]
pub unsafe extern "C" fn ds3_list_objects(
    s3_handle: *const DS3S3Client,
    bucket: *const u8,
    bucket_len: usize,
    prefix: *const u8,
    prefix_len: usize,
    delimiter: *const u8,
    delimiter_len: usize,
    max_keys: i32,
    continuation_token: *const u8,
    continuation_token_len: usize,
    out_json: *mut *mut u8,
    out_json_len: *mut usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if s3_handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let client = unsafe { &*s3_handle };
        let bucket = unsafe { ffi_str(bucket, bucket_len)? };
        let prefix = unsafe { ffi_opt_str(prefix, prefix_len)? };
        let delimiter = unsafe { ffi_opt_str(delimiter, delimiter_len)? };
        let max_keys_opt = if max_keys > 0 { Some(max_keys) } else { None };
        let cont_token = unsafe { ffi_opt_str(continuation_token, continuation_token_len)? };

        let result =
            block_on(client.list_objects(bucket, prefix, delimiter, max_keys_opt, cont_token))?;
        let json = serde_json::to_string(&result)?;
        unsafe { write_ffi_string(&json, out_json, out_json_len) };
        Ok(0)
    })
}

/// Lists all S3 buckets. Returns the result as JSON.
#[no_mangle]
pub unsafe extern "C" fn ds3_list_buckets(
    s3_handle: *const DS3S3Client,
    out_json: *mut *mut u8,
    out_json_len: *mut usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if s3_handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let client = unsafe { &*s3_handle };
        let buckets = block_on(client.list_buckets())?;
        let bucket_objects: Vec<serde_json::Value> = buckets
            .into_iter()
            .map(|(name, creation_date)| {
                serde_json::json!({"name": name, "creation_date": creation_date})
            })
            .collect();
        let json = serde_json::to_string(&bucket_objects)?;
        unsafe { write_ffi_string(&json, out_json, out_json_len) };
        Ok(0)
    })
}

/// Returns metadata for a single S3 object as JSON.
#[no_mangle]
pub unsafe extern "C" fn ds3_head_object(
    s3_handle: *const DS3S3Client,
    bucket: *const u8,
    bucket_len: usize,
    key: *const u8,
    key_len: usize,
    out_json: *mut *mut u8,
    out_json_len: *mut usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if s3_handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let client = unsafe { &*s3_handle };
        let bucket = unsafe { ffi_str(bucket, bucket_len)? };
        let key = unsafe { ffi_str(key, key_len)? };
        let metadata = block_on(client.head_object(bucket, key))?;
        let json = serde_json::to_string(&metadata)?;
        unsafe { write_ffi_string(&json, out_json, out_json_len) };
        Ok(0)
    })
}

/// Downloads an S3 object to a local file path.
#[no_mangle]
pub unsafe extern "C" fn ds3_download_object(
    s3_handle: *const DS3S3Client,
    bucket: *const u8,
    bucket_len: usize,
    key: *const u8,
    key_len: usize,
    file_path: *const u8,
    file_path_len: usize,
    progress_cb: Option<DS3ProgressCallbackFn>,
    progress_ctx: *mut std::ffi::c_void,
    out_json: *mut *mut u8,
    out_json_len: *mut usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if s3_handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let client = unsafe { &*s3_handle };
        let bucket = unsafe { ffi_str(bucket, bucket_len)? };
        let key = unsafe { ffi_str(key, key_len)? };
        let file_path_str = unsafe { ffi_str(file_path, file_path_len)? };
        let path = std::path::Path::new(file_path_str);

        let callback = wrap_c_progress_callback(progress_cb, progress_ctx);

        let result = block_on(client.download_object(bucket, key, path, callback.as_deref()))?;
        let json = serde_json::to_string(&result)?;
        unsafe { write_ffi_string(&json, out_json, out_json_len) };
        Ok(0)
    })
}

/// Uploads a local file to S3. Returns the ETag (or null) as a string.
#[no_mangle]
pub unsafe extern "C" fn ds3_upload_object(
    s3_handle: *const DS3S3Client,
    bucket: *const u8,
    bucket_len: usize,
    key: *const u8,
    key_len: usize,
    file_path: *const u8,
    file_path_len: usize,
    progress_cb: Option<DS3ProgressCallbackFn>,
    progress_ctx: *mut std::ffi::c_void,
    out_etag: *mut *mut u8,
    out_etag_len: *mut usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if s3_handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let client = unsafe { &*s3_handle };
        let bucket = unsafe { ffi_str(bucket, bucket_len)? };
        let key = unsafe { ffi_str(key, key_len)? };
        let file_path_str = unsafe { ffi_str(file_path, file_path_len)? };
        let path = std::path::Path::new(file_path_str);

        let callback = wrap_c_progress_callback(progress_cb, progress_ctx);

        let etag = block_on(client.upload_object(bucket, key, path, callback.as_deref(), None))?;

        if let Some(etag_str) = etag {
            unsafe { write_ffi_string(&etag_str, out_etag, out_etag_len) };
        } else {
            unsafe {
                *out_etag = std::ptr::null_mut();
                *out_etag_len = 0;
            };
        }
        Ok(0)
    })
}

/// Deletes a single S3 object.
#[no_mangle]
pub unsafe extern "C" fn ds3_delete_object(
    s3_handle: *const DS3S3Client,
    bucket: *const u8,
    bucket_len: usize,
    key: *const u8,
    key_len: usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if s3_handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let client = unsafe { &*s3_handle };
        let bucket = unsafe { ffi_str(bucket, bucket_len)? };
        let key = unsafe { ffi_str(key, key_len)? };
        block_on(client.delete_object(bucket, key))?;
        Ok(0)
    })
}

/// Copies an S3 object within the same bucket.
#[no_mangle]
pub unsafe extern "C" fn ds3_copy_object(
    s3_handle: *const DS3S3Client,
    bucket: *const u8,
    bucket_len: usize,
    source_key: *const u8,
    source_key_len: usize,
    dest_key: *const u8,
    dest_key_len: usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if s3_handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let client = unsafe { &*s3_handle };
        let bucket = unsafe { ffi_str(bucket, bucket_len)? };
        let source = unsafe { ffi_str(source_key, source_key_len)? };
        let dest = unsafe { ffi_str(dest_key, dest_key_len)? };
        block_on(client.copy_object(bucket, source, dest, None))?;
        Ok(0)
    })
}

/// Checks if a folder marker (.ds3keep) exists.
#[no_mangle]
pub unsafe extern "C" fn ds3_probe_folder_exists(
    s3_handle: *const DS3S3Client,
    bucket: *const u8,
    bucket_len: usize,
    folder_key: *const u8,
    folder_key_len: usize,
    out_result: *mut i32,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if s3_handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let client = unsafe { &*s3_handle };
        let bucket = unsafe { ffi_str(bucket, bucket_len)? };
        let folder_key = unsafe { ffi_str(folder_key, folder_key_len)? };
        let exists = block_on(client.probe_folder_exists(bucket, folder_key))?;
        unsafe { *out_result = if exists { 1 } else { 0 } };
        Ok(0)
    })
}

/// Creates a .ds3keep folder marker.
#[no_mangle]
pub unsafe extern "C" fn ds3_create_folder_marker(
    s3_handle: *const DS3S3Client,
    bucket: *const u8,
    bucket_len: usize,
    folder_key: *const u8,
    folder_key_len: usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if s3_handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let client = unsafe { &*s3_handle };
        let bucket = unsafe { ffi_str(bucket, bucket_len)? };
        let folder_key = unsafe { ffi_str(folder_key, folder_key_len)? };
        block_on(client.create_folder_marker(bucket, folder_key))?;
        Ok(0)
    })
}

// ---------------------------------------------------------------------------
// Sync exports (standalone, no handle needed)
// ---------------------------------------------------------------------------

/// Computes a sync diff from two JSON tree snapshots. Returns result as JSON.
#[no_mangle]
pub unsafe extern "C" fn ds3_compute_diff(
    local_json: *const u8,
    local_json_len: usize,
    remote_json: *const u8,
    remote_json_len: usize,
    out_json: *mut *mut u8,
    out_json_len: *mut usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        let local_str = unsafe { ffi_str(local_json, local_json_len)? };
        let remote_str = unsafe { ffi_str(remote_json, remote_json_len)? };

        let local: std::collections::HashMap<String, Option<String>> =
            serde_json::from_str(local_str)?;
        let remote: std::collections::HashMap<String, Option<String>> =
            serde_json::from_str(remote_str)?;

        let local_tree = ds3_sync::TreeSnapshot::from_map(local);
        let remote_tree = ds3_sync::TreeSnapshot::from_map(remote);
        let diff = ds3_sync::compute_diff(&local_tree, &remote_tree);

        let record: ds3_models::DiffResultRecord = diff.into();
        let json = serde_json::to_string(&record).map_err(|e| DS3Error::JsonError {
            message: e.to_string(),
        })?;
        unsafe { write_ffi_string(&json, out_json, out_json_len) };
        Ok::<i32, DS3Error>(0)
    })
}

/// Generates a conflict copy S3 key. Returns the result as a string.
#[no_mangle]
pub unsafe extern "C" fn ds3_conflict_key(
    original_key: *const u8,
    original_key_len: usize,
    hostname: *const u8,
    hostname_len: usize,
    nonce: *const u8,
    nonce_len: usize,
    out_key: *mut *mut u8,
    out_key_len: *mut usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        let original = unsafe { ffi_str(original_key, original_key_len)? };
        let hostname = unsafe { ffi_str(hostname, hostname_len)? };
        let nonce = unsafe { ffi_opt_str(nonce, nonce_len)? };

        let result = ds3_sync::conflict_key(original, hostname, chrono::Utc::now(), nonce);
        unsafe { write_ffi_string(&result, out_key, out_key_len) };
        Ok::<i32, DS3Error>(0)
    })
}

// ---------------------------------------------------------------------------
// Phase 17 Wave 0 additions (Windows P/Invoke surface)
//
// These exports close the gap identified in 17-RESEARCH §"Key Finding #2" so
// every operation the macOS adapter consumes is also reachable from C# via
// `extern "C"`. Each function follows the established conventions:
//
// - String inputs are `*const u8 + usize` (UTF-8, validated by `ffi_str`).
// - String outputs are heap-allocated by `write_ffi_string`; the caller MUST
//   free them via `ds3_free_string` (or `ds3_free_bytes` for raw byte buffers).
// - `out_error: *mut i32` is always written; a non-zero return code means
//   failure (-1 = DS3Error, -2 = panic).
// - Bodies are wrapped in `ffi_guard!` for panic safety.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Auth gap exports
// ---------------------------------------------------------------------------

/// Retrieves a Curve25519 challenge from the IAM coordinator.
///
/// Mirrors `ds3_auth::challenge::get_challenge`. The result is serialized as
/// a JSON `Challenge { challenge, salt }` document.
///
/// # Ownership
/// - `email`, `tenant_id`, `coordinator_url` are borrowed input UTF-8 slices.
///   `tenant_id` / `coordinator_url` are optional (pass null/0 to omit).
/// - On success, `*out_challenge_json` holds a heap allocation of length
///   `*out_challenge_json_len`. The caller MUST free it with `ds3_free_string`.
///
/// # Error contract
/// Returns 0 on success, -1 on `DS3Error` (code in `*out_error`), -2 on panic.
#[no_mangle]
pub unsafe extern "C" fn ds3_get_challenge(
    email: *const u8,
    email_len: usize,
    tenant_id: *const u8,
    tenant_id_len: usize,
    coordinator_url: *const u8,
    coordinator_url_len: usize,
    out_challenge_json: *mut *mut u8,
    out_challenge_json_len: *mut usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        let email = unsafe { ffi_str(email, email_len)? };
        let tenant = unsafe { ffi_opt_str(tenant_id, tenant_id_len)? };
        let coordinator = unsafe { ffi_opt_str(coordinator_url, coordinator_url_len)? };

        let urls = match coordinator {
            Some(url) => ds3_http::urls::CubbitAPIURLs::new(url),
            None => ds3_http::urls::CubbitAPIURLs::default_coordinator(),
        };
        let http = ds3_http::client::SharedHttpClient::new()?;
        let challenge = block_on(ds3_auth::challenge::get_challenge(
            &http, &urls, email, tenant,
        ))?;

        let json = serde_json::to_string(&challenge)?;
        unsafe { write_ffi_string(&json, out_challenge_json, out_challenge_json_len) };
        Ok::<i32, DS3Error>(0)
    })
}

/// Returns a clone of the current `AccountSession` (token + refreshToken)
/// serialized as JSON, matching the Swift `AccountSession` schema (camelCase
/// `refreshToken`). Used by the C# adapter to persist session state.
///
/// # Ownership
/// - `handle` is borrowed (must be a valid `*const DS3Session`).
/// - On success, `*out_session_json` holds a heap allocation of length
///   `*out_session_json_len`. The caller MUST free it with `ds3_free_string`.
#[no_mangle]
pub unsafe extern "C" fn ds3_current_session(
    handle: *const DS3Session,
    out_session_json: *mut *mut u8,
    out_session_json_len: *mut usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let session = unsafe { &*handle };
        let snapshot = block_on(session.current_session());
        let json = serde_json::to_string(&snapshot)?;
        unsafe { write_ffi_string(&json, out_session_json, out_session_json_len) };
        Ok(0)
    })
}

// ---------------------------------------------------------------------------
// S3 gap exports
// ---------------------------------------------------------------------------

/// Downloads an S3 object directly into a freshly allocated byte buffer.
///
/// Intended for small payloads (thumbnails, `.ds3keep` markers, JSON metadata).
/// For large objects use `ds3_download_object` which streams to a file.
///
/// # Ownership
/// - On success, `*out_buf` holds a heap allocation of length `*out_len`.
///   The caller MUST free it with `ds3_free_bytes`.
#[no_mangle]
pub unsafe extern "C" fn ds3_download_to_memory(
    s3_handle: *const DS3S3Client,
    bucket: *const u8,
    bucket_len: usize,
    key: *const u8,
    key_len: usize,
    out_buf: *mut *mut u8,
    out_len: *mut usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if s3_handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let client = unsafe { &*s3_handle };
        let bucket = unsafe { ffi_str(bucket, bucket_len)? };
        let key = unsafe { ffi_str(key, key_len)? };

        let bytes = block_on(client.download_to_memory(bucket, key))?;
        unsafe { write_ffi_bytes(bytes, out_buf, out_len) };
        Ok(0)
    })
}

/// Uploads an in-memory byte buffer to S3 with optional `Content-Type`
/// metadata (sent as `x-amz-meta-content-type`). Returns the normalized ETag
/// (or empty pointer when absent) via `out_etag` / `out_etag_len`.
///
/// # Ownership
/// - `body` is borrowed (the byte buffer is consumed only for the duration
///   of the call; the caller retains ownership).
/// - On success, `*out_etag` may hold a heap allocation (or null when the
///   server did not return an ETag). When non-null, the caller MUST free it
///   with `ds3_free_string`.
#[no_mangle]
pub unsafe extern "C" fn ds3_upload_from_memory(
    s3_handle: *const DS3S3Client,
    bucket: *const u8,
    bucket_len: usize,
    key: *const u8,
    key_len: usize,
    content_type: *const u8,
    content_type_len: usize,
    body: *const u8,
    body_len: usize,
    out_etag: *mut *mut u8,
    out_etag_len: *mut usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if s3_handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let client = unsafe { &*s3_handle };
        let bucket = unsafe { ffi_str(bucket, bucket_len)? };
        let key = unsafe { ffi_str(key, key_len)? };
        let content_type = unsafe { ffi_opt_str(content_type, content_type_len)? };

        if body.is_null() && body_len > 0 {
            return Err(DS3Error::Encoding);
        }
        let data: Vec<u8> = if body_len == 0 {
            Vec::new()
        } else {
            unsafe { std::slice::from_raw_parts(body, body_len).to_vec() }
        };

        let mut metadata: HashMap<String, String> = HashMap::new();
        if let Some(ct) = content_type {
            metadata.insert("content-type".to_string(), ct.to_string());
        }

        let etag = block_on(client.upload_from_memory(bucket, key, data, metadata))?;

        if let Some(etag_str) = etag {
            unsafe { write_ffi_string(&etag_str, out_etag, out_etag_len) };
        } else {
            unsafe {
                *out_etag = std::ptr::null_mut();
                *out_etag_len = 0;
            };
        }
        Ok(0)
    })
}

/// Generates a presigned GET URL for an S3 object.
///
/// `ttl_seconds` must be in `1..=604_800` (7-day AWS sigv4 cap).
///
/// # Ownership
/// - On success, `*out_url` holds a heap allocation of length `*out_url_len`.
///   The caller MUST free it with `ds3_free_string`.
#[no_mangle]
pub unsafe extern "C" fn ds3_presign_get(
    s3_handle: *const DS3S3Client,
    bucket: *const u8,
    bucket_len: usize,
    key: *const u8,
    key_len: usize,
    ttl_seconds: i64,
    out_url: *mut *mut u8,
    out_url_len: *mut usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if s3_handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let client = unsafe { &*s3_handle };
        let bucket = unsafe { ffi_str(bucket, bucket_len)? };
        let key = unsafe { ffi_str(key, key_len)? };

        let url = block_on(client.presign_get(bucket, key, ttl_seconds))?;
        unsafe { write_ffi_string(&url, out_url, out_url_len) };
        Ok(0)
    })
}

/// Generates a presigned PUT URL for a single multipart upload part.
///
/// `ttl_seconds` must be in `1..=604_800` (7-day AWS sigv4 cap).
///
/// # Ownership
/// - On success, `*out_url` holds a heap allocation of length `*out_url_len`.
///   The caller MUST free it with `ds3_free_string`.
#[no_mangle]
pub unsafe extern "C" fn ds3_presign_upload_part(
    s3_handle: *const DS3S3Client,
    bucket: *const u8,
    bucket_len: usize,
    key: *const u8,
    key_len: usize,
    upload_id: *const u8,
    upload_id_len: usize,
    part_number: i32,
    ttl_seconds: i64,
    out_url: *mut *mut u8,
    out_url_len: *mut usize,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if s3_handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let client = unsafe { &*s3_handle };
        let bucket = unsafe { ffi_str(bucket, bucket_len)? };
        let key = unsafe { ffi_str(key, key_len)? };
        let upload_id = unsafe { ffi_str(upload_id, upload_id_len)? };

        let url =
            block_on(client.presign_upload_part(bucket, key, upload_id, part_number, ttl_seconds))?;
        unsafe { write_ffi_string(&url, out_url, out_url_len) };
        Ok(0)
    })
}

/// Deletes multiple S3 objects in a single batch request.
///
/// `keys_json` is a UTF-8 JSON array of strings, e.g. `["a.txt","sub/b.bin"]`,
/// matching the format the Apple adapter already emits. Returns the number of
/// successfully deleted objects via `*out_deleted_count` (-1 if the pointer
/// is null).
#[no_mangle]
pub unsafe extern "C" fn ds3_delete_objects(
    s3_handle: *const DS3S3Client,
    bucket: *const u8,
    bucket_len: usize,
    keys_json: *const u8,
    keys_json_len: usize,
    out_deleted_count: *mut i32,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if s3_handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let client = unsafe { &*s3_handle };
        let bucket = unsafe { ffi_str(bucket, bucket_len)? };
        let keys_str = unsafe { ffi_str(keys_json, keys_json_len)? };
        let keys: Vec<String> = serde_json::from_str(keys_str)?;

        let deleted = block_on(client.delete_objects(bucket, &keys))?;
        if !out_deleted_count.is_null() {
            unsafe { *out_deleted_count = deleted as i32 };
        }
        Ok(0)
    })
}

// ---------------------------------------------------------------------------
// Error code helper (FFI-AUDIT A1 mirror — Apple consumes the UniFFI version,
// Windows P/Invokes this C ABI version of the same Display-string mapper)
// ---------------------------------------------------------------------------

/// Maps a `DS3Error::Display` string back to its numeric error code.
///
/// `message` is a UTF-8 byte slice carrying the error's stringified Display
/// (Swift / C# catch the error as a flat record and only have the message
/// available — Phase 16 Plan 02 baseline). Returns -1 for unknown messages.
///
/// This function does NOT use `ffi_guard!` because it cannot fail or panic —
/// the worst case (invalid UTF-8) returns -1.
#[no_mangle]
pub unsafe extern "C" fn ds3_error_code(message_ptr: *const u8, message_len: usize) -> i32 {
    if message_ptr.is_null() {
        return -1;
    }
    let slice = unsafe { std::slice::from_raw_parts(message_ptr, message_len) };
    let message = match std::str::from_utf8(slice) {
        Ok(s) => s,
        Err(_) => return -1,
    };
    crate::uniffi_exports::ds3_error_code(message.to_string())
}

// ---------------------------------------------------------------------------
// Cancellation handle exports
// ---------------------------------------------------------------------------

/// Creates a fresh cancellation handle in the "not cancelled" state.
///
/// # Ownership
/// The returned `*mut CancellationHandle` is heap-allocated. The caller MUST
/// destroy it exactly once with `ds3_cancellation_destroy`. Returns
/// `null_mut()` if the allocation panics (unwinding across the FFI boundary
/// is UB; the panic is caught here).
#[no_mangle]
pub extern "C" fn ds3_cancellation_create() -> *mut CancellationHandle {
    match std::panic::catch_unwind(|| {
        let handle = CancellationHandle::new();
        // Convert Arc<CancellationHandle> into a raw pointer for the C ABI;
        // the matching destroy reconstructs the Arc and drops it.
        std::sync::Arc::into_raw(handle) as *mut CancellationHandle
    }) {
        Ok(ptr) => ptr,
        Err(_panic) => std::ptr::null_mut(),
    }
}

/// Requests cancellation. Idempotent and thread-safe.
///
/// # Safety
/// `handle` must be a valid pointer obtained from `ds3_cancellation_create`.
/// Calling on a null pointer is a no-op.
#[no_mangle]
pub unsafe extern "C" fn ds3_cancellation_cancel(handle: *mut CancellationHandle) {
    if handle.is_null() {
        return;
    }
    let _ = std::panic::catch_unwind(|| {
        // SAFETY: caller guarantees `handle` was produced by `Arc::into_raw`.
        // `ManuallyDrop` ensures the Arc cannot be dropped during unwind —
        // even if `cancel()` ever panics, the caller still owns the handle
        // until `ds3_cancellation_destroy` is called (no double-free).
        let arc = std::mem::ManuallyDrop::new(unsafe {
            std::sync::Arc::from_raw(handle as *const CancellationHandle)
        });
        arc.cancel();
    });
}

/// Destroys a cancellation handle, freeing its resources.
///
/// # Safety
/// `handle` must be a valid pointer obtained from `ds3_cancellation_create`.
/// Must not be called twice for the same handle.
#[no_mangle]
pub unsafe extern "C" fn ds3_cancellation_destroy(handle: *mut CancellationHandle) {
    if handle.is_null() {
        return;
    }
    let _ = std::panic::catch_unwind(|| {
        // SAFETY: caller guarantees `handle` was produced by `Arc::into_raw`.
        // Reconstructing the Arc and letting it drop frees the underlying state.
        let _ = unsafe { std::sync::Arc::from_raw(handle as *const CancellationHandle) };
    });
}

// ---------------------------------------------------------------------------
// Log bridge (POL-01 Rust side — see core/ds3-ffi/src/log_bridge.rs)
// ---------------------------------------------------------------------------

/// Installs a C callback that receives every Rust `tracing` event emitted
/// from any `ds3-*` crate. See `core/ds3-ffi/src/log_bridge.rs` for the
/// dispatch semantics and the re-entrancy contract (Phase 17 RESEARCH
/// §"Pitfall 5").
///
/// Idempotent — calling twice replaces the previously registered callback.
///
/// Returns:
///   - `0` on success
///   - `1` if the caller attempted to install a non-null callback but a
///     global `tracing` subscriber was already installed before us — the
///     `CCallbackLayer` could not be added, so the callback would never
///     fire. Caller must surface this so the silent-failure mode does not
///     leak into production. Clearing (`None`) ALWAYS returns `0` regardless
///     of subscriber install state — clearing an absent callback is a no-op.
///   - `-2` on panic caught crossing the FFI boundary (should never happen)
///
/// Pass `None` (a null function pointer) to clear the callback. Callers that
/// cannot pass null function pointers through their FFI binding should use
/// `ds3_clear_log_callback` instead.
#[no_mangle]
pub extern "C" fn ds3_set_log_callback(cb: Option<DS3LogCallbackFn>) -> i32 {
    match std::panic::catch_unwind(|| log_bridge::set_callback(cb)) {
        Ok(Ok(())) => 0,
        Ok(Err(log_bridge::SetCallbackError::SubscriberAlreadyInstalled)) => 1,
        Err(_panic) => -2,
    }
}

/// Clears any previously registered log callback. Always returns `0`; safe
/// to call even if the subscriber install failed or no callback was ever
/// set. Provided as a companion to `ds3_set_log_callback` for FFI bindings
/// that cannot represent a null function pointer.
#[no_mangle]
pub extern "C" fn ds3_clear_log_callback() -> i32 {
    match std::panic::catch_unwind(log_bridge::clear_callback) {
        Ok(()) => 0,
        Err(_panic) => -2,
    }
}
