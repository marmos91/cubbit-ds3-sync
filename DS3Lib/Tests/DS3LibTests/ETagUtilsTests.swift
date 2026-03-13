import XCTest
@testable import DS3Lib

final class ETagUtilsTests: XCTestCase {
    // MARK: - normalize

    func testNormalizeStripsQuotes() {
        XCTAssertEqual(ETagUtils.normalize("\"abc123\""), "abc123")
    }

    func testNormalizeUnquotedUnchanged() {
        XCTAssertEqual(ETagUtils.normalize("abc123"), "abc123")
    }

    func testNormalizeEmptyString() {
        XCTAssertEqual(ETagUtils.normalize(""), "")
    }

    func testNormalizeNilReturnsNil() {
        XCTAssertNil(ETagUtils.normalize(nil))
    }

    func testNormalizeUnterminatedQuoteUntouched() {
        // Only matching surrounding double quotes are stripped
        XCTAssertEqual(ETagUtils.normalize("\"abc"), "\"abc")
    }

    func testNormalizeMultipartETag() {
        // Multipart ETags look like "abc123-5" (with quotes)
        XCTAssertEqual(ETagUtils.normalize("\"abc123-5\""), "abc123-5")
    }

    // MARK: - areEqual

    func testAreEqualQuotedVsUnquoted() {
        XCTAssertTrue(ETagUtils.areEqual("\"abc123\"", "abc123"))
    }

    func testAreEqualBothQuoted() {
        XCTAssertTrue(ETagUtils.areEqual("\"abc123\"", "\"abc123\""))
    }

    func testAreEqualBothUnquoted() {
        XCTAssertTrue(ETagUtils.areEqual("abc123", "abc123"))
    }

    func testAreEqualDifferent() {
        XCTAssertFalse(ETagUtils.areEqual("abc", "def"))
    }

    func testAreEqualNilLhs() {
        XCTAssertFalse(ETagUtils.areEqual(nil, "abc"))
    }

    func testAreEqualNilRhs() {
        XCTAssertFalse(ETagUtils.areEqual("abc", nil))
    }

    func testAreEqualBothNil() {
        let nilValue: String? = nil
        XCTAssertFalse(ETagUtils.areEqual(nilValue, nilValue))
    }

    func testAreEqualEmptyStrings() {
        XCTAssertTrue(ETagUtils.areEqual("", ""))
    }
}
