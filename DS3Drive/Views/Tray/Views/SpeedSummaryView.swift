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

    var body: some View {
        HStack(spacing: DS3Spacing.sm) {
            if isTransferring {
                speedIndicators
            }
            // Paused, syncing-without-transfers, and idle cases render nothing.
            // The footer's leading status icon + the per-drive rows already
            // convey state — repeating it here was redundant and amplified the
            // tray-flapping bug fixed in DS3DriveManager.handleDriveStatusChange.

            Spacer()
        }
        .padding(.horizontal, DS3Spacing.lg)
        .padding(.vertical, isTransferring ? DS3Spacing.sm : 0)
        .frame(height: isTransferring ? nil : 0)
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
