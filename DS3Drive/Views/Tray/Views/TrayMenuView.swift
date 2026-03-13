import SwiftUI
import DS3Lib

struct TrayMenuView: View {
    @Environment(\.openURL) var openURL
    @Environment(\.openWindow) var openWindow

    @Environment(DS3Authentication.self) var ds3Authentication: DS3Authentication
    @Environment(DS3DriveManager.self) var ds3DriveManager: DS3DriveManager
    @Environment(AppStatusManager.self) var appStatusManager: AppStatusManager

    @State private var coordinatorURL = ""
    @State private var tenantName = ""

    var body: some View {
        ZStack {
            Color(.background)
                .ignoresSafeArea()

            VStack(spacing: 0) {

                // MARK: - Drives list

                ForEach(ds3DriveManager.drives, id: \.name) { drive in
                    TrayDriveRowView(
                        driveViewModel: DS3DriveViewModel(drive: drive)
                    )

                    Divider()
                }

                TrayMenuItem(
                    title: canAddMoreDrives ? NSLocalizedString("Add a new Drive", comment: "Tray menu add new drive") : NSLocalizedString("You have reached the maximum number of Drives", comment: "Tray menu add new drive disabled"),
                    enabled: canAddMoreDrives
                ) {
                    openWindow(id: "io.cubbit.DS3Drive.drive.new")
                }

                Divider()

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
                }

                Divider()

                TrayMenuItem(
                    title: NSLocalizedString("Open web console ", comment: "Tray menu open console button")
                ) {
                    openURL(URL(string: ConsoleURLs.baseURL)!)
                }

                Divider()

                // MARK: - Sign Out

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

                // MARK: - Connection Info

                if ds3Authentication.isLogged {
                    Divider()

                    VStack(alignment: .leading, spacing: 0) {
                        if let account = ds3Authentication.account {
                            ConnectionInfoRow(label: "Signed in as", value: account.primaryEmail)
                        }
                        ConnectionInfoRow(label: "Coordinator", value: coordinatorURL)
                        ConnectionInfoRow(label: "S3 Endpoint", value: ds3Authentication.account?.endpointGateway ?? "N/A")
                        ConnectionInfoRow(label: "Tenant", value: tenantName)
                        ConnectionInfoRow(label: "Console", value: ConsoleURLs.baseURL)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .onAppear {
                        coordinatorURL = loadCoordinatorURL()
                        tenantName = loadTenantName()
                    }
                }

                Divider()

                TrayMenuFooterView(
                    status: appStatusManager.status.toString(),
                    version: DefaultSettings.appVersion,
                    build: DefaultSettings.appBuild
                )
            }
        }
        .frame(
            minWidth: 310,
            maxWidth: 310
        )
        .fixedSize(horizontal: true, vertical: false)

    }

    var canAddMoreDrives: Bool {
        ds3DriveManager.drives.count < DefaultSettings.maxDrives
    }

    // MARK: - Helpers

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
            // Remove all File Provider domains first
            for drive in ds3DriveManager.drives {
                try await ds3DriveManager.disconnect(driveWithId: drive.id)
            }
            // Clean auth (tokens, account, drives, API keys) but preserve tenant/coordinator URL
            try ds3Authentication.logout()
        } catch {
            // Log but don't block -- best effort cleanup
        }
    }
}

// MARK: - ConnectionInfoRow

private struct ConnectionInfoRow: View {
    let label: String
    let value: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(copied ? "Copied" : value)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .onTapGesture {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
        }
        .padding(.vertical, 2)
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
