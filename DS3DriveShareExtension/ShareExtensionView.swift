#if os(iOS)
import SwiftUI
import DS3Lib

// MARK: - Design System Tokens

/// Mirror of IOSDesignSystem tokens for Share Extension target.
/// The Share Extension runs as a separate target and cannot directly import
/// files from DS3DriveApp. These tokens mirror the values exactly.
enum ShareColors {
    static let accent = Color.accentColor
    static let background = Color(uiColor: .systemBackground)
    static let secondaryBackground = Color(uiColor: .secondarySystemBackground)
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let statusSynced = Color.green
    static let statusError = Color.red
}

enum ShareTypography {
    static let title = Font.title2.bold()
    static let headline = Font.headline
    static let body = Font.body
    static let caption = Font.caption
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
                            ? (configuration.isPressed ? Color.accentColor.opacity(0.8) : Color.accentColor)
                            : Color.secondary
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
