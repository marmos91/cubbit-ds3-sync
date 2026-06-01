namespace DS3Drive.Core;

using System.Text;
using System.Text.Json;
using DS3Drive.Core.Exceptions;
using DS3Drive.Core.Generated;
using DS3Drive.Core.Native;
using DS3Drive.Core.Records;

/// <summary>
/// Idiomatic C# facade over ds3_ffi.dll. Owns an opaque session handle minted by
/// <c>ds3_authenticate</c>; every method marshals UTF-8 inputs, calls the native
/// function, translates the return code through <see cref="DS3ExceptionFactory"/>,
/// and parses the JSON output — no <see cref="IntPtr"/> or numeric error code ever
/// leaks to callers. Port of Apple's <c>DS3Authentication</c> handle-owning
/// pattern (apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift lines 102-148,
/// 282-334); the "every method short-circuits to loggedOut if the handle is gone"
/// discipline (Swift lines 138-140) is preserved via <see cref="EnsureHandle"/>.
/// Not thread-safe for concurrent mutation; treat as single-owner. ViewModels
/// wrap it — it is intentionally not observable.
/// </summary>
public sealed class DS3Session : IDisposable
{
    private IntPtr _handle;

    /// <summary>The account id cached from <c>ds3_account_info</c> at authentication time.</summary>
    public string AccountId { get; private set; } = string.Empty;

    /// <summary>True while the native session handle is live (false after <see cref="Dispose"/>).</summary>
    public bool IsAuthenticated => _handle != IntPtr.Zero;

    private DS3Session(IntPtr handle) => _handle = handle;

    // --- Authentication factories ---

    /// <summary>Authenticates with email + password. Throws <see cref="DS3AuthenticationException"/>
    /// (Reason=TwoFactorRequired, code 1007) when a 2FA code is required — the caller then retries
    /// via <see cref="Authenticate2fa"/> (D-15 byte-identical to Apple).</summary>
    public static unsafe DS3Session Authenticate(string email, string password, string? tenantId, string coordinatorUrl)
    {
        IntPtr handle;
        int rc;
        int err;
        fixed (byte* e = M.Utf8(email), p = M.Utf8(password), t = M.Utf8(tenantId), c = M.Utf8(coordinatorUrl))
        {
            rc = DS3Native.ds3_authenticate(e, M.Len(email), p, M.Len(password), t, M.Len(tenantId), c, M.Len(coordinatorUrl), out handle, out err);
        }

        return Complete(rc, err, handle);
    }

    /// <summary>Authenticates with email + password + a 2FA code.</summary>
    public static unsafe DS3Session Authenticate2fa(string email, string password, string tfaCode, string? tenantId, string coordinatorUrl)
    {
        IntPtr handle;
        int rc;
        int err;
        fixed (byte* e = M.Utf8(email), p = M.Utf8(password), f = M.Utf8(tfaCode), t = M.Utf8(tenantId), c = M.Utf8(coordinatorUrl))
        {
            rc = DS3Native.ds3_authenticate_2fa(e, M.Len(email), p, M.Len(password), f, M.Len(tfaCode), t, M.Len(tenantId), c, M.Len(coordinatorUrl), out handle, out err);
        }

        return Complete(rc, err, handle);
    }

    private static DS3Session Complete(int rc, int err, IntPtr handle)
    {
        if (rc != 0)
        {
            throw DS3ExceptionFactory.From(err);
        }

        var session = new DS3Session(handle);
        session.AccountId = session.AccountInfo().AccountId;
        return session;
    }

    // --- Auth + SDK ---

    /// <summary>Returns the current account identity (cached at <see cref="AccountId"/>).</summary>
    public DS3AccountInfo AccountInfo()
    {
        int rc = DS3Native.ds3_account_info(EnsureHandle(), out IntPtr json, out nuint len, out int err);
        return Parse<DS3AccountInfo>(rc, err, json, len);
    }

    /// <summary>Refreshes the access token if expired.</summary>
    public void RefreshToken() => Check(DS3Native.ds3_refresh_token(EnsureHandle(), out int err), err);

    /// <summary>Forges an IAM token for the given user (returns the raw token string).</summary>
    public unsafe string ForgeIamToken(string iamUserId)
    {
        IntPtr h = EnsureHandle();
        int rc;
        IntPtr json;
        nuint len;
        int err;
        fixed (byte* u = M.Utf8(iamUserId))
        {
            rc = DS3Native.ds3_forge_iam_token(h, u, M.Len(iamUserId), out json, out len, out err);
        }

        Check(rc, err, json, len);
        return M.TakeString(json, len);
    }

