namespace DS3Drive.ViewModels.ViewModels;

using System;
using System.Threading;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using DS3Drive.Core;
using DS3Drive.Core.Records;
using DS3Drive.ViewModels.Navigation;
using DS3Drive.ViewModels.Services;
using Microsoft.Extensions.Logging;

/// <summary>
/// Settings view-model — port of <c>PreferencesViewModel.swift</c> trimmed from Apple's 5
/// tabs to the 4 Windows sections (CONTEXT D-24 / UI-SPEC §2.15):
/// Account / Coordinator URL / Drives / Logging. Lives in the WinUI-free DS3Drive.ViewModels
/// assembly. Destructive actions (Sign out, Remove drive) raise confirm hooks the SettingsPage
/// wires to a ContentDialog with the UI-SPEC §Destructive copy.
/// </summary>
public partial class SettingsViewModel : ObservableObject
{
    private readonly IAuthenticationService _auth;
    private readonly IDriveManagementService _driveManager;
    private readonly ConfigStore _configStore;
    private readonly INavigator _navigation;
    private readonly ILogger<SettingsViewModel> _logger;

    [ObservableProperty]
    private string displayName = string.Empty;

    [ObservableProperty]
    private string email = string.Empty;

    [ObservableProperty]
    private string coordinatorUrl = string.Empty;

    [ObservableProperty]
    private int logLevel = 2; // 0=Trace 1=Debug 2=Info 3=Warn 4=Error

    public SettingsViewModel(
        IAuthenticationService auth,
        IDriveManagementService driveManager,
        ConfigStore configStore,
        INavigator navigation,
        ILogger<SettingsViewModel> logger)
    {
        _auth = auth;
        _driveManager = driveManager;
        _configStore = configStore;
        _navigation = navigation;
        _logger = logger;

        DS3AccountInfo? account = _auth.CurrentAccount;
        DisplayName = account?.DisplayName ?? string.Empty;
        Email = account?.Email ?? string.Empty;
        CoordinatorUrl = _configStore.DefaultCoordinatorUrl;
    }

    /// <summary>The configured drives (bound to the Drives section table).</summary>
    public IReadOnlyList<DS3Drive> Drives => _driveManager.Drives;

    /// <summary>
    /// UI-SPEC §Destructive copy contract for the Sign-out dialog (the SettingsPage renders these
    /// in a ContentDialog). The cancel button MUST read "Stay signed in" (NOT "Cancel") per the
    /// destructive-action copywriting contract.
    /// </summary>
    public const string SignOutTitle = "Sign out of Cubbit?";
    public const string SignOutCancelLabel = "Stay signed in";

    /// <summary>
    /// Confirm hook for Sign out — the SettingsPage shows the UI-SPEC §Destructive dialog
    /// ("Sign out of Cubbit?" / body / "Sign out" / "Stay signed in") and returns the result.
    /// Null in tests (signs out directly).
    /// </summary>
    public Func<Task<bool>>? ConfirmSignOutAsync { get; set; }

    /// <summary>Confirm hook for Remove drive ("Remove this drive?" / "Remove drive" / "Cancel").</summary>
    public Func<DS3Drive, Task<bool>>? ConfirmRemoveDriveAsync { get; set; }

    /// <summary>Hook the page sets to surface the "Log export coming in Phase 18" TeachingTip.</summary>
    public Action? ShowLogExportPlaceholder { get; set; }

    /// <summary>
    /// Signs out (UI-SPEC §Destructive). Cancel button is "Stay signed in"; confirm clears the
    /// Credential Manager + disposes the session (IAuthenticationService.Logout) and navigates
    /// back to Login. All open windows react via the AuthStateChanged event (T-17-11-04 EoP).
    /// </summary>
    [RelayCommand]
    private async Task SignOutAsync()
    {
        if (ConfirmSignOutAsync is not null)
        {
            bool confirmed = await ConfirmSignOutAsync().ConfigureAwait(true);
            if (!confirmed)
            {
                return; // "Stay signed in"
            }
        }

        _logger.LogInformation("Sign out confirmed from Settings");
        _auth.Logout();
        _navigation.Navigate(PageKey.Login);
    }

    /// <summary>Removes a drive after the destructive confirm ("Remove this drive?").</summary>
    [RelayCommand]
    private async Task RemoveDriveAsync(DS3Drive drive)
    {
        if (drive is null)
        {
            return;
        }

        if (ConfirmRemoveDriveAsync is not null)
        {
            bool confirmed = await ConfirmRemoveDriveAsync(drive).ConfigureAwait(true);
            if (!confirmed)
            {
                return; // "Cancel"
            }
        }

        await _driveManager.RemoveAsync(drive.Id, CancellationToken.None).ConfigureAwait(true);
        OnPropertyChanged(nameof(Drives));
    }

    /// <summary>Toggles a drive's pause flag from the Drives section.</summary>
    [RelayCommand]
    private void TogglePause(DS3Drive drive)
    {
        if (drive is null)
        {
            return;
        }

        _driveManager.SetPaused(drive.Id, !_driveManager.IsPaused(drive.Id));
    }

    /// <summary>Resets the coordinator URL override back to the build-time default (D-13).</summary>
    [RelayCommand]
    private void UseDefaultCoordinatorUrl()
    {
        CoordinatorUrl = _configStore.DefaultCoordinatorUrl;
        _logger.LogInformation("Coordinator URL reset to default");
    }

    /// <summary>
    /// Plan 11 placeholder for the log folder: log export via the wevtutil-exported .evtx is
    /// deferred to Phase 18. Surfaces a TeachingTip rather than opening a folder.
    /// </summary>
    [RelayCommand]
    private void OpenLogFolder()
    {
        _logger.LogInformation("Open log folder requested (deferred to Phase 18)");
        ShowLogExportPlaceholder?.Invoke();
    }
}
