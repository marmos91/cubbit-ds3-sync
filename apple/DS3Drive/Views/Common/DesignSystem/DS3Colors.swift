import AppKit
import SwiftUI

/// Cubbit brand color tokens for DS3 Drive macOS app.
///
/// **Source of truth (Plan 05-17):** extracted from the live Composer canary
/// product (`https://composer-canary.cubbit.eu/en/dashboard`) in April 2026.
/// These supersede the earlier Plan 05-11 values which were extracted from the
/// `cubbit.io` marketing CSS and did not match the actual product palette. See
/// `.planning/phases/05-ux-polish/05-11-BRAND-TOKENS.md` for the supersession
/// note and the full token mapping.
enum DS3Colors {
    // MARK: - Legacy Blue / Violet / Grey palette (Plan 05-11)

    //
    // Kept for source compatibility with views that still reference
    // `brandBlueNNN`/`brandGreyNNN`. New code should prefer the semantic
    // tokens (`brandPrimary`, `brandSurface`, `brandBorder*`, etc.) below.

    static let brandBlue50 = Color(red: 0xE6 / 255.0, green: 0xF0 / 255.0, blue: 0xFF / 255.0)
    static let brandBlue100 = Color(red: 0xB0 / 255.0, green: 0xCF / 255.0, blue: 0xFF / 255.0)
    static let brandBlue200 = Color(red: 0x8A / 255.0, green: 0xB8 / 255.0, blue: 0xFF / 255.0)
    static let brandBlue300 = Color(red: 0x54 / 255.0, green: 0x98 / 255.0, blue: 0xFF / 255.0)
    static let brandBlue400 = Color(red: 0x33 / 255.0, green: 0x7C / 255.0, blue: 0xEC / 255.0)
    static let brandBlue500 = Color(red: 0x00 / 255.0, green: 0x65 / 255.0, blue: 0xFF / 255.0)
    static let brandBlue600 = Color(red: 0x00 / 255.0, green: 0x5C / 255.0, blue: 0xE8 / 255.0)
    static let brandBlue700 = Color(red: 0x00 / 255.0, green: 0x48 / 255.0, blue: 0xB5 / 255.0)
    static let brandBlue800 = Color(red: 0x00 / 255.0, green: 0x38 / 255.0, blue: 0x8C / 255.0)
    static let brandBlue900 = Color(red: 0x00 / 255.0, green: 0x2A / 255.0, blue: 0x6B / 255.0)

    static let brandViolet300 = Color(red: 0xAF / 255.0, green: 0x7A / 255.0, blue: 0xCB / 255.0)
    static let brandViolet500 = Color(red: 0x87 / 255.0, green: 0x39 / 255.0, blue: 0xB1 / 255.0)
    static let brandViolet700 = Color(red: 0x60 / 255.0, green: 0x28 / 255.0, blue: 0x7E / 255.0)

    static let brandGreen500 = Color(red: 0x26 / 255.0, green: 0xAB / 255.0, blue: 0x75 / 255.0)
    static let brandGreen600 = Color(red: 0x23 / 255.0, green: 0xA6 / 255.0, blue: 0x75 / 255.0)
    static let brandYellow500 = Color(red: 0xFF / 255.0, green: 0xB7 / 255.0, blue: 0x4D / 255.0)

    static let brandGrey50 = Color(red: 0xDE / 255.0, green: 0xE4 / 255.0, blue: 0xEA / 255.0)
    static let brandGrey100 = Color(red: 0xCC / 255.0, green: 0xD0 / 255.0, blue: 0xD4 / 255.0)
    static let brandGrey200 = Color(red: 0xB3 / 255.0, green: 0xB9 / 255.0, blue: 0xBF / 255.0)
    static let brandGrey300 = Color(red: 0x90 / 255.0, green: 0x99 / 255.0, blue: 0xA1 / 255.0)
    static let brandGrey500 = Color(red: 0x59 / 255.0, green: 0x67 / 255.0, blue: 0x73 / 255.0)
    static let brandGrey700 = Color(red: 0x3F / 255.0, green: 0x49 / 255.0, blue: 0x52 / 255.0)
    static let brandGrey800 = Color(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0)
    static let brandGrey900 = Color(red: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x15 / 255.0)
    static let brandGrey1000 = Color(red: 0x08 / 255.0, green: 0x08 / 255.0, blue: 0x10 / 255.0)
    static let brandBlack = Color(red: 0x04 / 255.0, green: 0x04 / 255.0, blue: 0x04 / 255.0)

    // MARK: - Composer canary palette (Plan 05-17, source of truth)

    /// Backgrounds
    /// Window backdrop — `#0E0E15` (bg-default).
    static let brandBg900 = Color(red: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x15 / 255.0)
    /// Paper / card surface — `#121212` (bg-paper dark).
    static let brandBg800 = Color(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0)
    /// Derived hover surface.
    static let brandBg700 = Color(red: 0x1A / 255.0, green: 0x1A / 255.0, blue: 0x22 / 255.0)

