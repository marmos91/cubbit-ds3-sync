using Microsoft.UI.Xaml;

namespace DS3Drive.App;

/// <summary>
/// Minimal WinUI 3 application shell for the empty scaffold (Plan 02).
/// The WinUI tooling generates the <c>Main</c> entry point from <c>App.xaml</c>,
/// which is what lets this <c>WinExe</c> project link. Plan 04 replaces this with
/// the real lifecycle: single-instance mutex, DI host (Host.CreateApplicationBuilder),
/// tray bootstrap, and the drive-setup wizard window.
/// </summary>
public partial class App : Application
{
    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // Intentionally empty in the scaffold. Plan 04 creates the main window,
        // wires the tray icon, and starts the DI-hosted services here.
    }
}
