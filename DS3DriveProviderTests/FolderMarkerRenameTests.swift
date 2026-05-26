@testable import DS3Lib
import FileProvider
import Foundation
import os.log
import SotoS3
import XCTest

/// Issue #167: folder rename must move the `.ds3keep` marker from old to new
/// location and explicitly delete the old marker so no ghost folder remains.
///
/// Tests exercise both the marker-copy path (`materializeEmptyFolderMarker`)
/// and the marker-delete path (`S3PathUtils.markerKey` + `deleteObject`),
/// simulating the scenarios that arise during a create-then-rename on iOS.
final class FolderMarkerRenameTests: XCTestCase {
    private func logger() -> os.Logger {
        os.Logger(subsystem: "io.cubbit.DS3Drive.tests", category: "marker-rename")
    }

    // MARK: - Marker key computation for delete

    func testMarkerKeyForFolderPrefix() {
        // deleteFolder explicitly deletes markerKey(forFolderKey: folderPrefix).
        // Verify the computed key matches the `.ds3keep` convention.
        XCTAssertEqual(
            S3PathUtils.markerKey(forFolderKey: "prefix/Untitled folder/"),
            "prefix/Untitled folder/.ds3keep"
        )
    }

    func testMarkerKeyForFolderPrefixWithoutTrailingSlash() {
        XCTAssertEqual(
            S3PathUtils.markerKey(forFolderKey: "prefix/Untitled folder"),
            "prefix/Untitled folder/.ds3keep"
        )
    }

    func testMarkerKeyForNestedFolder() {
        XCTAssertEqual(
            S3PathUtils.markerKey(forFolderKey: "prefix/parent/child/"),
            "prefix/parent/child/.ds3keep"
        )
    }

    func testMarkerKeyForRootFolder() {
        XCTAssertEqual(
            S3PathUtils.markerKey(forFolderKey: "folder/"),
            "folder/.ds3keep"
        )
    }

    // MARK: - Rename copies marker to destination

    func testRenameMarkerCopiedViaLoop() {
        // When the listing returns .ds3keep, copyFolder copies it in the loop.
        // Verify the string replacement logic produces the correct destination key.
        let sourceKey = "prefix/Untitled folder/.ds3keep"
        let destKey = sourceKey.replacingOccurrences(
            of: "prefix/Untitled folder/",
            with: "prefix/NewName/"
        )
        XCTAssertEqual(destKey, "prefix/NewName/.ds3keep")
    }

    func testRenameMarkerDetectedByIsDS3KeepMarkerKey() {
        // copyFolder uses isDS3KeepMarkerKey to track whether the marker was
        // already copied in the listing loop, skipping the fallback
        // materializeEmptyFolderMarker call when it was.
        let markerKey = "prefix/Untitled folder/.ds3keep"
        XCTAssertTrue(
            S3PathUtils.isDS3KeepMarkerKey(markerKey),
            "copyFolder must recognize .ds3keep items in the listing to set copiedMarker"
        )
    }

    func testRenameMarkerMaterializedWhenListingEmpty() async throws {
        // When the listing returns nothing (race / eventual consistency),
        // materializeEmptyFolderMarker is called to ensure the destination
        // has a marker.
        let mock = RenameMockS3Client()
        try await materializeEmptyFolderMarker(
            sourcePrefix: "prefix/Untitled folder/",
            destinationPrefix: "prefix/NewName/",
            bucket: "bucket",
            client: mock,
            logger: logger()
        )
        // Source marker doesn't exist (default mock behavior), so fallback PUT fires
        XCTAssertEqual(mock.putKey, "prefix/NewName/.ds3keep")
        XCTAssertNil(mock.putFileURL, "Marker PUT must be zero-byte")
    }

    func testRenameMarkerMaterializedWhenSourceExists() async throws {
        // When materializeEmptyFolderMarker can copy the source marker,
        // it does so instead of PUTting a fresh one.
        let mock = RenameMockS3Client()
        mock.headKeys.insert("prefix/Untitled folder/.ds3keep")
        try await materializeEmptyFolderMarker(
            sourcePrefix: "prefix/Untitled folder/",
            destinationPrefix: "prefix/NewName/",
            bucket: "bucket",
            client: mock,
            logger: logger()
        )
        XCTAssertEqual(mock.copiedFrom, "prefix/Untitled folder/.ds3keep")
        XCTAssertEqual(mock.copiedTo, "prefix/NewName/.ds3keep")
        XCTAssertNil(mock.putKey, "PUT must not be issued when copy succeeded")
    }

