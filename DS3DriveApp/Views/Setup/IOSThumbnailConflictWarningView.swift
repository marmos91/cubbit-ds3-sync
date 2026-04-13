#if os(iOS)
    import DS3Lib
    import SwiftUI

    /// Blocking warning shown when inspectThumbnailPrefix returns .conflicting.
    /// Displayed in the iOS setup wizard when the bucket's .thumbnails/ content
    /// doesn't match DS3Drive's layout.
    struct IOSThumbnailConflictWarningView: View {
        let onChooseDifferentPrefix: () -> Void
        let onUseAnyway: () -> Void

        private let buttonHeight: CGFloat = 54

        var body: some View {
            ZStack {
                IOSGradients.brandVerticalBackground
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 24) {
                            hero
                                .padding(.top, 16)

                            Spacer(minLength: 16)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                    }

                    pinnedCTA
                }
            }
            .navigationTitle("Warning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }

        // MARK: - Hero

        private var hero: some View {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(IOSColors.statusWarning.opacity(0.12))
                        .frame(width: 112, height: 112)

                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 64, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(IOSColors.statusWarning)
                }
                .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(String(localized: "thumbnail_conflict_title"))
                        .font(.custom("Figtree-SemiBold", size: 26))
                        .foregroundStyle(IOSColors.brandTextPrimary)
                        .multilineTextAlignment(.center)

                    Text(String(localized: "thumbnail_conflict_body"))
                        .font(.custom("Figtree-Regular", size: 16))
                        .foregroundStyle(IOSColors.brandTextSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.bottom, 8)
        }

        // MARK: - Pinned CTA

        private var pinnedCTA: some View {
            VStack(spacing: 8) {
                Divider()
                    .background(IOSColors.brandBorderSubtle)

                Button(action: onChooseDifferentPrefix) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 17, weight: .semibold))
                        Text(String(localized: "thumbnail_conflict_change_prefix"))
                            .font(.custom("Figtree-SemiBold", size: 17))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: buttonHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(IOSColors.brandPrimary)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint(String(localized: "thumbnail_conflict_hint_change_prefix"))

                Button(action: onUseAnyway) {
                    Text(String(localized: "thumbnail_conflict_use_anyway"))
                        .font(.custom("Figtree-Regular", size: 14))
                        .foregroundStyle(IOSColors.brandTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityHint(String(localized: "thumbnail_conflict_hint_use_anyway"))
                .padding(.bottom, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .background(.ultraThinMaterial)
        }
    }
#endif
