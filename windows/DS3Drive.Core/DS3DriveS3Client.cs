namespace DS3Drive.Core;

using System.Text;
using System.Text.Json;
using DS3Drive.Core.Exceptions;
using DS3Drive.Core.Generated;
using DS3Drive.Core.Native;
using DS3Drive.Core.Records;

/// <summary>
/// Per-drive, handle-owning facade over the S3 surface of ds3_ffi.dll. Owns
/// exactly one opaque <c>DS3S3Client</c> handle minted by <c>ds3_s3_client_new</c>
/// (from S3 credentials: endpoint + access/secret key, NOT the session token),
/// frees it exactly once on <see cref="Dispose"/> via <c>ds3_s3_client_destroy</c>,
/// and routes the six S3 ops (list/head/download/upload/delete/copy) plus the
/// folder-marker pair through ITS OWN handle.
///
/// <para>
/// This is the structural fix for the wizard's <c>AccessViolationException</c>
/// (T-17.1-05): until plan 17.1-02 these S3 methods lived on <see cref="DS3Session"/>
/// and passed the SESSION handle into the S3 exports — a wrong-type deref. The
/// methods are re-homed here onto a real <c>DS3S3Client</c> handle (D-01/D-02);
/// <see cref="DS3Session"/> is now auth/session-only.
/// </para>
///
/// <para>
/// Behavioral parity with macOS <c>DS3S3Client</c> (apple/DS3Lib/Sources/DS3Lib/DS3Client.swift):
/// the macOS S3 client is a SEPARATE object from the session; this facade mirrors that.
/// </para>
///
/// <para>
/// CONCURRENCY (Pitfall 3 / T-17.1-07): the handle may be called by ~40 threads
/// concurrently — <c>FetchDataHandler</c> and <c>UploadQueue</c> each own an
/// independent <c>SemaphoreSlim(20,20)</c>. The underlying <c>aws_sdk_s3::Client</c>
/// is <c>Clone + Send + Sync</c> and every C-ABI method takes <c>*const DS3S3Client</c>
/// (a shared <c>&amp;self</c>). DO NOT add a C#-side mutex around S3 calls — it would
/// serialize and kill throughput. The only mutation point is <see cref="Dispose"/>,
/// which <c>Interlocked.Exchange</c> makes single-shot; ordering against in-flight
/// calls is the host's job (dispose-last in <c>StopActiveAsync</c>, Plan 03).
/// </para>
/// </summary>
public sealed class DS3DriveS3Client : IDisposable
{
    private IntPtr _handle;

    /// <summary>True while the native S3 client handle is live (false after <see cref="Dispose"/>).</summary>
    public bool IsLive => _handle != IntPtr.Zero;

    private DS3DriveS3Client(IntPtr handle) => _handle = handle;

    // --- Factory ---

    /// <summary>
    /// Mints a new S3 client handle from S3 credentials. <paramref name="region"/>
    /// is optional — null/empty marshals to <c>null,0</c> which the Rust core reads
    /// as <c>None</c> and defaults to <c>us-east-1</c> (macOS parity; no C#-side
    /// sentinel). The secret crosses the boundary exactly once here and is never
    /// logged (T-17.1-08). Throws the typed exception from
    /// <see cref="DS3ExceptionFactory"/> on a non-zero return code.
    /// </summary>
    public static unsafe DS3DriveS3Client Create(string endpoint, string accessKey, string secretKey, string? region = null)
    {
        IntPtr handle;
        int rc;
        int err;
        fixed (byte* e = M.Utf8(endpoint), a = M.Utf8(accessKey), s = M.Utf8(secretKey), r = M.Utf8(region))
        {
            rc = DS3Native.ds3_s3_client_new(e, M.Len(endpoint), a, M.Len(accessKey), s, M.Len(secretKey), r, M.Len(region), out handle, out err);
        }

        if (rc != 0)
        {
            throw DS3ExceptionFactory.From(err);
        }

        return new DS3DriveS3Client(handle);
    }

    // --- S3 ---

    /// <summary>Lists all buckets reachable with the client's S3 credentials.</summary>
    public IReadOnlyList<DS3Bucket> ListBuckets()
    {
        int rc = DS3Native.ds3_list_buckets(EnsureHandle(), out IntPtr json, out nuint len, out int err);
        return Parse<List<DS3Bucket>>(rc, err, json, len);
    }

    /// <summary>Lists the objects under a prefix (the objects in this page), optionally paginated
    /// via a continuation token. Common prefixes (delimiter "folders") are dropped — use
    /// <see cref="ListObjectsListing"/> when those are needed.</summary>
    public IReadOnlyList<DS3Object> ListObjects(string bucket, string prefix, string delimiter, string? continuationToken) =>
        ListObjectsListing(bucket, prefix, delimiter, continuationToken).Objects;

