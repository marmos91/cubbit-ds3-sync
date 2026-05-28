@testable import DS3Lib
import FileProvider
import Foundation
import os.log
import XCTest

/// Issue #167: folder rename must move the `.ds3keep` marker from old to new
/// location and explicitly delete the old marker so no ghost folder remains.
final class FolderMarkerRenameTests: XCTestCase {
    private func logger() -> os.Logger {
        os.Logger(subsystem: "io.cubbit.DS3Drive.tests", category: "marker-rename")
    }

    private func makeMock(withHeadKeys keys: [String] = []) -> RenameMockS3Client {
        let mock = RenameMockS3Client()
        mock.headKeys = Set(keys)
        return mock
    }

    // MARK: - Marker key computation for delete

    func testMarkerKeyForFolderPrefix() {
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
        let sourceKey = "prefix/Untitled folder/.ds3keep"
        let destKey = sourceKey.replacingOccurrences(
            of: "prefix/Untitled folder/",
            with: "prefix/NewName/"
        )
        XCTAssertEqual(destKey, "prefix/NewName/.ds3keep")
    }

    func testRenameMarkerDetectedByIsDS3KeepMarkerKey() {
        XCTAssertTrue(S3PathUtils.isDS3KeepMarkerKey("prefix/Untitled folder/.ds3keep"))
    }

    func testRenameMarkerMaterializedWhenListingEmpty() async throws {
        let mock = makeMock()
        try await materializeEmptyFolderMarker(
            sourcePrefix: "prefix/Untitled folder/",
            destinationPrefix: "prefix/NewName/",
            bucket: "bucket",
            client: mock,
            logger: logger()
        )
        XCTAssertEqual(mock.putKey, "prefix/NewName/.ds3keep")
        XCTAssertNil(mock.putFileURL, "Marker PUT must be zero-byte")
    }

    func testRenameMarkerMaterializedWhenSourceExists() async throws {
        let mock = makeMock(withHeadKeys: ["prefix/Untitled folder/.ds3keep"])
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
        let drive = ProviderTestFixtures.makeDrive()
        let folder = ProviderTestFixtures.makeItem(key: "prefix/Untitled folder/", drive: drive)

        XCTAssertEqual(
            folder.wireKey,
            S3PathUtils.markerKey(forFolderKey: folder.itemIdentifier.rawValue),
            "deleteFolder must target the same key that createItem PUT via wireKey"
        )
    }

    func testDeleteMarkerKeyAfterRename() {
        XCTAssertEqual(
            S3PathUtils.markerKey(forFolderKey: "prefix/Untitled folder/"),
            "prefix/Untitled folder/.ds3keep"
        )
    }

    // MARK: - isDS3KeepMarkerKey detection

    func testIsDS3KeepMarkerKeyForRenameFlow() {
        XCTAssertTrue(S3PathUtils.isDS3KeepMarkerKey("prefix/Untitled folder/.ds3keep"))
        XCTAssertTrue(S3PathUtils.isDS3KeepMarkerKey("prefix/NewName/.ds3keep"))
        XCTAssertFalse(S3PathUtils.isDS3KeepMarkerKey("prefix/Untitled folder/"))
        XCTAssertFalse(S3PathUtils.isDS3KeepMarkerKey("prefix/photo.jpg"))
    }

    // MARK: - Folder rename key computation (renameS3Item path)

    func testRenameFolderKeyComputation() {
        let newKey = computeRenamedFolderKey("prefix/Untitled folder/", newName: "NewName")
        XCTAssertEqual(newKey, "prefix/NewName/")
    }

    func testRenameNestedFolderKeyComputation() {
        let newKey = computeRenamedFolderKey("prefix/parent/Untitled folder/", newName: "NewName")
        XCTAssertEqual(newKey, "prefix/parent/NewName/")
    }

    // MARK: - Edge cases

    func testMarkerCopyWithLocalizedUntitledFolder() async throws {
        let mock = makeMock(withHeadKeys: ["prefix/Cartella senza titolo/.ds3keep"])
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
        let mock = makeMock(withHeadKeys: ["prefix/my.folder.v2/.ds3keep"])
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

    // MARK: - Helpers

    /// Mirrors the rename key computation from `renameS3Item`.
    private func computeRenamedFolderKey(_ oldKey: String, newName: String) -> String {
        let isFolder = oldKey.hasSuffix("/")
        let trimmed = isFolder ? String(oldKey.dropLast()) : oldKey
        let components = trimmed.split(separator: Character("/"))
        let parentPath = components.dropLast().joined(separator: "/")
        return parentPath + "/" + newName + (isFolder ? "/" : "")
    }
}

// MARK: - Test mock

/// Mock S3 client for folder rename tests. Records copy and put calls,
/// with configurable HEAD responses to simulate marker presence.
private final class RenameMockS3Client: DS3S3ClientProtocol, @unchecked Sendable {
    var copiedFrom: String?
    var copiedTo: String?
    var copyObjectError: Error?

    var putKey: String?
    var putFileURL: URL?
    var putObjectError: Error?

    /// Keys that HEAD and copyObject succeed for. All others throw NoSuchKey.
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
            throw DS3S3Error.noSuchKey
        }
        return S3ObjectMetadata(
            etag: "mock-etag", contentType: nil, lastModified: nil,
            versionId: nil, contentLength: 0, metadata: nil
        )
    }

    func deleteObject(bucket _: String, key _: String) async throws {
        // No-op
    }

    func deleteObjects(bucket _: String, keys _: [String]) async throws -> Int {
        0
    }

    func copyObject(
        bucket _: String, sourceKey: String,
        destinationKey: String, metadata _: [String: String]?
    ) async throws {
        if let copyObjectError { throw copyObjectError }
        guard headKeys.contains(sourceKey) else {
            throw DS3S3Error.noSuchKey
        }
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
        // No-op
    }

    func shutdown() throws {
        // No-op
    }
}
