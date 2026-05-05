import XCTest
@testable import DS3Lib

final class SyncAnchorHashTests: XCTestCase {
    func testFormatPrefixIsV1() {
        let bytes = SyncAnchorHash.compute(over: [("a", "1")])
        let asString = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(asString.hasPrefix("v1:"), "anchor must be 'v1:' prefixed for forward compat")
    }

    func testEmptyInputProducesStableAnchor() {
        let a = SyncAnchorHash.compute(over: [(key: String, etag: String?)]())
        let b = SyncAnchorHash.compute(over: [(key: String, etag: String?)]())
        XCTAssertEqual(a, b)
    }

    func testOrderInsensitive() {
        let ascending = SyncAnchorHash.compute(over: [("a", "1"), ("b", "2"), ("c", "3")])
        let descending = SyncAnchorHash.compute(over: [("c", "3"), ("b", "2"), ("a", "1")])
        XCTAssertEqual(ascending, descending, "anchor must be order-insensitive")
    }

    func testEtagChangeChangesAnchor() {
        let original = SyncAnchorHash.compute(over: [("a", "1")])
        let modified = SyncAnchorHash.compute(over: [("a", "2")])
        XCTAssertNotEqual(original, modified)
    }

    func testKeyAddOrRemovalChangesAnchor() {
        let two = SyncAnchorHash.compute(over: [("a", "1"), ("b", "2")])
        let one = SyncAnchorHash.compute(over: [("a", "1")])
        XCTAssertNotEqual(two, one)
    }

    func testNilEtagAndEmptyEtagHashIdentically() {
        // Nil etag becomes "" via the compute formatter; an actual ""
        // remote etag is still distinguishable from a different etag value.
        // The anchor merely needs to be deterministic and stable; this test
        // pins that contract for future-proofing.
        let nilSide = SyncAnchorHash.compute(over: [("a", nil)])
        let emptySide = SyncAnchorHash.compute(over: [("a", "")])
        XCTAssertEqual(nilSide, emptySide, "documented: nil and \"\" hash identically (both serialise to empty)")
    }
}
