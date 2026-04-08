#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif
import SwiftUI

/// Cross-platform Cubbit brand color tokens, shared between the macOS app,
/// the File Provider extension, the iOS companion app, and the iOS Share
/// Extension.
///
/// **Source of truth (Plan 05-17):** extracted from the live Composer canary
/// product (`https://composer-canary.cubbit.eu/en/dashboard`). See
/// `.planning/phases/05-ux-polish/05-11-BRAND-TOKENS.md` for the supersession
/// note (the Plan 05-11 values extracted from `cubbit.io` marketing CSS no
/// longer match the actual product palette).
public enum DS3Colors {
    // MARK: - Legacy palette (kept for source compatibility)

    public static let brandBlue50 = Color(red: 0xE6 / 255.0, green: 0xF0 / 255.0, blue: 0xFF / 255.0)
    public static let brandBlue100 = Color(red: 0xB0 / 255.0, green: 0xCF / 255.0, blue: 0xFF / 255.0)
    public static let brandBlue200 = Color(red: 0x8A / 255.0, green: 0xB8 / 255.0, blue: 0xFF / 255.0)
    public static let brandBlue300 = Color(red: 0x54 / 255.0, green: 0x98 / 255.0, blue: 0xFF / 255.0)
    public static let brandBlue400 = Color(red: 0x33 / 255.0, green: 0x7C / 255.0, blue: 0xEC / 255.0)
    public static let brandBlue500 = Color(red: 0x00 / 255.0, green: 0x65 / 255.0, blue: 0xFF / 255.0)
    public static let brandBlue600 = Color(red: 0x00 / 255.0, green: 0x5C / 255.0, blue: 0xE8 / 255.0)
    public static let brandBlue700 = Color(red: 0x00 / 255.0, green: 0x48 / 255.0, blue: 0xB5 / 255.0)
    public static let brandBlue800 = Color(red: 0x00 / 255.0, green: 0x38 / 255.0, blue: 0x8C / 255.0)
    public static let brandBlue900 = Color(red: 0x00 / 255.0, green: 0x2A / 255.0, blue: 0x6B / 255.0)

    public static let brandViolet300 = Color(red: 0xAF / 255.0, green: 0x7A / 255.0, blue: 0xCB / 255.0)
    public static let brandViolet500 = Color(red: 0x87 / 255.0, green: 0x39 / 255.0, blue: 0xB1 / 255.0)
    public static let brandViolet700 = Color(red: 0x60 / 255.0, green: 0x28 / 255.0, blue: 0x7E / 255.0)

    public static let brandGreen500 = Color(red: 0x26 / 255.0, green: 0xAB / 255.0, blue: 0x75 / 255.0)
    public static let brandGreen600 = Color(red: 0x23 / 255.0, green: 0xA6 / 255.0, blue: 0x75 / 255.0)
    public static let brandYellow500 = Color(red: 0xFF / 255.0, green: 0xB7 / 255.0, blue: 0x4D / 255.0)

    public static let brandGrey50 = Color(red: 0xDE / 255.0, green: 0xE4 / 255.0, blue: 0xEA / 255.0)
    public static let brandGrey100 = Color(red: 0xCC / 255.0, green: 0xD0 / 255.0, blue: 0xD4 / 255.0)
    public static let brandGrey200 = Color(red: 0xB3 / 255.0, green: 0xB9 / 255.0, blue: 0xBF / 255.0)
    public static let brandGrey300 = Color(red: 0x90 / 255.0, green: 0x99 / 255.0, blue: 0xA1 / 255.0)
    public static let brandGrey500 = Color(red: 0x59 / 255.0, green: 0x67 / 255.0, blue: 0x73 / 255.0)
    public static let brandGrey700 = Color(red: 0x3F / 255.0, green: 0x49 / 255.0, blue: 0x52 / 255.0)
    public static let brandGrey800 = Color(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0)
    public static let brandGrey900 = Color(red: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x15 / 255.0)
    public static let brandGrey1000 = Color(red: 0x08 / 255.0, green: 0x08 / 255.0, blue: 0x10 / 255.0)
    public static let brandBlack = Color(red: 0x04 / 255.0, green: 0x04 / 255.0, blue: 0x04 / 255.0)

    // MARK: - Composer canary palette (Plan 05-17)

    /// Window backdrop — `#0E0E15` (bg-default).
    public static let brandBg900 = Color(red: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x15 / 255.0)
    /// Paper / card surface — `#121212` (bg-paper dark).
    public static let brandBg800 = Color(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0)
    /// Derived hover surface.
    public static let brandBg700 = Color(red: 0x1A / 255.0, green: 0x1A / 255.0, blue: 0x22 / 255.0)

