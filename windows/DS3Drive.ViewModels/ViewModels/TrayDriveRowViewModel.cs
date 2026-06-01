namespace DS3Drive.ViewModels.ViewModels;

using System;
using System.Threading;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using DS3Drive.Core.Records;
using DS3Drive.ViewModels.Navigation;
using DS3Drive.ViewModels.Services;
using Microsoft.Extensions.Logging;

/// <summary>
/// Per-drive tray row view-model — port of <c>TrayDriveRowView.swift</c> + its
/// <c>DS3DriveViewModel</c> (PATTERNS §2.14). Lives in the WinUI-free DS3Drive.ViewModels
/// assembly so it is unit-testable; the App's <c>TrayDriveRow</c> UserControl binds to it.
///
/// <para>
/// Status flows through <see cref="IDriveManagementService"/>: the row subscribes to its
/// <see cref="IDriveManagementService.Changed"/> event (which fires after every
/// <c>ReportStatus</c> / <c>SetPaused</c>) and re-reads <see cref="IDriveManagementService.GetStatus"/>.
/// This keeps the row decoupled from the Sync-layer <c>DriveStatusBroadcaster</c> (whose
/// instances live in the App's tray service, which forwards each StatusChanged into
/// ReportStatus). Transfer-speed updates arrive via <see cref="UpdateSpeed"/> from the same
/// forwarder.
/// </para>
/// </summary>
public partial class TrayDriveRowViewModel : ObservableObject, IDisposable
{
    private readonly IDriveManagementService _driveManager;
    private readonly INavigator _navigation;
    private readonly Action<string>? _openInExplorer;
    private readonly ILogger _logger;
    private bool _disposed;

    [ObservableProperty]
    private DS3Drive drive;

    [ObservableProperty]
    private DS3DriveStatus status = DS3DriveStatus.Idle;

    [ObservableProperty]
    private double uploadBytesPerSec;

    [ObservableProperty]
    private double downloadBytesPerSec;

    [ObservableProperty]
    private bool isPaused;

    [ObservableProperty]
    private DateTime? lastUpdated;

    /// <summary>
    /// Constructs a row. <paramref name="openInExplorer"/> is the platform hook the App
    /// injects (<c>Process.Start("explorer.exe", path)</c>) — kept as a delegate so the VM
    /// stays free of <c>System.Diagnostics.Process</c> shell coupling in tests.
    /// </summary>
    public TrayDriveRowViewModel(
        DS3Drive drive,
        IDriveManagementService driveManager,
        INavigator navigation,
        ILogger logger,
        Action<string>? openInExplorer = null)
    {
        this.drive = drive;
        _driveManager = driveManager;
        _navigation = navigation;
        _logger = logger;
        _openInExplorer = openInExplorer;

        _driveManager.Changed += OnManagerChanged;
        RefreshFromManager();
    }

    /// <summary>The "bucket / prefix" subtitle line (TrayDriveRowView.syncAnchorString()).</summary>
    public string SyncAnchorString
    {
        get
        {
            DS3SyncAnchor anchor = Drive.SyncAnchor;
            return string.IsNullOrEmpty(anchor.Prefix)
                ? anchor.Bucket
                : $"{anchor.Bucket}/{anchor.Prefix}";
        }
    }

    /// <summary>Updates the live transfer speeds (forwarded from the broadcaster/transfer events).</summary>
    public void UpdateSpeed(double uploadBytesPerSec, double downloadBytesPerSec)
    {
        UploadBytesPerSec = uploadBytesPerSec;
        DownloadBytesPerSec = downloadBytesPerSec;
        LastUpdated = DateTime.UtcNow;
    }

    /// <summary>Toggles the drive's pause flag through the manager (polling timer respects it).</summary>
    [RelayCommand]
    private Task PauseResumeAsync()
    {
        bool next = !_driveManager.IsPaused(Drive.Id);
        _driveManager.SetPaused(Drive.Id, next);
        _logger.LogInformation("Drive {Drive} {State} from tray row", Drive.Id, next ? "paused" : "resumed");
        return Task.CompletedTask;
    }

    /// <summary>Opens the drive's local sync folder in Explorer (delegate injected by the App).</summary>
    [RelayCommand]
    private void OpenInExplorer()
    {
        _openInExplorer?.Invoke(Drive.Name);
    }

    /// <summary>
    /// Removes the drive. The App passes a confirm callback via <see cref="ConfirmRemoveAsync"/>;
    /// this command path is invoked once confirmation succeeded (the UserControl wires the
    /// ContentDialog). When no confirm hook is set (tests) it removes directly.
    /// </summary>
    [RelayCommand]
    private async Task RemoveDriveAsync()
    {
        if (ConfirmRemoveAsync is not null)
        {
            bool confirmed = await ConfirmRemoveAsync().ConfigureAwait(true);
            if (!confirmed)
            {
                return;
            }
        }

        await _driveManager.RemoveAsync(Drive.Id, CancellationToken.None).ConfigureAwait(true);
    }

    /// <summary>
    /// Confirm hook the App sets to show the UI-SPEC §Destructive "Remove this drive?"
    /// ContentDialog. Returns true on confirm. Null in tests (direct removal).
    /// </summary>
    public Func<Task<bool>>? ConfirmRemoveAsync { get; set; }

    private void OnManagerChanged(object? sender, EventArgs e) => RefreshFromManager();

    private void RefreshFromManager()
    {
        Status = _driveManager.GetStatus(Drive.Id);
        IsPaused = _driveManager.IsPaused(Drive.Id);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _driveManager.Changed -= OnManagerChanged;
    }
}
