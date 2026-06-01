namespace DS3Drive.Sync.SyncEngine;

using System;

/// <summary>
/// Per-drive runtime sync state emitted by <see cref="DriveStatusBroadcaster"/>.
/// Mirrors the ViewModels-layer <c>DS3DriveStatus</c> (kept as a separate enum so the
/// Sync project has no dependency on DS3Drive.ViewModels). Plan 11's tray subscribes to
/// <see cref="DriveStatusBroadcaster.StatusChanged"/> and maps these to the tray icon.
/// Port of Apple's <c>DS3DriveStatus</c>.
/// </summary>
public enum DriveStatus
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
/// An immutable status-change event for a single drive. Carries ONLY the drive id (GUID)
/// and the new <see cref="DriveStatus"/> — never file names or counts (STRIDE
/// InfoDisclosure mitigation T-17-10-05).
/// </summary>
public sealed record DriveStatusChange(Guid DriveId, DriveStatus Status, DateTime Timestamp);
