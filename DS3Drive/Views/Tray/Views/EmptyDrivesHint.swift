import SwiftUI

/// Empty-state hint shown in the tray when the user is signed in but has not
/// yet created any drives (Plan 05-18b, Gap 23).
///
/// Before this existed the tray rendered nothing between the speed summary and
/// the `Add a new Drive` row, which left new users staring at blank space. The
/// aggregate status row is already gated on `drives.count >= 2` so it cannot
/// fill the gap. This view replaces that emptiness with an actionable nudge.
struct EmptyDrivesHint: View {
    var body: some View {
        VStack(spacing: DS3Spacing.sm) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(DS3Colors.brandTextSecondary)
            Text(
                NSLocalizedString(
                    "tray.empty.title",
                    value: "No drives yet",
                    comment: "Tray empty-state title when the user has no drives"
                )
            )
            .font(DS3Typography.bodyMedium)
            .foregroundStyle(DS3Colors.brandTextPrimary)
            Text(
                NSLocalizedString(
                    "tray.empty.subtitle",
                    value: "Click 'Add a new Drive' below to get started",
                    comment: "Tray empty-state subtitle prompting the user to add a drive"
                )
            )
            .font(DS3Typography.caption)
            .foregroundStyle(DS3Colors.brandTextSecondary)
            .multilineTextAlignment(.center)
        }
        .padding(.vertical, DS3Spacing.lg)
        .padding(.horizontal, DS3Spacing.md)
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    EmptyDrivesHint()
        .background(DS3Colors.brandBackground)
}
