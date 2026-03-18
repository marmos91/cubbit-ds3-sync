#if os(iOS)
import SwiftUI

/// Empty state view shown when no drives have been created.
/// Displays an illustration, heading, body text, and an "Add Drive" button.
struct EmptyDrivesView: View {
    let onAddDrive: () -> Void

    var body: some View {
        VStack(spacing: IOSSpacing.lg) {
            Spacer()

            Image(systemName: "externaldrive.fill.badge.icloud")
                .font(.system(size: 64))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(IOSColors.secondaryText)

            Text("No Drives Yet")
                .font(IOSTypography.title)

            Text("Add a drive to sync your S3 files. You can browse them in the Files app.")
                .font(IOSTypography.body)
                .foregroundStyle(IOSColors.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, IOSSpacing.xl)

            Button("Add Drive") {
                onAddDrive()
            }
            .buttonStyle(IOSPrimaryButtonStyle())
            .frame(maxWidth: 280)

            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No drives yet. Add a drive to sync your S3 files.")
    }
}
#endif
