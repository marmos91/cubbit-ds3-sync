import Foundation

public extension Account {
    /// Returns the primary (default) email for the account, or the first email, or "Unknown".
    var primaryEmail: String {
        emails.first(where: { $0.isDefault })?.email ?? emails.first?.email ?? "Unknown"
    }
}
