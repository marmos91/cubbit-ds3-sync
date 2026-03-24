import XCTest
@testable import DS3Lib

/// Tests that the mock S3 client records calls and returns configured responses.
final class MockDS3S3ClientTests: XCTestCase {
    var mock: MockDS3S3Client!

    override func setUp() {
        mock = MockDS3S3Client()
    }

    // MARK: - Call Recording

    func testRecordsListBuckets() async throws {
        mock.listBucketsResult = [("bucket-1", nil), ("bucket-2", Date())]

        let result = try await mock.listBuckets()

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].name, "bucket-1")
        XCTAssertTrue(mock.calls.contains("listBuckets"))
    }

    func testRecordsListObjects() async throws {
        mock.listObjectsResult = S3ListingResult(
            objects: [S3ObjectSummary(key: "file.txt", etag: "abc", lastModified: nil, size: 42)],
            commonPrefixes: [],
            nextContinuationToken: nil,
            isTruncated: false
        )

        let result = try await mock.listObjects(
            bucket: "test", prefix: "docs/", delimiter: "/", maxKeys: nil, continuationToken: nil
        )

        XCTAssertEqual(result.objects.count, 1)
        XCTAssertTrue(mock.calls.first?.contains("listObjects") == true)
    }

    func testRecordsDeleteObject() async throws {
        try await mock.deleteObject(bucket: "b", key: "file.txt")
        XCTAssertEqual(mock.calls, ["deleteObject(key:file.txt)"])
    }

    func testRecordsCopyObject() async throws {
        try await mock.copyObject(
            bucket: "b", sourceKey: "old.txt", destinationKey: "new.txt", metadata: nil
        )
        XCTAssertEqual(mock.calls, ["copyObject(from:old.txt,to:new.txt)"])
    }

    func testRecordsPutObject() async throws {
        let etag = try await mock.putObject(bucket: "b", key: "file.txt", fileURL: nil, onProgress: nil)
        XCTAssertEqual(etag, "mock-etag")
        XCTAssertTrue(mock.calls.contains("putObject(key:file.txt)"))
    }

    func testRecordsMultipartFlow() async throws {
        let uploadId = try await mock.createMultipartUpload(bucket: "b", key: "big.zip")
        XCTAssertEqual(uploadId, "mock-upload-id")

        let part = try await mock.uploadPart(
            bucket: "b", key: "big.zip", uploadId: uploadId, partNumber: 1, data: Data([0x00])
        )
        XCTAssertEqual(part.partNumber, 1)

        let result = try await mock.completeMultipartUpload(
            bucket: "b", key: "big.zip", uploadId: uploadId,
            parts: [(1, part.etag)]
        )
        XCTAssertEqual(result.etag, "mock-final-etag")

        XCTAssertEqual(mock.calls.count, 3)
    }

    // MARK: - Error Injection

    func testThrowsConfiguredError() async {
        mock.shouldThrow = DS3ClientError.parseError

        do {
            _ = try await mock.listBuckets()
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is DS3ClientError)
        }
    }

    func testDeleteObjectSpecificError() async {
        mock.deleteObjectError = DS3ClientError.missingETag

        do {
            try await mock.deleteObject(bucket: "b", key: "file.txt")
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is DS3ClientError)
        }
    }

    // MARK: - Call Reset

    func testResetCalls() async throws {
        _ = try await mock.listBuckets()
        XCTAssertFalse(mock.calls.isEmpty)

        mock.resetCalls()
        XCTAssertTrue(mock.calls.isEmpty)
    }

    // MARK: - Shutdown

    func testShutdownRecorded() throws {
        try mock.shutdown()
        XCTAssertEqual(mock.calls, ["shutdown"])
    }
}
