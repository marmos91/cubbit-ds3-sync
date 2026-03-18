#if os(iOS)
import SwiftUI

// MARK: - Primary Button Style

struct IOSPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(IOSTypography.headline)
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
            .hoverEffect(.highlight)
    }
}

// MARK: - Outline Button Style

struct IOSOutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(IOSTypography.headline)
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(configuration.isPressed ? Color(uiColor: .separator).opacity(0.3) : Color.clear)
                    .stroke(Color(uiColor: .separator), lineWidth: 1)
            )
            .hoverEffect(.highlight)
    }
}

// MARK: - Destructive Button Style

struct IOSDestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(IOSTypography.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        isEnabled
                            ? (configuration.isPressed ? Color.red.opacity(0.8) : Color.red)
                            : Color.secondary
                    )
            )
            .hoverEffect(.highlight)
    }
}

// MARK: - Shimmer Modifier

struct IOSShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
                .redacted(reason: .placeholder)
        } else {
            content
                .redacted(reason: .placeholder)
                .mask(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            .white.opacity(0.4),
                            .white,
                            .white.opacity(0.4)
                        ]),
                        startPoint: .init(x: phase - 0.5, y: 0.5),
                        endPoint: .init(x: phase + 0.5, y: 0.5)
                    )
                )
                .onAppear {
                    withAnimation(
                        .linear(duration: 1.5)
                            .repeatForever(autoreverses: false)
                    ) {
                        phase = 2
                    }
                }
        }
    }
}

extension View {
    /// Applies a shimmer/skeleton loading effect to the view.
    /// Respects `accessibilityReduceMotion` -- shows static placeholder when reduce motion is on.
    func iosShimmering() -> some View {
        modifier(IOSShimmerModifier())
    }

    /// Conditionally applies a shimmer effect when the condition is true.
    /// Respects `accessibilityReduceMotion` -- shows static placeholder when reduce motion is on.
    @ViewBuilder
    func iosShimmeringIf(_ condition: Bool) -> some View {
        if condition {
            modifier(IOSShimmerModifier())
        } else {
            self
        }
    }
}

#endif
