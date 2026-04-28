import AppKit
import CoreText
import DS3Lib
@preconcurrency import FileProvider
import os.log
import SwiftData
import SwiftUI
import UserNotifications

@main
struct DS3DriveApp: App {
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)

    private let metadataContainer: ModelContainer?

    @AppStorage(DefaultSettings.UserDefaultsKeys.tutorial) var tutorialShown: Bool = DefaultSettings.tutorialShown

    @State private var ds3Authentication: DS3Authentication
    @State private var appStatusManager: AppStatusManager = .default()
    @State private var ds3DriveManager = DS3DriveManager(appStatusManager: AppStatusManager.default())
    private let conflictNotificationHandler = ConflictNotificationHandler()
    private var authFailureObserver: NSObjectProtocol?
    private let recoveryTracker = AuthRecoveryTracker()
    @State private var refreshTask: Task<Void, Never>?

    @State private var updateManager = UpdateManager()
    private var updateNotificationHandler: UpdateNotificationHandler?

    @State private var trayMenuVisible: Bool = true

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
            .font(DS3Typography.body)
            .task {
                refreshTask?.cancel()
                refreshTask = ds3Authentication.startProactiveRefreshTimer()
            }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

        // MARK: - Preferences

        Window("Preferences", id: "io.cubbit.DS3Drive.preferences") {
            Group {
                if let account = ds3Authentication.account {
                    PreferencesView(
                        preferencesViewModel: PreferencesViewModel(
                            account: account
                        )
                    )
                    .environment(ds3Authentication)
                    .environment(ds3DriveManager)
                    .environment(updateManager)
                    .frame(minWidth: 720, idealWidth: 760, minHeight: 560, idealHeight: 600)
                } else {
                    VStack {
                        ProgressView()
                        Text(NSLocalizedString("Loading preferences…", comment: "Preferences loading state"))
                            .font(DS3Typography.caption)
                            .foregroundStyle(DS3Colors.brandTextSecondary)
                    }
                    .frame(width: 300, height: 200)
                }
            }
            // Plan 05-18b Gap 24: brand backdrop for the whole Preferences
            // scene (including any chrome the SwiftUI Window host draws
            // behind the content) and dark color scheme so the tab bar and
            // form controls inherit the brand palette.
            .background(DS3Colors.brandBackground.ignoresSafeArea())
            .preferredColorScheme(.dark)
            .font(DS3Typography.body)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)

        // MARK: - Add new drive

        Window("Add new Drive", id: "io.cubbit.DS3Drive.drive.new") {
            SetupSyncView()
                .environment(ds3Authentication)
                .environment(ds3DriveManager)
                .font(DS3Typography.body)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

        #if os(macOS)

            // MARK: - Tray Menu

            MenuBarExtra(isInserted: $trayMenuVisible) {
                TrayMenuView()
                    .environment(ds3Authentication)
                    .environment(ds3DriveManager)
                    .environment(appStatusManager)
                    .environment(updateManager)
                    .font(DS3Typography.body)
            } label: {
                // Single source of truth: derive the menu bar icon from
                // `ds3DriveManager.aggregateStatus`, which is computed from
                // per-drive states (Gap 15). Replaces the previous binding to
                // `AppStatusManager.status`, which could leak into a stuck
                // active state when the operation counter diverged.
                Group {
                    switch ds3DriveManager.aggregateAppStatus {
                    case .idle:
                        if updateManager.updateAvailable {
                            Image(.trayIconInfo)
                        } else {
                            Image(.trayIcon)
                        }
                    case .syncing:
                        Image(.trayIconSync)
                    case .error:
                        Image(.trayIconError)
                    case .info:
                        Image(.trayIconInfo)
                    case .offline:
                        Image(.trayIconOffline)
                    }
                }
            }
            .menuBarExtraStyle(.window)
            .commandsRemoved()
        #endif
    }

    /// Plan 05-17 Gap 31: explicit runtime registration of Figtree font files.
    /// `ATSApplicationFontsPath` in Info.plist is unreliable — registering via
    /// `CTFontManagerRegisterFontsForURL` guarantees the font loads regardless
    /// of Info.plist interpretation.
    private static func registerBrandFonts() {
        // The macOS bundle keeps fonts under `Assets/Fonts/` (mirroring
        // the source tree). Try the bundle root first for forward
        // compatibility, then fall back to the subdirectory — without
        // this lookup, registration silently no-ops on builds where the
        // resources aren't flattened.
        for name in ["Figtree-Regular", "Figtree-Medium", "Figtree-SemiBold", "Figtree-Bold"] {
            let url = Bundle.main.url(forResource: name, withExtension: "ttf")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Assets/Fonts")
            guard let url else {
                NSLog("[DS3DriveApp] WARNING: \(name).ttf not found in bundle Resources or Assets/Fonts")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error),
               let err = error?.takeRetainedValue(),
               CFErrorGetCode(err) != 105 { // 105 = kCTFontManagerErrorAlreadyRegistered
                NSLog("[DS3DriveApp] WARNING: Failed to register \(name): \(err)")
            }
        }
        if NSFontManager.shared.availableFontFamilies.contains("Figtree") {
            // Dump every font name in the family so DS3Typography uses the
            // exact name SwiftUI can resolve via Font.custom(_:size:).
            let members = NSFontManager.shared.availableMembers(ofFontFamily: "Figtree") ?? []
            let names = members.compactMap { $0.first as? String }
            NSLog("[DS3DriveApp] Figtree registered. PostScript names available: \(names)")
        } else {
            NSLog("[DS3DriveApp] WARNING: Figtree not in availableFontFamilies after registration")
        }
    }

    init() {
        Self.registerBrandFonts()

        // Load saved coordinator URL and construct auth with it
        let coordinatorURL = (try? SharedData.default().loadCoordinatorURLFromPersistence()) ?? CubbitAPIURLs
            .defaultCoordinatorURL
        let urls = CubbitAPIURLs(coordinatorURL: coordinatorURL)
        _ds3Authentication = State(initialValue: DS3Authentication.loadFromPersistenceOrCreateNew(urls: urls))

        do {
            self.metadataContainer = try MetadataStore.createContainer()
            logger.info("MetadataStore container initialized successfully")
        } catch {
            self.metadataContainer = nil
            logger.error("Failed to initialize MetadataStore container: \(error.localizedDescription)")
        }

        // Request notification permission for conflict alerts (best-effort)
        conflictNotificationHandler.requestPermission()

        // Start update checking (respecting user preference) and notification handler
        let autoCheck = UserDefaults(suiteName: DefaultSettings.appGroup)?
            .object(forKey: DefaultSettings.UserDefaultsKeys.autoCheckUpdates) as? Bool ?? true
        if autoCheck {
            updateManager.startPeriodicChecks()
        }
        updateNotificationHandler = UpdateNotificationHandler(updateManager: updateManager)

        // Listen for auth failure notifications from the File Provider extension
        authFailureObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(DefaultSettings.Notifications.authFailure),
            object: nil,
            queue: .main
        ) { [weak ds3Authentication, ds3DriveManager, logger, recoveryTracker] notification in
            let domainId = notification.object as? String
            let reason = (notification.userInfo as? [String: String])?["reason"]

            logger
                .warning(
                    "Auth failure from extension: reason=\(reason ?? "unknown", privacy: .public), domain=\(domainId ?? "nil", privacy: .public)"
                )

            Task { @MainActor in
                guard let auth = ds3Authentication, auth.isLogged else {
                    Self.showSessionExpiredNotification(logger: logger)
                    return
                }

                guard reason == "s3AuthError", let domainId else {
                    Self.showSessionExpiredNotification(logger: logger)
                    return
                }

                // Skip if recovery is already in progress for this domain
                guard !recoveryTracker.activeRecoveries.contains(domainId) else {
                    logger.info("Auth recovery already in progress for domain \(domainId, privacy: .public), skipping")
                    return
                }

                recoveryTracker.activeRecoveries.insert(domainId)
                defer { recoveryTracker.activeRecoveries.remove(domainId) }

                do {
                    guard let drive = ds3DriveManager.drives.first(where: { $0.id.uuidString == domainId }) else {
                        logger.error("No drive found for domain \(domainId, privacy: .public)")
                        return
                    }

                    try await auth.refreshIfNeeded(force: true)

                    let client = DS3Client(authentication: auth)
                    _ = try await client.loadOrCreateDS3APIKeys(
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
                } catch DS3AuthenticationError.tokenExpired {
                    logger.error("Refresh token rejected during auth recovery — forcing logout")
                    auth.logout()
                    Self.showSessionExpiredNotification(logger: logger)
                } catch {
                    logger.error("Failed to recover S3 credentials: \(error.localizedDescription, privacy: .public)")
                    Self.showSessionExpiredNotification(logger: logger)
                }
            }
        }
    }

    // MARK: - Auth Failure Notification

    private static func showSessionExpiredNotification(logger: Logger) {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("DS3 Drive", comment: "Auth failure notification title")
        content.body = NSLocalizedString(
            "Session expired -- sign in to resume syncing",
            comment: "Auth failure notification body"
        )
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

/// Tracks in-flight auth recovery operations per File Provider domain.
/// Only accessed from @MainActor context (notification observer + Task).
@MainActor
private final class AuthRecoveryTracker: @unchecked Sendable {
    var activeRecoveries: Set<String> = []
}