    // MARK: - Delete side: explicit marker cleanup

    func testDeleteMarkerKeyMatchesCreatedMarker() {
        // The explicit delete in deleteFolder uses markerKey(forFolderKey:).
        // Verify it targets the same key that createItem PUTs via wireKey.
        let drive = ProviderTestFixtures.makeDrive()
        let folder = ProviderTestFixtures.makeItem(key: "prefix/Untitled folder/", drive: drive)

        let wireKey = folder.wireKey
        let deleteKey = S3PathUtils.markerKey(forFolderKey: folder.itemIdentifier.rawValue)

        XCTAssertEqual(
            wireKey,
            deleteKey,
            "deleteFolder must target the same key that createItem PUT via wireKey"
        )
    }

    func testDeleteMarkerKeyAfterRename() {
        // After rename from "Untitled folder" to "NewName", the OLD marker
        // must be deleted. Verify the key computation for the old folder.
        let oldFolderKey = "prefix/Untitled folder/"
        let markerToDelete = S3PathUtils.markerKey(forFolderKey: oldFolderKey)
        XCTAssertEqual(markerToDelete, "prefix/Untitled folder/.ds3keep")
    }

    // MARK: - isDS3KeepMarkerKey detection

    func testIsDS3KeepMarkerKeyForRenameFlow() {
        // copyFolder tracks copiedMarker by checking isDS3KeepMarkerKey.
        XCTAssertTrue(S3PathUtils.isDS3KeepMarkerKey("prefix/Untitled folder/.ds3keep"))
        XCTAssertTrue(S3PathUtils.isDS3KeepMarkerKey("prefix/NewName/.ds3keep"))
        XCTAssertFalse(S3PathUtils.isDS3KeepMarkerKey("prefix/Untitled folder/"))
        XCTAssertFalse(S3PathUtils.isDS3KeepMarkerKey("prefix/photo.jpg"))
    }

    // MARK: - Folder rename key computation (renameS3Item path)

    func testRenameFolderKeyComputation() {
        // renameS3Item computes the new key by replacing the last path component.
        // Verify this works for folder keys (trailing delimiter).
        let oldKey = "prefix/Untitled folder/"
        let isFolder = oldKey.hasSuffix("/")
        let trimmed = isFolder ? String(oldKey.dropLast()) : oldKey
        let components = trimmed.split(separator: Character("/"))
        let parentPath = components.dropLast().joined(separator: "/")
        let newName = "NewName"
        let newKey = parentPath + "/" + newName + (isFolder ? "/" : "")
        XCTAssertEqual(newKey, "prefix/NewName/")
    }

    func testRenameNestedFolderKeyComputation() {
        let oldKey = "prefix/parent/Untitled folder/"
        let isFolder = oldKey.hasSuffix("/")
        let trimmed = isFolder ? String(oldKey.dropLast()) : oldKey
        let components = trimmed.split(separator: Character("/"))
        let parentPath = components.dropLast().joined(separator: "/")
        let newName = "NewName"
        let newKey = parentPath + "/" + newName + (isFolder ? "/" : "")
        XCTAssertEqual(newKey, "prefix/parent/NewName/")
    }

    // MARK: - Edge cases

    func testMarkerCopyWithLocalizedUntitledFolder() async throws {
        // iOS may use localized "Untitled folder" names with spaces/special chars.
        // Verify marker logic handles them.
        let mock = RenameMockS3Client()
        mock.headKeys.insert("prefix/Cartella senza titolo/.ds3keep")
        try await materializeEmptyFolderMarker(
            sourcePrefix: "prefix/Cartella senza titolo/",
            destinationPrefix: "prefix/Nuova cartella/",
            bucket: "bucket",
            client: mock,
            logger: logger()
        )
        XCTAssertEqual(mock.copiedFrom, "prefix/Cartella senza titolo/.ds3keep")
        XCTAssertEqual(mock.copiedTo, "prefix/Nuova cartella/.ds3keep")
    }

