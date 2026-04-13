import DS3Lib
import os.log
import SwiftUI

struct TrayMenuView: View {
    @Environment(\.openURL) var openURL
    @Environment(\.openWindow) var openWindow

    @Environment(DS3Authentication.self) var ds3Authentication: DS3Authentication
    @Environment(DS3DriveManager.self) var ds3DriveManager: DS3DriveManager
    @Environment(AppStatusManager.self) var appStatusManager: AppStatusManager
    @Environment(UpdateManager.self) var updateManager: UpdateManager

    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)

    @State private var floatingPanelManager = FloatingPanelManager()
    @State private var driveViewModels: [DS3DriveViewModel] = []

    /// Result feedback for "Check for Updates". Bound to an alert so the user always
    /// gets confirmation that the check ran.
    @State private var updateCheckAlert: UpdateCheckResult?

    var body: some View {
        Group {
            if ds3Authentication.isLogged {
                loggedInMenu
            } else {
                loggedOutMenu
            }
        }
        .frame(width: 310)
        .fixedSize(horizontal: true, vertical: false)
        // Plan 05-12: brand-coloured tray background so the surface
        // matches the rest of the app and floats the drive cards.
        .background(DS3Colors.brandBackground)
        .background(
            WindowAccessor(onWindow: floatingPanelManager.setTrayWindow)
        )
        .onAppear {
            rebuildDriveViewModels()
        }
        .onChange(of: ds3DriveManager.drives.map(\.id)) {
            rebuildDriveViewModels()
        }
        .onChange(of: updateManager.lastResult) { _, newValue in
            // When the user manually runs Check for Updates, surface the result
            // immediately. We only present feedback for *manual* invocations:
            // periodic background checks should not pop alerts on the user.
            if userInitiatedUpdateCheck, let newValue {
                updateCheckAlert = newValue
                userInitiatedUpdateCheck = false
            }
        }
        .alert(
            updateAlertTitle(for: updateCheckAlert),
            isPresented: Binding(
                get: { updateCheckAlert != nil },
                set: { if !$0 { updateCheckAlert = nil } }
            ),
            presenting: updateCheckAlert
        ) { result in
            switch result {
            case .upToDate, .updateAvailable:
                Button(NSLocalizedString("OK", comment: "Generic OK button")) {
                    updateCheckAlert = nil
                }
            case .failed:
                Button(NSLocalizedString("updates.retry", value: "Retry", comment: "Retry update check")) {
                    triggerUpdateCheck()
                }
                Button(NSLocalizedString("Cancel", comment: "Generic cancel"), role: .cancel) {
                    updateCheckAlert = nil
                }
            }
        } message: { result in
            Text(updateAlertMessage(for: result))
        }
    }

    @State private var userInitiatedUpdateCheck: Bool = false

    private func updateAlertTitle(for result: UpdateCheckResult?) -> String {
        switch result {
        case .upToDate:
            NSLocalizedString("updates.upToDateTitle", value: "You're up to date", comment: "Update check title")
        case .updateAvailable:
            NSLocalizedString(
                "updates.availableTitle",
                value: "Update available",
                comment: "Update check title"
            )
        case .failed:
            NSLocalizedString(
                "updates.failedTitle",
                value: "Couldn't check for updates",
                comment: "Update check title"
            )
        case .none:
            ""
        }
    }

    private func updateAlertMessage(for result: UpdateCheckResult) -> String {
        switch result {
        case let .upToDate(version):
            String(
                format: NSLocalizedString(
                    "updates.upToDate",
                    value: "Version %@ is the latest available.",
                    comment: "Up to date message"
                ),
                version
            )
        case let .updateAvailable(version):
            String(
                format: NSLocalizedString(
                    "updates.available",
                    value: "Version %@ is available to install.",
                    comment: "Update available message"
                ),
                version
            )
        case let .failed(message):
            String(
                format: NSLocalizedString(
                    "updates.failed",
                    value: "Couldn't check for updates: %@",
                    comment: "Update check failed message"
                ),
                message
            )
        }
    }

    private func triggerUpdateCheck() {
        userInitiatedUpdateCheck = true
        updateCheckAlert = nil
        // Plan 05-15 Gap 26: use the notification-aware variant so the user
        // gets a system UNUserNotification with the result, which survives
        // the tray closing before the check returns. The in-tray alert
        // (plumbed via `.onChange(of: updateManager.lastResult)` above) also
        // still fires — the two channels are complementary.
        Task { await updateManager.checkForUpdatesAndNotify() }
    }

    // MARK: - Logged Out Menu

    private var loggedOutMenu: some View {
        VStack(spacing: 0) {
            // Brand hero — fills the visual void at the top of the
            // signed-out tray with the Cubbit logo + welcome copy.
            VStack(spacing: DS3Spacing.sm) {
                ZStack {
                    DS3Gradients.brandRadialGlow
                        .frame(width: 180, height: 100)
                        .blur(radius: 24)
                    Image(.cubbitLogo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 36)
                }
                Text(NSLocalizedString(
                    "tray.signedOut.title",
                    value: "Welcome to DS3 Drive",
                    comment: "Tray signed-out hero title"
                ))
                .font(DS3Typography.body)
                .foregroundStyle(DS3Colors.brandTextPrimary)
                Text(NSLocalizedString(
                    "tray.signedOut.subtitle",
                    value: "Sign in to start syncing",
                    comment: "Tray signed-out hero subtitle"
                ))
                .font(DS3Typography.caption)
                .foregroundStyle(DS3Colors.brandTextSecondary)
            }
            .padding(.horizontal, DS3Spacing.lg)
            .padding(.vertical, DS3Spacing.lg)

            brandDivider

            TrayMenuItem(
                title: NSLocalizedString("Sign In", comment: "Tray menu sign in"),
                systemImage: "person.crop.circle"
            ) {
                openWindow(id: "io.cubbit.DS3Drive.main")
                NSApp.activate(ignoringOtherApps: true)
            }

            brandDivider

            TrayMenuItem(
                title: NSLocalizedString("Help", comment: "Tray menu help"),
                systemImage: "questionmark.circle"
            ) {
                if let url = URL(string: HelpURLs.baseURL) { openURL(url) }
            }

            brandDivider

            quitItem

            menuFooter(status: AppStatus.idle.toString())
        }
    }

    // MARK: - Logged In Menu

    private var loggedInMenu: some View {
        VStack(spacing: 0) {
            // Plan 05-18b: top breathing room. With the aggregate header
            // gone the first drive card was flush against the rounded
            // tray edge, which read as cramped.
            Color.clear.frame(height: DS3Spacing.sm)
            // Aggregate header row. With 2+ drives we always show it; with a
            // Aggregate status header row removed (Plan 05-18b iteration):
            // it duplicated the footer's status icon and the per-drive row
            // chrome. The footer carries the single source of truth for the
            // aggregate state across all surfaces; this row was redundant.

            // Plan 05-18b Gap 23: empty-state hint for signed-in users with
            // zero drives. Replaces the previous blank gap between the speed
            // summary and the `Add a new Drive` row. The aggregate header row
            // is already gated on `drives.count >= 2` so it cannot conflict.
            if ds3DriveManager.drives.isEmpty {
                EmptyDrivesHint()
                brandDivider
            }
            // SpeedSummaryView removed from top of tray (Plan 05-18b
            // iteration) — embedded in TrayMenuFooterView instead so the
            // footer is the single live status surface.

            driveListSection

            if canAddMoreDrives {
                addDriveItem
            }

            quickActionsSection

            // Sign Out intentionally hidden from the tray (Plan 05-18b
            // iteration). It's destructive and shouldn't be one-click in
            // a quick-access surface — moved to Preferences → Account
            // where it requires deliberate navigation, mirroring how
            // Dropbox / Google Drive handle the same action.

            // Quit isolated by a divider — destructive action deserves
            // visual separation from the everyday quick actions above.
            brandDivider

            quitItem

            // Footer reads the aggregate state from `ds3DriveManager` so it
            // matches the per-drive rows and the menu bar icon (Gap 15).
            menuFooter(
                status: ds3DriveManager.aggregateAppStatus.toString(),
                aggregateStatus: ds3DriveManager.aggregateAppStatus,
                embedSpeed: true
            )
        }
    }

    // MARK: - Brand Divider

    /// Soft brand-coloured separator (Plan 05-12). Replaces the system
    /// `Divider()` so the tray surface feels intentional and matches the
    /// brand chrome from plan 05-11. Inset horizontally so the line reads
    /// as "between sections" rather than slicing the whole window.
    private var brandDivider: some View {
        Rectangle()
            .fill(DS3Colors.brandBorder.opacity(0.4))
            .frame(height: 1)
            .padding(.horizontal, DS3Spacing.xl)
    }

    // MARK: - Logged In Sections

    private var driveListSection: some View {
        ForEach(driveViewModels, id: \.drive.id) { vm in
            TrayDriveRowView(
                driveViewModel: vm,
                onHoverDrive: handleDriveHover,
                onRequestPanelDismiss: { [floatingPanelManager] in
                    floatingPanelManager.dismiss()
                }
            )
        }
    }

    private var addDriveItem: some View {
        TrayMenuItem(
            title: NSLocalizedString("Add a new Drive", comment: "Tray menu add new drive"),
            systemImage: "plus.circle",
            enabled: true
        ) {
            openWindow(id: "io.cubbit.DS3Drive.drive.new")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Tray quick actions. Items are flush with the rest of the menu rows
    /// (no card wrapper) so the whole list reads as a single column —
    /// minimal, no indentation, hover highlight per row provides the only
    /// visual grouping needed.
    @ViewBuilder private var quickActionsSection: some View {
        TrayMenuItem(
            title: NSLocalizedString("Preferences", comment: "Tray open preferences"),
            systemImage: "gearshape"
        ) {
            openWindow(id: "io.cubbit.DS3Drive.preferences")
            NSApp.activate(ignoringOtherApps: true)
        }

        TrayMenuItem(
            title: NSLocalizedString("Open web console", comment: "Tray menu open console button"),
            systemImage: "safari"
        ) {
            if let url = URL(string: ConsoleURLs.baseURL) { openURL(url) }
        }

        TrayMenuItem(
            title: updateManager.isChecking
                ? NSLocalizedString("updates.checking", value: "Checking…", comment: "Update check in progress")
                : updateManager.updateMenuTitle,
            systemImage: updateManager.updateAvailable
                ? "arrow.down.circle.fill"
                : "arrow.down.circle",
            enabled: !updateManager.isChecking,
            accent: updateManager.updateAvailable
        ) {
            if updateManager.updateAvailable {
                updateManager.installUpdate()
            } else {
                triggerUpdateCheck()
            }
        }

        TrayMenuItem(
            title: NSLocalizedString("Help", comment: "Tray menu help"),
            systemImage: "questionmark.circle"
        ) {
            if let url = URL(string: HelpURLs.baseURL) { openURL(url) }
        }
    }

    // MARK: - Shared Components

    private var quitItem: some View {
        TrayMenuItem(
            title: NSLocalizedString("Quit", comment: "Tray menu quit"),
            systemImage: "power"
        ) {
            NSApp.terminate(nil)
        }
    }

    private func menuFooter(
        status: String,
        aggregateStatus: AppStatus = .idle,
        embedSpeed: Bool = false
    ) -> some View {
        Group {
            Spacer()
            TrayMenuFooterView(
                status: status,
                version: DefaultSettings.appVersion,
                build: DefaultSettings.appBuild,
                updateAvailable: updateManager.updateAvailable,
                latestVersion: updateManager.latestVersion,
                aggregateStatus: aggregateStatus,
                driveViewModels: embedSpeed ? driveViewModels : []
            )
        }
    }

    // MARK: - Floating Panels

    private func showRecentFiles(forDriveId driveId: UUID, anchorFrame: NSRect? = nil) {
        guard let vm = driveViewModels.first(where: { $0.drive.id == driveId }) else { return }
        floatingPanelManager.show(.recentFiles(driveId: driveId), anchorScreenFrame: anchorFrame) {
            RecentFilesPanel(driveViewModel: vm)
        }
    }

    // MARK: - Helpers

    private var canAddMoreDrives: Bool {
        ds3DriveManager.drives.count < DefaultSettings.maxDrives
    }

    private func handleDriveHover(driveId: UUID, hovering: Bool, rowFrame: NSRect) {
        if hovering {
            floatingPanelManager.cancelDismissTimer()
            showRecentFiles(forDriveId: driveId, anchorFrame: rowFrame)
        } else {
            floatingPanelManager.scheduleDismiss()
        }
    }

    private func rebuildDriveViewModels() {
        let currentIds = Set(driveViewModels.map(\.drive.id))
        let newDrives = ds3DriveManager.drives
        let newIds = Set(newDrives.map(\.id))

        if currentIds != newIds {
            driveViewModels.forEach { $0.cleanup() }
            driveViewModels = newDrives.map { DS3DriveViewModel(drive: $0) }
        }
    }

    private func signOut() {
        floatingPanelManager.dismiss()

        // Check if a main window already exists before logout,
        // because logout flips isLogged which re-renders any existing window to LoginView.
        let mainWindowExists = NSApp.windows.contains {
            $0.identifier?.rawValue.hasPrefix("io.cubbit.DS3Drive.main") == true && $0.isVisible
        }

        // Disconnect drives FIRST (while credentials still exist) so the extension
        // can handle cleanup gracefully, then delete credentials.
        Task {
            do {
                try await ds3DriveManager.disconnectAll()
            } catch {
                logger
                    .error(
                        "Failed to disconnect drives during sign out: \(error.localizedDescription, privacy: .public)"
                    )
            }

            await MainActor.run {
                ds3Authentication.logout()

                if !mainWindowExists {
                    openWindow(id: "io.cubbit.DS3Drive.main")
                }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

#Preview {
    TrayMenuView()
        .environment(DS3Authentication())
        .environment(AppStatusManager.default())
        .environment(DS3DriveManager(appStatusManager: AppStatusManager.default()))
        .environment(UpdateManager())
}
