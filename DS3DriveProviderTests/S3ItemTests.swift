@testable import DS3Lib
import FileProvider
import XCTest

final class S3ItemTests: XCTestCase {
    private func makeDrive(prefix: String? = "prefix/") -> DS3Drive {
        ProviderTestFixtures.makeDrive(prefix: prefix)
    }

    private func makeItem(
        key: String, drive: DS3Drive? = nil, etag: String? = nil,
        size: Int64 = 0, syncStatus: String? = nil
    ) -> S3Item {
        ProviderTestFixtures.makeItem(key: key, drive: drive, etag: etag, size: size, syncStatus: syncStatus)
    }

    // MARK: - Identifier Mapping

    func testRootDelimiterMapsToRootContainer() {
        let drive = makeDrive()
        let item = S3Item(
            identifier: NSFileProviderItemIdentifier("/"),
            drive: drive,
            objectMetadata: S3Item.Metadata(size: NSNumber(value: 0))
        )
        XCTAssertEqual(item.itemIdentifier, .rootContainer)
    }

    func testNonRootIdentifierPreserved() {
        let item = makeItem(key: "prefix/file.txt")
        XCTAssertEqual(item.itemIdentifier.rawValue, "prefix/file.txt")
    }

    // MARK: - Filename

    func testFilenameForFile() {
        let item = makeItem(key: "prefix/docs/report.pdf")
        XCTAssertEqual(item.filename, "report.pdf")
    }

    func testFilenameForFolder() {
        let item = makeItem(key: "prefix/docs/")
        XCTAssertEqual(item.filename, "docs")
    }

    func testFilenameForTrashContainer() {
        let drive = makeDrive()
        let item = S3Item(
            identifier: .trashContainer,
            drive: drive,
            objectMetadata: S3Item.Metadata(size: NSNumber(value: 0))
        )
        XCTAssertEqual(item.filename, "Trash")
    }

    // MARK: - Content Type

    func testContentTypeForFolder() {
        let item = makeItem(key: "prefix/docs/")
        XCTAssertEqual(item.contentType, .folder)
        XCTAssertTrue(item.isFolder)
    }

    func testContentTypeForPDF() {
        let item = makeItem(key: "prefix/report.pdf")
        XCTAssertEqual(item.contentType, .pdf)
        XCTAssertFalse(item.isFolder)
    }

    func testContentTypeForJPEG() {
        let item = makeItem(key: "prefix/photo.jpg")
        XCTAssertEqual(item.contentType, .jpeg)
    }

    func testContentTypeForUnknownExtension() {
        let item = makeItem(key: "prefix/data.xyz123")
        // Unknown extensions produce dynamic UTTypes, not .item
        XCTAssertFalse(item.isFolder)
        XCTAssertNotEqual(item.contentType, .folder)
    }

    func testContentTypeForNoExtension() {
        let item = makeItem(key: "prefix/Makefile")
        // Files without extensions produce dynamic UTTypes
        XCTAssertFalse(item.isFolder)
        XCTAssertNotEqual(item.contentType, .folder)
    }

    func testContentTypeForRootContainer() {
        let drive = makeDrive()
        let item = S3Item(
            identifier: .rootContainer,
            drive: drive,
            objectMetadata: S3Item.Metadata(size: NSNumber(value: 0))
        )
        XCTAssertEqual(item.contentType, .folder)
    }

    // MARK: - Parent Item Identifier

    func testParentOfFileAtRoot() {
        let item = makeItem(key: "prefix/file.txt")
        XCTAssertEqual(item.parentItemIdentifier, .rootContainer)
    }

    func testParentOfFolderAtRoot() {
        let item = makeItem(key: "prefix/docs/")
        XCTAssertEqual(item.parentItemIdentifier, .rootContainer)
    }

    func testParentOfFileInSubfolder() {
        let item = makeItem(key: "prefix/docs/report.pdf")
        XCTAssertEqual(item.parentItemIdentifier.rawValue, "prefix/docs/")
    }

    func testParentOfFolderInSubfolder() {
        let item = makeItem(key: "prefix/docs/archive/")
        XCTAssertEqual(item.parentItemIdentifier.rawValue, "prefix/docs/")
    }

    func testParentOfDeepFile() {
        let item = makeItem(key: "prefix/a/b/c/file.txt")
        XCTAssertEqual(item.parentItemIdentifier.rawValue, "prefix/a/b/c/")
    }

    // MARK: - Document Size

    func testDocumentSizeForFile() {
        let item = makeItem(key: "prefix/file.txt", size: 1024)
        XCTAssertEqual(item.documentSize, NSNumber(value: 1024))
    }

    func testDocumentSizeForFolder() {
        let item = makeItem(key: "prefix/docs/")
        XCTAssertNil(item.documentSize, "Folders should have nil documentSize")
    }

    // MARK: - Item Version

