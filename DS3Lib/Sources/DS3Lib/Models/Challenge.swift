import Foundation

/// A security challenge in the Cubbit DS3 ecosystem
public struct Challenge: Codable, Sendable {
    /// The challenge string to be signed
    public var challenge: String

    /// The salt used in key derivation
    public var salt: String
}
