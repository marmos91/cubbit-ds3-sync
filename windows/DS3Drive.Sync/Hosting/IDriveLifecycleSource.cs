namespace DS3Drive.Sync.Hosting;
using System;
using System.Collections.Generic;
using DS3DriveModel = DS3Drive.Core.Records.DS3Drive;

/// <summary>
/// Lifecycle seam the <see cref="SyncHostedService"/> subscribes to. The App layer adapts
/// its <c>IDriveManagementService</c> (DS3Drive.ViewModels) onto this interface so the
/// Sync project does not take a reverse project reference on ViewModels (which already
/// references Sync). Mirrors the <c>DriveAdded</c> / <c>DriveRemoved</c> events that drive
/// the per-drive cfapi + sync-engine lifecycle.
/// </summary>
public interface IDriveLifecycleSource
{
    /// <summary>The drives configured at startup (each gets a CfApiProvider + SyncEngine).</summary>
    IReadOnlyList<DS3DriveModel> Drives { get; }

    /// <summary>Raised after a drive is added + persisted (register the sync root).</summary>
    event EventHandler<DS3DriveModel>? DriveAdded;

    /// <summary>Raised before a drive is removed (unregister the sync root).</summary>
    event EventHandler<Guid>? DriveRemoved;

    /// <summary>True while the given drive is paused (the polling timer skips ticks).</summary>
    bool IsPaused(Guid driveId);

    /// <summary>The local root path for a drive (where the sync root folder lives).</summary>
    string GetLocalRootPath(DS3DriveModel drive);
}
