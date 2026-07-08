namespace DS3Drive.Sync.Hosting;

using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core;
using DS3Drive.Sync.CfApi;
using DS3Drive.Sync.Storage;
using DS3Drive.Sync.SyncEngine;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using DS3DriveModel = DS3Drive.Core.Records.DS3Drive;
using SyncEngineType = DS3Drive.Sync.SyncEngine.SyncEngine;

/// <summary>
/// Glue between <see cref="IDriveLifecycleSource"/> (adapted from the App's
/// <c>IDriveManagementService</c>, Plan 09) and the per-drive cfapi + sync-engine
/// lifecycle. On start it registers + spins up every existing drive; on
/// <c>DriveAdded</c> it creates a <see cref="CfApiProvider"/> + <see cref="SyncEngine"/>;
/// on <c>DriveRemoved</c> it tears them down; on stop it gracefully stops all drives.
/// </summary>
public sealed class SyncHostedService : IHostedService
{
    private readonly IDriveLifecycleSource _lifecycle;
    private readonly IDriveS3CredentialProvider _credentials;
    private readonly PlaceholderStore _store;
    private readonly PrefixAnchorStore _anchors;
    private readonly ConfigStore? _config;
    private readonly ILoggerFactory _loggerFactory;
    private readonly ILogger<SyncHostedService> _logger;

    private readonly Dictionary<Guid, ActiveDrive> _active = new();
    private readonly SemaphoreSlim _lock = new(1, 1);

    // The per-drive S3 client + a NON-REVERSIBLE fingerprint of the creds it was built from.
    // The adapter (DriveS3SessionAccess) routes the 6 cfapi ops through S3; the fingerprint lets
    // a later StartDriveAsync detect a credential/endpoint change and rebuild (Pitfall 5, macOS
    // reloadDriveCredentials parity) WITHOUT retaining the plaintext SecretKey for the drive's
    // lifetime (CR-17.1-01 / T-17.1-09: the secret crosses the FFI in DS3DriveS3Client.Create and
    // is not held in a long-lived, GC-movable, dumpable managed object afterwards).
    private sealed record ActiveDrive(
        CfApiProvider Provider,
        SyncEngineType Engine,
        DriveStatusBroadcaster Status,
        CancellationTokenSource Cts,
        DS3DriveS3Client S3,
        string CredsFingerprint);

    private static readonly byte[] FingerprintSeparator = { (byte)'\n' };

    // SHA-256 over endpoint|access|secret: collision-resistant change-detection that never
    // stores the secret in plaintext. Re-computed from transiently-resolved creds on each
    // StartDriveAsync and compared against the active drive's stored fingerprint. Fed
    // incrementally so the secret is never copied into a combined interpolated string.
    private static string CredsFingerprintOf(DriveS3Credentials c)
    {
        using IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hash.AppendData(Encoding.UTF8.GetBytes(c.Endpoint));
        hash.AppendData(FingerprintSeparator);
        hash.AppendData(Encoding.UTF8.GetBytes(c.AccessKey));
        hash.AppendData(FingerprintSeparator);
        hash.AppendData(Encoding.UTF8.GetBytes(c.SecretKey));
        return Convert.ToHexString(hash.GetHashAndReset());
    }

    public SyncHostedService(
        IDriveLifecycleSource lifecycle,
        IDriveS3CredentialProvider credentials,
        PlaceholderStore store,
        PrefixAnchorStore anchors,
        ConfigStore? config = null,
        ILoggerFactory? loggerFactory = null)
    {
        _lifecycle = lifecycle ?? throw new ArgumentNullException(nameof(lifecycle));
        _credentials = credentials ?? throw new ArgumentNullException(nameof(credentials));
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _anchors = anchors ?? throw new ArgumentNullException(nameof(anchors));
        _config = config;
        _loggerFactory = loggerFactory ?? NullLoggerFactory.Instance;
        _logger = _loggerFactory.CreateLogger<SyncHostedService>();
    }

