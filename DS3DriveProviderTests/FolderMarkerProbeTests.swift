@testable import DS3Lib
import Foundation
import os.log
import SotoS3
import XCTest

/// Tests for `probeFolderExists` — the two-step HEAD probe that checks the
/// `.ds3keep` marker key first, then falls back to the legacy `<folder>/`
/// zero-byte placeholder. Introduced by #170 to prevent reimported folders
/// from being silently re-PUT after Phase A.
final class FolderMarkerProbeTests: XCTestCase {
    private func logger() -> os.Logger {
        os.Logger(subsystem: "io.cubbit.DS3Drive.tests", category: "marker-probe")
    }

    // MARK: - Marker key found

    func testReturnsMetadataWhenMarkerKeyExists() async throws {
        let mock = ProbeMockS3Client()
        mock.existingKeys["prefix/photos/.ds3keep"] = S3ObjectMetadata(
            etag: "\"abc\"", contentType: nil,
            lastModified: Date(timeIntervalSince1970: 1_000_000),
            versionId: nil, contentLength: 0
        )

        let result = try await probeFolderExists(
            folderKey: "prefix/photos/",
            bucket: "test-bucket",
            client: mock,
            logger: logger()
        )

        XCTAssertNotNil(result, "Should return metadata when .ds3keep marker exists")
        XCTAssertEqual(result?.etag, "\"abc\"")
        XCTAssertEqual(
            mock.headedKeys, ["prefix/photos/.ds3keep"],
            "Should only HEAD the marker key, not the legacy key"
        )
    }

    // MARK: - Marker key missing, legacy key found

    func testFallsBackToLegacyKeyWhenMarkerMissing() async throws {
        let mock = ProbeMockS3Client()
        // No marker key — HEAD returns 404
        // Legacy key exists
        mock.existingKeys["prefix/photos/"] = S3ObjectMetadata(
            etag: "\"legacy\"", contentType: nil,
            lastModified: Date(timeIntervalSince1970: 2_000_000),
            versionId: nil, contentLength: 0
        )

        let result = try await probeFolderExists(
            folderKey: "prefix/photos/",
            bucket: "test-bucket",
            client: mock,
            logger: logger()
        )

        XCTAssertNotNil(result, "Should return metadata from legacy key")
        XCTAssertEqual(result?.etag, "\"legacy\"")
        XCTAssertEqual(
            mock.headedKeys,
            ["prefix/photos/.ds3keep", "prefix/photos/"],
            "Should HEAD marker first, then legacy key"
        )
    }

    // MARK: - Both keys missing

    func testReturnsNilWhenBothKeysMissing() async throws {
        let mock = ProbeMockS3Client()
        // No keys exist

        let result = try await probeFolderExists(
            folderKey: "prefix/photos/",
            bucket: "test-bucket",
            client: mock,
            logger: logger()
        )

        XCTAssertNil(result, "Should return nil when neither key exists")
        XCTAssertEqual(
            mock.headedKeys,
            ["prefix/photos/.ds3keep", "prefix/photos/"],
            "Should HEAD both keys before returning nil"
        )
    }

    // MARK: - Non-404 error propagates from marker HEAD

    func testNonNotFoundErrorPropagatesFromMarkerHEAD() async throws {
        let mock = ProbeMockS3Client()
        mock.headObjectError = NSError(
            domain: "S3", code: 403,
            userInfo: [NSLocalizedDescriptionKey: "AccessDenied"]
        )

        do {
            _ = try await probeFolderExists(
                folderKey: "prefix/photos/",
                bucket: "test-bucket",
                client: mock,
                logger: logger()
            )
            XCTFail("Expected non-404 error to propagate")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "S3")
            XCTAssertEqual(error.code, 403)
        }

