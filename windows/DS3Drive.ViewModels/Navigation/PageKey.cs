namespace DS3Drive.ViewModels.Navigation;

/// <summary>
/// WinUI-free page identifiers for view-model-driven navigation. The App's
/// Frame-based NavigationService maps each key to a concrete <c>Page</c> Type, so
/// view-models never reference WinUI page types (which would couple them to the App
/// assembly and break headless unit testing).
/// </summary>
public enum PageKey
{
    Login,
    TwoFactor,
    Tutorial,

    /// <summary>Post-tutorial drives list landing page (wired by Plan 09).</summary>
    DrivesList,

    /// <summary>Drive-setup wizard shell (Project → Bucket → Prefix → Confirm; Plan 09).</summary>
    DriveSetupWizard,

    /// <summary>Settings page — Account / Coordinator URL / Drives / Logging (Plan 11, UI-SPEC §2.15).</summary>
    Settings,
}
