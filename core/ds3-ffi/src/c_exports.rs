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

use crate::handles::runtime;
use crate::panic_guard::ffi_guard;
use crate::progress::DS3ProgressCallbackFn;
use ds3_auth::DS3Session;
use ds3_models::DS3Error;
use ds3_s3::DS3S3Client;

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
unsafe fn write_ffi_string(
    s: &str,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) {
    let bytes = s.as_bytes().to_vec();
    let len = bytes.len();
    let boxed = bytes.into_boxed_slice();
    let raw = Box::into_raw(boxed) as *mut u8;
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

        let session = runtime().block_on(DS3Session::authenticate(
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

        let session = runtime().block_on(DS3Session::authenticate_with_2fa(
            email, password, tfa, tenant, coordinator,
        ))?;

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
pub unsafe extern "C" fn ds3_refresh_token(
    handle: *const DS3Session,
    out_error: *mut i32,
) -> i32 {
    ffi_guard!(out_error, {
        if handle.is_null() {
            return Err(DS3Error::LoggedOut);
        }
        let session = unsafe { &*handle };
        runtime().block_on(session.refresh_if_needed())?;
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
        let token = runtime().block_on(session.forge_iam_token(user_id))?;
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
        runtime().block_on(session.refresh_if_needed())?;
        let token = runtime()
            .block_on(session.session.lock())
            .token
            .token
            .clone();
        let projects = runtime().block_on(ds3_http::projects::get_projects(
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
        let keys = runtime().block_on(ds3_http::keys::load_api_keys(
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
        let key = runtime().block_on(ds3_http::keys::create_api_key(
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
        runtime().block_on(ds3_http::keys::delete_api_key(
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

        let result = runtime().block_on(client.list_objects(
            bucket,
            prefix,
            delimiter,
            max_keys_opt,
            cont_token,
        ))?;
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
        let buckets = runtime().block_on(client.list_buckets())?;
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
        let metadata = runtime().block_on(client.head_object(bucket, key))?;
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

        let result =
            runtime().block_on(client.download_object(bucket, key, path, callback.as_deref()))?;
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

        let etag = runtime().block_on(
            client.upload_object(bucket, key, path, callback.as_deref()),
        )?;

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
        runtime().block_on(client.delete_object(bucket, key))?;
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
        runtime().block_on(client.copy_object(bucket, source, dest, None))?;
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
        let exists = runtime().block_on(client.probe_folder_exists(bucket, folder_key))?;
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
        runtime().block_on(client.create_folder_marker(bucket, folder_key))?;
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
