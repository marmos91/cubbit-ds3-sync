#if os(iOS)
    import SwiftUI

    /// Empty state shown when no drives exist. Circular brand-tinted
    /// illustration, title/body copy, and a 54pt CTA.
    struct EmptyDrivesView: View {
        let onAddDrive: () -> Void

        private let buttonHeight: CGFloat = 54

        var body: some View {
            ZStack {
                IOSGradients.brandVerticalBackground
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    VStack(spacing: 24) {
                        ZStack {
                            Circle()
                                .fill(IOSColors.brandPrimary.opacity(0.12))
                                .frame(width: 128, height: 128)

                            Image(systemName: "externaldrive.fill.badge.icloud")
                                .font(.system(size: 56, weight: .regular))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(IOSColors.brandPrimary)
                        }

                        VStack(spacing: 10) {
                            Text("No Drives Yet")
                                .font(.custom("Figtree-SemiBold", size: 24))
                                .foregroundStyle(IOSColors.brandTextPrimary)

                            Text("Add a drive to sync your S3 files. You can browse them in the Files app.")
                                .font(.custom("Figtree-Regular", size: 16))
                                .foregroundStyle(IOSColors.brandTextSecondary)
                                .multilineTextAlignment(.center)
                                .lineSpacing(2)
                                .padding(.horizontal, 24)
                        }

                        Button {
                            onAddDrive()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("Add Drive")
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
                        .buttonStyle(EmptyDrivesPressableScale())
                        .frame(maxWidth: 320)
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 24)

                    Spacer(minLength: 0)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("No drives yet. Add a drive to sync your S3 files.")
        }
    }

    // MARK: - Pressable Scale

    private struct EmptyDrivesPressableScale: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
                .opacity(configuration.isPressed ? 0.92 : 1.0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
#endif
