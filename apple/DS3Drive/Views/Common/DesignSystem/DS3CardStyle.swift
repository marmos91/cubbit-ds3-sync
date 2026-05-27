import SwiftUI

/// Shared brand card styling used across the DS3 Drive app after Plan 05-17.
///
/// Replicates the card pattern observed on the live Composer canary
/// dashboard: `brandSurface` fill, a 1pt ultra-subtle white-alpha stroke, and
/// a soft blue radial glow anchored to the bottom-trailing corner.
///
/// Apply with the `.brandCard()` view modifier. Downstream sweep plans
/// (05-18, 05-19) consume this helper instead of hand-rolling equivalent
/// background stacks.
struct BrandCardStyle: ViewModifier {
    var cornerRadius: CGFloat = 12
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(DS3Colors.brandSurface)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(DS3Gradients.brandCardGlow)
                        .blur(radius: 40)
                        .blendMode(.plusLighter)
                        .opacity(0.6)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(DS3Colors.brandBorderSubtle, lineWidth: 1)
            )
    }
}

extension View {
    /// Applies the shared Plan 05-17 brand card style
    /// (surface fill + ultra-subtle stroke + bottom-trailing blue glow).
    func brandCard(cornerRadius: CGFloat = 12, padding: CGFloat = 16) -> some View {
        modifier(BrandCardStyle(cornerRadius: cornerRadius, padding: padding))
    }
}
