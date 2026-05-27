#if os(iOS)
    import DS3Lib
    import SwiftUI

    /// Drive row card. Supplies its own brand-bordered container since
    /// it lives inside a plain `VStack` list, not a system `List`.
    struct DriveCardView: View {
        let drive: DS3Drive
        let status: DS3DriveStatus
        let speed: Double?

        var body: some View {
            HStack(spacing: 14) {
                driveIcon

                VStack(alignment: .leading, spacing: 6) {
                    Text(drive.name)
                        .font(.custom("Figtree-SemiBold", size: 17))
                        .foregroundStyle(IOSColors.brandTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 6) {
                        Image(.bucketIcon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                        Text(bucketPath)
                            .font(.custom("Figtree-Regular", size: 13))
                            .foregroundStyle(IOSColors.brandTextSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    statusRow
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IOSColors.brandTextSecondary.opacity(0.7))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(IOSColors.brandBorderSubtle, lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                Text("Drive \(drive.name), status \(statusLabel), bucket \(drive.syncAnchor.bucket.name)")
            )
        }

        // MARK: - Icon with status badge

        private var driveIcon: some View {
            ZStack(alignment: .bottomLeading) {
                Image(.rawDriveIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)

                statusBadgeImage
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .offset(x: -3, y: 3)
            }
            .accessibilityLabel(statusLabel)
        }

        // MARK: - Status Row

        private var statusRow: some View {
            let color = IOSDriveViewModel.statusColor(for: status)
            return HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)

                Text(statusRowText)
                    .font(.custom("Figtree-Medium", size: 12))
                    .foregroundStyle(color)
            }
        }

        private var statusRowText: String {
            if status == .sync, let speed, speed > 0 {
                return "\(statusLabel) — \(IOSDriveViewModel.formatSpeed(speed))"
            }
            return statusLabel
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
            case .sync: Image(.statusSyncBadge)
            case .error: Image(.statusErrorBadge)
            }
        }

        private var statusLabel: String {
            IOSDriveViewModel.statusLabel(for: status)
        }
    }
#endif
