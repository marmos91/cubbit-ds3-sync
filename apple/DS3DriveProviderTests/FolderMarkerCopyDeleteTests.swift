@testable import DS3Lib
import FileProvider
import Foundation
import os.log
import XCTest

/// Phase A: empty-folder copy must produce a `.ds3keep` marker at the
/// destination, regardless of whether the source had one (new) or not
/// (legacy `<folder>/` placeholder).
final class FolderMarkerCopyDeleteTests: XCTestCase {
    private func logger() -> os.Logger {
        os.Logger(subsystem: "io.cubbit.DS3Drive.tests", category: "marker-copy")
    }

    func testCopySourceMarkerWhenItExists() async throws {
        let mock = MarkerCopyMockS3Client()
        try await materializeEmptyFolderMarker(
            sourcePrefix: "prefix/src/",
            destinationPrefix: "prefix/dst/",
            bucket: "bucket",
            client: mock,
            logger: logger()
        )
        XCTAssertEqual(mock.copiedFrom, "prefix/src/.ds3keep")
        XCTAssertEqual(mock.copiedTo, "prefix/dst/.ds3keep")
        XCTAssertEqual(mock.copiedBucket, "bucket")
        XCTAssertNil(mock.putKey, "PUT must not be issued when copy succeeded")
    }

    func testFallsBackToPutWhenSourceMarkerMissing() async throws {
        let mock = MarkerCopyMockS3Client()
        // Soto's canonical NoSuchKey — `DS3S3Client.isNotFoundError(_:)` recovers
        // `errorCode == "NoSuchKey"` via the `DS3S3Error` conformance.
        mock.copyObjectError = DS3S3Error.noSuchKey
        try await materializeEmptyFolderMarker(
            sourcePrefix: "prefix/src/",
            destinationPrefix: "prefix/dst/",
            bucket: "bucket",
            client: mock,
            logger: logger()
        )
        XCTAssertEqual(
            mock.putKey,
            "prefix/dst/.ds3keep",
            "Fallback PUT must target the destination marker key"
        )
        XCTAssertNil(mock.putFileURL, "Marker PUT must be zero-byte (fileURL nil)")
    }

    func testReThrowsNonNotFoundError() async {
        let mock = MarkerCopyMockS3Client()
        mock.copyObjectError = NSError(domain: "S3", code: 500, userInfo: nil)
        do {
            try await materializeEmptyFolderMarker(
                sourcePrefix: "prefix/src/",
                destinationPrefix: "prefix/dst/",
                bucket: "bucket",
                client: mock,
                logger: logger()
            )
            XCTFail("Expected non-NotFound error to propagate")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "S3", "Original error domain must survive")
            XCTAssertEqual(error.code, 500, "Original error code must survive")
            XCTAssertNil(mock.putKey, "PUT must not be issued on non-NotFound error")
        }
    }

    func testFallbackPutFailurePropagates() async {
        let mock = MarkerCopyMockS3Client()
        mock.copyObjectError = DS3S3Error.noSuchKey
        mock.putObjectError = NSError(
            domain: "S3", code: 403,
            userInfo: [NSLocalizedDescriptionKey: "AccessDenied"]
        )
        do {
            try await materializeEmptyFolderMarker(
                sourcePrefix: "prefix/src/",
                destinationPrefix: "prefix/dst/",
                bucket: "bucket",
                client: mock,
                logger: logger()
            )
            XCTFail("Expected PUT failure to propagate after copy NotFound")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "S3")
            XCTAssertEqual(error.code, 403)
        }
    }
}

// MARK: - Test mock

/// Minimal `DS3S3ClientProtocol` mock that records `copyObject` and
/// `putObject` calls. Configurable error injection. All other protocol
/// methods stubbed to throw or return empty — see `HookMockS3Client` in
/// `UploadHookTests.swift` for the canonical stub list.
final class MarkerCopyMockS3Client: DS3S3ClientProtocol, @unchecked Sendable {
    var copiedBucket: String?
    var copiedFrom: String?
    var copiedTo: String?
    var copyObjectError: Error?

    var putKey: String?
    var putFileURL: URL?
    var putObjectError: Error?

    func listBuckets() async throws -> [(name: String, creationDate: Date?)] {
        []
    }

    func listObjects(
        bucket _: String, prefix _: String?, delimiter _: String?,
        maxKeys _: Int?, continuationToken _: String?
    ) async throws -> S3ListingResult {
        S3ListingResult(objects: [], commonPrefixes: [], nextContinuationToken: nil, isTruncated: false)
    }

    func headObject(bucket _: String, key _: String) async throws -> S3ObjectMetadata {
        throw DS3ClientError.parseError
    }

    func deleteObject(bucket _: String, key _: String) async throws {
        // No-op stub — marker-copy tests don't observe delete.
    }

    func deleteObjects(bucket _: String, keys _: [String]) async throws -> Int {
        0
    }

    func copyObject(
        bucket: String, sourceKey: String,
        destinationKey: String, metadata _: [String: String]?
    ) async throws {
        if let copyObjectError { throw copyObjectError }
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
        CompletedPartResult(partNumber: partNumber, etag: "etag-part-\(partNumber)")
    }

    func completeMultipartUpload(
        bucket _: String, key _: String, uploadId _: String,
        parts _: [(partNumber: Int, etag: String)]
    ) async throws -> MultipartCompleteResult {
        MultipartCompleteResult(etag: "mock-final-etag")
    }

    func abortMultipartUpload(bucket _: String, key _: String, uploadId _: String) async throws {
        // No-op stub — marker-copy tests don't observe multipart.
    }

    func shutdown() throws {
        // No-op stub — mock has no resources to release.
    }
}