    /// Primary brand blue — `#005CE8` (primary-main).
    public static let brandPrimary = Color(red: 0x00 / 255.0, green: 0x5C / 255.0, blue: 0xE8 / 255.0)
    /// Primary pressed — `#0048B5`.
    public static let brandPrimaryDark = Color(red: 0x00 / 255.0, green: 0x48 / 255.0, blue: 0xB5 / 255.0)
    /// Primary hover — `#337CEC`.
    public static let brandPrimaryLight = Color(red: 0x33 / 255.0, green: 0x7C / 255.0, blue: 0xEC / 255.0)

    public static let statusSuccess = Color(red: 0x26 / 255.0, green: 0xAB / 255.0, blue: 0x75 / 255.0)
    public static let statusErrorMain = Color(red: 0xE5 / 255.0, green: 0x63 / 255.0, blue: 0x63 / 255.0)
    public static let statusErrorDark = Color(red: 0xDC / 255.0, green: 0x2D / 255.0, blue: 0x20 / 255.0)
    public static let statusWarning = Color(red: 0xFF / 255.0, green: 0xB7 / 255.0, blue: 0x4D / 255.0)
    public static let statusInfo = Color(red: 0x54 / 255.0, green: 0x98 / 255.0, blue: 0xFF / 255.0)

    public static let textPrimary = Color.white
    public static let textSecondary = Color.white.opacity(0.60)
    public static let textTertiary = Color.white.opacity(0.45)
    public static let textDisabled = Color.white.opacity(0.30)

    public static let brandBorderUltraSubtle = Color.white.opacity(0.04)
    public static let brandBorderSubtle = Color.white.opacity(0.10)
    public static let brandBorderStrong = Color.white.opacity(0.30)
    public static let brandDivider = Color.white.opacity(0.12)

    // MARK: - Adaptive semantic tokens

    public static let brandSecondary = brandPrimaryLight
    public static let brandAccent = statusWarning

    /// Adaptive window background — dark: `#0E0E15`, light: white.
    public static let brandBackground: Color = {
        #if os(macOS)
            return Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                    ? NSColor(red: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x15 / 255.0, alpha: 1)
                    : NSColor.white
            })
        #elseif os(iOS)
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x15 / 255.0, alpha: 1)
                    : UIColor.white
            })
        #else
            return brandBg900
        #endif
    }()

    /// Adaptive card / panel surface — dark: `#121212`, light: white.
    public static let brandSurface: Color = {
        #if os(macOS)
            return Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                    ? NSColor(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0, alpha: 1)
                    : NSColor.white
            })
        #elseif os(iOS)
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0, alpha: 1)
                    : UIColor.white
            })
        #else
            return brandBg800
        #endif
    }()

    /// Adaptive primary text — dark: white, light: near-black.
    public static let brandTextPrimary: Color = {
        #if os(macOS)
            return Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                    ? NSColor.white
                    : NSColor(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0, alpha: 1)
            })
        #elseif os(iOS)
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor.white
                    : UIColor(red: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0, alpha: 1)
            })
        #else
            return .white
        #endif
    }()

    /// Adaptive secondary text — dark: white@60%, light: black@60%.
    public static let brandTextSecondary: Color = {
        #if os(macOS)
            return Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                    ? NSColor.white.withAlphaComponent(0.60)
                    : NSColor.black.withAlphaComponent(0.60)
            })
        #elseif os(iOS)
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor.white.withAlphaComponent(0.60)
                    : UIColor.black.withAlphaComponent(0.60)
            })
        #else
            return Color.white.opacity(0.60)
        #endif
    }()

    /// Adaptive ultra-subtle border.
    public static let brandBorder: Color = {
        #if os(macOS)
            return Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                    ? NSColor.white.withAlphaComponent(0.10)
                    : NSColor.black.withAlphaComponent(0.10)
            })
        #elseif os(iOS)
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor.white.withAlphaComponent(0.10)
                    : UIColor.black.withAlphaComponent(0.10)
            })
        #else
            return Color.white.opacity(0.10)
        #endif
    }()

    public static let brandGradientStart = brandPrimary
    public static let brandGradientEnd = brandBg900

    // MARK: - Status aliases

    public static let statusSynced = statusSuccess
    public static let statusSyncing = brandPrimary
    public static let statusError = statusErrorMain
    public static let statusPaused = statusWarning
    public static let statusCloudOnly = Color.white.opacity(0.45)
    public static let statusConflict = statusWarning
}
