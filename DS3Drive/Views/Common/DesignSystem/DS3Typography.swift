import SwiftUI

/// Cubbit typography tokens for DS3 Drive macOS app.
///
/// **Source of truth (Plan 05-17):** the Figtree font family from the live
/// Composer canary product. Figtree `.ttf` files are bundled in the app
/// Resources and registered at launch via `CTFontManagerRegisterFontsForURL`
/// in `DS3DriveApp.init()`.
///
/// **Why PostScript names, not family + weight modifier:** SwiftUI's
/// `Font.custom(_:size:)` calls into CoreText with the string treated as a
/// PostScript name. The runtime PostScript names for our bundled Figtree
/// family are `Figtree-Regular`, `Figtree-Medium`, `Figtree-SemiBold`,
/// `Figtree-Bold` (verified via `NSFontManager.shared.availableMembers`).
/// Passing the family name `"Figtree"` plus `.weight(.semibold)` causes the
/// initial lookup to silently fall back to the system font, after which the
/// `.weight()` modifier is a no-op.
enum DS3Typography {
    // MARK: - Headings

    /// Display heading — 40pt SemiBold (matches Composer `heading-h1`).
    static let h1 = Font.custom("Figtree-SemiBold", size: 40)
    /// Section heading — 32pt SemiBold.
    static let h2 = Font.custom("Figtree-SemiBold", size: 32)
    /// Sub-section heading — 24pt SemiBold (matches Composer `heading-h3`).
    static let h3 = Font.custom("Figtree-SemiBold", size: 24)

    // MARK: - Body

    /// Large body — 16pt Regular (matches Composer `body-md`).
    static let bodyLarge = Font.custom("Figtree-Regular", size: 16)
    /// Default body — 14pt Regular (matches Composer `body-sm`).
    static let body = Font.custom("Figtree-Regular", size: 14)
    /// Emphasised body — 14pt Medium.
    static let bodyMedium = Font.custom("Figtree-Medium", size: 14)

    // MARK: - Caption / UI chrome

    /// Caption — 12pt Regular.
    static let caption = Font.custom("Figtree-Regular", size: 12)
    /// Caption bold — 12pt SemiBold.
    static let captionBold = Font.custom("Figtree-SemiBold", size: 12)
    /// Button label — 14pt SemiBold.
    static let button = Font.custom("Figtree-SemiBold", size: 14)

    // MARK: - Legacy aliases (kept so views from 05-11/12/13/14 still compile)

    /// Window titles (18pt SemiBold).
    static let title = Font.custom("Figtree-SemiBold", size: 18)
    /// Larger title — used for empty-state heroes (22pt SemiBold).
    static let title2 = Font.custom("Figtree-SemiBold", size: 22)
    /// Section headers (16pt SemiBold) — matches Composer `body-md` weight emphasis.
    static let headline = Font.custom("Figtree-SemiBold", size: 16)
    /// Smallest text (11pt Regular).
    static let footnote = Font.custom("Figtree-Regular", size: 11)
    /// Generic heading alias — 18pt SemiBold.
    static let heading = Font.custom("Figtree-SemiBold", size: 18)
}
