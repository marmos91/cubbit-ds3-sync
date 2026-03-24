@testable import DS3Lib
import FileProvider
import XCTest

final class S3EnumeratorTests: XCTestCase {
    private func makeDrive(prefix: String? = "prefix/") -> DS3Drive {
        ProviderTestFixtures.makeDrive(prefix: prefix)
    }

    private func makeItem(key: String, drive: DS3Drive) -> S3Item {
        ProviderTestFixtures.makeItem(key: key, drive: drive, etag: "etag-\(key)", size: 100)
    }

    // MARK: - Virtual Folder Synthesis

    func testSynthesizeVirtualFoldersFromRecursiveListing() {
        let drive = makeDrive()
        let items = [
            makeItem(key: "prefix/a/b/file1.txt", drive: drive),
            makeItem(key: "prefix/a/c/file2.txt", drive: drive),
            makeItem(key: "prefix/d/file3.txt", drive: drive)
        ]

        let virtualFolders = S3Enumerator.synthesizeVirtualFolders(
            from: items, drive: drive, prefix: "prefix/"
        )

        let virtualKeys = Set(virtualFolders.map(\.itemIdentifier.rawValue))
        XCTAssertTrue(virtualKeys.contains("prefix/a/"))
        XCTAssertTrue(virtualKeys.contains("prefix/a/b/"))
        XCTAssertTrue(virtualKeys.contains("prefix/a/c/"))
        XCTAssertTrue(virtualKeys.contains("prefix/d/"))
    }

    func testSynthesizeVirtualFoldersSkipsExistingMarkers() {
        let drive = makeDrive()
        let items = [
            makeItem(key: "prefix/a/", drive: drive), // explicit folder marker
            makeItem(key: "prefix/a/file.txt", drive: drive)
        ]

        let virtualFolders = S3Enumerator.synthesizeVirtualFolders(
            from: items, drive: drive, prefix: "prefix/"
        )

        let virtualKeys = virtualFolders.map(\.itemIdentifier.rawValue)
        XCTAssertFalse(virtualKeys.contains("prefix/a/"), "Should not duplicate existing folder")
    }

    func testSynthesizeVirtualFoldersSkipsDrivePrefix() {
        let drive = makeDrive()
        let items = [
            makeItem(key: "prefix/file.txt", drive: drive)
        ]

        let virtualFolders = S3Enumerator.synthesizeVirtualFolders(
            from: items, drive: drive, prefix: "prefix/"
        )

        XCTAssertTrue(virtualFolders.isEmpty, "Root-level files should not produce virtual folders")
    }

    func testSynthesizeVirtualFoldersAllAreFolders() {
        let drive = makeDrive()
        let items = [
            makeItem(key: "prefix/a/b/c/file.txt", drive: drive)
        ]

        let virtualFolders = S3Enumerator.synthesizeVirtualFolders(
            from: items, drive: drive, prefix: "prefix/"
        )

        for folder in virtualFolders {
            XCTAssertTrue(folder.isFolder, "\(folder.itemIdentifier.rawValue) should be a folder")
            XCTAssertEqual(folder.contentType, .folder)
        }
    }

    func testSynthesizeVirtualFoldersDeduplicates() {
        let drive = makeDrive()
        let items = [
            makeItem(key: "prefix/docs/file1.txt", drive: drive),
            makeItem(key: "prefix/docs/file2.txt", drive: drive),
            makeItem(key: "prefix/docs/sub/file3.txt", drive: drive)
        ]

        let virtualFolders = S3Enumerator.synthesizeVirtualFolders(
            from: items, drive: drive, prefix: "prefix/"
        )

        let virtualKeys = virtualFolders.map(\.itemIdentifier.rawValue)
        // "prefix/docs/" should appear at most once
        XCTAssertEqual(virtualKeys.count(where: { $0 == "prefix/docs/" }), 1)
    }

    func testSynthesizeVirtualFoldersNilPrefix() {
        let drive = makeDrive(prefix: nil)
        let items = [
            makeItem(key: "a/b/file.txt", drive: drive)
        ]

        let virtualFolders = S3Enumerator.synthesizeVirtualFolders(
            from: items, drive: drive, prefix: nil
        )

        let virtualKeys = Set(virtualFolders.map(\.itemIdentifier.rawValue))
        XCTAssertTrue(virtualKeys.contains("a/"))
        XCTAssertTrue(virtualKeys.contains("a/b/"))
    }

    func testSynthesizeVirtualFoldersEmpty() {
        let drive = makeDrive()
        let virtualFolders = S3Enumerator.synthesizeVirtualFolders(
            from: [], drive: drive, prefix: "prefix/"
        )
        XCTAssertTrue(virtualFolders.isEmpty)
    }
}
