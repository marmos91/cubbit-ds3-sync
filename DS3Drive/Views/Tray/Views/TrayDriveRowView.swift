import DS3Lib
import FileProvider
import os.log
import SwiftUI

struct TrayDriveRowView: View {
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)
    @Environment(\.openWindow) var openWindow
    @Environment(\.openURL) var openURL
    @Environment(DS3DriveManager.self) var ds3DriveManager: DS3DriveManager

    @State var driveViewModel: DS3DriveViewModel

    @State private var isHover: Bool = false
    @State private var screenFrame: NSRect = .zero

    /// Callback to trigger the recent files side panel in TrayMenuView.
    /// Parameters: driveId, isHovering, row screen frame.
    var onHoverDrive: ((UUID, Bool, NSRect) -> Void)?

    var body: some View {
        HStack(spacing: DS3Spacing.sm) {
            // Drive icon with status badge
            driveStatusIcon
                .frame(width: 28, height: 28)

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
        .background(ScreenFrameReader { screenFrame = $0 })
        .onHover { hovering in
            isHover = hovering
            onHoverDrive?(driveViewModel.drive.id, hovering, screenFrame)
        }
        .contextMenu {
            driveContextMenuItems
        }
    }

    // MARK: - Drive Status Icon

    private var driveStatusIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(.rawDriveIcon)
                .resizable()
                .scaledToFit()

            statusBadge
                .frame(width: 12, height: 12)
                .offset(x: -2, y: 2)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch driveViewModel.driveStatus {
        case .idle:
            Image(.statusIdleBadge).resizable().scaledToFit()
        case .sync, .indexing:
            Image(.statusSyncBadge).resizable().scaledToFit()
        case .error:
            Image(.statusErrorBadge).resizable().scaledToFit()
        case .paused:
            Image(.statusPauseBadge).resizable().scaledToFit()
                .foregroundStyle(DS3Colors.statusPaused)
        }
    }

    // MARK: - Metrics Row

    private var metricsRow: some View {
        HStack(spacing: DS3Spacing.md) {
            // Current speed or status text
            if driveViewModel.driveStatus == .paused {
                Label {
                    Text(NSLocalizedString("Paused", comment: "Drive row paused status"))
                } icon: {
                    Image(systemName: "pause.circle")
                }
                .font(DS3Typography.footnote)
                .foregroundStyle(DS3Colors.statusPaused)
            } else if driveViewModel.driveStats.isTransferring {
                if let uploadSpeed = driveViewModel.driveStats.uploadSpeedBs {
                    Label {
                        Text(formatSpeed(uploadSpeed))
                    } icon: {
                        Image(systemName: "arrow.up")
                    }
                    .font(DS3Typography.footnote)
                    .foregroundStyle(.secondary)
                }
                if let downloadSpeed = driveViewModel.driveStats.downloadSpeedBs {
                    Label {
                        Text(formatSpeed(downloadSpeed))
                    } icon: {
                        Image(systemName: "arrow.down")
                    }
                    .font(DS3Typography.footnote)
                    .foregroundStyle(.secondary)
                }
            } else if driveViewModel.driveStatus == .indexing {
                Label {
                    Text(NSLocalizedString("Indexing…", comment: "Drive row indexing status"))
                } icon: {
                    Image(systemName: "magnifyingglass")
                }
                .font(DS3Typography.footnote)
                .foregroundStyle(.secondary)
            } else if driveViewModel.driveStatus == .sync {
                Label {
                    Text(NSLocalizedString("Syncing…", comment: "Drive row syncing status"))
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
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

        Button {
            let viewModel = driveViewModel
            Task {
                do {
                    try await viewModel.resetSync()
                } catch {
                    logger.error("Error resetting sync: \(error.localizedDescription)")
                }
            }
        } label: {
            Label(
                NSLocalizedString("Reset Sync", comment: "Drive menu reset sync"),
                systemImage: "arrow.counterclockwise"
            )
        }

        Divider()

        // Pause / Resume
        Button {
            let driveId = driveViewModel.drive.id
            let isPaused = driveViewModel.driveStatus == .paused
            do {
                try SharedData.default().setDrivePaused(driveId, paused: !isPaused)

                if isPaused {
                    // Resume: go to syncing so extension re-checks for pending work
                    driveViewModel.driveStatus = .sync
                    ds3DriveManager.notifyDriveResumedFromUI(driveId: driveId)

                    // Signal the enumerator to trigger a fresh scan
                    Task {
                        try? await NSFileProviderManager(
                            for: driveViewModel.fileProviderDomain()
                        )?.signalEnumerator(for: .rootContainer)
                    }
                } else {
                    // Pause: stop immediately
                    driveViewModel.driveStatus = .paused
                    ds3DriveManager.notifyDrivePausedFromUI(driveId: driveId)
                }
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