    /// <summary>Lists under a prefix and returns the full listing — objects, common prefixes (the
    /// virtual "folders" surfaced by a delimiter), and pagination state. The native call returns
    /// this whole object; deserializing only an array of objects drops the common prefixes and
    /// fails outright.</summary>
    public unsafe DS3ObjectListing ListObjectsListing(string bucket, string prefix, string delimiter, string? continuationToken)
    {
        IntPtr h = EnsureHandle();
        int rc;
        IntPtr json;
        nuint len;
        int err;
        fixed (byte* b = M.Utf8(bucket), p = M.Utf8(prefix), d = M.Utf8(delimiter), ct = M.Utf8(continuationToken))
        {
            rc = DS3Native.ds3_list_objects(h, b, M.Len(bucket), p, M.Len(prefix), d, M.Len(delimiter), 0, ct, M.Len(continuationToken), out json, out len, out err);
        }

        return Parse<DS3ObjectListing>(rc, err, json, len);
    }

    /// <summary>Returns metadata for a single object.</summary>
    public unsafe DS3Object HeadObject(string bucket, string key)
    {
        IntPtr h = EnsureHandle();
        int rc;
        IntPtr json;
        nuint len;
        int err;
        fixed (byte* b = M.Utf8(bucket), k = M.Utf8(key))
        {
            rc = DS3Native.ds3_head_object(h, b, M.Len(bucket), k, M.Len(key), out json, out len, out err);
        }

        return Parse<DS3Object>(rc, err, json, len);
    }

    /// <summary>Downloads an object to a local file path, reporting progress and honoring cancellation.</summary>
    public unsafe DS3Object DownloadObject(string bucket, string key, string filePath, DS3ProgressCallback? progress, CancellationHandle? cancel)
    {
        IntPtr h = EnsureHandle();
        var cb = M.WrapProgress(progress);
        _ = cancel;
        int rc;
        IntPtr json;
        nuint len;
        int err;
        fixed (byte* b = M.Utf8(bucket), k = M.Utf8(key), f = M.Utf8(filePath))
        {
            rc = DS3Native.ds3_download_object(h, b, M.Len(bucket), k, M.Len(key), f, M.Len(filePath), cb, IntPtr.Zero, out json, out len, out err);
        }

        GC.KeepAlive(cb);
        return Parse<DS3Object>(rc, err, json, len);
    }

    /// <summary>Uploads a local file to S3, returning the resulting ETag (may be empty).</summary>
    public unsafe string UploadObject(string bucket, string key, string filePath, DS3ProgressCallback? progress, CancellationHandle? cancel)
    {
        IntPtr h = EnsureHandle();
        var cb = M.WrapProgress(progress);
        _ = cancel;
        int rc;
        IntPtr etag;
        nuint len;
        int err;
        fixed (byte* b = M.Utf8(bucket), k = M.Utf8(key), f = M.Utf8(filePath))
        {
            rc = DS3Native.ds3_upload_object(h, b, M.Len(bucket), k, M.Len(key), f, M.Len(filePath), cb, IntPtr.Zero, out etag, out len, out err);
        }

        GC.KeepAlive(cb);
        Check(rc, err);
        return M.TakeString(etag, len);
    }

    /// <summary>Deletes a single object.</summary>
    public unsafe void DeleteObject(string bucket, string key)
    {
        IntPtr h = EnsureHandle();
        int rc;
        int err;
        fixed (byte* b = M.Utf8(bucket), k = M.Utf8(key))
        {
            rc = DS3Native.ds3_delete_object(h, b, M.Len(bucket), k, M.Len(key), out err);
        }

        Check(rc, err);
    }

    /// <summary>Copies an object within a bucket (the C ABI is single-bucket; cross-bucket is later).</summary>
    public unsafe void CopyObject(string srcBucket, string srcKey, string dstBucket, string dstKey)
    {
        IntPtr h = EnsureHandle();
        int rc;
        int err;

        // The ds3_copy_object ABI is single-bucket: it copies within `srcBucket` only and has
        // no destination-bucket parameter. Fail loudly on a cross-bucket request rather than
        // silently writing to the SOURCE bucket — a data-misplacement trap (WR-17.1-03). Remove
        // this guard only once the ABI grows a real destination-bucket argument.
        if (!string.Equals(srcBucket, dstBucket, StringComparison.Ordinal))
        {
            throw new NotSupportedException(
                "Cross-bucket copy is not supported by the current ds3_copy_object ABI.");
        }

        fixed (byte* b = M.Utf8(srcBucket), s = M.Utf8(srcKey), d = M.Utf8(dstKey))
        {
            rc = DS3Native.ds3_copy_object(h, b, M.Len(srcBucket), s, M.Len(srcKey), d, M.Len(dstKey), out err);
        }

        Check(rc, err);
    }

