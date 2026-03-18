#if os(iOS)
import SwiftUI

// MARK: - Colors

enum IOSColors {
    // MARK: - Brand

    static let accent = Color.accentColor

    // MARK: - Backgrounds

    static let background = Color(uiColor: .systemBackground)
    static let secondaryBackground = Color(uiColor: .secondarySystemBackground)

    // MARK: - Text

    static let primaryText = Color.primary
    static let secondaryText = Color.secondary

    // MARK: - Separators

    static let separator = Color(uiColor: .separator)

    // MARK: - Status

    static let statusSynced = Color.green
    static let statusSyncing = Color.blue
    static let statusError = Color.red
    static let statusPaused = Color.orange
    static let statusCloudOnly = Color.gray
    static let statusConflict = Color.orange
}

// MARK: - Typography

enum IOSTypography {
    /// Display role -- screen titles (e.g. "Drives", "Settings")
    static let title = Font.title2.bold()

    /// Heading role -- section headers, drive card names
    static let headline = Font.headline

    /// Body role -- form field labels, description text, settings rows
    static let body = Font.body

    /// Caption role -- bucket/prefix path, transfer speed, timestamps
    static let caption = Font.caption

    /// Smallest text -- version labels
    static let footnote = Font.footnote
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

#endif
