#if os(iOS)
import SwiftUI
import DS3Lib

// MARK: - Unauthenticated View

/// Displayed when the user is not authenticated or has no drives configured.
/// Shows a sign-in prompt or no-drives message depending on the `hasDrives` parameter.
struct ShareUnauthenticatedView: View {
    let hasDrives: Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: ShareSpacing.md) {
            Spacer()

            if hasDrives {
                noDrivesContent
            } else {
                unauthenticatedContent
            }

            Spacer()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    onCancel()
                }
            }
        }
    }

    // MARK: - Unauthenticated Content

    private var unauthenticatedContent: some View {
        VStack(spacing: ShareSpacing.md) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(ShareColors.secondaryText)
                .symbolRenderingMode(.hierarchical)

            Text("Sign In to Upload")
                .font(ShareTypography.title)
                .foregroundStyle(ShareColors.primaryText)

            Text("Open DS3 Drive to sign in and set up a drive first.")
                .font(ShareTypography.body)
                .foregroundStyle(ShareColors.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, ShareSpacing.xl)

            Button("Open DS3 Drive") {
                onCancel()
            }
            .buttonStyle(SharePrimaryButtonStyle())
            .padding(.horizontal, ShareSpacing.xl)
            .padding(.top, ShareSpacing.sm)
            .accessibilityLabel("Open DS3 Drive app")
        }
    }

    // MARK: - No Drives Content

    private var noDrivesContent: some View {
        VStack(spacing: ShareSpacing.md) {
            Image(systemName: "externaldrive.fill.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(ShareColors.secondaryText)

            Text("No Drives Available")
                .font(ShareTypography.title)
                .foregroundStyle(ShareColors.primaryText)

            Text("Set up a drive in DS3 Drive to start uploading files.")
                .font(ShareTypography.body)
                .foregroundStyle(ShareColors.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, ShareSpacing.xl)

            Button("Open DS3 Drive") {
                onCancel()
            }
            .buttonStyle(SharePrimaryButtonStyle())
            .padding(.horizontal, ShareSpacing.xl)
            .padding(.top, ShareSpacing.sm)
            .accessibilityLabel("Open DS3 Drive app")
        }
    }
}
#endif
