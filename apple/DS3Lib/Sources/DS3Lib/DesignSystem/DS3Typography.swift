import SwiftUI

/// Cross-platform Cubbit typography tokens, shared between the macOS app,
/// the File Provider extension, and the iOS targets (DS3DriveApp +
/// DS3DriveShareExtension).
///
/// **Source of truth (Plan 05-17):** the Figtree font family from the live
/// Composer canary product. Figtree `.ttf` files are bundled in the macOS app
/// under `DS3Drive/Assets/Fonts/` and in the iOS targets via `UIAppFonts`.
/// `Font.custom(_, size:)` falls back to the system font automatically if the
/// bundled font fails to load.
public enum DS3Typography {
    /// Display heading — 40pt SemiBold.
    public static let h1 = Font.custom("Figtree-SemiBold", size: 40)
    /// Section heading — 32pt SemiBold.
    public static let h2 = Font.custom("Figtree-SemiBold", size: 32)
    /// Sub-section heading — 24pt SemiBold.
    public static let h3 = Font.custom("Figtree-SemiBold", size: 24)

    /// Large body — 16pt Regular.
    public static let bodyLarge = Font.custom("Figtree-Regular", size: 16)
    /// Default body — 14pt Regular.
    public static let body = Font.custom("Figtree-Regular", size: 14)
    /// Emphasised body — 14pt Medium.
    public static let bodyMedium = Font.custom("Figtree-Medium", size: 14)

    /// Caption — 12pt Regular.
    public static let caption = Font.custom("Figtree-Regular", size: 12)
    /// Caption bold — 12pt SemiBold.
    public static let captionBold = Font.custom("Figtree-SemiBold", size: 12)
    /// Button label — 14pt SemiBold.
    public static let button = Font.custom("Figtree-SemiBold", size: 14)

    // MARK: - Legacy aliases

    /// Window titles (18pt SemiBold).
    public static let title = Font.custom("Figtree-SemiBold", size: 18)
    /// Larger title — used for empty-state heroes (22pt SemiBold).
    public static let title2 = Font.custom("Figtree-SemiBold", size: 22)
    /// Section headers (16pt SemiBold).
    public static let headline = Font.custom("Figtree-SemiBold", size: 16)
    /// Smallest text (11pt Regular).
    public static let footnote = Font.custom("Figtree-Regular", size: 11)
    /// Generic heading alias — 18pt SemiBold.
    public static let heading = Font.custom("Figtree-SemiBold", size: 18)
}