    func testItemVersionWithETag() {
        let item = makeItem(key: "prefix/file.txt", etag: "abc123")
        let version = item.itemVersion
        let expected = Data("abc123".utf8)
        XCTAssertEqual(version.contentVersion, expected)
    }

    func testItemVersionForFolder() {
        let item = makeItem(key: "prefix/docs/")
        let version = item.itemVersion
        // Folders use identifier-based stable version
        XCTAssertFalse(version.contentVersion.isEmpty)
    }

    // MARK: - Capabilities

    func testCapabilitiesForTrashContainer() {
        let drive = makeDrive()
        let item = S3Item(
            identifier: .trashContainer,
            drive: drive,
            objectMetadata: S3Item.Metadata(size: NSNumber(value: 0))
        )
        let caps = item.capabilities
        XCTAssertTrue(caps.contains(.allowsDeleting))
        XCTAssertTrue(caps.contains(.allowsReading))
        XCTAssertTrue(caps.contains(.allowsContentEnumerating))
        XCTAssertFalse(caps.contains(.allowsWriting))
    }

    func testCapabilitiesForRegularFile() {
        let item = makeItem(key: "prefix/file.txt")
        let caps = item.capabilities
        XCTAssertTrue(caps.contains(.allowsWriting))
        XCTAssertTrue(caps.contains(.allowsDeleting))
        XCTAssertTrue(caps.contains(.allowsRenaming))
        XCTAssertTrue(caps.contains(.allowsReparenting))
        XCTAssertTrue(caps.contains(.allowsTrashing))
    }

    // MARK: - Decorations

    #if os(macOS)
        func testDecorationSynced() {
            let item = makeItem(key: "prefix/file.txt", syncStatus: SyncStatus.synced.rawValue)
            XCTAssertEqual(item.decorations, [S3Item.decorationSynced])
        }

        func testDecorationSyncing() {
            let item = makeItem(key: "prefix/file.txt", syncStatus: SyncStatus.syncing.rawValue)
            XCTAssertEqual(item.decorations, [S3Item.decorationSyncing])
        }

        func testDecorationError() {
            let item = makeItem(key: "prefix/file.txt", syncStatus: SyncStatus.error.rawValue)
            XCTAssertEqual(item.decorations, [S3Item.decorationError])
        }

        func testDecorationConflict() {
            let item = makeItem(key: "prefix/file.txt", syncStatus: SyncStatus.conflict.rawValue)
            XCTAssertEqual(item.decorations, [S3Item.decorationConflict])
        }

        func testDecorationCloudOnlyDefault() {
            let item = makeItem(key: "prefix/file.txt", syncStatus: nil)
            XCTAssertEqual(item.decorations, [S3Item.decorationCloudOnly])
        }
    #endif

    // MARK: - Trash

    func testIsInTrashForTrashedKey() {
        let drive = makeDrive()
        let item = makeItem(key: "prefix/.trash/file.txt", drive: drive)
        XCTAssertTrue(item.isInTrash)
    }

    func testIsInTrashForNormalKey() {
        let drive = makeDrive()
        let item = makeItem(key: "prefix/docs/file.txt", drive: drive)
        XCTAssertFalse(item.isInTrash)
    }

    func testForcedTrashedItem() {
        let drive = makeDrive()
        let item = S3Item(
            identifier: NSFileProviderItemIdentifier("prefix/file.txt"),
            drive: drive,
            objectMetadata: S3Item.Metadata(size: NSNumber(value: 0)),
            forcedTrashed: true
        )
        XCTAssertTrue(item.isInTrash)
        XCTAssertEqual(item.parentItemIdentifier, .trashContainer)
        XCTAssertEqual(item.s3Key, "prefix/.trash/file.txt")
    }

    func testS3KeyForNormalItem() {
        let item = makeItem(key: "prefix/file.txt")
        XCTAssertEqual(item.s3Key, "prefix/file.txt")
    }

    func testTrashParentForTopLevelTrashedItem() {
        let drive = makeDrive()
        let item = makeItem(key: "prefix/.trash/file.txt", drive: drive)
        XCTAssertEqual(item.parentItemIdentifier, .trashContainer)
    }

    // MARK: - Drive with nil prefix

    func testParentWithNilPrefix() {
        let drive = makeDrive(prefix: nil)
        let item = S3Item(
            identifier: NSFileProviderItemIdentifier("docs/file.txt"),
            drive: drive,
            objectMetadata: S3Item.Metadata(size: NSNumber(value: 0))
        )
        XCTAssertEqual(item.parentItemIdentifier.rawValue, "docs/")
    }

    func testParentAtRootWithNilPrefix() {
        let drive = makeDrive(prefix: nil)
        let item = S3Item(
            identifier: NSFileProviderItemIdentifier("file.txt"),
            drive: drive,
            objectMetadata: S3Item.Metadata(size: NSNumber(value: 0))
        )
        XCTAssertEqual(item.parentItemIdentifier, .rootContainer)
    }
}
