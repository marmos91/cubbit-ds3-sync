import XCTest
import os.log
@testable import DS3Lib

/// Tests that platform-shared utilities compile and function correctly.
/// The #if os() guards in the extension target are verified by CI (iOS Simulator build).
/// These tests verify the DS3Lib utilities that both platforms depend on.
final class PlatformConditionalTests: XCTestCase {

    func testCacheTTLUtilityAvailableOnBothPlatforms() {
        // isCacheStale is in DS3Lib (shared), must work on both macOS and iOS
        let result = isCacheStale(lastEnumerated: Date(), ttl: 60)
        XCTAssertFalse(result, "Just-enumerated cache should be fresh")
    }

    func testMemoryLoggerAvailableOnBothPlatforms() {
        // logMemoryUsage is in DS3Lib (shared), must work on both macOS and iOS
        let logger = Logger(subsystem: "test.platform", category: "memory")
        // Should not crash on any platform
        logMemoryUsage(label: "platform-test", logger: logger)
    }

    func testCacheTTLEdgeCases() {
        // Verify the TTL utility handles extreme values correctly on both platforms
        let distantPast = Date.distantPast
        XCTAssertTrue(isCacheStale(lastEnumerated: distantPast, ttl: 60))

        let distantFuture = Date.distantFuture
        XCTAssertFalse(isCacheStale(lastEnumerated: distantFuture, ttl: 60))
    }
}
