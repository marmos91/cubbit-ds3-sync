namespace DS3Drive.App.Services;

using System;
using System.Collections.Generic;
using System.IO;
using DS3Drive.Sync.Hosting;
using DS3Drive.ViewModels.Services;
using DS3DriveModel = DS3Drive.Core.Records.DS3Drive;

/// <summary>
/// Adapts the ViewModels-layer <see cref="IDriveManagementService"/> onto the Sync layer's
/// <see cref="IDriveLifecycleSource"/> so <see cref="DS3Drive.Sync.Hosting.SyncHostedService"/>
/// can drive the per-drive cfapi lifecycle without the Sync project taking a reverse reference
/// on ViewModels (Plan 17 wiring; the seam was designed for this in
/// <see cref="DS3Drive.Sync.Hosting.IDriveLifecycleSource"/>).
///
/// <para>Drive list, add/remove events, and pause state forward 1:1 to the drive manager. The
/// local sync-root path uses the same <c>%USERPROFILE%\Cubbit\&lt;name&gt;</c> convention that
/// <c>DrivesRepository</c> persists as the <c>@root</c> column, so the registered sync root and
/// the tray's "Open in Explorer" target (<c>App.OpenDriveInExplorer</c>) resolve to one folder.</para>
/// </summary>
public sealed class DriveLifecycleSource : IDriveLifecycleSource
{
    private readonly IDriveManagementService _drives;

    public DriveLifecycleSource(IDriveManagementService drives) =>
        _drives = drives ?? throw new ArgumentNullException(nameof(drives));

    /// <inheritdoc />
    public IReadOnlyList<DS3DriveModel> Drives => _drives.Drives;

    /// <inheritdoc />
    public event EventHandler<DS3DriveModel>? DriveAdded
    {
        add => _drives.DriveAdded += value;
        remove => _drives.DriveAdded -= value;
    }

    /// <inheritdoc />
    public event EventHandler<Guid>? DriveRemoved
    {
        add => _drives.DriveRemoved += value;
        remove => _drives.DriveRemoved -= value;
    }

    /// <inheritdoc />
    public bool IsPaused(Guid driveId) => _drives.IsPaused(driveId);

    /// <inheritdoc />
    public string GetLocalRootPath(DS3DriveModel drive) =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Cubbit", drive.Name);
}
