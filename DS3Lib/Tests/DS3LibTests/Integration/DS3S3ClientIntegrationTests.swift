import XCTest
@testable import DS3Lib

/// Thread-safe boolean flag for use in @Sendable closures.
private final class LockedFlag: @unchecked Sendable {
    private var _value = false
    private let lock = NSLock()

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func set() {
        lock.lock()
        defer { lock.unlock() }
        _value = true
    }
}

/// Integration tests for DS3S3Client against the real Cubbit DS3 S3 API.
/// Tests CRUD operations, multipart uploads, and listing.
final class DS3S3ClientIntegrationTests: DS3S3IntegrationTestCase {
    // MARK: - List Buckets

    func testListBuckets() async throws {
        let buckets = try await s3Client.listBuckets()
        XCTAssertFalse(buckets.isEmpty, "Test account should have at least one bucket")

        let bucketNames = buckets.map(\.name)
        XCTAssertTrue(bucketNames.contains(bucket), "Test bucket '\(bucket!)' should be in the list")
    }

    // MARK: - Put and Get Object

    func testPutAndGetObject() async throws {
        let key = testPrefix + "test-file.txt"
        let content = "Hello from DS3 Drive integration tests!"
        let contentData = content.data(using: .utf8)!

        // Create a temp file
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        try contentData.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        // Upload
        let etag = try await s3Client.putObject(
            bucket: bucket,
            key: key,
            fileURL: tempFile
        )
        XCTAssertNotNil(etag, "Upload should return an ETag")

        // Download
        let downloadFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        FileManager.default.createFile(atPath: downloadFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: downloadFile) }

        let result = try await s3Client.getObject(
            bucket: bucket,
            key: key,
            toFile: downloadFile
        )
        XCTAssertNotNil(result.etag)
        XCTAssertEqual(result.contentLength, Int64(contentData.count))

