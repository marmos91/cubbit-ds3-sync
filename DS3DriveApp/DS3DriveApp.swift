import DS3Lib
import SwiftUI

@main
struct DS3DriveApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @State private var ds3Authentication: DS3Authentication
    @State private var ds3DriveManager: DS3DriveManager
    @State private var appStatusManager: AppStatusManager
    @State private var hasStartedRefreshTimer = false
    @State private var updateChecker = UpdateChecker()
    #if os(iOS)
        @State private var thumbnailBackfillDriver: ForegroundBackfillDriver
        private let thumbnailBackfillHandler: ThumbnailBackfillTaskHandler
    #endif

    var body: some Scene {
        WindowGroup {
            IOSAppRootView()
                .environment(ds3Authentication)
                .environment(ds3DriveManager)
                .environment(appStatusManager)
                .environment(updateChecker)
                .font(IOSTypography.body)
                .onChange(of: scenePhase, initial: true) { _, newPhase in
                    #if os(iOS)
                        // Drive must always observe scene phase, even before login,
                        // so cold-launch + later login also kicks the drain.
                        thumbnailBackfillDriver.handleScenePhase(newPhase)
                    #endif
                    guard ds3Authentication.isLogged else { return }
                    if newPhase == .active {
                        Task { await BackgroundRefreshManager.signalAllDrives() }
                        Task { await updateChecker.checkForUpdates() }
                    } else if newPhase == .background {
                        BackgroundRefreshManager.scheduleNextRefresh()
                        #if os(iOS)
                            thumbnailBackfillHandler.schedule()
                        #endif
                    }
                }
                .onAppear {
                    if !hasStartedRefreshTimer, ds3Authentication.isLogged {
                        _ = ds3Authentication.startProactiveRefreshTimer()
                        hasStartedRefreshTimer = true
                    }
                }
                .onChange(of: ds3Authentication.isLogged) { _, isLogged in
                    if isLogged, !hasStartedRefreshTimer {
                        _ = ds3Authentication.startProactiveRefreshTimer()
                        hasStartedRefreshTimer = true
                        #if os(iOS)
                            // Login may complete after scenePhase already became
                            // .active, missing the .onChange transition. Kick the
                            // drain now that a drive is available.
                            thumbnailBackfillDriver.handleScenePhase(scenePhase)
                        #endif
                    } else if !isLogged {
                        // Timer exits on its own when the refresh token is rejected;
                        // reset the latch so re-login spins up a fresh timer.
                        hasStartedRefreshTimer = false
                    }
                }
        }
        .backgroundTask(.appRefresh(BackgroundRefreshManager.taskIdentifier)) {
            let success = await BackgroundRefreshManager.signalAllDrives()
            if success {
                await MainActor.run { BackgroundRefreshManager.scheduleNextRefresh() }
            }
        }
    }

    init() {
        let appStatusManager = AppStatusManager.default()
        _appStatusManager = State(initialValue: appStatusManager)

        let coordinatorURL = (try? SharedData.default().loadCoordinatorURLFromPersistence()) ?? CubbitAPIURLs
            .defaultCoordinatorURL
        let urls = CubbitAPIURLs(coordinatorURL: coordinatorURL)
        _ds3Authentication = State(initialValue: DS3Authentication.loadFromPersistenceOrCreateNew(urls: urls))
        let driveManager = DS3DriveManager(appStatusManager: appStatusManager)
        _ds3DriveManager = State(initialValue: driveManager)
        #if os(iOS)
            let backfillDriver = ForegroundBackfillDriver(driveManager: driveManager)
            _thumbnailBackfillDriver = State(initialValue: backfillDriver)
            let handler = ThumbnailBackfillTaskHandler(driver: backfillDriver)
            thumbnailBackfillHandler = handler
            handler.register()
        #endif
    }
}
