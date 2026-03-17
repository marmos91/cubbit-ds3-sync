import SwiftUI
import SwiftData
import os.log
import UserNotifications
@preconcurrency import FileProvider
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

    @State var trayMenuVisible: Bool = true

    /// Animation state for syncing tray icon (alternates between frames)
    @State private var syncAnimationFrame: Int = 0
    @State private var syncAnimationTimer: Timer?

    var body: some Scene {
        // MARK: - Main view
        
        WindowGroup(id: "io.cubbit.DS3Drive.main") {
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
            } else {
                VStack {
                    ProgressView()
                    Text(NSLocalizedString("Loading preferences…", comment: "Preferences loading state"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 300, height: 200)
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
            Group {
                switch appStatusManager.status {
                case .idle:
                    Image(.trayIcon)
                case .syncing, .indexing:
                    // Animate: alternate between sync icon and base icon
                    if syncAnimationFrame % 2 == 0 {
                        Image(.trayIconSync)
                    } else {
                        Image(.trayIcon)
                    }
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
            .onChange(of: appStatusManager.status) { _, newStatus in
                if (newStatus == .syncing || newStatus == .indexing) && ds3Authentication.isLogged {
                    startSyncAnimation()
                } else {
                    stopSyncAnimation()
                }
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
        ) { [weak ds3Authentication, ds3DriveManager, logger] notification in
            let domainId = notification.object as? String
            let reason = (notification.userInfo as? [String: String])?["reason"]

            logger.warning("Auth failure from extension: reason=\(reason ?? "unknown", privacy: .public), domain=\(domainId ?? "nil", privacy: .public)")

            Task { @MainActor in
                guard let auth = ds3Authentication, auth.isLogged else {
                    Self.showSessionExpiredNotification(logger: logger)
                    return
                }

                guard reason == "s3AuthError", let domainId else {
                    Self.showSessionExpiredNotification(logger: logger)
                    return
                }

                do {
                    guard let drive = ds3DriveManager.drives.first(where: { $0.id.uuidString == domainId }) else {
                        logger.error("No drive found for domain \(domainId, privacy: .public)")
                        return
                    }

                    try await auth.refreshIfNeeded(force: true)

                    let sdk = DS3SDK(withAuthentication: auth, urls: auth.urls)
                    _ = try await sdk.loadOrCreateDS3APIKeys(
                        forIAMUser: drive.syncAnchor.IAMUser,
                        ds3ProjectName: drive.syncAnchor.project.name
                    )

                    logger.info("API key recreated for drive \(drive.name, privacy: .public)")

                    let fpDomain = NSFileProviderDomain(
                        identifier: NSFileProviderDomainIdentifier(rawValue: domainId),
                        displayName: drive.name
                    )
                    try await NSFileProviderManager(for: fpDomain)?.signalErrorResolved(
                        NSFileProviderError(.notAuthenticated) as NSError
                    )
                    logger.info("signalErrorResolved sent for domain \(domainId, privacy: .public)")
                } catch {
                    logger.error("Failed to recover S3 credentials: \(error.localizedDescription, privacy: .public)")
                    Self.showSessionExpiredNotification(logger: logger)
                }
            }
        }
    }

    // MARK: - Sync Animation

    private func startSyncAnimation() {
        guard syncAnimationTimer == nil else { return }
        syncAnimationFrame = 0
        // Use .common mode so the timer fires even when the menu is open
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            DispatchQueue.main.async {
                self.syncAnimationFrame += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        syncAnimationTimer = timer
    }

    private func stopSyncAnimation() {
        syncAnimationTimer?.invalidate()
        syncAnimationTimer = nil
        syncAnimationFrame = 0
    }

    // MARK: - Auth Failure Notification

    private static func showSessionExpiredNotification(logger: Logger) {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("DS3 Drive", comment: "Auth failure notification title")
        content.body = NSLocalizedString("Session expired -- sign in to resume syncing", comment: "Auth failure notification body")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "io.cubbit.DS3Drive.authFailure",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to deliver auth failure notification: \(error.localizedDescription)")
            }
        }
    }
}
