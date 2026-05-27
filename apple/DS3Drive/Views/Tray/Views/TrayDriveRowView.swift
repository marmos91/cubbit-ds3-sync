import DS3Lib
import FileProvider
import os.log
import SwiftUI

struct TrayDriveRowView: View {
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.app.rawValue)
    @Environment(\.openURL) var openURL
    @Environment(DS3DriveManager.self) var ds3DriveManager: DS3DriveManager

    @State private var driveViewModel: DS3DriveViewModel

    init(
        driveViewModel: DS3DriveViewModel,
        onHoverDrive: ((UUID, Bool, NSRect) -> Void)? = nil,
        onRequestPanelDismiss: (() -> Void)? = nil
    ) {
        self._driveViewModel = State(initialValue: driveViewModel)
        self.onHoverDrive = onHoverDrive
        self.onRequestPanelDismiss = onRequestPanelDismiss
    }

    @State private var isHover: Bool = false
    @State private var screenFrame: NSRect = .zero

    /// Callback to trigger the recent files side panel in TrayMenuView.
    /// Parameters: driveId, isHovering, row screen frame.
    var onHoverDrive: ((UUID, Bool, NSRect) -> Void)?

    /// Synchronous panel-dismiss callback. Used by the gear menu to clear
    /// the floating Recent Files panel BEFORE its 150ms scheduled-dismiss
    /// timer fires — otherwise the panel sits at `.statusBar` level next to
    /// the tray and AppKit's hit-test routes the gear click to the wrong
    /// window, causing the SwiftUI Menu to never present.
    var onRequestPanelDismiss: (() -> Void)?

    var body: some View {
        // Card-style drive row (Plan 05-12, Sync Share 2.0 layout):
        // brandSurface rounded card + leading accent stripe coloured by
        // the per-drive sync state. See 05-12-FIGMA-LAYOUT.md.
        HStack(spacing: 0) {
            // Leading accent stripe — colour reflects current drive status
            Rectangle()
                .fill(stripeColor)
                .frame(width: 3)

            HStack(spacing: DS3Spacing.sm) {
                driveStatusIcon
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(driveViewModel.drive.name)
                        .font(DS3Typography.headline)
                        .foregroundStyle(DS3Colors.brandTextPrimary)
                        .lineLimit(1)

                    Text(driveViewModel.syncAnchorString())
                        .font(DS3Typography.caption)
                        .foregroundStyle(DS3Colors.brandTextSecondary)
                        .lineLimit(1)

                    metricsRow
                }

                Spacer()

                gearMenu
            }
            .padding(.horizontal, DS3Spacing.md)
            .padding(.vertical, DS3Spacing.sm)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DS3Colors.brandSurface)
        )
        .overlay(
            // Hover-tint overlay. MUST disable hit testing — SwiftUI filled
            // shapes capture clicks even at opacity 0, which was eating
            // taps on the gear `NSButton` underneath and preventing the
            // NSMenu from popping. Took an hour to find. Don't remove.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DS3Colors.brandPrimary.opacity(isHover ? 0.08 : 0))
                .allowsHitTesting(false)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, DS3Spacing.lg)
        .padding(.vertical, DS3Spacing.xs)
        .background(ScreenFrameReader { screenFrame = $0 })
        .onHover { hovering in
            isHover = hovering
            // When the user hovers a row, the side panel takes ownership of the
            // popover slot — any open gear menu must dismiss (Gap 10).
            if hovering {
                driveViewModel.activePopover = .sidePanel(driveID: driveViewModel.drive.id)
            } else if case let .sidePanel(id) = driveViewModel.activePopover,
                      id == driveViewModel.drive.id {
                driveViewModel.activePopover = .none
            }
            onHoverDrive?(driveViewModel.drive.id, hovering, screenFrame)
        }
        .contextMenu {
            driveContextMenuItems
        }
    }

    // MARK: - Accent Stripe

    /// Per-drive accent stripe colour mapped from the current sync state.
    /// See `05-12-FIGMA-LAYOUT.md` (Drive Row section).
    private var stripeColor: Color {
        switch driveViewModel.driveStatus {
        case .idle: DS3Colors.statusSynced
        case .sync: DS3Colors.statusSyncing
        case .error: DS3Colors.statusError
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

    @ViewBuilder private var statusBadge: some View {
        switch driveViewModel.driveStatus {
        case .idle:
            Image(.statusIdleBadge).resizable().scaledToFit()
        case .sync:
            Image(.statusSyncBadge).resizable().scaledToFit()
        case .error:
            Image(.statusErrorBadge).resizable().scaledToFit()
        }
    }

    // MARK: - Metrics Row

    private var metricsRow: some View {
        HStack(spacing: DS3Spacing.md) {
            // Current speed or status text
            if driveViewModel.driveStats.isTransferring {
                if let uploadSpeed = driveViewModel.driveStats.uploadSpeedBs {
                    Label {
                        Text(formatSpeed(uploadSpeed))
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "arrow.up")
                    }
                    .font(DS3Typography.footnote)
                    .foregroundStyle(DS3Colors.brandTextSecondary)
                }
                if let downloadSpeed = driveViewModel.driveStats.downloadSpeedBs {
                    Label {
                        Text(formatSpeed(downloadSpeed))
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "arrow.down")
                    }
                    .font(DS3Typography.footnote)
                    .foregroundStyle(DS3Colors.brandTextSecondary)
                }
            } else if driveViewModel.driveStatus == .sync {
                Label {
                    Text(NSLocalizedString("Syncing…", comment: "Drive row syncing status"))
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolEffect(.pulse, options: .repeating)
                }
                .font(DS3Typography.footnote)
                .foregroundStyle(DS3Colors.brandTextSecondary)
            }

            // Last update time
            Label {
                Text(formatRelativeTime(driveViewModel.driveStats.lastUpdate))
                    .monospacedDigit()
            } icon: {
                Image(systemName: "clock")
            }
            .font(DS3Typography.footnote)
            .foregroundStyle(DS3Colors.brandTextSecondary)
        }
    }

    // MARK: - Gear Menu

    /// Bulletproof gear menu: a real `NSButton` (see `GearMenuButton` in
    /// `TrayDriveGearMenu.swift`) that pops a real `NSMenu` on click.
    /// Replaces the previous SwiftUI `Menu` which suffered intermittent
    /// hit-test failures on macOS Sequoia inside `MenuBarExtra`. Going
    /// through AppKit primitives sidesteps every SwiftUI Menu quirk.
    private var gearMenu: some View {
        GearMenuButton(
            menuBuilder: {
                TrayDriveGearMenu.build(
                    driveViewModel: driveViewModel,
                    ds3DriveManager: ds3DriveManager,
                    openURL: openURL,
                    logger: logger
                )
            },
            onClick: {
                // Synchronously dismiss the floating Recent Files panel
                // before the menu pops so its window stops competing for
                // clicks at `.statusBar` level next to the tray.
                onRequestPanelDismiss?()
                driveViewModel.activePopover = .gearMenu(driveID: driveViewModel.drive.id)
            }
        )
        .frame(width: 22, height: 22)
    }

    // MARK: - Shared Context Menu Items

    @ViewBuilder private var driveContextMenuItems: some View {
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
                do {
                    try await viewModel.openFinder()
                } catch {
                    // Finder open failure is non-critical
                }
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

        // Gap 16: the legacy per-drive gear action that opened a window scene
        // from the old bundle prefix has been removed — the scene no longer
        // existed and the call raised a SwiftUI runtime error. The remaining
        // gear entries (Disconnect, View in Finder, View in web console,
        // Refresh, Reset Sync, Empty Trash, Pause, Copy S3 Path) cover the
        // per-drive management surface.
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

        // Empty Trash
        Button(role: .destructive) {
            let driveId = driveViewModel.drive.id
            do {
                try SharedData.default().setEmptyTrashRequest(forDrive: driveId, requested: true)
                logger.info("Empty trash requested for drive \(driveId)")
            } catch {
                logger.error("Error requesting empty trash: \(error.localizedDescription)")
            }
        } label: {
            Label(NSLocalizedString("Empty Trash", comment: "Drive menu empty trash"), systemImage: "trash.slash")
        }

        Divider()

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
        }
        return String(format: "%.1f KB/s", bytesPerSecond / kilobyte)
    }

    private func formatRelativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))

        if seconds < 60 {
            return NSLocalizedString("Just now", comment: "Relative time just now")
        }
        if seconds < 3600 {
            let minutes = seconds / 60
            return String(format: NSLocalizedString("%d min ago", comment: "Relative time minutes"), minutes)
        }
        let hours = seconds / 3600
        return String(format: NSLocalizedString("%d hr ago", comment: "Relative time hours"), hours)
    }
}

#Preview {
    VStack(spacing: 0) {
        TrayDriveRowView(
            driveViewModel: DS3DriveViewModel(
                drive: PreviewData.drive
            )
        )
        .environment(
            DS3DriveManager(appStatusManager: AppStatusManager.default())
        )
    }
}
