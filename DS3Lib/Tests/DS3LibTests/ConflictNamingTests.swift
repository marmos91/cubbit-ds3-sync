import XCTest
@testable import DS3Lib

final class ConflictNamingTests: XCTestCase {
    // MARK: - Standard cases

    func testConflictKeyWithPathAndExtension() {
        let date = makeDate(2024, 1, 15, 14, 30, 45)
        let result = ConflictNaming.conflictKey(
            originalKey: "photos/report.pdf",
            hostname: "amaterasu",
            date: date
        )
        XCTAssertEqual(result, "photos/report (Conflict on amaterasu 2024-01-15 14-30-45).pdf")
    }

    func testConflictKeyWithoutExtension() {
        let date = makeDate(2024, 6, 1, 9, 0, 0)
        let result = ConflictNaming.conflictKey(
            originalKey: "README",
            hostname: "mac",
            date: date
        )
        XCTAssertEqual(result, "README (Conflict on mac 2024-06-01 09-00-00)")
    }

    func testConflictKeyWithDotsInFilename() {
        let date = makeDate(2024, 3, 20, 12, 15, 30)
        let result = ConflictNaming.conflictKey(
            originalKey: "docs/my.file.txt",
            hostname: "mac",
            date: date
        )
        XCTAssertEqual(result, "docs/my.file (Conflict on mac 2024-03-20 12-15-30).txt")
    }

    func testConflictKeyRootLevelFile() {
        let date = makeDate(2024, 7, 4, 18, 45, 12)
        let result = ConflictNaming.conflictKey(
            originalKey: "report.pdf",
            hostname: "mac",
            date: date
        )
        XCTAssertEqual(result, "report (Conflict on mac 2024-07-04 18-45-12).pdf")
    }

    func testConflictKeyDeeplyNestedPath() {
        let date = makeDate(2024, 11, 30, 23, 59, 59)
        let result = ConflictNaming.conflictKey(
            originalKey: "a/b/c/deep.jpg",
            hostname: "mac",
            date: date
        )
        XCTAssertEqual(result, "a/b/c/deep (Conflict on mac 2024-11-30 23-59-59).jpg")
    }

    func testConflictKeyPreservesUnicode() {
        let date = makeDate(2024, 2, 14, 10, 30, 0)
        let result = ConflictNaming.conflictKey(
            originalKey: "docs/resume\u{0301}.txt",
            hostname: "Marcos-MacBook",
            date: date
        )
        XCTAssertTrue(result.contains("Marcos-MacBook"))
        XCTAssertTrue(result.hasPrefix("docs/"))
        XCTAssertTrue(result.hasSuffix(".txt"))
        XCTAssertTrue(result.contains("Conflict on"))
    }

    // MARK: - Edge cases

    func testConflictKeyWithHiddenFile() {
        let date = makeDate(2024, 5, 10, 8, 0, 0)
        let result = ConflictNaming.conflictKey(
            originalKey: ".gitignore",
            hostname: "mac",
            date: date
        )
        // .gitignore has no "name" before the dot -- treat entire thing as name, no extension
        XCTAssertEqual(result, ".gitignore (Conflict on mac 2024-05-10 08-00-00)")
    }

    func testConflictKeyWithMultiplePathComponents() {
        let date = makeDate(2024, 8, 22, 16, 30, 0)
        let result = ConflictNaming.conflictKey(
            originalKey: "projects/2024/q3/budget.xlsx",
            hostname: "office-mac",
            date: date
        )
        XCTAssertEqual(result, "projects/2024/q3/budget (Conflict on office-mac 2024-08-22 16-30-00).xlsx")
    }

    func testConflictKeyDateFormatting() {
        // Verify single-digit months/days/hours get zero-padded
        let date = makeDate(2024, 1, 2, 3, 4, 5)
        let result = ConflictNaming.conflictKey(
            originalKey: "test.txt",
            hostname: "mac",
            date: date
        )
        XCTAssertEqual(result, "test (Conflict on mac 2024-01-02 03-04-05).txt")
    }

    // MARK: - Helpers

    private func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }
}
