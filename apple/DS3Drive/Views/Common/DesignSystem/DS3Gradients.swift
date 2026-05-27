import SwiftUI

/// Cubbit brand gradients used by hero areas across the app
/// (login background, wizard splash, tutorial chrome, card accents).
///
/// **Source of truth (Plan 05-17):** the subtle vertical background gradient
/// and bottom-right blue radial glow observed on cards in the live Composer
/// canary dashboard. See Gap 31 in `.planning/phases/05-ux-polish/05-08-GAPS.md`.
enum DS3Gradients {
    /// Vertical window backdrop — subtle top→bottom darkening from bg-default
    /// (`#0E0E15`) to an even deeper tone (`#080810`). Used as the full-window
    /// background on hero surfaces so the app doesn't feel flat.
    static let brandVerticalBackground = LinearGradient(
        colors: [
            Color(red: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x15 / 255.0),
            Color(red: 0x08 / 255.0, green: 0x08 / 255.0, blue: 0x10 / 255.0)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Subtle radial glow anchored to the bottom-trailing corner of a card,
    /// using the primary brand blue at ~10% alpha. Blur the output with
    /// `.blur(radius: 40)` to soften the edge when applied as a background
    /// fill on a rounded rectangle.
    static let brandCardGlow = RadialGradient(
        colors: [
            DS3Colors.brandPrimary.opacity(0.10),
            Color.clear
        ],
        center: .bottomTrailing,
        startRadius: 0,
        endRadius: 220
    )

    /// Primary brand hero gradient — alias to the vertical backdrop so views
    /// written against Plan 05-11's `brandHero` symbol keep working.
    static let brandHero = brandVerticalBackground

    /// Subtle variant — also aliased to the vertical backdrop. The old
    /// diagonal-blue gradient was misaligned with the canary product.
    static let brandHeroSubtle = brandVerticalBackground

    /// Soft radial glow centered on a hero element (e.g. the Cubbit logo on
    /// the login screen). Uses `brandPrimary` at very low alpha so the halo
    /// blends into the backdrop instead of reading as a hard halo.
    /// Iteration after user feedback: lowered from 0.35 → 0.18 to make the
    /// glow more subtle and ambient.
    static let brandRadialGlow = RadialGradient(
        gradient: Gradient(stops: [
            .init(color: DS3Colors.brandPrimary.opacity(0.18), location: 0),
            .init(color: DS3Colors.brandPrimary.opacity(0.0), location: 1)
        ]),
        center: .center,
        startRadius: 0,
        endRadius: 220
    )
}
