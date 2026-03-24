import Foundation
@testable import DS3Lib

/// Mock S3 client for unit testing. Records all calls and returns configurable responses.
final class MockDS3S3Client: DS3S3ClientProtocol, @unchecked Sendable {
    // MARK: - Configuration

    var listBucketsResult: [(name: String, creationDate: Date?)] = []
    var listObjectsResult: S3ListingResult = S3ListingResult(
        objects: [], commonPrefixes: [], nextContinuationToken: nil, isTruncated: false
    )
    var headObjectResult: S3ObjectMetadata?
    var deleteObjectError: Error?
    var deleteObjectsErrorCount: Int = 0
    var copyObjectError: Error?
    var getObjectResult: S3DownloadResult?
    var putObjectEtag: String? = "mock-etag"
    var putObjectDataEtag: String? = "mock-etag"
    var createMultipartUploadId: String = "mock-upload-id"
    var uploadPartResult: CompletedPartResult?
    var completeMultipartResult: MultipartCompleteResult = MultipartCompleteResult(etag: "mock-final-etag")
    var shouldThrow: Error?

    // MARK: - Call Recording

    private let lock = NSLock()
    private var _calls: [String] = []

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    private func record(_ call: String) {
        lock.lock()
        defer { lock.unlock() }
        _calls.append(call)
    }

    func resetCalls() {
        lock.lock()
        defer { lock.unlock() }
        _calls.removeAll()
    }

    // MARK: - DS3S3ClientProtocol

    func listBuckets() async throws -> [(name: String, creationDate: Date?)] {
        record("listBuckets")
        if let error = shouldThrow { throw error }
        return listBucketsResult
    }

    func listObjects(
        bucket: String,
        prefix: String?,
        delimiter: String?,
        maxKeys: Int?,
        continuationToken: String?
    ) async throws -> S3ListingResult {
        record("listObjects(bucket:\(bucket),prefix:\(prefix ?? "nil"))")
        if let error = shouldThrow { throw error }
        return listObjectsResult
    }

    func headObject(bucket: String, key: String) async throws -> S3ObjectMetadata {
        record("headObject(key:\(key))")
        if let error = shouldThrow { throw error }
        guard let result = headObjectResult else {
            throw DS3ClientError.parseError
        }
        return result
    }

    func deleteObject(bucket: String, key: String) async throws {
        record("deleteObject(key:\(key))")
        if let error = deleteObjectError ?? shouldThrow { throw error }
    }

    func deleteObjects(bucket: String, keys: [String]) async throws -> Int {
        record("deleteObjects(count:\(keys.count))")
        if let error = shouldThrow { throw error }
        return deleteObjectsErrorCount
    }

    func copyObject(
        bucket: String, sourceKey: String, destinationKey: String, metadata: [String: String]?
    ) async throws {
        record("copyObject(from:\(sourceKey),to:\(destinationKey))")
        if let error = copyObjectError ?? shouldThrow { throw error }
    }

    func getObject(
        bucket: String,
        key: String,
        toFile fileURL: URL,
        onProgress: TransferProgressHandler?
    ) async throws -> S3DownloadResult {
        record("getObject(key:\(key))")
        if let error = shouldThrow { throw error }
        guard let result = getObjectResult else {
            throw DS3ClientError.parseError
        }
        return result
    }

    func putObject(
        bucket: String,
        key: String,
        fileURL: URL?,
        onProgress: TransferProgressHandler?
    ) async throws -> String? {
        record("putObject(key:\(key))")
        if let error = shouldThrow { throw error }
        return putObjectEtag
    }

    func putObjectData(
        bucket: String,
        key: String,
        data: Data
    ) async throws -> String? {
        record("putObjectData(key:\(key),size:\(data.count))")
        if let error = shouldThrow { throw error }
        return putObjectDataEtag
    }

    func createMultipartUpload(bucket: String, key: String) async throws -> String {
        record("createMultipartUpload(key:\(key))")
        if let error = shouldThrow { throw error }
        return createMultipartUploadId
    }

    func uploadPart(
        bucket: String,
        key: String,
        uploadId: String,
        partNumber: Int,
        data: Data
    ) async throws -> CompletedPartResult {
        record("uploadPart(key:\(key),part:\(partNumber))")
        if let error = shouldThrow { throw error }
        return uploadPartResult ?? CompletedPartResult(partNumber: partNumber, etag: "etag-part-\(partNumber)")
    }

    func completeMultipartUpload(
        bucket: String,
        key: String,
        uploadId: String,
        parts: [(partNumber: Int, etag: String)]
    ) async throws -> MultipartCompleteResult {
        record("completeMultipartUpload(key:\(key),parts:\(parts.count))")
        if let error = shouldThrow { throw error }
        return completeMultipartResult
    }

    func abortMultipartUpload(bucket: String, key: String, uploadId: String) async throws {
        record("abortMultipartUpload(key:\(key),uploadId:\(uploadId))")
        if let error = shouldThrow { throw error }
    }

    func shutdown() throws {
        record("shutdown")
    }
}