    public Task StartAsync(CancellationToken cancellationToken)
    {
        _lifecycle.DriveAdded += OnDriveAdded;
        _lifecycle.DriveRemoved += OnDriveRemoved;

        // Deliberately NOT starting the existing drives here. Each per-drive start does an S3
        // credential reconcile (forge IAM token + load/create API key) that needs a LIVE session,
        // and at host start the user has not signed in yet (there is no session-restore-on-launch
        // path). Starting here would throw 1005 for every drive. Instead the App (re)starts drives
        // via DriveAdded once a session exists — on login, and after session restore is added.
        return Task.CompletedTask;
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        _lifecycle.DriveAdded -= OnDriveAdded;
        _lifecycle.DriveRemoved -= OnDriveRemoved;

        await _lock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            foreach (ActiveDrive active in _active.Values)
            {
                await StopActiveAsync(active).ConfigureAwait(false);
            }

            _active.Clear();
        }
        finally
        {
            _lock.Release();
        }
    }

    private async void OnDriveAdded(object? sender, DS3DriveModel drive)
    {
        try
        {
            await StartDriveAsync(drive, CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "failed to start drive {DriveId} on DriveAdded", drive.Id);
        }
    }

    private async void OnDriveRemoved(object? sender, Guid driveId)
    {
        try
        {
            await _lock.WaitAsync().ConfigureAwait(false);
            try
            {
                if (_active.Remove(driveId, out ActiveDrive? active))
                {
                    await StopActiveAsync(active).ConfigureAwait(false);
                }
            }
            finally
            {
                _lock.Release();
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "failed to stop drive {DriveId} on DriveRemoved", driveId);
        }
    }

    private async Task StartDriveAsync(DS3DriveModel drive, CancellationToken ct)
    {
        // Resolve the per-drive S3 credentials OUTSIDE the lock (the reconcile does network
        // I/O — forge IAM token + load/create API key — and the lock must not be held across
        // an await of unbounded duration). Mirrors macOS s3Client(forProject:iamUser:), which
        // does the API-key fetch outside its NSLock.
        DriveS3Credentials creds = await _credentials.GetCredentialsAsync(drive, ct).ConfigureAwait(false);

        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            // Rebuild-on-change (Pitfall 5 / macOS reloadDriveCredentials): if the drive is
            // already active but the persisted endpoint/key differs from the live client's,
            // tear the old one down and rebuild from the fresh creds. Unchanged creds => no-op.
            if (_active.TryGetValue(drive.Id, out ActiveDrive? existing))
            {
                if (existing.CredsFingerprint == CredsFingerprintOf(creds))
                {
                    return;
                }

                _logger.LogInformation("credentials changed for drive {DriveId}; rebuilding S3 client", drive.Id);
                _active.Remove(drive.Id);
                await StopActiveAsync(existing).ConfigureAwait(false);
            }

            string localRoot = _lifecycle.GetLocalRootPath(drive);

            // Build the per-drive S3 client from the reconciled creds (NOT the session token).
            // Region null => Rust defaults to us-east-1 (macOS parity). The host owns this
            // handle and disposes it LAST in StopActiveAsync (Pitfall 4).
            var s3 = DS3DriveS3Client.Create(creds.Endpoint, creds.AccessKey, creds.SecretKey);

            // Capture the change-detection fingerprint NOW (the only point we hold the live
            // secret), then never retain `creds` itself. DS3DriveS3Client.Create is the sole
            // consumer of the plaintext SecretKey (CR-17.1-01 / T-17.1-09).
            string credsFingerprint = CredsFingerprintOf(creds);
            var access = new DriveS3SessionAccess(s3, drive.SyncAnchor.IamUserId);

            var debounce = TimeSpan.FromMilliseconds(400);
            var status = new DriveStatusBroadcaster(drive.Id, debounce, _loggerFactory.CreateLogger<DriveStatusBroadcaster>());
            var uploads = new UploadQueue(access, _store, status, _loggerFactory.CreateLogger<UploadQueue>());
            var provider = new CfApiProvider(
                drive, localRoot, AppContext.BaseDirectory, access, _store, uploads, status,
                _loggerFactory.CreateLogger<CfApiProvider>());
            var engine = new SyncEngineType(
                drive, access, _store, uploads, status, _config,
                isPaused: () => _lifecycle.IsPaused(drive.Id),
                logger: _loggerFactory.CreateLogger<SyncEngineType>(),
                localRootPath: localRoot,
                anchorStore: _anchors);

            var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            try
            {
                await provider.RegisterAsync(cts.Token).ConfigureAwait(false);
                await engine.StartAsync(cts.Token).ConfigureAwait(false);
            }
            catch
            {
                // Startup failed after the handle was minted: dispose it so a failed drive
                // does not leak the native S3 client. The cts/engine/provider are torn down
                // by the caller's per-drive guard re-raising; only the S3 handle is ours here.
                s3.Dispose();
                cts.Dispose();
                throw;
            }

            _active[drive.Id] = new ActiveDrive(provider, engine, status, cts, s3, credsFingerprint);
            _logger.LogInformation("sync started for drive {DriveId}", drive.Id);
        }
        finally
        {
            _lock.Release();
        }
    }

    private async Task StopActiveAsync(ActiveDrive active)
    {
        try
        {
            active.Cts.Cancel();
            await active.Engine.StopAsync(CancellationToken.None).ConfigureAwait(false);
            await active.Provider.DisconnectAsync(CancellationToken.None).ConfigureAwait(false);
            await active.Engine.DisposeAsync().ConfigureAwait(false);
            await active.Status.ShutdownAsync().ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "error stopping active drive");
        }
        finally
        {
            // Dispose unconditionally (WR-17.1-02): if any await above threw, the native
            // DS3S3Client handle (and the CTS) would otherwise leak for the life of the
            // process on every failed teardown during drive churn. Dispose the S3 client
            // LAST (Pitfall 4 / T-17.1-11) — only after the engine + provider stop attempts
            // complete, so no in-flight FETCH/upload can race the free. Interlocked.Exchange
            // in the facade makes the free single-shot; ordering prevents the use-after-free.
            active.Cts.Dispose();
            active.S3.Dispose();
        }
    }
}
