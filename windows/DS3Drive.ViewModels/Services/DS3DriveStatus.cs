namespace DS3Drive.ViewModels.Services;

/// <summary>
/// Per-drive runtime sync status. Port of Apple's <c>DS3DriveStatus</c>
/// (apple/DS3Lib/Sources/DS3Lib/Models/DS3DriveStatus.swift). The cfapi sync engine
/// (Plan 10) and the tray (Plan 11) report transitions through
/// <see cref="IDriveManagementService"/>; the reducer in <see cref="AggregateStatus"/>
/// collapses the per-drive map into one tray-icon state.
/// </summary>
public enum DS3DriveStatus
{
    /// <summary>No activity; everything in sync.</summary>
    Idle = 0,

    /// <summary>Transfers in progress.</summary>
    Syncing = 1,

    /// <summary>User paused the drive.</summary>
    Paused = 2,

    /// <summary>The drive hit a sync error.</summary>
    Error = 3,
}

/// <summary>
/// Tray aggregate state computed by reducing the per-drive
/// <see cref="DS3DriveStatus"/> map. Port of Apple's <c>AggregateStatus</c>
/// (apple/DS3Lib/Sources/DS3Lib/Models/AggregateStatus.swift, reducer at
/// DS3DriveManager.swift:43-58). Precedence (UI-SPEC §"Interaction Contracts"
/// multi-state precedence): Error &gt; Syncing &gt; Paused &gt; Idle. The
/// <see cref="NoDrives"/> case is kept distinguishable from <see cref="Idle"/> so the
/// tray can show the empty-state copy rather than a misleading "all synced".
/// </summary>
public enum AggregateStatus
{
    /// <summary>No drives configured at all.</summary>
    NoDrives = 0,

    /// <summary>Every drive idle.</summary>
    Idle = 1,

    /// <summary>At least one drive is paused (and none syncing/error).</summary>
    Paused = 2,

    /// <summary>At least one drive is syncing (and none in error).</summary>
    Syncing = 3,

    /// <summary>At least one drive is in error (highest precedence).</summary>
    Error = 4,
}

/// <summary>Reducer for <see cref="AggregateStatus"/> (DS3DriveManager.swift:43-58 port).</summary>
public static class AggregateStatusReducer
{
    /// <summary>
    /// Collapses a set of per-drive statuses into the single tray state, applying the
    /// Error &gt; Syncing &gt; Paused &gt; Idle precedence (UI-SPEC multi-state precedence).
    /// An empty input maps to <see cref="AggregateStatus.NoDrives"/>.
    /// </summary>
    public static AggregateStatus From(IReadOnlyCollection<DS3DriveStatus> statuses)
    {
        if (statuses.Count == 0)
        {
            return AggregateStatus.NoDrives;
        }

        if (statuses.Any(s => s == DS3DriveStatus.Error))
        {
            return AggregateStatus.Error;
        }

        if (statuses.Any(s => s == DS3DriveStatus.Syncing))
        {
            return AggregateStatus.Syncing;
        }

        if (statuses.Any(s => s == DS3DriveStatus.Paused))
        {
            return AggregateStatus.Paused;
        }

        return AggregateStatus.Idle;
    }
}
