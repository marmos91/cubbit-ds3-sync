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
            // Status dot
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .accessibilityLabel(statusLabel)

            // Drive info
            VStack(alignment: .leading, spacing: IOSSpacing.xs) {
                Text(drive.name)
                    .font(IOSTypography.headline)
                    .lineLimit(1)

                Text("s3://\(drive.syncAnchor.bucket.name)/\(drive.syncAnchor.prefix ?? "")")
                    .font(IOSTypography.caption)
                    .foregroundStyle(IOSColors.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            // Transfer speed (visible only when syncing)
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
            if status == .paused {
                Button {
                    onPauseResume()
                } label: {
                    Label("Resume", systemImage: "play.circle")
                }
                .tint(.green)
            } else {
                Button {
                    onPauseResume()
                } label: {
                    Label("Pause", systemImage: "pause.circle")
                }
                .tint(.orange)
            }
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

    private var statusColor: Color {
        switch status {
        case .idle: IOSColors.statusSynced
        case .sync, .indexing: IOSColors.statusSyncing
        case .error: IOSColors.statusError
        case .paused: IOSColors.statusPaused
        }
    }

    private var statusLabel: String {
        switch status {
        case .idle: "Synced"
        case .sync: "Syncing"
        case .indexing: "Indexing"
        case .error: "Error"
        case .paused: "Paused"
        }
    }
}
#endif
