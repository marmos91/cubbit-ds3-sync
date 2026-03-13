import SwiftUI
import os.log
import DS3Lib

/// Represents which side panel is currently displayed.
enum SidePanel: Equatable {
    case recentFiles(driveId: UUID)
    case connectionInfo
}

struct TrayMenuView: View {
    @Environment(\.openURL) var openURL
    @Environment(\.openWindow) var openWindow

    @Environment(DS3Authentication.self) var ds3Authentication: DS3Authentication
    @Environment(DS3DriveManager.self) var ds3DriveManager: DS3DriveManager
    @Environment(AppStatusManager.self) var appStatusManager: AppStatusManager

    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)

    @State private var floatingPanelManager = FloatingPanelManager()
    @State private var coordinatorURL = ""
    @State private var tenantName = ""
    @State private var driveViewModels: [DS3DriveViewModel] = []

    var body: some View {
        mainTrayContent
            .frame(width: 310)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                WindowAccessor { window in
                    floatingPanelManager.setTrayWindow(window)
                }
            )
            .onAppear {
                coordinatorURL = loadCoordinatorURL()
                tenantName = loadTenantName()
                rebuildDriveViewModels()
            }
            .onChange(of: ds3DriveManager.drives.count) {
                rebuildDriveViewModels()
            }
    }

    // MARK: - Main Tray Content

    @ViewBuilder
    private var mainTrayContent: some View {
        VStack(spacing: 0) {
            // Signed in as
            if ds3Authentication.isLogged, let account = ds3Authentication.account {
                HStack {
                    Image(systemName: "person.circle")
                        .font(DS3Typography.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: NSLocalizedString("Signed in as %@", comment: "Signed in label"), account.primaryEmail))
                        .font(DS3Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, DS3Spacing.lg)
                .padding(.vertical, DS3Spacing.sm)

                Divider()
            }

            // Speed summary
            SpeedSummaryView(driveViewModels: driveViewModels)

            Divider()

            // Drive rows
            ForEach(driveViewModels, id: \.drive.id) { vm in
                TrayDriveRowView(
                    driveViewModel: vm,
                    onHoverDrive: { driveId, hovering in
                        if hovering {
                            floatingPanelManager.cancelDismissTimer()
                            showRecentFiles(forDriveId: driveId)
                        } else {
                            floatingPanelManager.scheduleDismiss()
                        }
                    }
                )

                Divider()
            }

            // Add new drive
            TrayMenuItem(
                title: canAddMoreDrives
                    ? NSLocalizedString("Add a new Drive", comment: "Tray menu add new drive")
                    : NSLocalizedString("You have reached the maximum number of Drives", comment: "Tray menu add new drive disabled"),
                enabled: canAddMoreDrives
            ) {
                openWindow(id: "io.cubbit.DS3Drive.drive.new")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            // Quick actions
            TrayMenuItem(
                title: NSLocalizedString("Help", comment: "Tray menu help")
            ) {
                openURL(URL(string: HelpURLs.baseURL)!)
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
                title: NSLocalizedString("Open web console", comment: "Tray menu open console button")
            ) {
                openURL(URL(string: ConsoleURLs.baseURL)!)
            }

            Divider()

            // Connection Info row
            TrayMenuItem(
                title: NSLocalizedString("Connection Info", comment: "Tray menu connection info")
            ) {
                if floatingPanelManager.activePanel == .connectionInfo {
                    floatingPanelManager.dismiss()
                } else {
                    showConnectionInfo()
                }
            }

            Divider()

            // Sign Out
            TrayMenuItem(
                title: NSLocalizedString("Sign Out", comment: "Tray menu sign out")
            ) {
                Task { await signOut() }
            }

            Divider()

            TrayMenuItem(
                title: NSLocalizedString("Quit", comment: "Tray menu quit")
            ) {
                NSApplication.shared.terminate(self)
            }

            Spacer()

            Divider()

            // Footer — show idle when not logged in to avoid misleading "Synchronizing"
            TrayMenuFooterView(
                status: (ds3Authentication.isLogged ? appStatusManager.status : .idle).toString(),
                version: DefaultSettings.appVersion,
                build: DefaultSettings.appBuild
            )
        }
    }

    // MARK: - Floating Panels

    private func showRecentFiles(forDriveId driveId: UUID) {
        guard let vm = driveViewModels.first(where: { $0.drive.id == driveId }) else { return }
        floatingPanelManager.show(.recentFiles(driveId: driveId)) {
            RecentFilesPanel(
                recentFiles: vm.recentFiles,
                driveViewModel: vm
            )
        }
    }

    private func showConnectionInfo() {
        floatingPanelManager.show(.connectionInfo) {
            ConnectionInfoPanel(
                coordinatorURL: coordinatorURL,
                s3Endpoint: ds3Authentication.account?.endpointGateway ?? NSLocalizedString("N/A", comment: "Not available"),
                tenant: tenantName,
                consoleURL: ConsoleURLs.baseURL,
                onClose: { floatingPanelManager.dismiss() }
            )
        }
    }

    // MARK: - Helpers

    var canAddMoreDrives: Bool {
        ds3DriveManager.drives.count < DefaultSettings.maxDrives
    }

    private func rebuildDriveViewModels() {
        let currentIds = Set(driveViewModels.map(\.drive.id))
        let newDrives = ds3DriveManager.drives

        // Only rebuild if the drive set changed
        let newIds = Set(newDrives.map(\.id))
        if currentIds != newIds {
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

    @MainActor
    private func signOut() async {
        do {
            for drive in ds3DriveManager.drives {
                try await ds3DriveManager.disconnect(driveWithId: drive.id)
            }
            try ds3Authentication.logout()
        } catch {
            logger.error("Sign out cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

#Preview {
    TrayMenuView()
        .environment(
            DS3Authentication()
        )
        .environment(
            AppStatusManager.default()
        )
        .environment(
            DS3DriveManager(appStatusManager: AppStatusManager.default())
        )
}
