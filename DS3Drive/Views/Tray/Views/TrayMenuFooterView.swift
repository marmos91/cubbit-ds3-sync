import DS3Lib
import SwiftUI

struct TrayMenuFooterView: View {
    var status: String
    var version: String
    var build: String
    var updateAvailable: Bool = false
    var latestVersion: String?
    /// The aggregate app status used to render the leading state icon (Gap 13).
    /// Defaults to `.idle` so previews and the logged-out menu render cleanly.
    var aggregateStatus: AppStatus = .idle
    /// When provided, shows inline aggregate transfer speeds in the footer
    /// during sync activity. Plan 05-18b iteration: SpeedSummaryView used to
    /// be a separate row at the top of the tray; embedding it here means
    /// the footer is the single live status surface (no redundant rows).
    var driveViewModels: [DS3DriveViewModel] = []

    var body: some View {
        HStack(spacing: DS3Spacing.xs) {
            Image(systemName: statusIcon.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusIcon.color)

            Text(status)
                .font(DS3Typography.footnote)
                .foregroundStyle(DS3Colors.brandTextSecondary)

            // Inline speed indicators when any drive is actively transferring.
            if !driveViewModels.isEmpty {
                SpeedSummaryView(driveViewModels: driveViewModels)
                    .fixedSize()
            }

            Spacer()

            if updateAvailable, let latestVersion {
                Text("Update available: \(latestVersion)")
                    .font(DS3Typography.footnote)
                    .monospacedDigit()
                    .foregroundStyle(DS3Colors.brandPrimary)
            } else {
                // Tap-to-copy version (Raycast / Linear delight). Power
                // users can grab the build string for bug reports without
                // opening Preferences.
                Text("Version \(version) (\(build))")
                    .font(DS3Typography.footnote)
                    .monospacedDigit()
                    .foregroundStyle(DS3Colors.brandTextSecondary)
                    .onTapGesture {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(version) (\(build))", forType: .string)
                    }
                    .help(NSLocalizedString(
                        "tray.footer.copyVersion",
                        value: "Click to copy version",
                        comment: "Tray footer version copy tooltip"
                    ))
            }
        }
        .padding(.horizontal, DS3Spacing.lg)
        .padding(.vertical, DS3Spacing.sm)
        // Plan 05-12: tinted footer chrome with a soft top border so the
        // footer sits visually below the action list.
        .background(DS3Colors.brandSurface.opacity(0.6))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DS3Colors.brandBorder.opacity(0.4))
                .frame(height: 1)
        }
    }

    /// Display descriptor for the footer state icon. Static — no animation.
    /// The previous spinning syncing icon flapped under transient sync pulses
    /// (e.g. enumeration bursts), which read as visual noise rather than
    /// progress. State transitions are conveyed by icon shape + color now.
    private struct StatusIcon {
        let name: String
        let color: Color
    }

    /// Maps the aggregate status to an SF Symbol + color.
    private var statusIcon: StatusIcon {
        switch aggregateStatus {
        case .idle:
            StatusIcon(name: "checkmark.circle.fill", color: DS3Colors.statusSynced)
        case .syncing:
            StatusIcon(name: "arrow.triangle.2.circlepath", color: DS3Colors.statusSyncing)
        case .error:
            StatusIcon(name: "exclamationmark.triangle.fill", color: DS3Colors.statusError)
        case .offline:
            StatusIcon(name: "wifi.slash", color: DS3Colors.brandTextSecondary)
        case .info:
            StatusIcon(name: "info.circle.fill", color: DS3Colors.statusSyncing)
        }
    }
}

#Preview {
    TrayMenuFooterView(
        status: "Idle",
        version: "1.0.0",
        build: "1"
    )
}
