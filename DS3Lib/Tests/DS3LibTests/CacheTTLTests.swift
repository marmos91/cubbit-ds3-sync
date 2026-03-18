import XCTest
@testable import DS3Lib

/// Wave 0 stub: Tests for cache TTL logic (IEXT-04).
/// Plan 07-02 Task 2 will replace these stubs with full implementations.
final class CacheTTLTests: XCTestCase {

    func testFreshCacheWithinTTL() {
        // STUB: Will verify TTL returns "fresh" when < 60s ago
        // Implemented by 07-02 Task 2
        XCTExpectFailure("Wave 0 stub -- awaiting 07-02 implementation")
        XCTFail("Not yet implemented")
    }

    func testStaleCacheBeyondTTL() {
        // STUB: Will verify TTL returns "stale" when > 60s ago
        // Implemented by 07-02 Task 2
        XCTExpectFailure("Wave 0 stub -- awaiting 07-02 implementation")
        XCTFail("Not yet implemented")
    }

    func testNilDateIsAlwaysStale() {
        // STUB: Will verify nil date returns "stale"
        // Implemented by 07-02 Task 2
        XCTExpectFailure("Wave 0 stub -- awaiting 07-02 implementation")
        XCTFail("Not yet implemented")
    }

    func testExactlyAtTTLBoundary() {
        // STUB: Will verify exactly-at-boundary returns "stale"
        // Implemented by 07-02 Task 2
        XCTExpectFailure("Wave 0 stub -- awaiting 07-02 implementation")
        XCTFail("Not yet implemented")
    }

    func testZeroTTLIsAlwaysStale() {
        // STUB: Will verify zero TTL is always stale
        // Implemented by 07-02 Task 2
        XCTExpectFailure("Wave 0 stub -- awaiting 07-02 implementation")
        XCTFail("Not yet implemented")
    }
}
