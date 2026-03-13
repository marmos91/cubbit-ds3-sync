import Foundation

extension Account {
    /// Returns the primary (default) email for the account, or the first email, or "Unknown".
    public var primaryEmail: String {
        emails.first(where: { $0.isDefault })?.email ?? emails.first?.email ?? "Unknown"
    }
}
