import SwiftUI
import DS3Lib

/// Displays aggregate upload/download speed across all drives at the top of the tray menu.
struct SpeedSummaryView: View {
    let driveViewModels: [DS3DriveViewModel]

    private var totalSpeed: Double {
        driveViewModels.compactMap(\.driveStats.currentSpeedBs).reduce(0, +)
    }

    private var isTransferring: Bool {
        totalSpeed > 0
    }

    private var isSyncing: Bool {
        driveViewModels.contains { $0.driveStatus == .sync }
    }

    private var isIndexing: Bool {
        driveViewModels.contains { $0.driveStatus == .indexing }
    }

    var body: some View {
        HStack(spacing: DS3Spacing.sm) {
            if isTransferring {
                Image(systemName: "arrow.up.arrow.down")
                    .font(DS3Typography.caption)
                    .foregroundStyle(DS3Colors.accent)

                Text(formatSpeed(totalSpeed))
                    .font(DS3Typography.caption)
                    .foregroundStyle(DS3Colors.secondaryText)
            } else if isSyncing {
                ProgressView()
                    .controlSize(.mini)

                Text(NSLocalizedString("Syncing files…", comment: "Speed summary syncing"))
                    .font(DS3Typography.caption)
                    .foregroundStyle(DS3Colors.secondaryText)
            } else if isIndexing {
                ProgressView()
                    .controlSize(.mini)

                Text(NSLocalizedString("Indexing files…", comment: "Speed summary indexing"))
                    .font(DS3Typography.caption)
                    .foregroundStyle(DS3Colors.secondaryText)
            } else {
                Image(systemName: "checkmark.circle")
                    .font(DS3Typography.caption)
                    .foregroundStyle(DS3Colors.statusSynced)

                Text(NSLocalizedString("All drives up to date", comment: "Speed summary idle"))
                    .font(DS3Typography.caption)
                    .foregroundStyle(DS3Colors.secondaryText)
            }

            Spacer()
        }
        .padding(.horizontal, DS3Spacing.lg)
        .padding(.vertical, DS3Spacing.sm)
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
}
