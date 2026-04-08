import SwiftUI

/// Cross-platform Cubbit brand gradients used by hero areas across the
/// macOS and iOS apps.
///
/// **Source of truth (Plan 05-17):** the subtle vertical backdrop and
/// bottom-right blue radial glow observed on cards in the live Composer
/// canary dashboard.
public enum DS3Gradients {
    /// Vertical window backdrop — subtle top→bottom darkening from bg-default
    /// (`#0E0E15`) to an even deeper tone (`#080810`).
    public static let brandVerticalBackground = LinearGradient(
        colors: [
            Color(red: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x15 / 255.0),
            Color(red: 0x08 / 255.0, green: 0x08 / 255.0, blue: 0x10 / 255.0)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Bottom-trailing radial glow with the primary brand blue at 10% alpha.
    public static let brandCardGlow = RadialGradient(
        colors: [
            DS3Colors.brandPrimary.opacity(0.10),
            Color.clear
        ],
        center: .bottomTrailing,
        startRadius: 0,
        endRadius: 220
    )

    /// Primary hero — aliased to the vertical backdrop.
    public static let brandHero = brandVerticalBackground

    /// Subtle variant — also aliased to the vertical backdrop.
    public static let brandHeroSubtle = brandVerticalBackground

    /// Soft radial glow centered on a hero element (e.g. Cubbit logo).
    public static let brandRadialGlow = RadialGradient(
        gradient: Gradient(stops: [
            .init(color: DS3Colors.brandPrimary.opacity(0.35), location: 0),
            .init(color: DS3Colors.brandPrimary.opacity(0.0), location: 1)
        ]),
        center: .center,
        startRadius: 0,
        endRadius: 220
    )
}
