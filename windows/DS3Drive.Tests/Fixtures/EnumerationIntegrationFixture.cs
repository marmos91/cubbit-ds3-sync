namespace DS3Drive.Tests.Fixtures;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core;
using DS3Drive.Sync;
using Xunit;

/// <summary>
/// Shared fixture for <c>EnumerationIntegrationTests</c> (D-07). When Cubbit credentials are
/// present it authenticates, reconciles a throwaway API key, mints a <see cref="DS3DriveS3Client"/>,
/// picks the first reachable bucket, and seeds a unique prefix with &gt;2000 tiny objects so the
/// pagination + idempotency tests run against a genuinely multi-page listing. When credentials are
/// absent it is a no-op (<see cref="Available"/> == false) and every test self-skips via
/// <see cref="RequiresCredentialsAttribute"/>, so the default PR build never touches S3.
///
/// <para>
/// Seeded objects live under <c>ds3drive-enum-itest/&lt;guid&gt;/bulk/</c>; the remote-mutating
/// tests carve their own sibling sub-prefixes off <see cref="BasePrefix"/> so they never disturb
/// the shared read-only set. Everything created here is removed in <see cref="DisposeAsync"/>
/// (objects + the throwaway API key), so a run leaves no residue in the bucket.
/// </para>
/// </summary>
public sealed class EnumerationIntegrationFixture : IAsyncLifetime
{
    // The pagination regression needs >2000 keys to cross the 2000-key LIST_BATCH_SIZE page
    // boundary. Overridable so a developer can trade coverage for speed locally; CI uses the default.
    private static int SeedCountFromEnv()
    {
        string? raw = Environment.GetEnvironmentVariable("CUBBIT_TEST_ENUM_COUNT");
        return int.TryParse(raw, out int n) && n > 0 ? n : 2050;
    }

    private const int UploadConcurrency = 16;

    private DS3Session? _session;
    private string? _accountId;
    private string? _iamToken;
    private string? _apiKeyId;
    private readonly List<string> _bulkKeys = new();

    /// <summary>True when credentials were present and the bucket was seeded.</summary>
    public bool Available { get; private set; }

    public DS3DriveS3Client? S3 { get; private set; }
    public IDS3SessionAccess? Access { get; private set; }
    public string Bucket { get; private set; } = string.Empty;

    /// <summary>The unique root prefix for this run (ends in '/'); the mutating tests hang their
    /// isolated sibling sub-prefixes off it.</summary>
    public string BasePrefix { get; private set; } = string.Empty;

    /// <summary>The read-only, &gt;2000-object bulk prefix the pagination/idempotency tests list.</summary>
    public string Prefix => BasePrefix + "bulk/";

    /// <summary>Number of objects seeded under <see cref="Prefix"/>.</summary>
    public int SeededCount { get; private set; }

    public async Task InitializeAsync()
    {
        CubbitCredentials creds = CubbitCredentials.FromEnvironment();
        if (!creds.IsAvailable)
        {
            return; // no-op; tests self-skip via [RequiresCredentials]
        }

        _session = DS3Session.Authenticate(creds.Email, creds.Password, creds.Tenant, creds.CoordinatorUrl);
        var account = _session.AccountInfo();
        _accountId = account.AccountId;

        // Reconcile a throwaway API key exactly like the wizard/host do, then mint the S3 client
        // from (endpoint_gateway, accessKey, secretKey) — never the session token.
        _iamToken = _session.ForgeIamToken(account.AccountId);
        var apiKey = _session.CreateApiKey(account.AccountId, _iamToken, $"ds3drive-enum-itest-{Guid.NewGuid():N}");
        _apiKeyId = apiKey.Id;

        S3 = DS3DriveS3Client.Create(account.EndpointGateway, apiKey.AccessKey, apiKey.SecretKey);
        Access = new DriveS3SessionAccess(S3, account.AccountId);

        var buckets = S3.ListBuckets();
        Assert.NotEmpty(buckets);
        Bucket = buckets[0].Name;

        BasePrefix = $"ds3drive-enum-itest/{Guid.NewGuid():N}/";
        SeededCount = SeedCountFromEnv();

        var keys = new List<string>(SeededCount);
        for (int i = 0; i < SeededCount; i++)
        {
            keys.Add(Prefix + $"file{i:D5}.txt");
        }

        await SeedObjectsAsync(keys);
        _bulkKeys.AddRange(keys);
        Available = true;
    }

    /// <summary>Uploads a 1-byte object for each key with bounded concurrency (the aws-sdk client is
    /// Send+Sync, so parallel PUTs are safe — 17.1 concurrency note).</summary>
    public async Task SeedObjectsAsync(IReadOnlyList<string> keys)
    {
        if (S3 is null)
        {
            return;
        }

        string tempFile = Path.Combine(Path.GetTempPath(), $"ds3drive-seed-{Guid.NewGuid():N}.txt");
        await File.WriteAllTextAsync(tempFile, "x");
        try
        {
            using var gate = new SemaphoreSlim(UploadConcurrency, UploadConcurrency);
            IEnumerable<Task> uploads = keys.Select(async key =>
            {
                await gate.WaitAsync().ConfigureAwait(false);
                try
                {
                    await Task.Run(() => S3!.UploadObject(Bucket, key, tempFile, progress: null, cancel: null))
                        .ConfigureAwait(false);
                }
                finally
                {
                    gate.Release();
                }
            });

            await Task.WhenAll(uploads).ConfigureAwait(false);
        }
        finally
        {
            try
            {
                File.Delete(tempFile);
            }
            catch
            {
                // best effort
            }
        }
    }

    /// <summary>Best-effort delete of each key (already-absent keys are ignored).</summary>
    public async Task DeleteObjectsAsync(IReadOnlyList<string> keys)
    {
        if (S3 is null)
        {
            return;
        }

        using var gate = new SemaphoreSlim(UploadConcurrency, UploadConcurrency);
        IEnumerable<Task> deletes = keys.Select(async key =>
        {
            await gate.WaitAsync().ConfigureAwait(false);
            try
            {
                await Task.Run(() =>
                {
                    try
                    {
                        S3!.DeleteObject(Bucket, key);
                    }
                    catch
                    {
                        // already gone / never created — fine
                    }
                }).ConfigureAwait(false);
            }
            finally
            {
                gate.Release();
            }
        });

        await Task.WhenAll(deletes).ConfigureAwait(false);
    }

    public async Task DisposeAsync()
    {
        if (!Available && S3 is null)
        {
            _session?.Dispose();
            return;
        }

        try
        {
            if (_bulkKeys.Count > 0)
            {
                await DeleteObjectsAsync(_bulkKeys).ConfigureAwait(false);
            }
        }
        catch
        {
            // best effort — leave nothing, but never fail teardown
        }

        try
        {
            if (_session is not null && _accountId is not null && _apiKeyId is not null && _iamToken is not null)
            {
                _session.DeleteApiKey(_accountId, _apiKeyId, _iamToken);
            }
        }
        catch
        {
            // best effort
        }

        S3?.Dispose();
        _session?.Dispose();
    }
}
