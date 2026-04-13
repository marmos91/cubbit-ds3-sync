import XCTest
@testable import DS3Lib

/// Tests for the centralized S3 key visibility filter.
final class S3KeyFilterTests: XCTestCase {
    // MARK: - User-Visible Keys

    func testIsUserVisibleRegularFile() {
        XCTAssertTrue(S3KeyFilter.isUserVisible(key: "prefix/docs/report.pdf", drivePrefix: "prefix/"))
    }

    func testIsUserVisibleTrashKey() {
        XCTAssertFalse(S3KeyFilter.isUserVisible(key: "prefix/.trash/file.txt", drivePrefix: "prefix/"))
    }

    func testIsUserVisibleThumbnailKey() {
        XCTAssertFalse(S3KeyFilter.isUserVisible(key: "prefix/.thumbnails/a.heic.jpg", drivePrefix: "prefix/"))
    }

    func testIsUserVisibleNestedThumbnail() {
        XCTAssertFalse(S3KeyFilter.isUserVisible(key: "prefix/sub/.thumbnails/b.png.jpg", drivePrefix: "prefix/"))
    }

    func testIsUserVisibleTrashInsideThumbnails() {
        XCTAssertFalse(S3KeyFilter.isUserVisible(key: "prefix/.trash/.thumbnails/x.jpg", drivePrefix: "prefix/"))
    }

    func testIsUserVisibleThumbnailInsideTrash() {
        XCTAssertFalse(S3KeyFilter.isUserVisible(key: "prefix/.thumbnails/.trash/x.jpg", drivePrefix: "prefix/"))
    }

    func testIsUserVisibleUserTrashFolder() {
        XCTAssertTrue(
            S3KeyFilter.isUserVisible(key: "prefix/my.trash/file.txt", drivePrefix: "prefix/"),
            "A user folder named 'my.trash' should be visible — only '.trash/' at drive root is hidden"
        )
    }

    func testIsUserVisibleNilPrefix() {
        XCTAssertFalse(S3KeyFilter.isUserVisible(key: ".thumbnails/a.jpg", drivePrefix: nil))
    }

    func testIsUserVisibleEmptyPrefix() {
        XCTAssertFalse(S3KeyFilter.isUserVisible(key: ".trash/file.txt", drivePrefix: ""))
    }

    func testIsUserVisibleNestedDrivePrefix() {
        XCTAssertFalse(S3KeyFilter.isUserVisible(key: "org/team/drive/.thumbnails/a.jpg", drivePrefix: "org/team/drive/"))
    }

    func testIsUserVisibleRootFolder() {
        XCTAssertTrue(S3KeyFilter.isUserVisible(key: "prefix/photos/", drivePrefix: "prefix/"))
    }
}
