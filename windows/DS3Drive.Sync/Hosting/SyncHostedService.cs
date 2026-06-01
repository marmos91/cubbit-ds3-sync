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
    private readonly IDS3SessionAccess _session;
    private readonly PlaceholderStore _store;
    private readonly ConfigStore? _config;
    private readonly ILoggerFactory _loggerFactory;
    private readonly ILogger<SyncHostedService> _logger;

    private readonly Dictionary<Guid, ActiveDrive> _active = new();
    private readonly SemaphoreSlim _lock = new(1, 1);

    private sealed record ActiveDrive(CfApiProvider Provider, SyncEngineType Engine, DriveStatusBroadcaster Status, CancellationTokenSource Cts);

    public SyncHostedService(
        IDriveLifecycleSource lifecycle,
        IDS3SessionAccess session,
        PlaceholderStore store,
        ConfigStore? config = null,
        ILoggerFactory? loggerFactory = null)
    {
        _lifecycle = lifecycle ?? throw new ArgumentNullException(nameof(lifecycle));
        _session = session ?? throw new ArgumentNullException(nameof(session));
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
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (_active.ContainsKey(drive.Id))
            {
                return;
            }

            string localRoot = _lifecycle.GetLocalRootPath(drive);
            var debounce = TimeSpan.FromMilliseconds(400);
            var status = new DriveStatusBroadcaster(drive.Id, debounce, _loggerFactory.CreateLogger<DriveStatusBroadcaster>());
            var uploads = new UploadQueue(_session, _store, status, _loggerFactory.CreateLogger<UploadQueue>());
            var provider = new CfApiProvider(
                drive, localRoot, AppContext.BaseDirectory, _session, _store, uploads, status,
                _loggerFactory.CreateLogger<CfApiProvider>());
            var engine = new SyncEngineType(
                drive, _session, _store, uploads, status, _config,
                isPaused: () => _lifecycle.IsPaused(drive.Id),
                logger: _loggerFactory.CreateLogger<SyncEngineType>(),
                localRootPath: localRoot);

            var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            await provider.RegisterAsync(cts.Token).ConfigureAwait(false);
            await engine.StartAsync(cts.Token).ConfigureAwait(false);

            _active[drive.Id] = new ActiveDrive(provider, engine, status, cts);
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
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "error stopping active drive");
        }
    }
}
