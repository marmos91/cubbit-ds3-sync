namespace DS3Drive.Sync.Hosting;

using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core;
using DS3Drive.Sync.CfApi;
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
    private readonly ConfigStore? _config;
    private readonly ILoggerFactory _loggerFactory;
    private readonly ILogger<SyncHostedService> _logger;

    private readonly Dictionary<Guid, ActiveDrive> _active = new();
    private readonly SemaphoreSlim _lock = new(1, 1);

    // The per-drive S3 client + the creds it was built from. The adapter (DriveS3SessionAccess)
    // routes the 6 cfapi ops through S3; Creds let a later StartDriveAsync detect a
    // credential/endpoint change and rebuild (Pitfall 5, macOS reloadDriveCredentials parity).
    private sealed record ActiveDrive(
        CfApiProvider Provider,
        SyncEngineType Engine,
        DriveStatusBroadcaster Status,
        CancellationTokenSource Cts,
        DS3DriveS3Client S3,
        DriveS3Credentials Creds);

    public SyncHostedService(
        IDriveLifecycleSource lifecycle,
        IDriveS3CredentialProvider credentials,
        PlaceholderStore store,
        ConfigStore? config = null,
        ILoggerFactory? loggerFactory = null)
    {
        _lifecycle = lifecycle ?? throw new ArgumentNullException(nameof(lifecycle));
        _credentials = credentials ?? throw new ArgumentNullException(nameof(credentials));
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _config = config;
        _loggerFactory = loggerFactory ?? NullLoggerFactory.Instance;
        _logger = _loggerFactory.CreateLogger<SyncHostedService>();
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        _lifecycle.DriveAdded += OnDriveAdded;
        _lifecycle.DriveRemoved += OnDriveRemoved;

        foreach (DS3DriveModel drive in _lifecycle.Drives)
        {
            // Isolate per-drive failures: one drive that fails to register (non-NTFS volume,
            // transient cfapi error, not-yet-authenticated session) must not abort the start
            // loop and leave the remaining drives unsynced. Mirrors OnDriveAdded's guard.
            try
            {
                await StartDriveAsync(drive, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "failed to start drive {DriveId} at host start", drive.Id);
            }
        }
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
                if (existing.Creds == creds)
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
                localRootPath: localRoot);

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

            _active[drive.Id] = new ActiveDrive(provider, engine, status, cts, s3, creds);
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
            active.Cts.Dispose();

            // Dispose the S3 client LAST (Pitfall 4 / T-17.1-11): only after the engine +
            // provider have fully stopped, so no in-flight FETCH/upload can race the free.
            // Interlocked.Exchange in the facade makes this single-shot; ordering is what
            // prevents the use-after-free.
            active.S3.Dispose();
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "error stopping active drive");
        }
    }
}
