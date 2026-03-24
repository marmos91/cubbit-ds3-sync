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
    @State private var coordinatorURL = ""
    @State private var tenantName = ""
    @State private var driveViewModels: [DS3DriveViewModel] = []

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
        .background(
            WindowAccessor(onWindow: floatingPanelManager.setTrayWindow)
        )
        .onAppear {
            coordinatorURL = loadCoordinatorURL()
            tenantName = loadTenantName()
            rebuildDriveViewModels()
        }
        .onChange(of: ds3DriveManager.drives.map(\.id)) {
            rebuildDriveViewModels()
        }
    }

    // MARK: - Logged Out Menu

    private var loggedOutMenu: some View {
        VStack(spacing: 0) {
            TrayMenuItem(
                title: NSLocalizedString("Sign In", comment: "Tray menu sign in")
            ) {
                openWindow(id: "io.cubbit.DS3Drive.main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            TrayMenuItem(
                title: NSLocalizedString("Help", comment: "Tray menu help")
            ) {
                if let url = URL(string: HelpURLs.baseURL) { openURL(url) }
            }

            Divider()

            quitItem

            menuFooter(status: AppStatus.idle.toString())
        }
    }

    // MARK: - Logged In Menu

    private var loggedInMenu: some View {
        VStack(spacing: 0) {
            signedInHeader

            SpeedSummaryView(driveViewModels: driveViewModels)

            Divider()

            driveListSection

            addDriveItem

            Divider()

            quickActionsSection

            TrayMenuItem(
                title: NSLocalizedString("Sign Out", comment: "Tray menu sign out")
            ) {
                signOut()
            }

            Divider()

            quitItem

            menuFooter(status: appStatusManager.status.toString())
        }
    }

    // MARK: - Logged In Sections

    @ViewBuilder private var signedInHeader: some View {
        if let account = ds3Authentication.account {
            HStack {
                Image(systemName: "person.circle")
                Text(String(
                    format: NSLocalizedString("Signed in as %@", comment: "Signed in label"),
                    account.primaryEmail
                ))
                .lineLimit(1)
                Spacer()
            }
            .font(DS3Typography.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS3Spacing.lg)
            .padding(.vertical, DS3Spacing.sm)

            Divider()
        }
    }

    private var driveListSection: some View {
        ForEach(driveViewModels, id: \.drive.id) { vm in
            TrayDriveRowView(
                driveViewModel: vm,
                onHoverDrive: handleDriveHover
            )

            Divider()
        }
    }

    private var addDriveItem: some View {
        let title = canAddMoreDrives
            ? NSLocalizedString("Add a new Drive", comment: "Tray menu add new drive")
            : NSLocalizedString(
                "You have reached the maximum number of Drives",
                comment: "Tray menu add new drive disabled"
            )

        return TrayMenuItem(title: title, enabled: canAddMoreDrives) {
            openWindow(id: "io.cubbit.DS3Drive.drive.new")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @ViewBuilder private var quickActionsSection: some View {
        TrayMenuItem(
            title: NSLocalizedString("Help", comment: "Tray menu help")
        ) {
            if let url = URL(string: HelpURLs.baseURL) { openURL(url) }
        }

        Divider()

        TrayMenuItem(
            title: NSLocalizedString("Preferences", comment: "Tray open preferences")
        ) {
            openWindow(id: "io.cubbit.DS3Drive.preferences")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        TrayMenuItem(
            title: updateManager.updateMenuTitle,
            accent: updateManager.updateAvailable
        ) {
            if updateManager.updateAvailable {
                updateManager.installUpdate()
            } else {
                Task { await updateManager.checkForUpdates() }
            }
        }

        Divider()

        TrayMenuItem(
            title: NSLocalizedString("Open web console", comment: "Tray menu open console button")
        ) {
            if let url = URL(string: ConsoleURLs.baseURL) { openURL(url) }
        }

        Divider()

        TrayMenuItem(
            title: NSLocalizedString("Connection Info", comment: "Tray menu connection info")
        ) {
            toggleConnectionInfo()
        }

        Divider()
    }

    // MARK: - Shared Components

    private var quitItem: some View {
        TrayMenuItem(
            title: NSLocalizedString("Quit", comment: "Tray menu quit")
        ) {
            NSApp.terminate(nil)
        }
    }

    private func menuFooter(status: String) -> some View {
        Group {
            Spacer()
            Divider()
            TrayMenuFooterView(
                status: status,
                version: DefaultSettings.appVersion,
                build: DefaultSettings.appBuild,
                updateAvailable: updateManager.updateAvailable,
                latestVersion: updateManager.latestVersion
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

    private func showConnectionInfo() {
        let s3Endpoint = ds3Authentication.account?.endpointGateway
            ?? NSLocalizedString("N/A", comment: "Not available")

        floatingPanelManager.show(.connectionInfo) {
            ConnectionInfoPanel(
                coordinatorURL: coordinatorURL,
                s3Endpoint: s3Endpoint,
                tenant: tenantName,
                consoleURL: ConsoleURLs.baseURL,
                onClose: floatingPanelManager.dismiss
            )
        }
    }

    private func toggleConnectionInfo() {
        if floatingPanelManager.activePanel == .connectionInfo {
            floatingPanelManager.dismiss()
        } else {
            showConnectionInfo()
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

    private func loadCoordinatorURL() -> String {
        (try? SharedData.default().loadCoordinatorURLFromPersistence()) ?? CubbitAPIURLs.defaultCoordinatorURL
    }

    private func loadTenantName() -> String {
        let tenant = (try? SharedData.default().loadTenantNameFromPersistence()) ?? ""
        return tenant.isEmpty ? DefaultSettings.defaultTenantName : tenant
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
