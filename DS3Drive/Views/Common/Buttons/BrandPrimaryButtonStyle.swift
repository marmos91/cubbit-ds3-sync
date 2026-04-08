import SwiftUI

/// Shared primary CTA button style for DS3 Drive after Plan 05-17.
///
/// Uses the Composer canary primary blue (`#005CE8`) with white contrast
/// text, an 8pt corner radius, Figtree-SemiBold label typography, and a
/// pressed-state dark variant. Set `fillWidth` to make the button expand to
/// the available width (useful for stacked wizards / modal actions).
///
/// Apply with `.buttonStyle(BrandPrimaryButtonStyle())` — downstream sweep
/// plans (05-18, 05-19) wire this into existing `PrimaryButtonStyle` call
/// sites.
struct BrandPrimaryButtonStyle: ButtonStyle {
    var fillWidth: Bool = false
    var cornerRadius: CGFloat = 8

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS3Typography.button)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 20)
            .frame(minHeight: 44)
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .opacity(isEnabled ? 1.0 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if !isEnabled {
            return DS3Colors.brandPrimary
        }
        return isPressed ? DS3Colors.brandPrimaryDark : DS3Colors.brandPrimary
    }
}
