namespace DS3Drive.App;

using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.App.Pages;
using DS3Drive.App.Services;
using DS3Drive.Core;
using DS3Drive.Core.Logging;
using DS3Drive.Core.Records;
using DS3Drive.Sync;
using DS3Drive.Sync.Hosting;
using DS3Drive.Sync.Storage;
using DS3Drive.Sync.SyncEngine;
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

        // App services. AuthenticationService owns the live DS3Session and also adapts it
        // onto IDS3SessionGateway (Plan 09) — register the SAME instance for both interfaces.
        s.AddSingleton<AuthenticationService>();
        s.AddSingleton<IAuthenticationService>(sp => sp.GetRequiredService<AuthenticationService>());
        s.AddSingleton<IDS3SessionGateway>(sp => sp.GetRequiredService<AuthenticationService>());
        s.AddSingleton<NavigationService>();
        s.AddSingleton<INavigationService>(sp => sp.GetRequiredService<NavigationService>());
        // View-models consume the WinUI-free INavigator; forward it to the same instance.
        s.AddSingleton<INavigator>(sp => sp.GetRequiredService<NavigationService>());
        s.AddSingleton<ISingleInstanceService, SingleInstanceService>();

        // Persistence + SDK + drive management (Plan 09). SyncDatabase is the SQLite store
        // (Plan 06); it is opened once in OnLaunched before any consumer runs.
        s.AddSingleton<SyncDatabase>(_ => new SyncDatabase());
        s.AddSingleton<IInstallationIdProvider, SqliteInstallationIdProvider>();
        s.AddSingleton<IDS3SdkService, DS3SdkService>();
        s.AddSingleton<DrivesRepository>();
        s.AddSingleton<DriveManagementService>();
        s.AddSingleton<IDriveManagementService>(sp => sp.GetRequiredService<DriveManagementService>());

        // Sync subsystem (Plans 06/10/11) — the cfapi sync host runs for the app's lifetime.
        //   PlaceholderStore: SQLite-backed placeholder index (over the shared SyncDatabase).
        //   IDS3SessionAccess: the cfapi engine borrows the SAME live session AuthenticationService
        //     owns (adapter is that singleton; no second handle, mirrors the IDS3SessionGateway wiring).
        //   IDriveLifecycleSource: adapts the drive manager's add/remove/pause onto the Sync seam.
        //   SyncHostedService: registers a sync root + spins a SyncEngine per drive. Started in
        //     OnLaunched AFTER the drive list loads (so existing drives re-register at launch).
        s.AddSingleton<PlaceholderStore>();
        s.AddSingleton<IDS3SessionAccess>(sp => sp.GetRequiredService<AuthenticationService>());
        s.AddSingleton<IDriveLifecycleSource, DriveLifecycleSource>();
        s.AddHostedService<SyncHostedService>();

        // Window (resolved once at launch).
        s.AddSingleton<MainWindow>();

        // View-models (transient: a fresh state machine per page navigation).
        s.AddTransient<LoginViewModel>();
        s.AddTransient<TwoFactorViewModel>();
        s.AddTransient<TutorialViewModel>();
        s.AddTransient<DriveSetupViewModel>();
        s.AddTransient<DrivesListViewModel>();
        s.AddTransient<SettingsViewModel>();

        // Tray (Plan 11). RecentFilesService is in-memory (T-17-11-01, no persistence).
        s.AddSingleton<IRecentFilesService, RecentFilesService>();

        // Per-drive row factory: the App owns the platform Open-in-Explorer hook
        // (Process.Start) so the WinUI-free row VM stays shell-coupling-free.
        s.AddSingleton<Func<DS3Drive, TrayDriveRowViewModel>>(sp => drive =>
            new TrayDriveRowViewModel(
                drive,
                sp.GetRequiredService<IDriveManagementService>(),
                sp.GetRequiredService<INavigator>(),
                sp.GetRequiredService<ILoggerFactory>().CreateLogger<TrayDriveRowViewModel>(),
                OpenDriveInExplorer));

        s.AddSingleton<TrayViewModel>(sp => new TrayViewModel(
            sp.GetRequiredService<IDriveManagementService>(),
            sp.GetRequiredService<IRecentFilesService>(),
            sp.GetRequiredService<INavigator>(),
            sp.GetRequiredService<ILogger<TrayViewModel>>(),
            sp.GetRequiredService<Func<DS3Drive, TrayDriveRowViewModel>>(),
            showMainWindow: BringMainWindowForward));

        s.AddSingleton<ITrayService, TrayService>();

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

        // Open the SQLite store (Plan 06) before the SDK / drive manager touch it. Runs
        // migrations on first open; failures here are surfaced via the store's recovery path.
        Host.Services.GetRequiredService<SyncDatabase>()
            .OpenAsync(CancellationToken.None)
            .GetAwaiter().GetResult();

        // Load configured drives from SQLite BEFORE the sync host enumerates them, so a returning
        // user's existing drives re-register their cfapi sync roots at launch. Idempotent (the
        // drives list VM also calls this) and a fast local read; run on the UI thread so the
        // bound Drives collection is only mutated here.
        Host.Services.GetRequiredService<DriveManagementService>()
            .InitializeAsync(CancellationToken.None)
            .GetAwaiter().GetResult();

        // Start the cfapi sync host (Plans 10/11): registers a sync root per existing drive and
        // subscribes to DriveAdded/DriveRemoved so the wizard's new drives register live. Run off
        // the UI thread and guarded — a cfapi/registration failure degrades to "no sync this
        // session" rather than crashing launch (the login/UI surface stays usable).
        _ = Task.Run(async () =>
        {
            try
            {
                await Host.StartAsync().ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                Host.Services.GetRequiredService<ILogger<App>>()
                    .LogError(ex, "Sync host failed to start; sync is disabled for this session.");
            }
        });

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

        // Initialise the tray AFTER MainWindow activation — the H.NotifyIcon TaskbarIcon needs
        // a live UI dispatcher (Plan 11, UI-SPEC §Component Inventory TrayHost row).
        Host.Services.GetRequiredService<ITrayService>().Initialize();
    }

    /// <summary>Brings the main window forward (tray "Open Cubbit" / double-click).</summary>
    private static void BringMainWindowForward() =>
        ((App)Current)._window?.DispatcherQueue.TryEnqueue(() =>
            ((App)Current)._window?.BringToForeground());

    /// <summary>
    /// Opens a drive's local sync-root folder in Explorer (tray row "Open in Explorer").
    /// The local root mirrors the cfapi sync-root convention (Plan 10):
    /// <c>%USERPROFILE%\Cubbit\&lt;drive name&gt;</c>.
    /// </summary>
    private static void OpenDriveInExplorer(string driveName)
    {
        string root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Cubbit",
            driveName);

        try
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{root}\"") { UseShellExecute = true });
        }
        catch (Exception)
        {
            // Opening Explorer is non-critical (folder may not exist before first sync).
        }
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
        // lands with a later plan; until then, an authenticated launch shows the tutorial
        // on first run and the drives list thereafter. Plan 09 wires the DrivesListPage
        // landing page (Plan 08 TODO resolved): authenticated → DrivesListPage.
        navigation.Navigate(typeof(DrivesListPage));
    }
}
