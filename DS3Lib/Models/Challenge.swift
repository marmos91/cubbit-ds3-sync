import Foundation

/// A security challenge in the Cubbit DS3 ecosystem
struct Challenge: Codable {
    var challenge: String
    var salt: String
}
