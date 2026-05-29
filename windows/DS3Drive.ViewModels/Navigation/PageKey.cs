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

    /// <summary>Drives list / setup wizard entry — wired by Plan 09.</summary>
    DrivesList,
}
