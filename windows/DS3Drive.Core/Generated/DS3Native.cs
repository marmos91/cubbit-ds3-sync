// ---------------------------------------------------------------------------
// DS3Native.cs — csbindgen-style hand-mirror of core/ds3-ffi/src/c_exports.rs.
//
// Source of truth: core/ds3-ffi/out/NativeMethods.g.cs (the committed csbindgen
// output from Phase 15) + core/ds3-ffi/src/c_exports.rs (the Rust C ABI).
//
// When the C ABI changes, regenerate from
//   cargo run -p ds3-ffi --bin csbindgen-cs > core/ds3-ffi/out/NativeMethods.g.cs
// (deferred to CI — the local dev box lacks the MSVC C++ linker, see STATE.md
// 17-02 blocker) OR update this file by hand and verify with
//   grep -c "DllImport(\"ds3_ffi\"" DS3Native.cs   (must match the export count).
//
// Differences from the raw csbindgen output (intentional, idiomatic):
//   - Opaque handles (DS3Session*, DS3S3Client*, CancellationHandle*) are
//     surfaced as plain `IntPtr` so the managed facade owns lifetime via
//     Interlocked guards rather than typed pointers. The native side only ever
//     dereferences pointers it minted, so the ABI is unchanged.
//   - String/byte outputs use `byte** == out IntPtr` and `nuint* == out nuint`.
//   - The DLL name is "ds3_ffi" (RESEARCH Pitfall 6 / Plan 01); the stale
//     pre-Phase-15 name is intentionally never referenced anywhere in this file.
//
// All functions return `int` status (0 = success; -1 = DS3Error in *out_error;
// -2 = panic). Output buffers MUST be freed exactly once via ds3_free_string /
// ds3_free_bytes (ownership documented per-function in c_exports.rs).
// ---------------------------------------------------------------------------

namespace DS3Drive.Core.Generated;

using System.Runtime.InteropServices;

/// <summary>
/// Progress callback ABI: <c>(long transferred, long total, void* ctx)</c>.
/// Matches <c>DS3ProgressCallbackFn</c> in core/ds3-ffi/src/progress.rs.
/// </summary>
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
internal delegate void DS3ProgressCallbackFn(long transferred, long total, IntPtr ctx);

/// <summary>
/// Raw P/Invoke surface over ds3_ffi.dll. Internal — only <see cref="DS3Session"/>,
/// <see cref="Native.CancellationHandle"/> and tests touch it. Pointers bind at
/// runtime, so this compiles without the native DLL present (Phase 17 local gate).
/// </summary>
internal static unsafe partial class DS3Native
{
    // -----------------------------------------------------------------------
    // Memory management
    // -----------------------------------------------------------------------

