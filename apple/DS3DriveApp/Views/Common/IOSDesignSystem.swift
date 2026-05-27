#if os(iOS)
    import DS3Lib
    import SwiftUI

    // MARK: - Colors

    enum IOSColors {
        // MARK: - Brand (Cubbit) — sourced from DS3Lib for cross-platform parity

        /// Primary Cubbit brand color (#005CE8). See DS3Lib.DS3Colors.brandPrimary.
        static let brandPrimary = DS3Lib.DS3Colors.brandPrimary

        /// Pressed / dark variant (#0048B5).
        static let brandPrimaryDark = DS3Lib.DS3Colors.brandPrimaryDark

        /// Hover / light variant (#337CEC).
        static let brandPrimaryLight = DS3Lib.DS3Colors.brandPrimaryLight

        /// Secondary Cubbit brand accent.
        static let brandSecondary = DS3Lib.DS3Colors.brandSecondary

        /// Highlight accent.
        static let brandAccent = DS3Lib.DS3Colors.brandAccent

        /// Adaptive Cubbit window background (white light / `#0E0E15` dark).
        static let brandBackground = DS3Lib.DS3Colors.brandBackground

        /// Adaptive Cubbit card / panel surface (white light / `#121212` dark).
        static let brandSurface = DS3Lib.DS3Colors.brandSurface

        /// Adaptive primary text on brand surface.
        static let brandTextPrimary = DS3Lib.DS3Colors.brandTextPrimary

        /// Adaptive secondary text on brand surface.
        static let brandTextSecondary = DS3Lib.DS3Colors.brandTextSecondary

        /// Adaptive border / divider matching the brand surface.
        static let brandBorder = DS3Lib.DS3Colors.brandBorder

        /// White-alpha border ramp (mirrors macOS BrandCardStyle borders).
        static let brandBorderUltraSubtle = DS3Lib.DS3Colors.brandBorderUltraSubtle
        static let brandBorderSubtle = DS3Lib.DS3Colors.brandBorderSubtle
        static let brandBorderStrong = DS3Lib.DS3Colors.brandBorderStrong
        static let brandDivider = DS3Lib.DS3Colors.brandDivider

        /// Status palette from the canary.
        static let statusSuccess = DS3Lib.DS3Colors.statusSuccess
        static let statusErrorMain = DS3Lib.DS3Colors.statusErrorMain
        static let statusWarning = DS3Lib.DS3Colors.statusWarning
        static let statusInfo = DS3Lib.DS3Colors.statusInfo

        /// Tertiary text (45% white) — useful for footnotes / disabled labels.
        static let textTertiary = DS3Lib.DS3Colors.textTertiary

        /// Generic accent — kept for legacy call sites.
        static let accent = DS3Lib.DS3Colors.brandPrimary

        // MARK: - Backgrounds (now wired to brand tokens for visual parity with macOS)

        static let background = DS3Lib.DS3Colors.brandBackground
        static let secondaryBackground = DS3Lib.DS3Colors.brandSurface

        // MARK: - Text

        static let primaryText = DS3Lib.DS3Colors.brandTextPrimary
        static let secondaryText = DS3Lib.DS3Colors.brandTextSecondary

        // MARK: - Separators

        static let separator = DS3Lib.DS3Colors.brandBorder

        // MARK: - Status

        static let statusSynced = DS3Lib.DS3Colors.statusSuccess
        static let statusSyncing = DS3Lib.DS3Colors.brandPrimary
        static let statusError = DS3Lib.DS3Colors.statusErrorMain
        static let statusPaused = DS3Lib.DS3Colors.statusWarning
        static let statusCloudOnly = DS3Lib.DS3Colors.textTertiary
        static let statusConflict = DS3Lib.DS3Colors.statusWarning
    }

    // MARK: - Typography (Figtree, sourced from DS3Lib)

    enum IOSTypography {
        /// Display role -- screen titles (e.g. "Drives", "Settings"). Figtree SemiBold 18.
        static let title = DS3Lib.DS3Typography.title

        /// Larger title — used for empty-state heroes. Figtree SemiBold 22.
        static let title2 = DS3Lib.DS3Typography.title2

        /// Heading role -- section headers, drive card names. Figtree SemiBold 16.
        static let headline = DS3Lib.DS3Typography.headline

        /// Body role -- form field labels, description text, settings rows. Figtree Regular 14.
        static let body = DS3Lib.DS3Typography.body

        /// Caption role -- bucket/prefix path, transfer speed, timestamps. Figtree Regular 12.
        static let caption = DS3Lib.DS3Typography.caption

        /// Emphasized caption — field labels that need a little more
        /// weight than regular caption. Figtree SemiBold 12.
        static let captionBold = DS3Lib.DS3Typography.captionBold

        /// Smallest text -- version labels. Figtree Regular 11.
        static let footnote = DS3Lib.DS3Typography.footnote

        /// Button label — Figtree SemiBold 14.
        static let button = DS3Lib.DS3Typography.button
    }

    // MARK: - Spacing

    enum IOSSpacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
        static let xxxl: CGFloat = 64
    }

    // MARK: - Gradients

    /// Cubbit brand gradients exposed to iOS views via DS3Lib.
    enum IOSGradients {
        /// Subtle vertical hero backdrop (#0E0E15 → #080810).
        static let brandVerticalBackground = DS3Lib.DS3Gradients.brandVerticalBackground

        /// Diagonal hero gradient (legacy alias — now points at the canary vertical gradient).
        static let brandHero = DS3Lib.DS3Gradients.brandHero

        /// Subtle overlay variant for layering on brand surfaces.
        static let brandHeroSubtle = DS3Lib.DS3Gradients.brandHeroSubtle

        /// Soft radial glow centered on hero element.
        static let brandRadialGlow = DS3Lib.DS3Gradients.brandRadialGlow
    }

    // MARK: - Animations

    enum IOSAnimations {
        /// Standard view transition animation
        static let transition = Animation.spring(duration: 0.3)

        /// Subtle state change animation (progress, color changes)
        static let stateChange = Animation.easeInOut(duration: 0.2)

        /// Error/warning appearance
        static let errorAppear = Animation.easeOut(duration: 0.25)
    }

#endif
