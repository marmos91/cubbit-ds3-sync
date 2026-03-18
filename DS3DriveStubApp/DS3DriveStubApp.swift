import SwiftUI
@preconcurrency import FileProvider
import BackgroundTasks
import DS3Lib
import os.log

@main
struct DS3DriveStubApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @State private var ds3Authentication: DS3Authentication
    @State private var ds3DriveManager: DS3DriveManager
    @State private var appStatusManager: AppStatusManager = AppStatusManager.default()
    @State private var refreshTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "io.cubbit.DS3Drive", category: "app")

    var body: some Scene {
        WindowGroup {
            IOSAppRootView()
                .environment(ds3Authentication)
                .environment(ds3DriveManager)
                .environment(appStatusManager)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { await signalAllDrives() }
                    } else if newPhase == .background {
                        scheduleBackgroundRefresh()
                    }
                }
                .task {
                    refreshTask?.cancel()
                    refreshTask = ds3Authentication.startProactiveRefreshTimer()
                }
        }
        .backgroundTask(.appRefresh("io.cubbit.DS3Drive.refreshDrives")) {
            await signalAllDrives()
            await MainActor.run { scheduleBackgroundRefresh() }
        }
    }

    init() {
        let coordinatorURL = (try? SharedData.default().loadCoordinatorURLFromPersistence()) ?? CubbitAPIURLs.defaultCoordinatorURL
        let urls = CubbitAPIURLs(coordinatorURL: coordinatorURL)
        _ds3Authentication = State(initialValue: DS3Authentication.loadFromPersistenceOrCreateNew(urls: urls))
        _ds3DriveManager = State(initialValue: DS3DriveManager(appStatusManager: AppStatusManager.default()))
    }

    /// Signals all active drives to check for remote changes via the File Provider system.
    private func signalAllDrives() async {
        for drive in ds3DriveManager.drives {
            let domain = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(rawValue: drive.id.uuidString),
                displayName: drive.name
            )
            try? await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
        }
    }

    /// Schedules a background app refresh task to periodically signal drives (~30 min intervals).
    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "io.cubbit.DS3Drive.refreshDrives")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