    /// <summary>Frees a string allocated by the Rust FFI layer. Single-call only.</summary>
    [DllImport("ds3_ffi", EntryPoint = "ds3_free_string", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern void ds3_free_string(byte* ptr, nuint len);

    /// <summary>Frees a byte buffer allocated by the Rust FFI layer. Single-call only.</summary>
    [DllImport("ds3_ffi", EntryPoint = "ds3_free_bytes", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern void ds3_free_bytes(byte* ptr, nuint len);

    // -----------------------------------------------------------------------
    // Auth — handle ownership: out_handle is owned by the caller; free via
    // ds3_session_destroy exactly once.
    // -----------------------------------------------------------------------

    [DllImport("ds3_ffi", EntryPoint = "ds3_authenticate", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_authenticate(byte* email, nuint email_len, byte* password, nuint password_len, byte* tenant_id, nuint tenant_id_len, byte* coordinator_url, nuint coordinator_url_len, out IntPtr out_handle, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_authenticate_2fa", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_authenticate_2fa(byte* email, nuint email_len, byte* password, nuint password_len, byte* tfa_code, nuint tfa_code_len, byte* tenant_id, nuint tenant_id_len, byte* coordinator_url, nuint coordinator_url_len, out IntPtr out_handle, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_session_destroy", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern void ds3_session_destroy(IntPtr handle);

    [DllImport("ds3_ffi", EntryPoint = "ds3_refresh_token", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_refresh_token(IntPtr handle, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_account_info", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_account_info(IntPtr handle, out IntPtr out_json, out nuint out_json_len, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_forge_iam_token", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_forge_iam_token(IntPtr handle, byte* user_id, nuint user_id_len, out IntPtr out_json, out nuint out_json_len, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_current_session", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_current_session(IntPtr handle, out IntPtr out_session_json, out nuint out_session_json_len, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_get_challenge", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_get_challenge(byte* email, nuint email_len, byte* tenant_id, nuint tenant_id_len, byte* coordinator_url, nuint coordinator_url_len, out IntPtr out_challenge_json, out nuint out_challenge_json_len, out int out_error);

    // -----------------------------------------------------------------------
    // Projects / API keys
    // -----------------------------------------------------------------------

    [DllImport("ds3_ffi", EntryPoint = "ds3_get_projects", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_get_projects(IntPtr handle, out IntPtr out_json, out nuint out_json_len, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_load_api_keys", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_load_api_keys(IntPtr handle, byte* user_id, nuint user_id_len, byte* iam_token, nuint iam_token_len, out IntPtr out_json, out nuint out_json_len, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_create_api_key", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_create_api_key(IntPtr handle, byte* user_id, nuint user_id_len, byte* key_name, nuint key_name_len, byte* iam_token, nuint iam_token_len, out IntPtr out_json, out nuint out_json_len, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_delete_api_key", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_delete_api_key(IntPtr handle, byte* user_id, nuint user_id_len, byte* api_key_id, nuint api_key_id_len, byte* iam_token, nuint iam_token_len, out int out_error);

    // -----------------------------------------------------------------------
    // S3 — s3_handle is an IntPtr to a DS3S3Client minted by the Rust core.
    // -----------------------------------------------------------------------

    [DllImport("ds3_ffi", EntryPoint = "ds3_list_objects", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_list_objects(IntPtr s3_handle, byte* bucket, nuint bucket_len, byte* prefix, nuint prefix_len, byte* delimiter, nuint delimiter_len, int max_keys, byte* continuation_token, nuint continuation_token_len, out IntPtr out_json, out nuint out_json_len, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_list_buckets", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_list_buckets(IntPtr s3_handle, out IntPtr out_json, out nuint out_json_len, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_head_object", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_head_object(IntPtr s3_handle, byte* bucket, nuint bucket_len, byte* key, nuint key_len, out IntPtr out_json, out nuint out_json_len, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_download_object", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_download_object(IntPtr s3_handle, byte* bucket, nuint bucket_len, byte* key, nuint key_len, byte* file_path, nuint file_path_len, DS3ProgressCallbackFn? progress_cb, IntPtr progress_ctx, out IntPtr out_json, out nuint out_json_len, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_upload_object", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_upload_object(IntPtr s3_handle, byte* bucket, nuint bucket_len, byte* key, nuint key_len, byte* file_path, nuint file_path_len, DS3ProgressCallbackFn? progress_cb, IntPtr progress_ctx, out IntPtr out_etag, out nuint out_etag_len, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_delete_object", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_delete_object(IntPtr s3_handle, byte* bucket, nuint bucket_len, byte* key, nuint key_len, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_copy_object", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_copy_object(IntPtr s3_handle, byte* bucket, nuint bucket_len, byte* source_key, nuint source_key_len, byte* dest_key, nuint dest_key_len, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_probe_folder_exists", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_probe_folder_exists(IntPtr s3_handle, byte* bucket, nuint bucket_len, byte* folder_key, nuint folder_key_len, out int out_result, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_create_folder_marker", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_create_folder_marker(IntPtr s3_handle, byte* bucket, nuint bucket_len, byte* folder_key, nuint folder_key_len, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_download_to_memory", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_download_to_memory(IntPtr s3_handle, byte* bucket, nuint bucket_len, byte* key, nuint key_len, out IntPtr out_buf, out nuint out_len, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_upload_from_memory", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_upload_from_memory(IntPtr s3_handle, byte* bucket, nuint bucket_len, byte* key, nuint key_len, byte* content_type, nuint content_type_len, byte* body, nuint body_len, out IntPtr out_etag, out nuint out_etag_len, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_presign_get", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_presign_get(IntPtr s3_handle, byte* bucket, nuint bucket_len, byte* key, nuint key_len, long ttl_seconds, out IntPtr out_url, out nuint out_url_len, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_presign_upload_part", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_presign_upload_part(IntPtr s3_handle, byte* bucket, nuint bucket_len, byte* key, nuint key_len, byte* upload_id, nuint upload_id_len, int part_number, long ttl_seconds, out IntPtr out_url, out nuint out_url_len, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_delete_objects", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_delete_objects(IntPtr s3_handle, byte* bucket, nuint bucket_len, byte* keys_json, nuint keys_json_len, out int out_deleted_count, out int out_error);

    // -----------------------------------------------------------------------
    // Sync (standalone — no session/S3 handle needed)
    // -----------------------------------------------------------------------

    [DllImport("ds3_ffi", EntryPoint = "ds3_compute_diff", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_compute_diff(byte* local_json, nuint local_json_len, byte* remote_json, nuint remote_json_len, out IntPtr out_json, out nuint out_json_len, out int out_error);

    [DllImport("ds3_ffi", EntryPoint = "ds3_conflict_key", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_conflict_key(byte* original_key, nuint original_key_len, byte* hostname, nuint hostname_len, byte* nonce, nuint nonce_len, out IntPtr out_key, out nuint out_key_len, out int out_error);

    // -----------------------------------------------------------------------
    // Error-code helper (Display string → numeric code; -1 unknown). No guard.
    // -----------------------------------------------------------------------

    [DllImport("ds3_ffi", EntryPoint = "ds3_error_code", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_error_code(byte* message_ptr, nuint message_len);

    // -----------------------------------------------------------------------
    // Cancellation handle (heap-allocated; destroy exactly once)
    // -----------------------------------------------------------------------

    [DllImport("ds3_ffi", EntryPoint = "ds3_cancellation_create", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern IntPtr ds3_cancellation_create();

    [DllImport("ds3_ffi", EntryPoint = "ds3_cancellation_cancel", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern void ds3_cancellation_cancel(IntPtr handle);

    [DllImport("ds3_ffi", EntryPoint = "ds3_cancellation_destroy", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern void ds3_cancellation_destroy(IntPtr handle);

    // -----------------------------------------------------------------------
    // Log bridge (POL-01). Clear via ds3_clear_log_callback (null fn ptr).
    // -----------------------------------------------------------------------

    [DllImport("ds3_ffi", EntryPoint = "ds3_set_log_callback", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_set_log_callback(delegate* unmanaged[Cdecl]<int, byte*, nuint, byte*, nuint, void> cb);

    [DllImport("ds3_ffi", EntryPoint = "ds3_clear_log_callback", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int ds3_clear_log_callback();
}
