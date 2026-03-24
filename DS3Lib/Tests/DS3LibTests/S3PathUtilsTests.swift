import XCTest
@testable import DS3Lib

/// Tests for S3 path/key manipulation logic (extracted from S3Item/S3Enumerator).
final class S3PathUtilsTests: XCTestCase {
    // MARK: - Filename Extraction

    func testFilenameFromSimpleKey() {
        XCTAssertEqual(S3PathUtils.filename(fromKey: "photos/vacation/beach.jpg"), "beach.jpg")
    }

    func testFilenameFromRootKey() {
        XCTAssertEqual(S3PathUtils.filename(fromKey: "file.txt"), "file.txt")
    }

    func testFilenameFromFolderKey() {
        XCTAssertEqual(S3PathUtils.filename(fromKey: "photos/vacation/"), "vacation")
    }

    func testFilenameFromDeepKey() {
        XCTAssertEqual(S3PathUtils.filename(fromKey: "a/b/c/d/e.txt"), "e.txt")
    }

    func testFilenameFromEmptyKey() {
        XCTAssertEqual(S3PathUtils.filename(fromKey: ""), "")
    }

    // MARK: - Is Folder

    func testIsFolderWithTrailingSlash() {
        XCTAssertTrue(S3PathUtils.isFolder("photos/vacation/"))
    }

    func testIsFolderWithoutTrailingSlash() {
        XCTAssertFalse(S3PathUtils.isFolder("photos/vacation/beach.jpg"))
    }

    func testIsFolderRootSlash() {
        XCTAssertTrue(S3PathUtils.isFolder("/"))
    }

    func testIsFolderEmptyString() {
        XCTAssertFalse(S3PathUtils.isFolder(""))
    }

    // MARK: - Parent Key

    func testParentKeyForFileInSubfolder() {
        let parent = S3PathUtils.parentKey(forKey: "prefix/docs/file.txt", drivePrefix: "prefix/")
        XCTAssertEqual(parent, "prefix/docs/")
    }

    func testParentKeyForFileAtRoot() {
        let parent = S3PathUtils.parentKey(forKey: "prefix/file.txt", drivePrefix: "prefix/")
        XCTAssertNil(parent, "File at drive root should have nil parent (maps to rootContainer)")
    }

    func testParentKeyForFolderAtRoot() {
        let parent = S3PathUtils.parentKey(forKey: "prefix/docs/", drivePrefix: "prefix/")
        XCTAssertNil(parent, "Folder at drive root should have nil parent")
    }

    func testParentKeyForDeepFile() {
        let parent = S3PathUtils.parentKey(forKey: "prefix/a/b/c/file.txt", drivePrefix: "prefix/")
        XCTAssertEqual(parent, "prefix/a/b/c/")
    }

    func testParentKeyWithNilPrefix() {
        let parent = S3PathUtils.parentKey(forKey: "docs/file.txt", drivePrefix: nil)
        XCTAssertEqual(parent, "docs/")
    }

    func testParentKeyForRootFileWithNilPrefix() {
        let parent = S3PathUtils.parentKey(forKey: "file.txt", drivePrefix: nil)
        XCTAssertNil(parent)
    }

    // MARK: - Trash Prefix

    func testTrashPrefixWithDrivePrefix() {
        let trash = S3PathUtils.trashPrefix(forDrivePrefix: "photos/")
        XCTAssertEqual(trash, "photos/.trash/")
    }

    func testTrashPrefixWithNilDrivePrefix() {
        let trash = S3PathUtils.trashPrefix(forDrivePrefix: nil)
        XCTAssertEqual(trash, ".trash/")
    }

    func testTrashPrefixWithEmptyDrivePrefix() {
        let trash = S3PathUtils.trashPrefix(forDrivePrefix: "")
        XCTAssertEqual(trash, ".trash/")
    }

    // MARK: - Is Trashed Key

    func testIsTrashedKeyTrue() {
        XCTAssertTrue(S3PathUtils.isTrashedKey("prefix/.trash/file.txt", drivePrefix: "prefix/"))
    }

    func testIsTrashedKeyFalse() {
        XCTAssertFalse(S3PathUtils.isTrashedKey("prefix/docs/file.txt", drivePrefix: "prefix/"))
    }

    func testIsTrashedKeyNilPrefix() {
        XCTAssertTrue(S3PathUtils.isTrashedKey(".trash/file.txt", drivePrefix: nil))
    }

    // MARK: - Trash Key Computation

    func testTrashKeyForFile() {
        let trashKey = S3PathUtils.trashKey(forKey: "prefix/docs/file.txt", drivePrefix: "prefix/")
        XCTAssertEqual(trashKey, "prefix/.trash/docs/file.txt")
    }

    func testTrashKeyForFolder() {
        let trashKey = S3PathUtils.trashKey(forKey: "prefix/docs/", drivePrefix: "prefix/")
        XCTAssertEqual(trashKey, "prefix/.trash/docs/")
    }

    func testTrashKeyForRootFile() {
        let trashKey = S3PathUtils.trashKey(forKey: "prefix/file.txt", drivePrefix: "prefix/")
        XCTAssertEqual(trashKey, "prefix/.trash/file.txt")
    }

    func testTrashKeyNilPrefix() {
        let trashKey = S3PathUtils.trashKey(forKey: "file.txt", drivePrefix: nil)
        XCTAssertEqual(trashKey, ".trash/file.txt")
    }

    // MARK: - Original Key from Trash Key

