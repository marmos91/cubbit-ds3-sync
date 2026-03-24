import Foundation
@testable import DS3Lib

/// Shared test helpers for DS3LibTests.
enum TestHelpers {
    /// Creates a Token with a specific expiration date via JSON decoding.
    static func makeToken(expiringAt date: Date) throws -> Token {
        let exp = Int64(date.timeIntervalSince1970)
        let expDateString = DateFormatter.iso8601.string(from: date)
        let json: [String: Any] = [
            "token": "test-jwt-token",
            "exp": exp,
            "exp_date": expDateString
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(Token.self, from: data)
    }
}