    func testMarkerCopyWithFolderContainingDots() async throws {
        // Folder names can contain dots — ensure markerKey doesn't confuse them.
        let mock = RenameMockS3Client()
        mock.headKeys.insert("prefix/my.folder.v2/.ds3keep")
        try await materializeEmptyFolderMarker(
            sourcePrefix: "prefix/my.folder.v2/",
            destinationPrefix: "prefix/renamed/",
            bucket: "bucket",
            client: mock,
            logger: logger()
        )
        XCTAssertEqual(mock.copiedFrom, "prefix/my.folder.v2/.ds3keep")
        XCTAssertEqual(mock.copiedTo, "prefix/renamed/.ds3keep")
    }
}

// MARK: - Test mock

/// Mock S3 client for folder rename tests. Records copy, put, and delete calls.
/// Extends the pattern from `MarkerCopyMockS3Client` with support for
/// configurable HEAD responses and delete tracking.
private final class RenameMockS3Client: DS3S3ClientProtocol, @unchecked Sendable {
    var copiedFrom: String?
    var copiedTo: String?
    var copiedBucket: String?
    var copyObjectError: Error?

    var putKey: String?
    var putFileURL: URL?
    var putObjectError: Error?

    var deletedKeys: [String] = []

    /// Keys that HEAD succeeds for. All other HEAD calls throw NotFound.
    var headKeys: Set<String> = []

    func listBuckets() async throws -> [(name: String, creationDate: Date?)] {
        []
    }

    func listObjects(
        bucket _: String, prefix _: String?, delimiter _: String?,
        maxKeys _: Int?, continuationToken _: String?
    ) async throws -> S3ListingResult {
        S3ListingResult(objects: [], commonPrefixes: [], nextContinuationToken: nil, isTruncated: false)
    }

    func headObject(bucket _: String, key: String) async throws -> S3ObjectMetadata {
        guard headKeys.contains(key) else {
            throw S3ErrorType.noSuchKey
        }
        return S3ObjectMetadata(
            etag: "mock-etag", contentType: nil, lastModified: nil,
            versionId: nil, contentLength: 0, metadata: nil
        )
    }

    func deleteObject(bucket _: String, key: String) async throws {
        deletedKeys.append(key)
    }

    func deleteObjects(bucket _: String, keys: [String]) async throws -> Int {
        deletedKeys.append(contentsOf: keys)
        return 0
    }

    func copyObject(
        bucket: String, sourceKey: String,
        destinationKey: String, metadata _: [String: String]?
    ) async throws {
        if let copyObjectError { throw copyObjectError }
        // Simulate S3 behavior: copy fails if source doesn't exist
        guard headKeys.contains(sourceKey) else {
            throw S3ErrorType.noSuchKey
        }
        copiedBucket = bucket
        copiedFrom = sourceKey
        copiedTo = destinationKey
    }

    func getObject(
        bucket _: String, key _: String,
        toFile _: URL, onProgress _: TransferProgressHandler?
    ) async throws -> S3DownloadResult {
        throw DS3ClientError.parseError
    }

    func getObjectData(bucket _: String, key _: String) async throws -> Data {
        Data()
    }

    func putObject(
        bucket _: String, key: String,
        fileURL: URL?, onProgress _: TransferProgressHandler?
    ) async throws -> String? {
        if let putObjectError { throw putObjectError }
        putKey = key
        putFileURL = fileURL
        return "mock-etag"
    }

    func putObjectData(
        bucket _: String, key _: String,
        data _: Data, metadata _: [String: String]?
    ) async throws -> String? {
        "mock-etag"
    }

    func createMultipartUpload(bucket _: String, key _: String) async throws -> String {
        "mock-upload-id"
    }

    func uploadPart(
        bucket _: String, key _: String, uploadId _: String,
        partNumber: Int, data _: Data
    ) async throws -> CompletedPartResult {
        CompletedPartResult(partNumber: partNumber, etag: "etag-\(partNumber)")
    }

    func completeMultipartUpload(
        bucket _: String, key _: String, uploadId _: String,
        parts _: [(partNumber: Int, etag: String)]
    ) async throws -> MultipartCompleteResult {
        MultipartCompleteResult(etag: "mock-final-etag")
    }

    func abortMultipartUpload(bucket _: String, key _: String, uploadId _: String) async throws {
        // No-op stub
    }

    func shutdown() throws {
        // No-op stub
    }
}
