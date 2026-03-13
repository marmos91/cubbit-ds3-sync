import SwiftUI
import AppKit

enum DS3Colors {
    // MARK: - Brand

    static let accent = Color.accentColor

    // MARK: - Backgrounds

    static let background = Color(nsColor: .windowBackgroundColor)
    static let secondaryBackground = Color(nsColor: .controlBackgroundColor)

    // MARK: - Text

    static let primaryText = Color.primary
    static let secondaryText = Color.secondary

    // MARK: - Separators

    static let separator = Color(nsColor: .separatorColor)

    // MARK: - Status

    static let statusSynced = Color.green
    static let statusSyncing = Color.blue
    static let statusError = Color.red
    static let statusPaused = Color.orange
    static let statusCloudOnly = Color.gray
    static let statusConflict = Color.orange
}
