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

    /// <summary>
    /// True once the tray "Quit" path has begun a real shutdown. The main window's close button
    /// otherwise only HIDES the window (macOS menu-bar parity — the app keeps running in the tray);
    /// this flag tells <see cref="MainWindow"/> to allow the genuine close that
    /// <see cref="ShutdownHost"/> → <c>Application.Exit()</c> drives.
    /// </summary>
    public static bool IsShuttingDown { get; private set; }

    private MainWindow? _window;

    public App()
    {
        // Startup diagnostics: opaque WinUI startup failures FailFast as a stowed
        // exception (0xc000027b) with no managed stack in the event log. Capture the
        // real exception to %LOCALAPPDATA%\DS3Drive\startup-error.log so launch
        // failures are diagnosable instead of silent. Handlers are wired before any
        // other work so even ctor-time faults are recorded.
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            LogStartupError("AppDomain.UnhandledException", e.ExceptionObject as Exception);
        UnhandledException += (_, e) =>
            LogStartupError("Application.UnhandledException", e.Exception);

        try
        {
            Host = BuildHost();
            InitializeComponent();
        }
        catch (Exception ex)
        {
            LogStartupError("App..ctor", ex);
            throw;
        }
    }

    /// <summary>
    /// Appends a startup-phase exception to <c>%LOCALAPPDATA%\DS3Drive\startup-error.log</c>
    /// (and the debugger output). Best-effort — diagnostics must never throw.
    /// </summary>
    private static void LogStartupError(string phase, Exception? ex)
    {
        try
        {
            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "DS3Drive");
            Directory.CreateDirectory(dir);
            File.AppendAllText(
                Path.Combine(dir, "startup-error.log"),
                $"[{DateTime.Now:O}] {phase}:{Environment.NewLine}{ex}{Environment.NewLine}{Environment.NewLine}");
            Debug.WriteLine($"DS3Drive STARTUP ERROR ({phase}): {ex}");
        }
        catch
        {
            // Diagnostics must never throw.
        }
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

        // Sync subsystem (Plans 06/10/11; 17.1-03 rewires the S3 surface) — the cfapi sync
        // host runs for the app's lifetime.
        //   PlaceholderStore: SQLite-backed placeholder index (over the shared SyncDatabase).
        //   IDriveS3CredentialProvider: resolves per-drive S3 creds (reconciled API key +
        //     endpoint_gateway) so SyncHostedService builds ONE DS3DriveS3Client per drive and
        //     wraps it in a DriveS3SessionAccess (17.1-03). The cfapi sync IDS3SessionAccess is
        //     now that host-built per-drive adapter — NOT the shared AuthenticationService
        //     singleton, which dereferenced the session handle inside the S3 exports (the AVE).
        //   IDriveLifecycleSource: adapts the drive manager's add/remove/pause onto the Sync seam.
        //   SyncHostedService: registers a sync root + spins a SyncEngine per drive. Started in
        //     OnLaunched AFTER the drive list loads (so existing drives re-register at launch).
        s.AddSingleton<PlaceholderStore>();
        s.AddSingleton<IDriveS3CredentialProvider, DriveS3CredentialProvider>();
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

                // The sync host is now subscribed to DriveAdded. Persisted drives can't start
                // before login (the per-drive S3 reconcile needs a live session), so (re)start
                // them whenever a session becomes available. THIS is what connects the cfapi sync
                // root and fires on-demand placeholder population for a returning user's drives.
                var driveManager = Host.Services.GetRequiredService<DriveManagementService>();
                var auth = Host.Services.GetRequiredService<AuthenticationService>();
                auth.AuthStateChanged += (_, isAuthenticated) =>
                {
                    if (isAuthenticated)
                    {
                        driveManager.ReconnectExistingDrives();
                    }
                };

                // Cover the race where session restore (kicked off in OnLaunched) authenticated
                // before this subscription was wired: start the drives now if already signed in.
                if (auth.IsAuthenticated)
                {
                    driveManager.ReconnectExistingDrives();
                }
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

        // Size the window per page to mirror the macOS per-scene frames: a compact
        // login/2FA window (540x680) vs the larger drives/wizard surface (760x640).
        // Subscribed before the initial navigation so the first page sizes correctly.
        _window.NavigationFrame.Navigated += (_, e) =>
        {
            bool compact = e.SourcePageType == typeof(LoginPage)
                        || e.SourcePageType == typeof(TwoFactorPage);
            _window.ResizeToLogical(compact ? 540 : 760, compact ? 680 : 640);
        };

        // Route Login by default, then attempt to restore a persisted session in the background.
        bool hasSession = Host.Services.GetRequiredService<AuthenticationService>().HasPersistedSession;
        RouteInitialPage(navigation);
        RestoreSessionThenRoute(navigation);

        if (hasSession)
        {
            // Returning user: start SILENTLY in the tray (like a real sync client / the macOS
            // menu-bar app). Realize the window so the process stays alive and the tray can reopen
            // it, then hide it. If restore later fails, RestoreSessionThenRoute surfaces it.
            _window.Activate();
            _window.AppWindow.Hide();
        }
        else
        {
            // Fresh user: show the Login window.
            _window.Activate();
        }

        // Initialise the tray AFTER MainWindow activation — the H.NotifyIcon TaskbarIcon needs
        // a live UI dispatcher (Plan 11, UI-SPEC §Component Inventory TrayHost row).
        Host.Services.GetRequiredService<ITrayService>().Initialize();
    }

    /// <summary>
    /// Stops the sync host (per-drive <c>CfDisconnectSyncRoot</c>, engine stop, upload drain,
    /// status-broadcaster shutdown) and disposes the DI host. Called from the tray Quit path so
    /// a clean exit doesn't leak cfapi sync-root registrations or abandon in-flight uploads — the
    /// <see cref="IHost"/> is otherwise never stopped. Best-effort and time-bounded so a stuck
    /// teardown cannot wedge the quit; all of SyncHostedService awaits with ConfigureAwait(false),
    /// so blocking here does not deadlock the UI thread.
    /// </summary>
    internal static void ShutdownHost()
    {
        // Signal the genuine-quit path so MainWindow stops intercepting the close and the app
        // actually exits (rather than hiding to the tray as it does for the X button).
        IsShuttingDown = true;

        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(8));
            Host.StopAsync(cts.Token).GetAwaiter().GetResult();
        }
        catch (Exception ex)
        {
            Host.Services.GetService<ILogger<App>>()?
                .LogWarning(ex, "Sync host did not stop cleanly on quit.");
        }
        finally
        {
            Host.Dispose();
        }
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
    /// Restores a persisted session off the UI thread (it does network I/O), then navigates to the
    /// drives list on success. On failure the user stays on the already-shown Login page. The
    /// AuthStateChanged handler wired at host start (re)starts the drives once restore authenticates.
    /// </summary>
    private void RestoreSessionThenRoute(INavigationService navigation)
    {
        var auth = Host.Services.GetRequiredService<AuthenticationService>();
        bool hadSession = auth.HasPersistedSession;
        _ = Task.Run(() =>
        {
            bool restored = false;
            try
            {
                restored = auth.TryRestoreSession();
            }
            catch (Exception ex)
            {
                Host.Services.GetRequiredService<ILogger<App>>().LogError(ex, "Session restore failed.");
            }

            _window?.DispatcherQueue.TryEnqueue(() =>
            {
                if (restored)
                {
                    // Stay hidden in the tray (started minimized); ready for when the user opens it.
                    navigation.Navigate(typeof(DrivesListPage));
                }
                else if (hadSession)
                {
                    // We expected to restore but couldn't (expired token / offline): surface Login.
                    navigation.Navigate(typeof(LoginPage));
                    _window?.BringToForeground();
                }
            });
        });
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
