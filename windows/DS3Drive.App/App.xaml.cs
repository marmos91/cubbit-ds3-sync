namespace DS3Drive.App;

using DS3Drive.App.Pages;
using DS3Drive.App.Services;
using DS3Drive.Core;
using DS3Drive.Core.Logging;
using DS3Drive.ViewModels.Navigation;
using DS3Drive.ViewModels.Platform;
using DS3Drive.ViewModels.Services;
using DS3Drive.ViewModels.ViewModels;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

/// <summary>
/// Application entry point + composition root for the DS3 Drive Windows shell.
/// Port of <c>apple/DS3Drive/DS3DriveApp.swift</c> lines 1-120 (PATTERNS §2.17): the
/// macOS <c>@main struct</c> scene graph + environment injection becomes a
/// <see cref="IHost"/> DI container plus a <see cref="Frame"/>-routed
/// <see cref="MainWindow"/>.
///
/// Lifecycle (OnLaunched):
///   1. Acquire the single-instance mutex (D-27); a losing instance signals + exits.
///   2. Initialise the Rust→ETW log bridge BEFORE the first FFI call (Plan 07 / POL-01).
///   3. Build MainWindow from DI, apply the Mica backdrop (UI-SPEC §Design System).
///   4. Route the content Frame: LoginPage when signed out, else TutorialPage on first
///      run, else (Plan 09 wires DrivesListPage).
/// </summary>
public partial class App : Application
{
    /// <summary>The DI host, available to pages/view-models that resolve services lazily.</summary>
    public static IHost Host { get; private set; } = null!;

    private MainWindow? _window;

    public App()
    {
        Host = BuildHost();
        InitializeComponent();
    }

    private static IHost BuildHost()
    {
        HostApplicationBuilder builder = Microsoft.Extensions.Hosting.Host.CreateApplicationBuilder();

        // Build-time defaults (D-13). appsettings.json ships next to DS3Drive.Core.dll.
        builder.Configuration.AddJsonFile("appsettings.json", optional: true, reloadOnChange: false);

        IServiceCollection s = builder.Services;

        // Core stores + session facade (DS3Session is single-owner; AuthenticationService
        // mints + owns the handle, so it is registered as a singleton without a live
        // session instance here).
        s.AddSingleton<ConfigStore>();
        s.AddSingleton<IConfiguration>(_ => builder.Configuration);
        s.AddSingleton<CredentialStore>(_ => new CredentialStore());

        // App services.
        s.AddSingleton<IAuthenticationService, AuthenticationService>();
        s.AddSingleton<NavigationService>();
        s.AddSingleton<INavigationService>(sp => sp.GetRequiredService<NavigationService>());
        // View-models consume the WinUI-free INavigator; forward it to the same instance.
        s.AddSingleton<INavigator>(sp => sp.GetRequiredService<NavigationService>());
        s.AddSingleton<ISingleInstanceService, SingleInstanceService>();

        // Window (resolved once at launch).
        s.AddSingleton<MainWindow>();

        // View-models (transient: a fresh state machine per page navigation).
        s.AddTransient<LoginViewModel>();
        s.AddTransient<TwoFactorViewModel>();
        s.AddTransient<TutorialViewModel>();

        // ILogger<T> → EventSource (Plan 07: provider Cubbit-DS3Drive-App).
        s.AddLogging(b => b.AddEventSourceLogger());

        return builder.Build();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var singleInstance = Host.Services.GetRequiredService<ISingleInstanceService>();
        if (!singleInstance.Acquire())
        {
            // Another instance already owns the app — poke it to surface, then exit (D-27).
            singleInstance.SignalExistingInstance();
            Exit();
            return;
        }

        // POL-01: install the Rust tracing → C# EventSource bridge BEFORE any FFI call so
        // authentication-time core logs are captured (Plan 07).
        RustLogBridge.Initialize();

        // Surface a second-launch signal by bringing the existing window forward.
        singleInstance.SecondInstanceLaunched += (_, _) =>
            _window?.DispatcherQueue.TryEnqueue(() => _window?.BringToForeground());

        _window = Host.Services.GetRequiredService<MainWindow>();

        // Mica backdrop (UI-SPEC §Design System: Mica on the main window).
        _window.SystemBackdrop = new MicaBackdrop { Kind = MicaKind.Base };

        // Wire navigation to the window's content Frame and route the initial page.
        var navigation = Host.Services.GetRequiredService<INavigationService>();
        navigation.Initialize(_window.NavigationFrame);
        RouteInitialPage(navigation);

        _window.Activate();
    }

    /// <summary>
    /// Initial-page routing — port of DS3DriveApp.swift lines 34-52 (PATTERNS §2.17):
    /// LoginPage when not authenticated, else TutorialPage on first run, else DrivesListPage
    /// (Plan 09 fills the final branch).
    /// </summary>
    private static void RouteInitialPage(INavigationService navigation)
    {
        var auth = Host.Services.GetRequiredService<IAuthenticationService>();

        if (!auth.IsAuthenticated)
        {
            navigation.Navigate(typeof(LoginPage));
            return;
        }

        // First-run tutorial flag. The persistent store (SQLite tutorial_shown, D-25)
        // lands with the wizard plumbing; until then, an authenticated launch shows the
        // tutorial. Plan 09 wires the DrivesListPage branch:
        //   else navigation.Navigate(typeof(DrivesListPage));
        navigation.Navigate(typeof(TutorialPage));
    }
}