    /// <summary>Lists the projects visible to the account.</summary>
    public IReadOnlyList<DS3Project> GetProjects()
    {
        int rc = DS3Native.ds3_get_projects(EnsureHandle(), out IntPtr json, out nuint len, out int err);
        return Parse<List<DS3Project>>(rc, err, json, len);
    }

    /// <summary>Loads the API keys for an IAM user (requires a forged IAM token).</summary>
    public unsafe IReadOnlyList<DS3ApiKey> LoadApiKeys(string iamUserId, string iamToken)
    {
        IntPtr h = EnsureHandle();
        int rc;
        IntPtr json;
        nuint len;
        int err;
        fixed (byte* u = M.Utf8(iamUserId), t = M.Utf8(iamToken))
        {
            rc = DS3Native.ds3_load_api_keys(h, u, M.Len(iamUserId), t, M.Len(iamToken), out json, out len, out err);
        }

        return Parse<List<DS3ApiKey>>(rc, err, json, len);
    }

    /// <summary>Creates a new API key for an IAM user (the secret is returned only here).</summary>
    public unsafe DS3ApiKey CreateApiKey(string iamUserId, string iamToken, string apiKeyName)
    {
        IntPtr h = EnsureHandle();
        int rc;
        IntPtr json;
        nuint len;
        int err;
        fixed (byte* u = M.Utf8(iamUserId), n = M.Utf8(apiKeyName), t = M.Utf8(iamToken))
        {
            rc = DS3Native.ds3_create_api_key(h, u, M.Len(iamUserId), n, M.Len(apiKeyName), t, M.Len(iamToken), out json, out len, out err);
        }

        return Parse<DS3ApiKey>(rc, err, json, len);
    }

    /// <summary>Deletes an API key by id (requires a forged IAM token).</summary>
    public unsafe void DeleteApiKey(string iamUserId, string apiKeyId, string iamToken)
    {
        IntPtr h = EnsureHandle();
        int rc;
        int err;
        fixed (byte* u = M.Utf8(iamUserId), k = M.Utf8(apiKeyId), t = M.Utf8(iamToken))
        {
            rc = DS3Native.ds3_delete_api_key(h, u, M.Len(iamUserId), k, M.Len(apiKeyId), t, M.Len(iamToken), out err);
        }

        Check(rc, err);
    }

    // --- S3 methods removed in plan 17.1-02 (D-02): they now live on
    // DS3DriveS3Client, which owns a real DS3S3Client handle minted by
    // ds3_s3_client_new. DS3Session passed its SESSION handle into the S3 exports
    // (a wrong-type deref → AccessViolationException); that path is gone. ---

    // --- Sync (standalone — no handle required) ---

    /// <summary>Computes the upload/download/delete actions between two tree snapshots.</summary>
    public static unsafe DS3DiffActions ComputeDiff(string localTreeJson, string remoteTreeJson)
    {
        int rc;
        IntPtr json;
        nuint len;
        int err;
        fixed (byte* l = M.Utf8(localTreeJson), r = M.Utf8(remoteTreeJson))
        {
            rc = DS3Native.ds3_compute_diff(l, M.Len(localTreeJson), r, M.Len(remoteTreeJson), out json, out len, out err);
        }

        return Parse<DS3DiffActions>(rc, err, json, len);
    }

    /// <summary>Generates a conflict-copy key for an object (device name disambiguates).</summary>
    public static unsafe string ConflictKey(string originalKey, string deviceName)
    {
        int rc;
        IntPtr key;
        nuint len;
        int err;
        fixed (byte* o = M.Utf8(originalKey), d = M.Utf8(deviceName))
        {
            rc = DS3Native.ds3_conflict_key(o, M.Len(originalKey), d, M.Len(deviceName), null, 0, out key, out len, out err);
        }

        Check(rc, err, key, len);
        return M.TakeString(key, len);
    }

    // --- Lifecycle ---

    /// <summary>
    /// Frees the native session handle exactly once (Interlocked guard; double-dispose
    /// is a no-op). PERSISTENCE NOTE (PATTERNS §3.3): callers MUST persist drives /
    /// session state BEFORE disposing — once disposed, no FFI call can re-read it.
    /// </summary>
    public void Dispose()
    {
        IntPtr prev = Interlocked.Exchange(ref _handle, IntPtr.Zero);
        if (prev != IntPtr.Zero)
        {
            DS3Native.ds3_session_destroy(prev);
        }
    }

    /// <summary>Returns the live handle or throws loggedOut — port of the Swift
    /// <c>guard let handle else { throw .loggedOut }</c> short-circuit (PATTERNS §3.2).</summary>
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

    /// <summary>UTF-8 marshalling + native-buffer RAII helpers, isolated so the
    /// public methods read as a flat call → check → parse sequence.</summary>
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
