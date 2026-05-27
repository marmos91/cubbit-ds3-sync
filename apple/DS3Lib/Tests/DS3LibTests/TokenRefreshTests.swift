import XCTest
@testable import DS3Lib

final class TokenRefreshTests: XCTestCase {
    // MARK: - shouldRefreshToken tests

    func testTokenFarFromExpiryDoesNotNeedRefresh() throws {
        let token = try TestHelpers.makeToken(expiringAt: Date().addingTimeInterval(600)) // 10 minutes
        XCTAssertFalse(DS3Authentication.shouldRefreshToken(token))
    }

    func testTokenNearExpiryNeedsRefresh() throws {
        let token = try TestHelpers.makeToken(expiringAt: Date().addingTimeInterval(240)) // 4 minutes
        XCTAssertTrue(DS3Authentication.shouldRefreshToken(token))
    }

    func testExpiredTokenNeedsRefresh() throws {
        let token = try TestHelpers.makeToken(expiringAt: Date().addingTimeInterval(-60)) // 1 minute ago
        XCTAssertTrue(DS3Authentication.shouldRefreshToken(token))
    }

    func testTokenExactlyAtThresholdNeedsRefresh() throws {
        // Just inside the 5-minute threshold -- should refresh
        let token = try TestHelpers.makeToken(expiringAt: Date().addingTimeInterval(299))
        XCTAssertTrue(DS3Authentication.shouldRefreshToken(token))
    }
}
