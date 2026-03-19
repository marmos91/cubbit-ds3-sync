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
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(IOSColors.accent)

                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .offset(x: -2, y: 2)
            }
            .accessibilityLabel(statusLabel)

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

    private var statusColor: Color {
        IOSDriveViewModel.statusColor(for: status)
    }

    private var statusLabel: String {
        IOSDriveViewModel.statusLabel(for: status)
    }
}
#endif
