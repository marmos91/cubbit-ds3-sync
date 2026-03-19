#if os(iOS)
import SwiftUI
import DS3Lib

/// Individual drive card showing status dot, name, bucket/prefix path, transfer speed, and swipe actions.
struct DriveCardView: View {
    let drive: DS3Drive
    let status: DS3DriveStatus
    let speed: Double?
    let onDisconnect: () -> Void
    let onPauseResume: () -> Void

    var body: some View {
        HStack(spacing: IOSSpacing.md) {
            ZStack(alignment: .bottomLeading) {
                Image(.rawDriveIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)

                statusBadgeImage
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .offset(x: -2, y: 2)
            }
            .accessibilityLabel(statusLabel)

            VStack(alignment: .leading, spacing: IOSSpacing.xs) {
                Text(drive.name)
                    .font(IOSTypography.headline)
                    .lineLimit(1)

                Label {
                    Text("\(drive.syncAnchor.bucket.name)/\(drive.syncAnchor.prefix ?? "")")
                } icon: {
                    Image(.bucketIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                }
                .font(IOSTypography.caption)
                .foregroundStyle(IOSColors.secondaryText)
                .lineLimit(1)
            }

            Spacer()

            if let speed, status == .sync {
                Text(IOSDriveViewModel.formatSpeed(speed))
                    .font(IOSTypography.caption)
                    .foregroundStyle(IOSColors.secondaryText)
            }
        }
        .padding(IOSSpacing.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drive \(drive.name), status \(statusLabel), bucket \(drive.syncAnchor.bucket.name)")
        .hoverEffect(.highlight)
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

    // MARK: - Helpers

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
