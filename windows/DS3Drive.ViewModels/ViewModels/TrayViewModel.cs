namespace DS3Drive.ViewModels.ViewModels;

using System;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using DS3Drive.Core.Records;
using DS3Drive.ViewModels.Navigation;
using DS3Drive.ViewModels.Services;
using Microsoft.Extensions.Logging;

/// <summary>
/// Aggregate tray state — port of <c>DS3DriveViewModel.swift</c> + the aggregate reducer in
/// <c>DS3DriveManager.swift:43-58</c> (PATTERNS §2.7 / §2.14). Lives in the WinUI-free
/// DS3Drive.ViewModels assembly so the precedence + tooltip logic is unit-testable (the
/// TrayViewModelTests run in the headless xUnit host). The App's TrayService binds the tray
/// icon + flyout to this view-model and forwards <c>DriveStatusBroadcaster.StatusChanged</c>
/// into <see cref="IDriveManagementService.ReportStatus"/>, which raises
/// <see cref="IDriveManagementService.Changed"/> and re-drives this view-model.
///
/// <para>
/// Multi-state precedence (UI-SPEC §"Interaction Contracts"): Error &gt; Syncing &gt; Paused
/// &gt; Idle. The reduction itself is owned by <see cref="AggregateStatusReducer"/> (via
/// <see cref="IDriveManagementService.AggregateStatus"/>); this view-model maps that to the
/// tooltip variants and the per-drive row collection.
/// </para>
/// </summary>
public partial class TrayViewModel : ObservableObject, IDisposable
{
    private readonly IDriveManagementService _driveManager;
    private readonly IRecentFilesService _recentFiles;
    private readonly INavigator _navigation;
    private readonly ILogger<TrayViewModel> _logger;
    private readonly Func<DS3Drive, TrayDriveRowViewModel> _rowFactory;
    private readonly Action? _showMainWindow;
    private bool _disposed;

    [ObservableProperty]
    private AggregateStatus aggregateStatus = AggregateStatus.NoDrives;

    [ObservableProperty]
    private string tooltipText = "DS3 Drive — Idle";

    [ObservableProperty]
    private ObservableCollection<TrayDriveRowViewModel> driveRows = new();

    [ObservableProperty]
    private bool canAddDrive = true;

    [ObservableProperty]
    private ObservableCollection<RecentFileEntry> recentFiles = new();

    public TrayViewModel(
        IDriveManagementService driveManager,
        IRecentFilesService recentFiles,
        INavigator navigation,
        ILogger<TrayViewModel> logger,
        Func<DS3Drive, TrayDriveRowViewModel> rowFactory,
        Action? showMainWindow = null)
    {
        _driveManager = driveManager;
        _recentFiles = recentFiles;
        _navigation = navigation;
        _logger = logger;
        _rowFactory = rowFactory;
        _showMainWindow = showMainWindow;

        _driveManager.Changed += OnDriveManagerChanged;
        _recentFiles.RecentChanged += OnRecentChanged;

        SyncRows();
        Recompute();
    }

    /// <summary>True when there are no drives (flyout shows the empty-state copy).</summary>
    public bool IsEmpty => DriveRows.Count == 0;

    /// <summary>Opens the tray flyout (the App wires the actual window show).</summary>
    [RelayCommand]
    private void ShowFlyout() => ShowFlyoutRequested?.Invoke(this, EventArgs.Empty);

    /// <summary>Brings the main window forward (double-click / "Open Cubbit").</summary>
    [RelayCommand]
    private void ShowMainWindow() => _showMainWindow?.Invoke();

    /// <summary>Pauses every drive (right-click "Pause all").</summary>
    [RelayCommand]
    private void PauseAll()
    {
        foreach (var d in _driveManager.Drives.ToArray())
        {
            _driveManager.SetPaused(d.Id, true);
        }

        _logger.LogInformation("Paused all drives from tray");
    }

    /// <summary>Resumes every drive (right-click "Resume all").</summary>
    [RelayCommand]
    private void ResumeAll()
    {
        foreach (var d in _driveManager.Drives.ToArray())
        {
            _driveManager.SetPaused(d.Id, false);
        }

        _logger.LogInformation("Resumed all drives from tray");
    }