        let downloaded = try Data(contentsOf: downloadFile)
        XCTAssertEqual(String(data: downloaded, encoding: .utf8), content)
    }

    // MARK: - Put Object Data (in-memory)

    func testPutObjectData() async throws {
        let key = testPrefix + "data-upload.json"
        let data = "{\"test\": true}".data(using: .utf8)!

        let etag = try await s3Client.putObjectData(bucket: bucket, key: key, data: data)
        XCTAssertNotNil(etag)

        // Verify with HEAD
        let metadata = try await s3Client.headObject(bucket: bucket, key: key)
        XCTAssertEqual(metadata.contentLength, Int64(data.count))
    }

    // MARK: - Head Object

    func testHeadObject() async throws {
        let key = testPrefix + "head-test.txt"
        let data = "test content".data(using: .utf8)!
        _ = try await s3Client.putObjectData(bucket: bucket, key: key, data: data)

        let metadata = try await s3Client.headObject(bucket: bucket, key: key)

        XCTAssertNotNil(metadata.etag)
        XCTAssertEqual(metadata.contentLength, Int64(data.count))
        XCTAssertNotNil(metadata.lastModified)
    }

    func testHeadObjectNonExistentThrows() async throws {
        let key = testPrefix + "definitely-does-not-exist-\(UUID().uuidString).txt"

        do {
            _ = try await s3Client.headObject(bucket: bucket, key: key)
            XCTFail("HEAD on non-existent key should throw")
        } catch {
            XCTAssertTrue(DS3S3Client.isNotFoundError(error))
        }
    }

    // MARK: - List Objects

    func testListObjectsWithPrefix() async throws {
        // Create a few test files
        for i in 1 ... 3 {
            let key = testPrefix + "list-test/file\(i).txt"
            _ = try await s3Client.putObjectData(
                bucket: bucket, key: key, data: "content \(i)".data(using: .utf8)!
            )
        }

        let result = try await s3Client.listObjects(
            bucket: bucket,
            prefix: testPrefix + "list-test/",
            delimiter: "/"
        )

        XCTAssertEqual(result.objects.count, 3)
        XCTAssertFalse(result.isTruncated)
    }

    func testListObjectsWithDelimiterShowsPrefixes() async throws {
        // Create files in subfolders
        _ = try await s3Client.putObjectData(
            bucket: bucket,
            key: testPrefix + "folders/a/file.txt",
            data: "a".data(using: .utf8)!
        )
        _ = try await s3Client.putObjectData(
            bucket: bucket,
            key: testPrefix + "folders/b/file.txt",
            data: "b".data(using: .utf8)!
        )

        let result = try await s3Client.listObjects(
            bucket: bucket,
            prefix: testPrefix + "folders/",
            delimiter: "/"
        )

        XCTAssertEqual(result.commonPrefixes.count, 2, "Should see two subfolder prefixes")
        XCTAssertTrue(result.commonPrefixes.contains(testPrefix + "folders/a/"))
        XCTAssertTrue(result.commonPrefixes.contains(testPrefix + "folders/b/"))
    }

    func testListObjectsPagination() async throws {
        // Create enough files to test pagination with maxKeys=2
        for i in 1 ... 5 {
            _ = try await s3Client.putObjectData(
                bucket: bucket,
                key: testPrefix + "pagination/file\(i).txt",
                data: "content".data(using: .utf8)!
            )
        }

        // First page
        let page1 = try await s3Client.listObjects(
            bucket: bucket,
            prefix: testPrefix + "pagination/",
            maxKeys: 2
        )
        XCTAssertEqual(page1.objects.count, 2)
        XCTAssertTrue(page1.isTruncated)
        XCTAssertNotNil(page1.nextContinuationToken)

        // Second page
        let page2 = try await s3Client.listObjects(
            bucket: bucket,
            prefix: testPrefix + "pagination/",
            maxKeys: 2,
            continuationToken: page1.nextContinuationToken
        )
        XCTAssertEqual(page2.objects.count, 2)

        // Third page
        let page3 = try await s3Client.listObjects(
            bucket: bucket,
            prefix: testPrefix + "pagination/",
            maxKeys: 2,
            continuationToken: page2.nextContinuationToken
        )
        XCTAssertEqual(page3.objects.count, 1)
        XCTAssertFalse(page3.isTruncated)
    }

    // MARK: - Delete Object

    func testDeleteObject() async throws {
        let key = testPrefix + "delete-me.txt"
        _ = try await s3Client.putObjectData(
            bucket: bucket, key: key, data: "delete me".data(using: .utf8)!
        )

        // Verify it exists
        _ = try await s3Client.headObject(bucket: bucket, key: key)

        // Delete it
        try await s3Client.deleteObject(bucket: bucket, key: key)

        // Verify it's gone
        do {
            _ = try await s3Client.headObject(bucket: bucket, key: key)
            XCTFail("Object should be deleted")
        } catch {
            XCTAssertTrue(DS3S3Client.isNotFoundError(error))
        }
    }

    func testDeleteObjects() async throws {
        let keys = (1 ... 3).map { testPrefix + "batch-delete/file\($0).txt" }
        for key in keys {
            _ = try await s3Client.putObjectData(
                bucket: bucket, key: key, data: "data".data(using: .utf8)!
            )
        }

        let errorCount = try await s3Client.deleteObjects(bucket: bucket, keys: keys)
        XCTAssertEqual(errorCount, 0)

        // Verify all deleted
        let result = try await s3Client.listObjects(
            bucket: bucket, prefix: testPrefix + "batch-delete/"
        )
        XCTAssertTrue(result.objects.isEmpty)
    }

    // MARK: - Copy Object

    func testCopyObject() async throws {
        let sourceKey = testPrefix + "copy-source.txt"
        let destKey = testPrefix + "copy-dest.txt"
        let content = "copy me"

        _ = try await s3Client.putObjectData(
            bucket: bucket, key: sourceKey, data: content.data(using: .utf8)!
        )

        try await s3Client.copyObject(
            bucket: bucket, sourceKey: sourceKey, destinationKey: destKey
        )

        // Verify copy exists
        let metadata = try await s3Client.headObject(bucket: bucket, key: destKey)
        XCTAssertEqual(metadata.contentLength, Int64(content.utf8.count))
    }

    // MARK: - Multipart Upload

    func testMultipartUpload() async throws {
        let key = testPrefix + "multipart-test.bin"
        let partSize = DefaultSettings.S3.multipartUploadPartSize
        // Create data that's just over one part (5 MB + 1 KB)
        let totalSize = partSize + 1024
        let data = Data(repeating: 0xAB, count: totalSize)

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bin")
        try data.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        // Create multipart upload
        let uploadId = try await s3Client.createMultipartUpload(bucket: bucket, key: key)
        XCTAssertFalse(uploadId.isEmpty)

        // Upload parts
        let part1Data = try DS3S3Client.readFilePart(at: tempFile, offset: 0, length: partSize)
        let part1 = try await s3Client.uploadPart(
            bucket: bucket, key: key, uploadId: uploadId, partNumber: 1, data: part1Data
        )
        XCTAssertEqual(part1.partNumber, 1)
        XCTAssertFalse(part1.etag.isEmpty)

        let part2Data = try DS3S3Client.readFilePart(at: tempFile, offset: partSize, length: 1024)
        let part2 = try await s3Client.uploadPart(
            bucket: bucket, key: key, uploadId: uploadId, partNumber: 2, data: part2Data
        )
        XCTAssertEqual(part2.partNumber, 2)

        // Complete
        let result = try await s3Client.completeMultipartUpload(
            bucket: bucket, key: key, uploadId: uploadId,
            parts: [(1, part1.etag), (2, part2.etag)]
        )
        XCTAssertFalse(result.etag.isEmpty)

        // Verify uploaded size
        let metadata = try await s3Client.headObject(bucket: bucket, key: key)
        XCTAssertEqual(metadata.contentLength, Int64(totalSize))
    }

    func testAbortMultipartUpload() async throws {
        let key = testPrefix + "abort-multipart.bin"

        let uploadId = try await s3Client.createMultipartUpload(bucket: bucket, key: key)

        // Abort without completing
        try await s3Client.abortMultipartUpload(bucket: bucket, key: key, uploadId: uploadId)

        // Verify the object doesn't exist
        do {
            _ = try await s3Client.headObject(bucket: bucket, key: key)
            XCTFail("Aborted multipart should not create an object")
        } catch {
            XCTAssertTrue(DS3S3Client.isNotFoundError(error))
        }
    }

    // MARK: - Folder Operations

    func testCreateFolderMarker() async throws {
        let key = testPrefix + "new-folder/"
        _ = try await s3Client.putObject(bucket: bucket, key: key, fileURL: nil)

        let metadata = try await s3Client.headObject(bucket: bucket, key: key)
        XCTAssertEqual(metadata.contentLength, 0)
    }

    // MARK: - Special Characters in Keys

    func testKeyWithSpaces() async throws {
        let key = testPrefix + "folder with spaces/file name.txt"
        _ = try await s3Client.putObjectData(
            bucket: bucket, key: key, data: "space test".data(using: .utf8)!
        )

        let result = try await s3Client.listObjects(
            bucket: bucket, prefix: testPrefix + "folder with spaces/"
        )
        XCTAssertEqual(result.objects.count, 1)
        XCTAssertEqual(result.objects.first?.key, key)
    }

    func testKeyWithUnicode() async throws {
        let key = testPrefix + "folder/café-résumé.txt"
        _ = try await s3Client.putObjectData(
            bucket: bucket, key: key, data: "unicode test".data(using: .utf8)!
        )

        let metadata = try await s3Client.headObject(bucket: bucket, key: key)
        XCTAssertNotNil(metadata.etag)
    }

    // MARK: - Progress Tracking

    func testUploadWithProgressCallback() async throws {
        let key = testPrefix + "progress-test.txt"
        let data = Data(repeating: 0x42, count: 10240) // 10 KB

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        try data.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let progressCalled = LockedFlag()
        _ = try await s3Client.putObject(
            bucket: bucket,
            key: key,
            fileURL: tempFile,
            onProgress: { progress in
                progressCalled.set()
            }
        )

        XCTAssertTrue(progressCalled.value, "Progress callback should be called during upload")
    }

    // MARK: - ETag Consistency

    func testETagConsistency() async throws {
        let key = testPrefix + "etag-test.txt"
        let data = "etag consistency check".data(using: .utf8)!

        let putEtag = try await s3Client.putObjectData(bucket: bucket, key: key, data: data)
        let headMetadata = try await s3Client.headObject(bucket: bucket, key: key)

        let normalizedPut = ETagUtils.normalize(putEtag)
        let normalizedHead = ETagUtils.normalize(headMetadata.etag)

        XCTAssertNotNil(normalizedPut)
        XCTAssertNotNil(normalizedHead)
        XCTAssertEqual(normalizedPut, normalizedHead, "PUT and HEAD ETags should match after normalization")
    }
}