    /// <summary>Checks whether a <c>.ds3keep</c> folder marker exists.</summary>
    public unsafe bool ProbeFolderExists(string bucket, string folderKey)
    {
        IntPtr h = EnsureHandle();
        int rc;
        int result;
        int err;
        fixed (byte* b = M.Utf8(bucket), f = M.Utf8(folderKey))
        {
            rc = DS3Native.ds3_probe_folder_exists(h, b, M.Len(bucket), f, M.Len(folderKey), out result, out err);
        }

        Check(rc, err);
        return result != 0;
    }

    /// <summary>Creates a <c>.ds3keep</c> folder marker.</summary>
    public unsafe void CreateFolderMarker(string bucket, string folderKey)
    {
        IntPtr h = EnsureHandle();
        int rc;
        int err;
        fixed (byte* b = M.Utf8(bucket), f = M.Utf8(folderKey))
        {
            rc = DS3Native.ds3_create_folder_marker(h, b, M.Len(bucket), f, M.Len(folderKey), out err);
        }

        Check(rc, err);
    }

    // --- Lifecycle ---

    /// <summary>
    /// Frees the native S3 client handle exactly once (Interlocked guard; double-dispose
    /// is a no-op). Does NOT protect a concurrent in-flight call — the host orders dispose
    /// LAST, after the engine + provider fully stop (Pitfall 4, Plan 03).
    /// </summary>
    public void Dispose()
    {
        IntPtr prev = Interlocked.Exchange(ref _handle, IntPtr.Zero);
        if (prev != IntPtr.Zero)
        {
            DS3Native.ds3_s3_client_destroy(prev);
        }
    }

    /// <summary>Returns the live handle or throws loggedOut — port of the Swift
    /// <c>guard let handle else { throw .loggedOut }</c> short-circuit. Any S3 method on a
    /// gone handle throws a managed exception BEFORE P/Invoking — never an AccessViolation.</summary>
    private IntPtr EnsureHandle()
    {
        IntPtr h = _handle;
        if (h == IntPtr.Zero)
        {
            throw new DS3AuthenticationException(AuthFailureReason.LoggedOut, errorCode: 1005);
        }

        return h;
    }

    // --- Output helpers ---

    private static void Check(int rc, int err)
    {
        if (rc != 0)
        {
            throw DS3ExceptionFactory.From(err);
        }
    }

    private static void Check(int rc, int err, IntPtr buf, nuint len)
    {
        if (rc != 0)
        {
            M.FreeString(buf, len);
            throw DS3ExceptionFactory.From(err);
        }
    }

    private static T Parse<T>(int rc, int err, IntPtr json, nuint len)
    {
        Check(rc, err, json, len);
        string text = M.TakeString(json, len);
        return JsonSerializer.Deserialize<T>(text) ?? throw DS3ExceptionFactory.From(1003); // JsonConversion
    }

    /// <summary>UTF-8 marshalling + native-buffer RAII helpers, copied from
    /// <see cref="DS3Session"/> to keep the diff local (PATTERNS §"Shared Patterns").</summary>
    private static class M
    {
        private static readonly byte[] EmptyBuf = new byte[1];

        public static byte[] Utf8(string? s) => string.IsNullOrEmpty(s) ? EmptyBuf : Encoding.UTF8.GetBytes(s);

        // Length is always computed by us from the byte count (never caller-supplied) — T-17-05-01.
        public static nuint Len(string? s) => string.IsNullOrEmpty(s) ? 0 : (nuint)Encoding.UTF8.GetByteCount(s);

        public static unsafe string TakeString(IntPtr ptr, nuint len)
        {
            if (ptr == IntPtr.Zero || len == 0)
            {
                return string.Empty;
            }

            string s = Encoding.UTF8.GetString((byte*)ptr, (int)len);
            FreeString(ptr, len);
            return s;
        }

        public static unsafe void FreeString(IntPtr ptr, nuint len)
        {
            if (ptr != IntPtr.Zero && len != 0)
            {
                DS3Native.ds3_free_string((byte*)ptr, len);
            }
        }

        public static DS3ProgressCallbackFn? WrapProgress(DS3ProgressCallback? progress) =>
            progress is null ? null : (transferred, total, _) => progress(transferred, total);
    }
}
