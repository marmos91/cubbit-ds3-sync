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

    func testIsUserVisibleUserThumbnailFolder() {
        XCTAssertTrue(
            S3KeyFilter.isUserVisible(key: "prefix/my.thumbnails/photo.jpg", drivePrefix: "prefix/"),
            "A user folder named 'my.thumbnails' should be visible — only '.thumbnails/' as a path segment is hidden"
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

    // MARK: - Sentinel-Poisoned Keys

    func testIsUserVisibleRejectsTrashSentinelKeyAtRoot() {
        XCTAssertFalse(S3KeyFilter.isUserVisible(
            key: "NSFileProviderTrashContainerItemIdentifierIMG_4172.MOV", drivePrefix: nil
        ))
    }

    func testIsUserVisibleRejectsTrashSentinelKeyUnderPrefix() {
        XCTAssertFalse(S3KeyFilter.isUserVisible(
            key: "prefix/NSFileProviderTrashContainerItemIdentifierIMG_4172.MOV",
            drivePrefix: "prefix/"
        ))
    }

    func testIsUserVisibleRejectsRootSentinelKey() {
        XCTAssertFalse(S3KeyFilter.isUserVisible(
            key: "NSFileProviderRootContainerItemIdentifierfoo.txt", drivePrefix: nil
        ))
    }

    func testIsUserVisibleRejectsWorkingSetSentinelKey() {
        XCTAssertFalse(S3KeyFilter.isUserVisible(
            key: "NSFileProviderWorkingSetContainerItemIdentifierx.dat", drivePrefix: nil
        ))
    }

    func testIsUserVisibleAllowsLegitimateSimilarKey() {
        // A user could legitimately name a folder/file that contains "NSFile" as a substring;
        // only EXACT sentinel-prefix matches at the relative-key start should be rejected.
        XCTAssertTrue(S3KeyFilter.isUserVisible(
            key: "NSFileProviderTrashFooBar.txt", drivePrefix: nil
        ))
    }

    // MARK: - DS3Keep Marker

    func testRejectsDS3KeepMarkerInSubfolder() {
        XCTAssertFalse(S3KeyFilter.isUserVisible(key: "prefix/photos/.ds3keep", drivePrefix: "prefix/"))
    }

    func testRejectsDS3KeepMarkerAtPrefixRoot() {
        XCTAssertFalse(S3KeyFilter.isUserVisible(key: "prefix/.ds3keep", drivePrefix: "prefix/"))
    }

    func testRejectsDS3KeepMarkerWithNilDrivePrefix() {
        XCTAssertFalse(S3KeyFilter.isUserVisible(key: ".ds3keep", drivePrefix: nil))
        XCTAssertFalse(S3KeyFilter.isUserVisible(key: "photos/.ds3keep", drivePrefix: nil))
    }

    func testAllowsLookalikeFilename() {
        XCTAssertTrue(S3KeyFilter.isUserVisible(key: "prefix/notes/my.ds3keep.txt", drivePrefix: "prefix/"))
    }

    func testStillAllowsLegacyFolderPlaceholder() {
        // The trailing-slash placeholder remains user-visible (it surfaces as a
        // folder via CommonPrefix). Marker filter must not regress this.
        XCTAssertTrue(S3KeyFilter.isUserVisible(key: "prefix/photos/", drivePrefix: "prefix/"))
    }
}
