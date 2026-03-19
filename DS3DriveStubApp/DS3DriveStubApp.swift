import SwiftUI
import DS3Lib

@main
struct DS3DriveStubApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @State private var ds3Authentication: DS3Authentication
    @State private var ds3DriveManager: DS3DriveManager
    @State private var appStatusManager: AppStatusManager
    @State private var hasStartedRefreshTimer = false

    var body: some Scene {
        WindowGroup {
            IOSAppRootView()
                .environment(ds3Authentication)
                .environment(ds3DriveManager)
                .environment(appStatusManager)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { await BackgroundRefreshManager.signalAllDrives() }
                    } else if newPhase == .background {
                        BackgroundRefreshManager.scheduleNextRefresh()
                    }
                }
                .onAppear {
                    if !hasStartedRefreshTimer {
                        _ = ds3Authentication.startProactiveRefreshTimer()
                        hasStartedRefreshTimer = true
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

        let coordinatorURL = (try? SharedData.default().loadCoordinatorURLFromPersistence()) ?? CubbitAPIURLs.defaultCoordinatorURL
        let urls = CubbitAPIURLs(coordinatorURL: coordinatorURL)
        _ds3Authentication = State(initialValue: DS3Authentication.loadFromPersistenceOrCreateNew(urls: urls))
        _ds3DriveManager = State(initialValue: DS3DriveManager(appStatusManager: appStatusManager))
    }
}
