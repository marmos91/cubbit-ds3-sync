#if os(iOS)
import SwiftUI
import DS3Lib

/// Individual drive card showing status, name, bucket/prefix path, and contextual info.
struct DriveCardView: View {
    let drive: DS3Drive
    let status: DS3DriveStatus
    let speed: Double?
    let onDisconnect: () -> Void
    let onPauseResume: () -> Void

    var body: some View {
        HStack(spacing: IOSSpacing.md) {
            // Drive icon with status badge
            ZStack(alignment: .bottomLeading) {
                Image(.rawDriveIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)

                statusBadgeImage
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .offset(x: -3, y: 3)
            }
            .accessibilityLabel(statusLabel)

            VStack(alignment: .leading, spacing: IOSSpacing.xs) {
                Text(drive.name)
                    .font(IOSTypography.headline)
                    .lineLimit(1)

                HStack(spacing: IOSSpacing.xs) {
                    Image(.bucketIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                    Text(bucketPath)
                        .font(IOSTypography.caption)
                        .foregroundStyle(IOSColors.secondaryText)
                        .lineLimit(1)
                }

                // Status row
                statusRow
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, IOSSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drive \(drive.name), status \(statusLabel), bucket \(drive.syncAnchor.bucket.name)")
        .swipeActions(edge: .leading) {
            Button {
                onPauseResume()
            } label: {
                if status == .paused {
                    Label("Resume", systemImage: "play.circle")
                } else {
                    Label("Pause", systemImage: "pause.circle")
                }
            }
            .tint(status == .paused ? .green : .orange)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                onDisconnect()
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        }
    }

    // MARK: - Status Row

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: IOSSpacing.xs) {
            Circle()
                .fill(IOSDriveViewModel.statusColor(for: status))
                .frame(width: 7, height: 7)

            if status == .sync, let speed, speed > 0 {
                Text("\(statusLabel) — \(IOSDriveViewModel.formatSpeed(speed))")
                    .font(IOSTypography.caption)
                    .foregroundStyle(IOSDriveViewModel.statusColor(for: status))
            } else {
                Text(statusLabel)
                    .font(IOSTypography.caption)
                    .foregroundStyle(IOSDriveViewModel.statusColor(for: status))
            }
        }
    }

    // MARK: - Helpers

    private var bucketPath: String {
        let bucket = drive.syncAnchor.bucket.name
        if let prefix = drive.syncAnchor.prefix, !prefix.isEmpty {
            return "\(bucket)/\(prefix)"
        }
        return bucket
    }

    private var statusBadgeImage: Image {
        switch status {
        case .idle: Image(.statusIdleBadge)
        case .sync, .indexing: Image(.statusSyncBadge)
        case .error: Image(.statusErrorBadge)
        case .paused: Image(.statusPauseBadge)
        }
    }

    private var statusLabel: String {
        IOSDriveViewModel.statusLabel(for: status)
    }
}
#endif
