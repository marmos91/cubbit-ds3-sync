import XCTest
@testable import DS3Lib

final class CacheTTLTests: XCTestCase {

    func testFreshCacheWithinTTL() {
        let now = Date()
        let lastEnumerated = now.addingTimeInterval(-30) // 30s ago
        XCTAssertFalse(isCacheStale(lastEnumerated: lastEnumerated, ttl: 60, now: now))
    }

    func testStaleCacheBeyondTTL() {
        let now = Date()
        let lastEnumerated = now.addingTimeInterval(-90) // 90s ago
        XCTAssertTrue(isCacheStale(lastEnumerated: lastEnumerated, ttl: 60, now: now))
    }

    func testNilDateIsAlwaysStale() {
        XCTAssertTrue(isCacheStale(lastEnumerated: nil, ttl: 60))
    }

    func testExactlyAtTTLBoundary() {
        let now = Date()
        let lastEnumerated = now.addingTimeInterval(-60) // exactly 60s ago
        XCTAssertTrue(isCacheStale(lastEnumerated: lastEnumerated, ttl: 60, now: now))
    }

    func testZeroTTLIsAlwaysStale() {
        let now = Date()
        let lastEnumerated = now // just now
        XCTAssertTrue(isCacheStale(lastEnumerated: lastEnumerated, ttl: 0, now: now))
    }
}