        XCTAssertEqual(
            mock.headedKeys, ["prefix/photos/.ds3keep"],
            "Should not attempt legacy key after non-404 error"
        )
    }

    // MARK: - Non-404 error propagates from legacy HEAD

    func testNonNotFoundErrorPropagatesFromLegacyHEAD() async throws {
        let mock = ProbeMockS3Client()
        // Marker key → 404
        // Legacy key → 500
        mock.legacyKeyError = NSError(
            domain: "S3", code: 500,
            userInfo: [NSLocalizedDescriptionKey: "InternalError"]
        )

        do {
            _ = try await probeFolderExists(
                folderKey: "prefix/photos/",
                bucket: "test-bucket",
                client: mock,
                logger: logger()
            )
            XCTFail("Expected non-404 error to propagate from legacy HEAD")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "S3")
            XCTAssertEqual(error.code, 500)
        }

        XCTAssertEqual(
            mock.headedKeys,
            ["prefix/photos/.ds3keep", "prefix/photos/"],
            "Should attempt both keys before propagating legacy error"
        )
    }

    // MARK: - Root-level folder (no prefix)

    func testRootLevelFolderProbe() async throws {
        let mock = ProbeMockS3Client()
        mock.existingKeys["docs/.ds3keep"] = S3ObjectMetadata(
            etag: "\"root-marker\"", contentType: nil,
            lastModified: nil, versionId: nil, contentLength: 0
        )

        let result = try await probeFolderExists(
            folderKey: "docs/",
            bucket: "test-bucket",
            client: mock,
            logger: logger()
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.etag, "\"root-marker\"")
        XCTAssertEqual(mock.headedKeys, ["docs/.ds3keep"])
    }
}

// MARK: - Test mock

/// Minimal `DS3S3ClientProtocol` mock that tracks `headObject` calls and
/// returns metadata from a pre-configured key→metadata map. Keys not in
/// the map produce a `S3ErrorType.noSuchKey` (404).
///
/// Supports optional error injection:
/// - `headObjectError` — injected for ALL HEAD calls (simulates 403, 500, etc.)
/// - `legacyKeyError` — injected only for non-marker HEAD calls (marker 404, legacy error)
final class ProbeMockS3Client: DS3S3ClientProtocol, @unchecked Sendable {
    /// Keys that "exist" on S3. HEAD returns the associated metadata.
    var existingKeys: [String: S3ObjectMetadata] = [:]

    /// If set, ALL headObject calls throw this error.
    var headObjectError: Error?

    /// If set, headObject throws this error for non-marker keys (after
    /// the marker key has already returned 404).
    var legacyKeyError: Error?

    /// Records every key passed to `headObject` in order.
    private(set) var headedKeys: [String] = []

    func headObject(bucket _: String, key: String) async throws -> S3ObjectMetadata {
        headedKeys.append(key)

        if let headObjectError {
            throw headObjectError
        }

        if let legacyKeyError, !key.hasSuffix(DefaultSettings.S3.markerFileName) {
            throw legacyKeyError
        }

        if let metadata = existingKeys[key] {
            return metadata
        }

        throw S3ErrorType.noSuchKey
    }

    // MARK: - Stubs (unused by probe tests)

    func listBuckets() async throws -> [(name: String, creationDate: Date?)] {
        []
    }

    func listObjects(
        bucket _: String, prefix _: String?, delimiter _: String?,
        maxKeys _: Int?, continuationToken _: String?
    ) async throws -> S3ListingResult {
        S3ListingResult(objects: [], commonPrefixes: [], nextContinuationToken: nil, isTruncated: false)
    }

    func deleteObject(bucket _: String, key _: String) async throws {
        // No-op stub
    }
    func deleteObjects(bucket _: String, keys _: [String]) async throws -> Int {
        0
    }

    func copyObject(
        bucket _: String, sourceKey _: String,
        destinationKey _: String, metadata _: [String: String]?
    ) async throws {
        // No-op stub
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
        bucket _: String, key _: String,
        fileURL _: URL?, onProgress _: TransferProgressHandler?
    ) async throws -> String? {
        "mock-etag"
    }

    func putObjectData(
        bucket _: String, key _: String,
        data _: Data, metadata _: [String: String]?
    ) async throws -> String? {
        "mock-etag"
    }

    func createMultipartUpload(bucket _: String, key _: String) async throws -> String {
        "mock-id"
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
