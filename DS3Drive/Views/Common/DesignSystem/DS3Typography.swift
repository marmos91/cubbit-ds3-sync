import SwiftUI

enum DS3Typography {
    /// Window titles (18pt bold)
    static let title = Font.system(size: 18, weight: .bold)

    /// Section headers (16pt semibold)
    static let headline = Font.system(size: 16, weight: .semibold)

    /// Main body text (14pt regular) -- replaces .custom("Nunito", size: 14)
    static let body = Font.system(size: 14)

    /// Secondary text (12pt regular) -- replaces .custom("Nunito", size: 12)
    static let caption = Font.system(size: 12)

    /// Smallest text (11pt regular)
    static let footnote = Font.system(size: 11)
}
