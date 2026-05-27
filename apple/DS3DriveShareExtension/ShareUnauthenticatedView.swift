#if os(iOS)
    import DS3Lib
    import SwiftUI

    // MARK: - Unauthenticated View

    /// Displayed when the user is not authenticated or has no drives configured.
    /// Shows a sign-in prompt or no-drives message depending on the `hasDrives` parameter.
    struct ShareUnauthenticatedView: View {
        let hasDrives: Bool
        let onCancel: () -> Void

        private var iconName: String {
            hasDrives ? "externaldrive.fill.badge.exclamationmark" : "person.crop.circle.badge.exclamationmark"
        }

        private var title: String {
            hasDrives ? "No Drives Available" : "Sign In to Upload"
        }

        private var message: String {
            hasDrives
                ? "Set up a drive in DS3 Drive to start uploading files."
                : "Open DS3 Drive to sign in and set up a drive first."
        }

        var body: some View {
            VStack(spacing: ShareSpacing.md) {
                Spacer()

                Image(systemName: iconName)
                    .font(.system(size: 48))
                    .foregroundStyle(ShareColors.secondaryText)
                    .symbolRenderingMode(.hierarchical)

                Text(title)
                    .font(ShareTypography.title)
                    .foregroundStyle(ShareColors.primaryText)

                Text(message)
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
    }
#endif
