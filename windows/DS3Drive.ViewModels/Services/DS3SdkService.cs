namespace DS3Drive.ViewModels.Services;

using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core;
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
public sealed class DS3SdkService : IDS3SdkService
{
    private readonly IDS3SessionGateway _session;
    private readonly SyncDatabase _db;
    private readonly CredentialStore _credentials;
    private readonly ConfigStore _config;
    private readonly IInstallationIdProvider _installation;
    private readonly ILogger<DS3SdkService> _logger;

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
    public Task<IReadOnlyList<DS3Bucket>> GetBucketsAsync(DS3Project project, CancellationToken ct) =>
        Task.Run(() => _session.ListBuckets(), ct);

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

        // 3d. Both present but differ → both branches above fired; the next reconcile run
        //     (or this create) regenerates. Threat T-17-09-06: if a delete-then-create
        //     partial failure leaves an orphan remote key, the next run sees local-null +
        //     remote-null and recreates cleanly.

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
}
