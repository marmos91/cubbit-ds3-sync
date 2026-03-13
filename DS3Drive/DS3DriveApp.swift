import SwiftUI
import SwiftData
import os.log
import UserNotifications
import DS3Lib

@main
struct DS3DriveApp: App {
    private let logger: Logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)

    private let metadataContainer: ModelContainer?

    @AppStorage(DefaultSettings.UserDefaultsKeys.tutorial) var tutorialShown: Bool = DefaultSettings.tutorialShown
    @AppStorage(DefaultSettings.UserDefaultsKeys.loginItemSet) var loginItemSet: Bool = DefaultSettings.loginItemSet

    @State var ds3Authentication: DS3Authentication
    @State var appStatusManager: AppStatusManager = AppStatusManager.default()
    @State var ds3DriveManager: DS3DriveManager = DS3DriveManager(appStatusManager: AppStatusManager.default())
    private let conflictNotificationHandler = ConflictNotificationHandler()
    private var authFailureObserver: NSObjectProtocol?
    @State private var refreshTask: Task<Void, Never>?

    // TODO: Hide tray menu when not logged in
    @State var trayMenuVisible: Bool = true
    
    var body: some Scene {
        // MARK: - Main view
        
        WindowGroup {
            Group {
                if ds3Authentication.isLogged {
                    if !tutorialShown {
                        TutorialView()
                    } else {
                        // Note: if no drives are present, show the setup view
                        if ds3DriveManager.drives.isEmpty {
                            SetupSyncView()
                                .environment(ds3Authentication)
                                .environment(ds3DriveManager)
                        }
                    }
                } else {
                    LoginView()
                        .environment(ds3Authentication)
                }
            }
            .task {
                refreshTask?.cancel()
                refreshTask = ds3Authentication.startProactiveRefreshTimer()
            }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        
        // MARK: - Manage drive
        
        WindowGroup(id: "io.cubbit.DS3Drive.drive.manage", for: UUID.self) { $ds3DriveId in
            if let driveId = ds3DriveId, let drive = ds3DriveManager.driveWithID(driveId) {
                ManageDS3DriveView(ds3Drive: drive)
                    .environment(ds3DriveManager)
            }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        
        // MARK: - Preferences
        
        Window("Preferences", id: "io.cubbit.DS3Drive.preferences") {
            if let account = ds3Authentication.account {
                PreferencesView(
                    preferencesViewModel: PreferencesViewModel(
                        account: account
                    )
                )
                .environment(ds3DriveManager)
            }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        
        // MARK: - Add new drive
        
        Window("Add new Drive", id: "io.cubbit.DS3Drive.drive.new") {
            SetupSyncView()
                .environment(ds3Authentication)
                .environment(ds3DriveManager)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        
#if os(macOS)
        // MARK: - Tray Menu
        
        MenuBarExtra(isInserted: $trayMenuVisible) {
            TrayMenuView()
                .environment(ds3Authentication)
                .environment(ds3DriveManager)
                .environment(appStatusManager)
        } label: {
            switch appStatusManager.status {
            case .idle:
                Image(.trayIcon)
            case .syncing:
                Image(.trayIconSync)
            case .error:
                Image(.trayIconError)
            case .info:
                Image(.trayIconInfo)
            case .offline:
                Image(.trayIconOffline)
            case .paused:
                Image(.trayIconPause)
            }
        }
        .menuBarExtraStyle(.window)
        .commandsRemoved()
#endif
    }
    
    init() {
        // Load saved coordinator URL and construct auth with it
        let coordinatorURL = (try? SharedData.default().loadCoordinatorURLFromPersistence()) ?? CubbitAPIURLs.defaultCoordinatorURL
        let urls = CubbitAPIURLs(coordinatorURL: coordinatorURL)
        _ds3Authentication = State(initialValue: DS3Authentication.loadFromPersistenceOrCreateNew(urls: urls))

        do {
            self.metadataContainer = try MetadataStore.createContainer()
            logger.info("MetadataStore container initialized successfully")
        } catch {
            self.metadataContainer = nil
            logger.error("Failed to initialize MetadataStore container: \(error.localizedDescription)")
        }

        if !loginItemSet {
            do {
                try setLoginItem(true)
            } catch {
                self.logger.error("An error occurred while setting the app as login item: \(error)")
            }
        }

        // Request notification permission for conflict alerts (best-effort)
        conflictNotificationHandler.requestPermission()

        // Listen for auth failure notifications from the File Provider extension
        authFailureObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(DefaultSettings.Notifications.authFailure),
            object: nil,
            queue: .main
        ) { [logger] _ in
            logger.warning("Received auth failure notification from extension")

            let notification = UNMutableNotificationContent()
            notification.title = NSLocalizedString("DS3 Drive", comment: "Auth failure notification title")
            notification.body = NSLocalizedString("Session expired -- sign in to resume syncing", comment: "Auth failure notification body")
            notification.sound = .default

            let request = UNNotificationRequest(
                identifier: "io.cubbit.DS3Drive.authFailure",
                content: notification,
                trigger: nil
            )

            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    logger.error("Failed to deliver auth failure notification: \(error.localizedDescription)")
                }
            }
        }
    }
}
