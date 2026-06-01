namespace DS3Drive.ViewModels.ViewModels;

using System.Threading;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using DS3Drive.Core.Records;
using DS3Drive.ViewModels.Navigation;
using DS3Drive.ViewModels.Services;
using Microsoft.Extensions.Logging;

/// <summary>
/// Post-tutorial landing page view-model — the drives list. Port of the iOS
/// <c>DriveListView</c> model (apple/DS3DriveApp/Views/Dashboard/DriveListView.swift,
/// PATTERNS §1.3 row). Surfaces the configured drives, the empty-state copy (UI-SPEC
/// §"Empty states"), and the "Add drive" CTA whose label + visibility follow the
/// 3-drive cap (CONTEXT D-23).
/// </summary>
public partial class DrivesListViewModel : ObservableObject
{
    /// <summary>Empty-state heading (UI-SPEC §"Empty states" — Drives list).</summary>
    public const string EmptyHeading = "No drives yet";

    /// <summary>Empty-state body (UI-SPEC §"Empty states" — Drives list).</summary>
    public const string EmptyBody = "Add a drive to start syncing files between this PC and Cubbit DS3.";

    private readonly IDriveManagementService _driveManager;
    private readonly INavigator _navigation;
    private readonly ILogger<DrivesListViewModel> _logger;

    public DrivesListViewModel(
        IDriveManagementService driveManager,
        INavigator navigation,
        ILogger<DrivesListViewModel> logger)
    {
        _driveManager = driveManager;
        _navigation = navigation;
        _logger = logger;
        _driveManager.Changed += OnDriveManagerChanged;
    }

    /// <summary>The configured drives (bound to the ListView).</summary>
    public IReadOnlyList<DS3Drive> Drives => _driveManager.Drives;

    /// <summary>True when no drives are configured (renders the empty state).</summary>
    public bool IsEmpty => Drives.Count == 0;

    /// <summary>False once the 3-drive cap is reached — hides the Add button (D-23).</summary>
    public bool CanAddDrive => _driveManager.CanAddDrive;

    /// <summary>CTA caption: "Add your first drive" when empty, else "Add drive" (UI-SPEC).</summary>
    public string AddDriveLabel => IsEmpty ? "Add your first drive" : "Add drive";

    /// <summary>Loads drives from SQLite (idempotent) and refreshes bindings.</summary>
    [RelayCommand]
    private async Task LoadAsync(CancellationToken ct)
    {
        if (_driveManager is DriveManagementService concrete)
        {
            await concrete.InitializeAsync(ct).ConfigureAwait(true);
        }

        RaiseAll();
    }

    /// <summary>Opens the drive-setup wizard (port of DriveListView "Add" action).</summary>
    [RelayCommand]
    private void AddDrive()
    {
        if (!CanAddDrive)
        {
            _logger.LogWarning("Add drive invoked while at the {Max}-drive cap; ignoring (D-23).", 3);
            return;
        }

        _navigation.Navigate(PageKey.DriveSetupWizard);
    }

    /// <summary>Removes a drive (Plan 11 promotes this to a confirm dialog).</summary>
    [RelayCommand]
    private async Task RemoveDriveAsync(Guid driveId)
    {
        await _driveManager.RemoveAsync(driveId, CancellationToken.None).ConfigureAwait(true);
        RaiseAll();
    }

    private void OnDriveManagerChanged(object? sender, EventArgs e) => RaiseAll();

    private void RaiseAll()
    {
        OnPropertyChanged(nameof(Drives));
        OnPropertyChanged(nameof(IsEmpty));
        OnPropertyChanged(nameof(CanAddDrive));
        OnPropertyChanged(nameof(AddDriveLabel));
    }
}
