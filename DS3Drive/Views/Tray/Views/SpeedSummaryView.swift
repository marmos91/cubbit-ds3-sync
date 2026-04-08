import DS3Lib
import SwiftUI

/// Displays aggregate upload/download speed across all drives at the top of the tray menu.
struct SpeedSummaryView: View {
    let driveViewModels: [DS3DriveViewModel]

    private var totalUploadSpeed: Double {
        driveViewModels.compactMap(\.driveStats.uploadSpeedBs).reduce(0, +)
    }

    private var totalDownloadSpeed: Double {
        driveViewModels.compactMap(\.driveStats.downloadSpeedBs).reduce(0, +)
    }

    private var isTransferring: Bool {
        totalUploadSpeed > 0 || totalDownloadSpeed > 0
    }

    private var isSyncing: Bool {
        driveViewModels.contains { $0.driveStatus == .sync }
    }

    private var isIndexing: Bool {
        driveViewModels.contains { $0.driveStatus == .indexing }
    }

    private var allPaused: Bool {
        !driveViewModels.isEmpty && driveViewModels.allSatisfy { $0.driveStatus == .paused }
    }

    var body: some View {
        HStack(spacing: DS3Spacing.sm) {
            if isTransferring {
                speedIndicators
            } else if isSyncing {
                ProgressView()
                    .controlSize(.mini)

                Text(NSLocalizedString("Syncing files…", comment: "Speed summary syncing"))
                    .font(DS3Typography.caption)
                    .foregroundStyle(DS3Colors.brandTextSecondary)
            } else if isIndexing {
                ProgressView()
                    .controlSize(.mini)

                Text(NSLocalizedString("Indexing files…", comment: "Speed summary indexing"))
                    .font(DS3Typography.caption)
                    .foregroundStyle(DS3Colors.brandTextSecondary)
            } else if allPaused {
                Image(.statusPauseBadge)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .foregroundStyle(DS3Colors.statusPaused)

                Text(NSLocalizedString("All drives paused", comment: "Speed summary all paused"))
                    .font(DS3Typography.caption)
                    .foregroundStyle(DS3Colors.brandTextSecondary)
            }
            // Idle case intentionally renders nothing — the tray footer
            // already shows "Idle" with the green pill, so repeating
            // "All drives up to date" here is redundant.

            Spacer()
        }
        .padding(.horizontal, DS3Spacing.lg)
        .padding(.vertical, isIdle ? 0 : DS3Spacing.sm)
        .frame(height: isIdle ? 0 : nil)
    }

    private var isIdle: Bool {
        !isTransferring && !isSyncing && !isIndexing && !allPaused
    }

    @ViewBuilder private var speedIndicators: some View {
        if totalUploadSpeed > 0 {
            Image(systemName: "arrow.up")
                .font(DS3Typography.caption)
                .foregroundStyle(DS3Colors.brandPrimary)

            Text(formatSpeed(totalUploadSpeed))
                .font(DS3Typography.caption.bold())
                .foregroundStyle(DS3Colors.brandPrimary)
        }

        if totalDownloadSpeed > 0 {
            Image(systemName: "arrow.down")
                .font(DS3Typography.caption)
                .foregroundStyle(DS3Colors.brandPrimary)

            Text(formatSpeed(totalDownloadSpeed))
                .font(DS3Typography.caption.bold())
                .foregroundStyle(DS3Colors.brandPrimary)
        }
    }

    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        let kilobyte = 1024.0
        let megabyte = kilobyte * kilobyte

        if bytesPerSecond >= megabyte {
            return String(format: "%.1f MB/s", bytesPerSecond / megabyte)
        }
        return String(format: "%.1f KB/s", bytesPerSecond / kilobyte)
    }
}
