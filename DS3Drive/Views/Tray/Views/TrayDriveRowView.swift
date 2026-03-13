import SwiftUI
import os.log
import DS3Lib

struct TrayDriveRowView: View {
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)
    @Environment(\.openWindow) var openWindow
    @Environment(\.openURL) var openURL
    @Environment(DS3DriveManager.self) var ds3DriveManager: DS3DriveManager

    @State var driveViewModel: DS3DriveViewModel

    @State private var isHover: Bool = false

    /// Callback to trigger the recent files side panel in TrayMenuView
    var onTapDrive: ((UUID) -> Void)?

    var body: some View {
        HStack(spacing: DS3Spacing.sm) {
            // Status dot indicator
            statusDot

            VStack(alignment: .leading, spacing: 2) {
                Text(driveViewModel.drive.name)
                    .font(DS3Typography.body)
                    .lineLimit(1)

                Text(driveViewModel.syncAnchorString())
                    .font(DS3Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // Metrics row
                metricsRow
            }

            Spacer()

            // Gear menu
            gearMenu
        }
        .padding(.horizontal, DS3Spacing.lg)
        .padding(.vertical, DS3Spacing.sm)
        .background(isHover ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.15) : Color.clear)
        .onTapGesture {
            onTapDrive?(driveViewModel.drive.id)
        }
        .onHover { hovering in
            isHover = hovering
        }
        .contextMenu {
            driveContextMenuItems
        }
    }

    // MARK: - Status Dot

    @ViewBuilder
    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
    }

    private var statusColor: Color {
        switch driveViewModel.driveStatus {
        case .idle:
            return DS3Colors.statusSynced
        case .sync, .indexing:
            return DS3Colors.statusSyncing
        case .error:
            return DS3Colors.statusError
        case .paused:
            return DS3Colors.statusPaused
        }
    }

    // MARK: - Metrics Row

    @ViewBuilder
    private var metricsRow: some View {
        HStack(spacing: DS3Spacing.md) {
            // Current speed or status
            if let speed = driveViewModel.driveStats.currentSpeedBs {
                Label {
                    Text(formatSpeed(speed))
                } icon: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .font(DS3Typography.footnote)
                .foregroundStyle(.secondary)
            }

            // Last update time
            Label {
                Text(formatRelativeTime(driveViewModel.driveStats.lastUpdate))
            } icon: {
                Image(systemName: "clock")
            }
            .font(DS3Typography.footnote)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Gear Menu

    @ViewBuilder
    private var gearMenu: some View {
        Menu {
            driveContextMenuItems
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .menuStyle(BorderlessButtonMenuStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Shared Context Menu Items

    @ViewBuilder
    private var driveContextMenuItems: some View {
        Button {
            let manager = ds3DriveManager
            let driveId = driveViewModel.drive.id
            Task {
                do {
                    try await manager.disconnect(driveWithId: driveId)
                } catch {
                    logger.error("Error disconnecting drive: \(error.localizedDescription)")
                }
            }
        } label: {
            Label(NSLocalizedString("Disconnect", comment: "Drive menu disconnect"), systemImage: "eject")
        }

        Button {
            let viewModel = driveViewModel
            Task {
                try await viewModel.openFinder()
            }
        } label: {
            Label(NSLocalizedString("View in Finder", comment: "Drive menu view in Finder"), systemImage: "folder")
        }

        Button {
            if let consoleURL = driveViewModel.consoleURL() {
                openURL(consoleURL)
            }
        } label: {
            Label(NSLocalizedString("View in web console", comment: "Drive menu view in console"), systemImage: "globe")
        }

        Button {
            openWindow(id: "io.cubbit.CubbitDS3Sync.drive.manage", value: driveViewModel.drive.id)
        } label: {
            Label(NSLocalizedString("Manage", comment: "Drive menu manage"), systemImage: "slider.horizontal.3")
        }

        Button {
            let viewModel = driveViewModel
            Task {
                do {
                    try await viewModel.reEnumerate()
                } catch {
                    logger.error("Error refreshing drive: \(error.localizedDescription)")
                }
            }
        } label: {
            Label(NSLocalizedString("Refresh", comment: "Drive menu refresh"), systemImage: "arrow.clockwise")
        }

        Divider()

        // Pause / Resume
        Button {
            let driveId = driveViewModel.drive.id
            let isPaused = driveViewModel.driveStatus == .paused
            do {
                try SharedData.default().setDrivePaused(driveId, paused: !isPaused)
            } catch {
                logger.error("Error toggling pause state: \(error.localizedDescription)")
            }
        } label: {
            if driveViewModel.driveStatus == .paused {
                Label(NSLocalizedString("Resume", comment: "Drive menu resume"), systemImage: "play")
            } else {
                Label(NSLocalizedString("Pause", comment: "Drive menu pause"), systemImage: "pause")
            }
        }

        // Copy S3 Path
        Button {
            let s3Path = buildS3Path()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s3Path, forType: .string)
        } label: {
            Label(NSLocalizedString("Copy S3 Path", comment: "Drive menu copy S3 path"), systemImage: "doc.on.doc")
        }
    }

    // MARK: - Helpers

    private func buildS3Path() -> String {
        var path = driveViewModel.drive.syncAnchor.bucket.name
        if let prefix = driveViewModel.drive.syncAnchor.prefix, !prefix.isEmpty {
            path += "/\(prefix)"
        }
        return path
    }

    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        let kilobyte = 1024.0
        let megabyte = kilobyte * kilobyte

        if bytesPerSecond >= megabyte {
            return String(format: "%.1f MB/s", bytesPerSecond / megabyte)
        } else {
            return String(format: "%.1f KB/s", bytesPerSecond / kilobyte)
        }
    }

    private func formatRelativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))

        if seconds < 60 {
            return NSLocalizedString("Just now", comment: "Relative time just now")
        } else if seconds < 3600 {
            let minutes = seconds / 60
            return String(format: NSLocalizedString("%d min ago", comment: "Relative time minutes"), minutes)
        } else {
            let hours = seconds / 3600
            return String(format: NSLocalizedString("%d hr ago", comment: "Relative time hours"), hours)
        }
    }
}

#Preview {
    VStack(spacing: 0) {
        TrayDriveRowView(
            driveViewModel: DS3DriveViewModel(
                drive: DS3Drive(
                    id: UUID(),
                    name: "My drive",
                    syncAnchor: SyncAnchor(
                        project: Project(
                            id: UUID().uuidString,
                            name: "My Project",
                            description: "My project description",
                            email: "test@cubbit.io",
                            createdAt: "Now",
                            bannedAt: nil,
                            imageUrl: nil,
                            tenantId: UUID().uuidString,
                            rootAccountEmail: nil,
                            users: [
                                IAMUser(
                                    id: "root",
                                    username: "Root",
                                    isRoot: true
                                )
                            ]
                        ),
                        IAMUser: IAMUser(
                            id: "root",
                            username: "Root",
                            isRoot: true
                        ),
                        bucket: Bucket(name: "Personal"),
                        prefix: "folder1"
                    )
                )
            )
        )
        .environment(
            DS3DriveManager(appStatusManager: AppStatusManager.default())
        )
    }
}
