#if os(iOS)
    import DS3Lib
    import SwiftUI

    // MARK: - Design System Tokens

    /// Mirror of IOSDesignSystem tokens for Share Extension target.
    /// The Share Extension runs as a separate target and cannot directly import
    /// files from DS3DriveApp. These tokens mirror the values exactly.
    enum ShareColors {
        // Brand tokens (sourced from DS3Lib so the Share Extension matches
        // the macOS app and iOS companion app visually).
        static let brandPrimary = DS3Lib.DS3Colors.brandPrimary
        static let brandSecondary = DS3Lib.DS3Colors.brandSecondary
        static let brandAccent = DS3Lib.DS3Colors.brandAccent
        static let brandBackground = DS3Lib.DS3Colors.brandBackground
        static let brandSurface = DS3Lib.DS3Colors.brandSurface
        static let brandTextPrimary = DS3Lib.DS3Colors.brandTextPrimary
        static let brandTextSecondary = DS3Lib.DS3Colors.brandTextSecondary
        static let brandBorder = DS3Lib.DS3Colors.brandBorder

        // Legacy aliases — now wired to brand tokens for visual parity.
        static let accent = DS3Lib.DS3Colors.brandPrimary
        static let background = DS3Lib.DS3Colors.brandBackground
        static let secondaryBackground = DS3Lib.DS3Colors.brandSurface
        static let primaryText = DS3Lib.DS3Colors.brandTextPrimary
        static let secondaryText = DS3Lib.DS3Colors.brandTextSecondary
        static let statusSynced = Color.green
        static let statusError = Color.red
    }

    /// Figtree-based typography mirroring `IOSTypography` — sourced from
    /// `DS3Lib.DS3Typography` so the Share Extension renders with the same
    /// font family as the iOS companion app and the macOS app.
    enum ShareTypography {
        static let title = DS3Lib.DS3Typography.title2
        static let headline = DS3Lib.DS3Typography.headline
        static let body = DS3Lib.DS3Typography.body
        static let caption = DS3Lib.DS3Typography.caption
        static let captionBold = DS3Lib.DS3Typography.captionBold
        static let button = DS3Lib.DS3Typography.button
    }

    enum ShareSpacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    /// Button style matching IOSPrimaryButtonStyle for the Share Extension.
    struct SharePrimaryButtonStyle: ButtonStyle {
        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(ShareTypography.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            isEnabled
                                ?
                                (configuration.isPressed ? ShareColors.brandPrimary.opacity(0.8) : ShareColors
                                    .brandPrimary)
                                : ShareColors.brandTextSecondary
                        )
                )
        }
    }

    /// Button style matching IOSOutlineButtonStyle for the Share Extension.
    struct ShareOutlineButtonStyle: ButtonStyle {
        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(ShareTypography.headline)
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(configuration.isPressed ? Color(uiColor: .separator).opacity(0.3) : Color.clear)
                        .stroke(Color(uiColor: .separator), lineWidth: 1)
                )
        }
    }

    // MARK: - Root View

    /// Root SwiftUI view for the Share Extension.
    /// Switches between states: loading, unauthenticated, drive picker, folder picker, and upload progress.
    struct ShareExtensionView: View {
        @Bindable var viewModel: ShareUploadViewModel
        weak var extensionContext: NSExtensionContext?

        var body: some View {
            Group {
                switch viewModel.state {
                case .loadingItems:
                    NavigationStack {
                        loadingView
                    }
                case .unauthenticated:
                    NavigationStack {
                        ShareUnauthenticatedView(
                            hasDrives: false,
                            onCancel: { viewModel.cancel() }
                        )
                    }
                case .pickDrive:
                    NavigationStack {
                        ShareDrivePickerView(
                            viewModel: viewModel,
                            onCancel: { viewModel.cancel() }
                        )
                    }
                case .pickFolder:
                    ShareFolderPickerView(
                        viewModel: viewModel,
                        onCancel: { viewModel.cancel() }
                    )
                case .uploading, .complete, .partialFailure:
                    NavigationStack {
                        ShareUploadProgressView(
                            viewModel: viewModel,
                            onCancel: { viewModel.cancel() }
                        )
                    }
                }
            }
            .font(ShareTypography.body)
            .animation(.spring(duration: 0.3), value: viewModel.state)
            .task {
                await viewModel.loadSharedItems(from: extensionContext)
            }
        }

        // MARK: - Loading View

        private var loadingView: some View {
            VStack(spacing: ShareSpacing.md) {
                ProgressView()
                Text("Preparing files...")
                    .font(ShareTypography.body)
                    .foregroundStyle(ShareColors.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

#endif
