import XCTest
@testable import DS3Lib

final class TokenRefreshTests: XCTestCase {
    /// Helper to create a Token with a specific expiration date via JSON decoding.
    private func makeToken(expiringAt date: Date) throws -> Token {
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

    // MARK: - shouldRefreshToken tests

    func testTokenFarFromExpiryDoesNotNeedRefresh() throws {
        let token = try makeToken(expiringAt: Date().addingTimeInterval(600)) // 10 minutes
        XCTAssertFalse(DS3Authentication.shouldRefreshToken(token))
    }

    func testTokenNearExpiryNeedsRefresh() throws {
        let token = try makeToken(expiringAt: Date().addingTimeInterval(240)) // 4 minutes
        XCTAssertTrue(DS3Authentication.shouldRefreshToken(token))
    }

    func testExpiredTokenNeedsRefresh() throws {
        let token = try makeToken(expiringAt: Date().addingTimeInterval(-60)) // 1 minute ago
        XCTAssertTrue(DS3Authentication.shouldRefreshToken(token))
    }

    func testTokenExactlyAtThresholdNeedsRefresh() throws {
        // Just under 5 minutes -- should refresh since it is within the threshold
        let token = try makeToken(expiringAt: Date().addingTimeInterval(299))
        XCTAssertTrue(DS3Authentication.shouldRefreshToken(token))
    }
}
