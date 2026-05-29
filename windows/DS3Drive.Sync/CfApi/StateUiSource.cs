using System;
using DS3Drive.Sync.SyncEngine;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace DS3Drive.Sync.CfApi;

/// <summary>
/// Surfaces per-drive sync state to the Windows shell through the cfapi state-UI contract
/// (the platform renders state icons in Explorer's status column from placeholder pin
/// states + sync-root status — NOT from a shell extension).
///
/// <para>
/// DO NOT implement <c>IShellIconOverlayIdentifier</c>. cfapi delivers state icons via
/// this contract + placeholder in-sync/pin states. Implementing an overlay handler is the
/// classic mistake documented in RESEARCH Pitfall 4 and UI-SPEC §"Explorer sync state
/// contracts" (superseded D-19): overlay handlers are global, capped at 15 per machine,
/// load-order-fragile, and fight cfapi's own badges.
/// </para>
///
/// <para>
/// Plan 11 (tray) drives the state input by subscribing to
/// <see cref="DriveStatusBroadcaster.StatusChanged"/>; this type only plumbs the
/// cfapi-side contract so the platform reflects the same state.
/// </para>
/// </summary>
public sealed class StateUiSource
{
    private readonly Guid _driveId;
    private readonly ILogger _logger;
    private DriveStatus _current = DriveStatus.Idle;

    public StateUiSource(Guid driveId, DriveStatusBroadcaster broadcaster, ILogger? logger = null)
    {
        ArgumentNullException.ThrowIfNull(broadcaster);
        _driveId = driveId;
        _logger = logger ?? NullLogger.Instance;
        broadcaster.StatusChanged += OnStatusChanged;
    }

    /// <summary>The last status pushed to the platform (Plan 11 reads this for the flyout).</summary>
    public DriveStatus Current => _current;

    private void OnStatusChanged(object? sender, DriveStatus status)
    {
        _current = status;
        // The platform reflects placeholder pin/in-sync state changes automatically once
        // CfSetInSyncState is called per file (UploadQueue / FetchDataHandler). This hook
        // exists so the tray (Plan 11) and any future StorageProviderStatusUI source share
        // a single state authority. No shell overlay handler is involved.
        _logger.LogDebug("state-ui drive={DriveId} status={Status}", _driveId, status);
    }
}
