import DS3Lib
import SwiftUI

/// Blocking warning shown when inspectThumbnailPrefix returns .conflicting.
/// Displayed in the setup wizard when the bucket's .thumbnails/ content
/// doesn't match DS3Drive's layout.
struct ThumbnailConflictWarningView: View {
    let onChooseDifferentPrefix: () -> Void
    let onUseAnyway: () -> Void

    var body: some View {
        VStack(spacing: DS3Spacing.xl) {
            // Warning icon
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DS3Colors.statusWarning)
                .font(.system(size: 48))
                .accessibilityHidden(true)

            // Title
            Text(String(localized: "thumbnail_conflict_title"))
                .font(DS3Typography.h3)
                .foregroundStyle(DS3Colors.brandTextPrimary)
                .multilineTextAlignment(.center)

            // Warning banner
            HStack(alignment: .top, spacing: DS3Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DS3Colors.statusWarning)
                Text(String(localized: "thumbnail_conflict_body"))
                    .font(DS3Typography.caption)
                    .foregroundStyle(DS3Colors.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .padding(DS3Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DS3Colors.statusWarning.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(DS3Colors.statusWarning.opacity(0.3), lineWidth: 1)
            )
            .allowsHitTesting(false)

            // Primary CTA
            Button(action: onChooseDifferentPrefix) {
                Text(String(localized: "thumbnail_conflict_change_prefix"))
                    .font(DS3Typography.button)
                    .foregroundStyle(.white)
                    .frame(maxWidth: 280, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .tint(DS3Colors.brandPrimary)
            .accessibilityHint(String(localized: "thumbnail_conflict_hint_change_prefix"))

            // Secondary CTA
            Button(action: onUseAnyway) {
                Text(String(localized: "thumbnail_conflict_use_anyway"))
                    .font(DS3Typography.caption)
                    .foregroundStyle(DS3Colors.brandTextSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityHint(String(localized: "thumbnail_conflict_hint_use_anyway"))
        }
        .padding(DS3Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS3Colors.brandBackground)
    }
}