    /// Primary
    /// Primary brand blue — `#005CE8` (primary-main).
    static let brandPrimary = Color(red: 0x00 / 255.0, green: 0x5C / 255.0, blue: 0xE8 / 255.0)
    /// Primary pressed / dark — `#0048B5` (primary-dark).
    static let brandPrimaryDark = Color(red: 0x00 / 255.0, green: 0x48 / 255.0, blue: 0xB5 / 255.0)
    /// Primary hover / light — `#337CEC` (primary-light).
    static let brandPrimaryLight = Color(red: 0x33 / 255.0, green: 0x7C / 255.0, blue: 0xEC / 255.0)

    // Status (Composer canary Material-UI palette)
    static let statusSuccess = Color(red: 0x26 / 255.0, green: 0xAB / 255.0, blue: 0x75 / 255.0) // #26AB75
    static let statusErrorMain = Color(red: 0xE5 / 255.0, green: 0x63 / 255.0, blue: 0x63 / 255.0) // #E56363
    static let statusErrorDark = Color(red: 0xDC / 255.0, green: 0x2D / 255.0, blue: 0x20 / 255.0) // #DC2D20
    static let statusWarning = Color(red: 0xFF / 255.0, green: 0xB7 / 255.0, blue: 0x4D / 255.0) // #FFB74D
    static let statusInfo = Color(red: 0x54 / 255.0, green: 0x98 / 255.0, blue: 0xFF / 255.0) // #5498FF

    // Text — white with alpha
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.60) // FFFFFF99
    static let textTertiary = Color.white.opacity(0.45) // FFFFFF73
    static let textDisabled = Color.white.opacity(0.30) // FFFFFF4D

    // Borders — white with alpha
    static let brandBorderUltraSubtle = Color.white.opacity(0.04) // FFFFFF0A
    static let brandBorderSubtle = Color.white.opacity(0.10) // FFFFFF1A
    static let brandBorderStrong = Color.white.opacity(0.30) // FFFFFF4D
    static let brandDivider = Color.white.opacity(0.12)

    // MARK: - Adaptive semantic tokens

    /// Primary brand accent — used for CTA fills, active tab chips, focus rings.
    static let brandSecondary = brandPrimaryLight
    /// Legacy accent alias (Plan 05-11). Now maps to warning orange.
    static let brandAccent = statusWarning

    /// Adaptive window background (dark: `#0E0E15`, light: white).
    static let brandBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x15 / 255.0, alpha: 1)
            : NSColor.white
    })

    /// Adaptive card / panel surface (dark: `#121212`, light: white).
    static let brandSurface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0, alpha: 1)
            : NSColor.white
    })

    /// Adaptive primary text (dark: white, light: near-black).
    static let brandTextPrimary = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor.white
            : NSColor(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0, alpha: 1)
    })

    /// Adaptive secondary text (dark: white@60%, light: black@60%).
    static let brandTextSecondary = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor.white.withAlphaComponent(0.60)
            : NSColor.black.withAlphaComponent(0.60)
    })

    /// Adaptive ultra-subtle border (dark: white@10%, light: black@10%).
    static let brandBorder = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.black.withAlphaComponent(0.10)
    })

    /// Gradient start — primary brand blue.
    static let brandGradientStart = brandPrimary
    /// Gradient end — deep canary background.
    static let brandGradientEnd = brandBg900

    // MARK: - Legacy generic tokens (kept for compatibility)

    static let accent = Color.accentColor
    static let background = Color(nsColor: .windowBackgroundColor)
    static let secondaryBackground = Color(nsColor: .controlBackgroundColor)
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let hoverHighlight = Color(nsColor: .selectedContentBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)

    // MARK: - Badges

    static let badgeProject = brandPrimary
    static let badgeText = Color.white

    // MARK: - Status aliases (wired to canary palette)

    static let statusSynced = statusSuccess
    static let statusSyncing = brandPrimary
    static let statusError = statusErrorMain
    static let statusPaused = statusWarning
    static let statusCloudOnly = Color.white.opacity(0.45)
    static let statusConflict = statusWarning

    // MARK: - Project badge palette

    /// Stable, high-contrast palette used to render the per-project badge in
    /// the wizard tree. A project's color is derived from a stable hash of its
    /// identifier so the same project always gets the same color.
    static let projectBadgePalette: [Color] = [
        brandBlue400,
        brandViolet500,
        brandGreen500,
        brandYellow500,
        brandBlue600,
        brandViolet300,
        brandGreen600,
        brandBlue200
    ]

    /// Returns a stable badge color for a project identifier.
    /// Uses a deterministic FNV-1a-style hash so colors are stable across runs
    /// (Swift's `hashValue` is randomized per process and would change every launch).
    static func colorForProject(_ id: String) -> Color {
        var hash: UInt64 = 14_695_981_039_346_656_037 // FNV offset basis
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211 // FNV prime
        }
        let index = Int(hash % UInt64(projectBadgePalette.count))
        return projectBadgePalette[index]
    }
}
