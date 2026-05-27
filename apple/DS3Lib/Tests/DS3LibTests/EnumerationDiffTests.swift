import XCTest
@testable import DS3Lib

final class EnumerationDiffTests: XCTestCase {
    func testEmptyInputsProduceEmptyDelta() {
        let delta = EnumerationDiff.compute(local: [:], remote: [:])
        XCTAssertTrue(delta.isEmpty)
    }

    func testNewOnlyKeysAreNewOrModified() {
        let delta = EnumerationDiff.compute(
            local: [:],
            remote: ["a": "etag-a", "b": "etag-b"]
        )
        XCTAssertEqual(delta.newOrModified, ["a", "b"])
        XCTAssertTrue(delta.deleted.isEmpty)
    }

    func testRemovedKeysAreDeleted() {
        let delta = EnumerationDiff.compute(
            local: ["a": "etag-a", "b": "etag-b"],
            remote: ["a": "etag-a"]
        )
        XCTAssertTrue(delta.newOrModified.isEmpty)
        XCTAssertEqual(delta.deleted, ["b"])
    }

    func testEtagDriftIsModification() {
        let delta = EnumerationDiff.compute(
            local: ["a": "etag-old"],
            remote: ["a": "etag-new"]
        )
        XCTAssertEqual(delta.newOrModified, ["a"])
        XCTAssertTrue(delta.deleted.isEmpty)
    }

    func testIdenticalEtagsProduceNoDelta() {
        let delta = EnumerationDiff.compute(
            local: ["a": "x", "b": "y"],
            remote: ["a": "x", "b": "y"]
        )
        XCTAssertTrue(delta.isEmpty)
    }

    func testNilEtagsOnBothSidesAreEqual() {
        let delta = EnumerationDiff.compute(
            local: ["a": nil],
            remote: ["a": nil]
        )
        XCTAssertTrue(delta.isEmpty)
    }
}