    func testOriginalKeyFromTrashKey() {
        let original = S3PathUtils.originalKey(fromTrashKey: "prefix/.trash/docs/file.txt", drivePrefix: "prefix/")
        XCTAssertEqual(original, "prefix/docs/file.txt")
    }

    func testOriginalKeyFromTrashKeyNilPrefix() {
        let original = S3PathUtils.originalKey(fromTrashKey: ".trash/file.txt", drivePrefix: nil)
        XCTAssertEqual(original, "file.txt")
    }

    func testTrashKeyRoundTrip() {
        let originalKey = "prefix/photos/vacation/beach.jpg"
        let drivePrefix = "prefix/"
        let trashKey = S3PathUtils.trashKey(forKey: originalKey, drivePrefix: drivePrefix)
        let restored = S3PathUtils.originalKey(fromTrashKey: trashKey, drivePrefix: drivePrefix)
        XCTAssertEqual(restored, originalKey, "Trash key → original key round-trip should be lossless")
    }

    // MARK: - Trash Parent Key

    func testTrashParentKeyTopLevel() {
        let parent = S3PathUtils.trashParentKey(forKey: "prefix/.trash/file.txt", drivePrefix: "prefix/")
        XCTAssertNil(parent, "Top-level trash item has no parent within trash")
    }

    func testTrashParentKeyNested() {
        let parent = S3PathUtils.trashParentKey(forKey: "prefix/.trash/docs/file.txt", drivePrefix: "prefix/")
        XCTAssertEqual(parent, "prefix/.trash/docs/")
    }

    func testTrashParentKeyFolder() {
        let parent = S3PathUtils.trashParentKey(forKey: "prefix/.trash/folder/", drivePrefix: "prefix/")
        XCTAssertNil(parent, "Top-level trash folder has no parent")
    }

    // MARK: - Virtual Folder Synthesis

    func testSynthesizeVirtualFolders() {
        let keys: Set<String> = [
            "prefix/a/b/file1.txt",
            "prefix/a/c/file2.txt",
            "prefix/d/file3.txt"
        ]

        let virtual = S3PathUtils.synthesizeVirtualFolderKeys(fromKeys: keys, prefix: "prefix/")

        XCTAssertTrue(virtual.contains("prefix/a/"), "Should synthesize 'prefix/a/'")
        XCTAssertTrue(virtual.contains("prefix/a/b/"), "Should synthesize 'prefix/a/b/'")
        XCTAssertTrue(virtual.contains("prefix/a/c/"), "Should synthesize 'prefix/a/c/'")
        XCTAssertTrue(virtual.contains("prefix/d/"), "Should synthesize 'prefix/d/'")
        XCTAssertFalse(virtual.contains("prefix/"), "Should NOT synthesize the prefix itself")
    }

    func testSynthesizeVirtualFoldersSkipsExisting() {
        let keys: Set<String> = [
            "prefix/a/",           // Folder already exists as explicit marker
            "prefix/a/file.txt"
        ]

        let virtual = S3PathUtils.synthesizeVirtualFolderKeys(fromKeys: keys, prefix: "prefix/")

        XCTAssertFalse(virtual.contains("prefix/a/"), "Should NOT synthesize already-existing folder")
    }

    func testSynthesizeVirtualFoldersNilPrefix() {
        let keys: Set<String> = [
            "docs/reports/q1.pdf"
        ]

        let virtual = S3PathUtils.synthesizeVirtualFolderKeys(fromKeys: keys, prefix: nil)

        XCTAssertTrue(virtual.contains("docs/"))
        XCTAssertTrue(virtual.contains("docs/reports/"))
    }

    func testSynthesizeVirtualFoldersEmpty() {
        let keys: Set<String> = []
        let virtual = S3PathUtils.synthesizeVirtualFolderKeys(fromKeys: keys, prefix: "prefix/")
        XCTAssertTrue(virtual.isEmpty)
    }

    func testSynthesizeVirtualFoldersFlatStructure() {
        let keys: Set<String> = [
            "prefix/file1.txt",
            "prefix/file2.txt"
        ]

        let virtual = S3PathUtils.synthesizeVirtualFolderKeys(fromKeys: keys, prefix: "prefix/")
        XCTAssertTrue(virtual.isEmpty, "Flat file listing should not produce virtual folders")
    }

    // MARK: - Suggested Drive Name

    func testSuggestedDriveNameBucketOnly() {
        let name = S3PathUtils.suggestedDriveName(bucketName: "my-bucket", prefix: nil)
        XCTAssertEqual(name, "my-bucket")
    }

    func testSuggestedDriveNameBucketEmptyPrefix() {
        let name = S3PathUtils.suggestedDriveName(bucketName: "my-bucket", prefix: "")
        XCTAssertEqual(name, "my-bucket")
    }

    func testSuggestedDriveNameWithPrefix() {
        let name = S3PathUtils.suggestedDriveName(bucketName: "my-bucket", prefix: "documents/")
        XCTAssertEqual(name, "my-bucket/documents")
    }

    func testSuggestedDriveNameWithDeepPrefix() {
        let name = S3PathUtils.suggestedDriveName(bucketName: "my-bucket", prefix: "a/b/subfolder/")
        XCTAssertEqual(name, "my-bucket/subfolder")
    }

    func testSuggestedDriveNameWithPrefixNoTrailingSlash() {
        let name = S3PathUtils.suggestedDriveName(bucketName: "my-bucket", prefix: "docs")
        XCTAssertEqual(name, "my-bucket/docs")
    }
}
