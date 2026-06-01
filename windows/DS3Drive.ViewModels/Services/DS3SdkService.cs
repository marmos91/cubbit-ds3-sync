namespace DS3Drive.ViewModels.Services;

using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core;
using DS3Drive.Core.Exceptions;
using DS3Drive.Core.Records;
using DS3Drive.Sync.Storage;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging;

/// <summary>
/// Default <see cref="IDS3SdkService"/>. Byte-for-byte port of Apple's <c>DS3SDK</c>
/// (apple/DS3Lib/Sources/DS3Lib/DS3SDK.swift:68-249) — the API-key reconciliation
/// algorithm (D-10, PATTERNS §2.6) is load-bearing for cross-platform drive
/// interoperability and is reproduced branch-for-branch from DS3SDK.swift:163-195.
///
/// Boundary discipline (STRIDE T-17-09-02): a created key's <c>SecretKey</c> is passed
/// straight to <see cref="CredentialStore.Save"/> and never persisted to SQLite
/// (D-12/D-14); only the non-secret metadata (name, access_key, iam_user_id) lands in
/// the <c>api_keys</c> table.
/// </summary>
public sealed class DS3SdkService : IDS3SdkService, IDisposable
{
    private readonly IDS3SessionGateway _session;
    private readonly SyncDatabase _db;
    private readonly CredentialStore _credentials;
    private readonly ConfigStore _config;
    private readonly IInstallationIdProvider _installation;
    private readonly ILogger<DS3SdkService> _logger;

    // Per-project wizard-browse S3 client cache (keyed by project name — the project only
    // selects which reconciled credentials build the client; ds3_list_buckets takes no project
    // arg, Q3). A plain SemaphoreSlim guarding the dictionary suffices on Windows: the C-ABI S3
    // client is independent of the session handle, so macOS's connectS3-on-shared-handle
    // double-check-under-lock does not apply (PATTERNS §"macOS behavioral parity"). The most
    // recently built client backs ListChildPrefixesAsync, which carries no project context.
    private readonly Dictionary<string, DS3DriveS3Client> _browseClients = new();
    private readonly SemaphoreSlim _browseLock = new(1, 1);
    private DS3DriveS3Client? _currentBrowseClient;

    // In-flight browse-operation gate (WR-17.1-01). GetBucketsAsync/ListChildPrefixesAsync run the
    // blocking S3 call on a worker thread; Dispose() (a DI-singleton dispose at Host shutdown) must
    // NOT free a native browse handle while a worker is mid-ListBuckets/ListObjects inside Rust —
    // that is a use-after-free / AccessViolationException. _disposed flips first so no NEW operation
    // can start touching a handle that is about to be freed; _inFlight tracks running operations and
    // _drained is set when the last one completes after disposal began. All three are guarded by
    // _browseLock (the same lock that guards the client dictionary + _currentBrowseClient pointer),
    // mirroring the sync host's dispose-last discipline.
    private int _inFlight;
    private bool _disposed;
    private readonly ManualResetEventSlim _drained = new(true);

    public DS3SdkService(
        IDS3SessionGateway session,
        SyncDatabase db,
        CredentialStore credentials,
        ConfigStore config,
        IInstallationIdProvider installation,
        ILogger<DS3SdkService> logger)
    {
        _session = session;
        _db = db;
        _credentials = credentials;
        _config = config;
        _installation = installation;
        _logger = logger;
    }

    /// <inheritdoc />
    public Task<IReadOnlyList<DS3Project>> GetProjectsAsync(CancellationToken ct) =>
        // The FFI call is synchronous + blocking; run it off the UI thread (UI-SPEC
        // §Loading states shows the "Loading projects…" ring during this window).
        Task.Run(() => _session.GetProjects(), ct);

    /// <inheritdoc />
    public async Task<IReadOnlyList<DS3Bucket>> GetBucketsAsync(DS3Project project, CancellationToken ct)
    {
        // Route the browse through a per-drive DS3DriveS3Client built from the reconciled
        // API key for (root user, project) + the account's endpoint_gateway — NOT the session
        // handle (17.1-03 fix; the old _session.ListBuckets() dereferenced the session handle
        // inside the S3 export → AccessViolationException). The FFI call is synchronous +
        // blocking; run it off the UI thread (UI-SPEC "Loading buckets…" ring).
        DS3DriveS3Client client = await GetBrowseClientAsync(project, ct).ConfigureAwait(false);
        EnterBrowseOperation();
        try
        {
            return await Task.Run(() => client.ListBuckets(), ct).ConfigureAwait(false);
        }
        finally
        {
            ExitBrowseOperation();
        }
    }