    /// <summary>Opens the drive-setup wizard from the flyout's "Add drive" button.</summary>
    [RelayCommand]
    private void AddDrive()
    {
        if (!_driveManager.CanAddDrive)
        {
            return;
        }

        // Surface the main window first: the close button hides it to the tray, so navigating the
        // frame alone would update an invisible window.
        _showMainWindow?.Invoke();
        _navigation.Navigate(PageKey.DriveSetupWizard);
    }

    /// <summary>Navigates to Settings (flyout footer + right-click "Settings").</summary>
    [RelayCommand]
    private void OpenSettings()
    {
        _showMainWindow?.Invoke();
        _navigation.Navigate(PageKey.Settings);
    }

    /// <summary>Quits the app (right-click "Quit" / flyout footer — non-destructive, no confirm).</summary>
    [RelayCommand]
    private void Quit() => QuitRequested?.Invoke(this, EventArgs.Empty);

    /// <summary>Raised when the flyout should be shown (the App owns the window).</summary>
    public event EventHandler? ShowFlyoutRequested;

    /// <summary>Raised when the app should exit (the App calls Application.Exit/process shutdown).</summary>
    public event EventHandler? QuitRequested;

    private void OnDriveManagerChanged(object? sender, EventArgs e)
    {
        SyncRows();
        Recompute();
    }

    private void OnRecentChanged(object? sender, EventArgs e)
    {
        var snapshot = _recentFiles.GetRecentGlobal(5);
        RecentFiles = new ObservableCollection<RecentFileEntry>(snapshot);
    }

    /// <summary>Reconciles the row collection 1:1 with the drive manager's drive list.</summary>
    private void SyncRows()
    {
        // Drop rows whose drive is gone.
        for (int i = DriveRows.Count - 1; i >= 0; i--)
        {
            if (!_driveManager.Drives.Any(d => d.Id == DriveRows[i].Drive.Id))
            {
                DriveRows[i].Dispose();
                DriveRows.RemoveAt(i);
            }
        }

        // Add rows for new drives.
        foreach (var drive in _driveManager.Drives)
        {
            if (DriveRows.All(r => r.Drive.Id != drive.Id))
            {
                DriveRows.Add(_rowFactory(drive));
            }
        }

        OnPropertyChanged(nameof(IsEmpty));
    }

    private void Recompute()
    {
        AggregateStatus = _driveManager.AggregateStatus;
        CanAddDrive = _driveManager.CanAddDrive;
        TooltipText = BuildTooltip();
    }

    /// <summary>
    /// Tooltip variants per UI-SPEC §"Interaction Contracts":
    ///   Idle    → "DS3 Drive — Idle"
    ///   Syncing → "DS3 Drive — Syncing N files (M.M MB/s)" (file count + speed unknown at this
    ///             layer → "DS3 Drive — Syncing")
    ///   Paused  → "DS3 Drive — N drives paused"
    ///   Error   → "DS3 Drive — N drives need attention"
    /// </summary>
    private string BuildTooltip()
    {
        int errorCount = CountStatus(DS3DriveStatus.Error);
        int pausedCount = CountStatus(DS3DriveStatus.Paused);

        return AggregateStatus switch
        {
            AggregateStatus.Error => $"DS3 Drive — {errorCount} drive{Plural(errorCount)} need attention",
            AggregateStatus.Syncing => "DS3 Drive — Syncing",
            AggregateStatus.Paused => $"DS3 Drive — {pausedCount} drive{Plural(pausedCount)} paused",
            _ => "DS3 Drive — Idle",
        };
    }

    private int CountStatus(DS3DriveStatus status) =>
        _driveManager.Drives.Count(d => _driveManager.GetStatus(d.Id) == status);

    private static string Plural(int n) => n == 1 ? string.Empty : "s";

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _driveManager.Changed -= OnDriveManagerChanged;
        _recentFiles.RecentChanged -= OnRecentChanged;
        foreach (var row in DriveRows)
        {
            row.Dispose();
        }
    }
}