    /// <inheritdoc />
    public async Task<IReadOnlyList<string>> ListChildPrefixesAsync(string bucket, string? prefix, CancellationToken ct)
    {
        // The prefix-tree browse carries no project context, so it reuses the most recently
        // built browse client (the wizard always lists buckets — selecting a project — before
        // browsing prefixes, so _currentBrowseClient is live). Snapshot it UNDER _browseLock
        // (WR-17.1-01): the pointer is mutated under the lock by GetBrowseClientAsync, so an
        // unlocked read here could observe a torn/disposed reference. If absent (defensive),
        // surface a managed loggedOut rather than a null deref.
        DS3DriveS3Client client;
        await _browseLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            client = _currentBrowseClient
                ?? throw new DS3AuthenticationException(AuthFailureReason.LoggedOut, errorCode: 1005);
        }
        finally
        {
            _browseLock.Release();
        }

        EnterBrowseOperation();
        try
        {
            return await Task.Run<IReadOnlyList<string>>(() =>
            {
                // Delimiter "/" gives folder-style listing; the FFI returns objects whose keys
                // end in "/" for child prefixes. Keep only those (the tree shows folders).
                IReadOnlyList<DS3Object> objects = client.ListObjects(bucket, prefix ?? string.Empty, "/", null);
                return objects
                    .Select(o => o.Key)
                    .Where(k => k.EndsWith('/') && k != (prefix ?? string.Empty))
                    .Distinct()
                    .ToList();
            }, ct).ConfigureAwait(false);
        }
        finally
        {
            ExitBrowseOperation();
        }
    }

    /// <summary>
    /// Builds (or returns the cached) per-project <see cref="DS3DriveS3Client"/> for the wizard
    /// browse. The reconcile (forge IAM token + load/create API key) runs OUTSIDE the lock so
    /// the lock is never held across an await; the dictionary mutation + the "current client"
    /// pointer update happen under the lock with a double-check (another browse may have
    /// populated the cache while we awaited the API-key fetch). Mirrors macOS
    /// <c>s3Client(forProject:iamUser:)</c> (caching divergence: Windows keys per project).
    /// </summary>
    private async Task<DS3DriveS3Client> GetBrowseClientAsync(DS3Project project, CancellationToken ct)
    {
        await _browseLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (_browseClients.TryGetValue(project.Name, out DS3DriveS3Client? cached))
            {
                _currentBrowseClient = cached;
                return cached;
            }
        }
        finally
        {
            _browseLock.Release();
        }

        // The wizard's IAM user is the account root (id == account id) — the same user
        // DriveSetupWizardPage seeds as CurrentUser and RepairCredentialsAsync reconstructs
        // from the anchor. LoadOrCreateApiKeyAsync forges the IAM token from this id and
        // reconciles the deterministic key for (user, project.Name).
        var rootUser = new DS3IAMUser(_session.AccountId, _session.AccountId, string.Empty);
        DS3ApiKey key = await LoadOrCreateApiKeyAsync(rootUser, project.Name, ct).ConfigureAwait(false);
        string endpoint = _session.EndpointGateway;

        await _browseLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (_browseClients.TryGetValue(project.Name, out DS3DriveS3Client? raced))
            {
                _currentBrowseClient = raced;
                return raced;
            }

            // Region null => Rust defaults to us-east-1 (macOS parity). The secret crosses the
            // FFI boundary here and is not retained C#-side beyond this call (T-17.1-09).
            var client = DS3DriveS3Client.Create(endpoint, key.AccessKey, key.SecretKey);
            _browseClients[project.Name] = client;
            _currentBrowseClient = client;
            return client;
        }
        finally
        {
            _browseLock.Release();
        }
    }

    /// <inheritdoc />
    public string ApiKeyName(DS3IAMUser user, string projectName)
    {
        // Port of DS3SDK.swift:242-248 — DO NOT modify the format string. The Swift
        // source: "\(prefix)(\(username)_\(name.lowercased().replacingOccurrences(of: " ", with: "_"))_\(appUUID))".
        string prefix = _config.ApiKeyNamePrefix;
        string sanitized = projectName.ToLowerInvariant().Replace(" ", "_", StringComparison.Ordinal);
        string installationId = _installation.InstallationId;
        return $"{prefix}({user.Username}_{sanitized}_{installationId})";
    }

    /// <inheritdoc />
    public async Task<DS3ApiKey> LoadOrCreateApiKeyAsync(DS3IAMUser user, string projectName, CancellationToken ct)
    {
        // === Byte-for-byte port of DS3SDK.swift:163-195 (D-10 / PATTERNS §2.6) ===
        string apiKeyName = ApiKeyName(user, projectName);

        // 1. Local keys for this IAM user (secret lives in Credential Manager, not SQLite).
        IReadOnlyList<DS3ApiKey> localApiKeys = await LoadLocalApiKeysAsync(user.Id, ct).ConfigureAwait(false);
        DS3ApiKey? localApiKey = localApiKeys.FirstOrDefault(k => k.Name == apiKeyName);

        // 2. Forge IAM token (DS3SDK.swift:172) + load remote keys (DS3SDK.swift:174).
        string iamToken = await Task.Run(() => _session.ForgeIamToken(user.Id), ct).ConfigureAwait(false);
        IReadOnlyList<DS3ApiKey> remoteApiKeys =
            await Task.Run(() => _session.LoadApiKeys(user.Id, iamToken), ct).ConfigureAwait(false);
        DS3ApiKey? remoteApiKey = remoteApiKeys.FirstOrDefault(k => k.Name == apiKeyName);

        // 3a. Matching pair → reuse local (DS3SDK.swift:178-181). Equality is by name +
        //     access key (the only fields both sides carry; the remote re-list omits the secret).
        if (localApiKey is not null && remoteApiKey is not null && KeysMatch(localApiKey, remoteApiKey))
        {
            _logger.LogDebug("Returning existing API key since it matches the remote one.");
            return localApiKey;
        }

        // 3b. Remote-only → delete the orphan remote key (DS3SDK.swift:184-187).
        if (remoteApiKey is not null && localApiKey is null)
        {
            _logger.LogDebug("Deleting remote API key since it is not found locally.");
            await Task.Run(() => _session.DeleteApiKey(user.Id, remoteApiKey.Id, iamToken), ct).ConfigureAwait(false);
        }

        // 3c. Local-only → delete the stale local key (DS3SDK.swift:189-192).
        if (localApiKey is not null && remoteApiKey is null)
        {
            _logger.LogDebug("Deleting local key since it is not found remotely.");
            await DeleteLocalApiKeyAsync(apiKeyName, ct).ConfigureAwait(false);
        }

        // 3d. Both present but differ (same name, different access key). Branches 3b/3c do NOT
        //     fire here (3b needs local-null, 3c needs remote-null), so without this branch the
        //     stale remote key would be left undeleted — an orphan with live S3 credentials
        //     (WR-17.1-06). Delete BOTH sides before recreating so we never leak the old key.
        //     Threat T-17-09-06: if a delete-then-create partial failure leaves an orphan remote
        //     key, the next run sees local-null + remote-null and recreates cleanly.
        if (localApiKey is not null && remoteApiKey is not null)
        {
            _logger.LogDebug("Deleting mismatched local + remote API keys before regenerating.");
            await Task.Run(() => _session.DeleteApiKey(user.Id, remoteApiKey.Id, iamToken), ct).ConfigureAwait(false);
            await DeleteLocalApiKeyAsync(apiKeyName, ct).ConfigureAwait(false);
        }

        // 4. Create + persist (DS3SDK.swift:194 → generateDS3APIKey:203-235).
        return await CreateAndPersistAsync(user.Id, iamToken, apiKeyName, ct).ConfigureAwait(false);
    }

    private static bool KeysMatch(DS3ApiKey local, DS3ApiKey remote) =>
        local.Name == remote.Name && local.AccessKey == remote.AccessKey;

    /// <summary>Generates a new key (DS3SDK.swift:203-235): create remotely, then persist
    /// the non-secret metadata to SQLite + the secret to Credential Manager.</summary>
    private async Task<DS3ApiKey> CreateAndPersistAsync(string userId, string iamToken, string apiKeyName, CancellationToken ct)
    {
        _logger.LogDebug("Generating new API key.");
        DS3ApiKey created = await Task.Run(() => _session.CreateApiKey(userId, iamToken, apiKeyName), ct)
            .ConfigureAwait(false);

        await using SqliteConnection conn = await _db.AcquireConnectionAsync(ct).ConfigureAwait(false);
        await using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText =
                "INSERT INTO api_keys (id, name, access_key, iam_user_id, created_at) " +
                "VALUES (@id, @name, @access, @user, @created) " +
                "ON CONFLICT(id) DO UPDATE SET name = @name, access_key = @access, iam_user_id = @user;";
            cmd.Parameters.AddWithValue("@id", created.Id);
            cmd.Parameters.AddWithValue("@name", apiKeyName);
            cmd.Parameters.AddWithValue("@access", created.AccessKey);
            cmd.Parameters.AddWithValue("@user", userId);
            cmd.Parameters.AddWithValue("@created", DateTime.UtcNow.ToString("O"));
            await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
        }

        // Secret crosses the boundary straight into the OS-sealed store; no SQLite copy
        // (T-17-09-02). The account scope is the live session's account id.
        if (!string.IsNullOrEmpty(created.SecretKey))
        {
            _credentials.Save(_session.AccountId, $"apiKey:{created.Id}:secretKey", created.SecretKey);
        }

        return created with { IamUserId = userId };
    }

    /// <summary>Reads the non-secret local key metadata for an IAM user from SQLite.</summary>
    private async Task<IReadOnlyList<DS3ApiKey>> LoadLocalApiKeysAsync(string userId, CancellationToken ct)
    {
        var keys = new List<DS3ApiKey>();
        await using SqliteConnection conn = await _db.AcquireConnectionAsync(ct).ConfigureAwait(false);
        await using var cmd = conn.CreateCommand();
        cmd.CommandText =
            "SELECT id, name, access_key, iam_user_id FROM api_keys WHERE iam_user_id = @user;";
        cmd.Parameters.AddWithValue("@user", userId);
        await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);
        while (await reader.ReadAsync(ct).ConfigureAwait(false))
        {
            string id = reader.GetString(0);
            string name = reader.GetString(1);
            string access = reader.GetString(2);
            string user = reader.GetString(3);
            // Secret re-hydrated from Credential Manager (may be null if a manual purge
            // removed it — equality still works because the matching-pair branch compares
            // access keys, and a missing secret is recovered by RepairCredentialsAsync).
            string secret = _credentials.Load(_session.AccountId, $"apiKey:{id}:secretKey") ?? string.Empty;
            keys.Add(new DS3ApiKey(name, access, secret, user));
        }

        return keys;
    }

    /// <summary>Deletes a local key by name from SQLite + its Credential Manager secret.</summary>
    private async Task DeleteLocalApiKeyAsync(string apiKeyName, CancellationToken ct)
    {
        await using SqliteConnection conn = await _db.AcquireConnectionAsync(ct).ConfigureAwait(false);
        await using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = "DELETE FROM api_keys WHERE name = @name;";
            cmd.Parameters.AddWithValue("@name", apiKeyName);
            await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
        }

        // The coordinator keys on the name, so id == name (DS3ApiKey.Id).
        try
        {
            _credentials.Delete(_session.AccountId, $"apiKey:{apiKeyName}:secretKey");
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to delete local API key secret from Credential Manager.");
        }
    }

    /// <summary>Registers a browse operation that is about to touch a native handle on a worker
    /// thread. Throws if disposal has begun (no new work against a handle being freed) and resets
    /// the drained gate while at least one operation is in flight (WR-17.1-01).</summary>
    private void EnterBrowseOperation()
    {
        _browseLock.Wait();
        try
        {
            if (_disposed)
            {
                throw new ObjectDisposedException(nameof(DS3SdkService));
            }

            if (_inFlight++ == 0)
            {
                _drained.Reset();
            }
        }
        finally
        {
            _browseLock.Release();
        }
    }

    /// <summary>Marks a browse operation complete; signals the drained gate when the last one
    /// finishes so a disposal in progress can free the handles safely.</summary>
    private void ExitBrowseOperation()
    {
        _browseLock.Wait();
        try
        {
            if (--_inFlight == 0)
            {
                _drained.Set();
            }
        }
        finally
        {
            _browseLock.Release();
        }
    }

    /// <summary>Disposes the cached wizard-browse S3 clients (single-owner; the host-built
    /// per-drive sync clients are owned separately by <c>SyncHostedService</c>, not here).
    /// Mirrors the sync host's dispose-last discipline (WR-17.1-01): flips <c>_disposed</c> so
    /// no NEW browse operation can start, then DRAINS the in-flight ones before freeing any
    /// native handle — otherwise a worker mid-<c>ListBuckets</c>/<c>ListObjects</c> inside Rust
    /// would hit a use-after-free.</summary>
    public void Dispose()
    {
        // Phase 1: block new operations and snapshot the in-flight state under the lock.
        _browseLock.Wait();
        try
        {
            _disposed = true;
        }
        finally
        {
            _browseLock.Release();
        }

        // Phase 2: wait for outstanding worker-thread S3 calls to finish OUTSIDE the lock
        // (ExitBrowseOperation needs the lock to signal). _drained starts signaled, so this
        // returns immediately when nothing is in flight.
        _drained.Wait();

        // Phase 3: now that no worker can be inside a native call, free the handles.
        _browseLock.Wait();
        try
        {
            foreach (DS3DriveS3Client client in _browseClients.Values)
            {
                client.Dispose();
            }

            _browseClients.Clear();
            _currentBrowseClient = null;
        }
        finally
        {
            _browseLock.Release();
            _browseLock.Dispose();
            _drained.Dispose();
        }
    }
}
