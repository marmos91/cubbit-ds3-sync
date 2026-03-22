// swiftlint:disable file_length
import Foundation
import SotoS3
import os.log

// MARK: - Supporting Types

/// Result of an S3 ListObjectsV2 call.
public struct S3ListingResult: Sendable {
    public let objects: [S3ObjectSummary]
    public let commonPrefixes: [String]
    public let nextContinuationToken: String?
    public let isTruncated: Bool

    public init(
        objects: [S3ObjectSummary],
        commonPrefixes: [String],
        nextContinuationToken: String?,
        isTruncated: Bool
    ) {
        self.objects = objects
        self.commonPrefixes = commonPrefixes
        self.nextContinuationToken = nextContinuationToken
        self.isTruncated = isTruncated
    }
}

/// Summary of an S3 object from a listing response.
public struct S3ObjectSummary: Sendable {
    public let key: String
    public let etag: String?
    public let lastModified: Date?
    public let size: Int64

    public init(key: String, etag: String?, lastModified: Date?, size: Int64) {
        self.key = key
        self.etag = etag
        self.lastModified = lastModified
        self.size = size
    }
}

/// Metadata from an S3 HeadObject response.
public struct S3ObjectMetadata: Sendable {
    public let etag: String?
    public let contentType: String?
    public let lastModified: Date?
    public let versionId: String?
    public let contentLength: Int64

    public init(etag: String?, contentType: String?, lastModified: Date?, versionId: String?, contentLength: Int64) {
        self.etag = etag
        self.contentType = contentType
        self.lastModified = lastModified
        self.versionId = versionId
        self.contentLength = contentLength
    }
}

/// Metadata from an S3 GetObject response (download result).
public struct S3DownloadResult: Sendable {
    public let etag: String?
    public let contentType: String?
    public let lastModified: Date?
    public let contentLength: Int64

    public init(etag: String?, contentType: String?, lastModified: Date?, contentLength: Int64) {
        self.etag = etag
        self.contentType = contentType
        self.lastModified = lastModified
        self.contentLength = contentLength
    }
}

/// Progress information for transfers.
public struct TransferProgress: Sendable {
    public let bytesTransferred: Int64
    public let totalBytes: Int64?
    public let duration: TimeInterval
    public let direction: TransferDirection
    public let filename: String?

    public init(bytesTransferred: Int64, totalBytes: Int64?, duration: TimeInterval, direction: TransferDirection, filename: String?) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.duration = duration
        self.direction = direction
        self.filename = filename
    }
}

/// Progress callback type for transfer operations.
public typealias TransferProgressHandler = @Sendable (TransferProgress) -> Void

/// Errors specific to DS3S3Client operations.
public enum DS3ClientError: Error, Sendable {
    case missingUploadId
    case emptyFileData
    case missingETag
    case parseError
    case unableToOpenFile
}

/// Groups the constant parameters shared across all parts of a multipart upload.
public struct MultipartUploadContext: Sendable {
    public let bucket: String
    public let key: String
    public let uploadId: String
    public let totalSize: Int64

    public init(bucket: String, key: String, uploadId: String, totalSize: Int64) {
        self.bucket = bucket
        self.key = key
        self.uploadId = uploadId
        self.totalSize = totalSize
    }
}

/// Describes an upload part by its position within the file.
public struct PartDescriptor: Sendable {
    public let partNumber: Int
    public let offset: Int
    public let length: Int

    public init(partNumber: Int, offset: Int, length: Int) {
        self.partNumber = partNumber
        self.offset = offset
        self.length = length
    }
}

/// Result of a completed part upload.
public struct CompletedPartResult: Sendable {
    public let partNumber: Int
    public let etag: String

    public init(partNumber: Int, etag: String) {
        self.partNumber = partNumber
        self.etag = etag
    }
}

/// Result of a multipart upload completion.
public struct MultipartCompleteResult: Sendable {
    public let etag: String

    public init(etag: String) {
        self.etag = etag
    }
}

// MARK: - DS3S3Client

/// Centralized S3 client that wraps all SotoS3 operations.
/// Other targets should use this instead of importing SotoS3 directly.
public final class DS3S3Client: Sendable { // swiftlint:disable:this type_body_length
    private let s3: S3
    private let logger = os.Logger(subsystem: LogSubsystem.provider, category: LogCategory.transfer.rawValue)

    /// The underlying AWSClient, exposed for lifecycle management (shutdown).
    public let awsClient: AWSClient

    /// Creates a new DS3S3Client with the given credentials and endpoint.
    /// - Parameters:
    ///   - accessKeyId: The AWS access key ID
    ///   - secretAccessKey: The AWS secret access key
    ///   - endpoint: The S3 endpoint URL
    ///   - timeout: Optional timeout in seconds (defaults to DefaultSettings.S3.timeoutInSeconds)
    public init(
        accessKeyId: String,
        secretAccessKey: String,
        endpoint: String?,
        timeout: Int64 = DefaultSettings.S3.timeoutInSeconds
    ) {
        let client = AWSClient(
            credentialProvider: .static(
                accessKeyId: accessKeyId,
                secretAccessKey: secretAccessKey
            ),
            httpClientProvider: .createNew
        )
        self.awsClient = client
        self.s3 = S3(client: client, endpoint: endpoint, timeout: .seconds(timeout))
    }

    /// Shuts down the underlying AWSClient. Must be called when the client is no longer needed.
    public func shutdown() throws {
        try awsClient.syncShutdown()
    }

    // MARK: - Bucket Operations

    /// Lists all buckets accessible with the current credentials.
    public func listBuckets() async throws -> [(name: String, creationDate: Date?)] {
        let response = try await s3.listBuckets()
        return (response.buckets ?? []).map { bucket in
            (name: bucket.name ?? "<No name>", creationDate: bucket.creationDate)
        }
    }

    // MARK: - List and Metadata

    /// Lists objects in an S3 bucket with the given parameters.
    /// - Parameters:
    ///   - bucket: The bucket name
    ///   - prefix: Optional prefix to filter objects
    ///   - delimiter: Optional delimiter for hierarchical listing
    ///   - maxKeys: Maximum number of keys to return
    ///   - continuationToken: Token for paginated results
    ///   - encodingType: URL encoding type (defaults to .url)
    /// - Returns: An S3ListingResult containing objects, prefixes, and pagination info
    public func listObjects(
        bucket: String,
        prefix: String? = nil,
        delimiter: String? = nil,
        maxKeys: Int? = nil,
        continuationToken: String? = nil,
        encodingType: S3.EncodingType? = .url
    ) async throws -> S3ListingResult {
        let request = S3.ListObjectsV2Request(
            bucket: bucket,
            continuationToken: continuationToken,
            delimiter: delimiter,
            encodingType: encodingType,
            maxKeys: maxKeys,
            prefix: prefix
        )

        let response = try await s3.listObjectsV2(request)

        let decode: (String) -> String? = encodingType == .url
            ? { try? Self.decodeS3Key($0) }
            : { $0 }

        let objects = (response.contents ?? []).compactMap { object -> S3ObjectSummary? in
            guard let rawKey = object.key, let key = decode(rawKey) else { return nil }
            return S3ObjectSummary(
                key: key,
                etag: ETagUtils.normalize(object.eTag),
                lastModified: object.lastModified,
                size: object.size ?? 0
            )
        }

        let prefixes: [String] = (response.commonPrefixes ?? []).compactMap { commonPrefix in
            guard let rawPrefix = commonPrefix.prefix else { return nil }
            return decode(rawPrefix)
        }

        let isTruncated = response.isTruncated ?? false

        return S3ListingResult(
            objects: objects,
            commonPrefixes: prefixes,
            nextContinuationToken: isTruncated ? response.nextContinuationToken : nil,
            isTruncated: isTruncated
        )
    }

    /// Retrieves metadata for an S3 object using a HEAD request.
    public func headObject(bucket: String, key: String) async throws -> S3ObjectMetadata {
        let request = S3.HeadObjectRequest(bucket: bucket, key: key)
        let response = try await s3.headObject(request)

        return S3ObjectMetadata(
            etag: ETagUtils.normalize(response.eTag),
            contentType: response.contentType,
            lastModified: response.lastModified,
            versionId: response.versionId,
            contentLength: response.contentLength ?? 0
        )
    }

    // MARK: - Downloads

    /// Downloads an S3 object to a file via streaming.
    /// - Parameters:
    ///   - bucket: The bucket name
    ///   - key: The object key
    ///   - toFile: The destination file URL (must already exist as an empty file)
    ///   - onProgress: Optional callback for download progress
    /// - Returns: Download result with metadata from the response
    public func getObject(
        bucket: String,
        key: String,
        toFile fileURL: URL,
        onProgress: TransferProgressHandler? = nil
    ) async throws -> S3DownloadResult {
        let request = S3.GetObjectRequest(bucket: bucket, key: key)
        let response = try await streamToFile(request: request, fileURL: fileURL, key: key, onProgress: onProgress)

        return S3DownloadResult(
            etag: ETagUtils.normalize(response.eTag),
            contentType: response.contentType,
            lastModified: response.lastModified,
            contentLength: response.contentLength ?? 0
        )
    }

    /// Downloads a byte range of an S3 object to a file.
    public func getObjectRange(
        bucket: String,
        key: String,
        range: String,
        toFile fileURL: URL,
        onProgress: TransferProgressHandler? = nil
    ) async throws {
        let request = S3.GetObjectRequest(bucket: bucket, key: key, range: range)
        _ = try await streamToFile(request: request, fileURL: fileURL, key: key, onProgress: onProgress)
    }

    /// Streams an S3 GetObject response to a local file, reporting progress along the way.
    private func streamToFile(
        request: S3.GetObjectRequest,
        fileURL: URL,
        key: String,
        onProgress: TransferProgressHandler?
    ) async throws -> S3.GetObjectOutput {
        let fileHandle = try FileHandle(forWritingTo: fileURL)
        defer { fileHandle.closeFile() }

        var bytesDownloaded: Int64 = 0
        let downloadStart = Date()
        let filename = key.components(separatedBy: "/").last

        return try await s3.getObjectStreaming(request) { byteBuffer, eventLoop in
            let bufferSize = Int64(byteBuffer.readableBytes)
            byteBuffer.withUnsafeReadableBytes { bufferPointer in
                guard let baseAddress = bufferPointer.baseAddress else { return }
                let data = Data(
                    bytesNoCopy: UnsafeMutableRawPointer(mutating: baseAddress),
                    count: bufferPointer.count,
                    deallocator: .none
                )
                fileHandle.write(data)
            }
            bytesDownloaded += bufferSize

            let duration = Date().timeIntervalSince(downloadStart)
            onProgress?(TransferProgress(
                bytesTransferred: bytesDownloaded,
                totalBytes: nil,
                duration: duration,
                direction: .download,
                filename: filename
            ))

            return eventLoop.makeSucceededFuture(())
        }
    }

    // MARK: - Uploads

    /// Uploads a file to S3 using a streaming PUT request.
    /// - Parameters:
    ///   - bucket: The bucket name
    ///   - key: The object key
    ///   - fileURL: The local file URL to upload (nil for creating empty folder markers)
    ///   - onProgress: Optional callback for upload progress
    /// - Returns: The ETag of the uploaded object, or nil
    public func putObject(
        bucket: String,
        key: String,
        fileURL: URL? = nil,
        onProgress: TransferProgressHandler? = nil
    ) async throws -> String? {
        var request: S3.PutObjectRequest
        var size: Int64 = 0

        if let fileURL {
            let uploadHandle: FileHandle
            do {
                uploadHandle = try FileHandle(forReadingFrom: fileURL)
            } catch {
                throw DS3ClientError.unableToOpenFile
            }

            let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            size = (fileAttributes[.size] as? Int64) ?? 0

            let chunkSize = 65_536
            let payload = AWSPayload.stream(size: Int(size)) { eventLoop in
                let chunk = uploadHandle.readData(ofLength: chunkSize)
                if chunk.isEmpty {
                    try? uploadHandle.close()
                    return eventLoop.makeSucceededFuture(.end)
                }
                return eventLoop.makeSucceededFuture(.byteBuffer(ByteBuffer(data: chunk)))
            }

            request = S3.PutObjectRequest(body: payload, bucket: bucket, key: key)
        } else {
            request = S3.PutObjectRequest(bucket: bucket, key: key)
        }

        let uploadStart = Date()
        let filename = key.components(separatedBy: "/").last

        let response = try await s3.putObject(request)

        let duration = Date().timeIntervalSince(uploadStart)
        onProgress?(TransferProgress(
            bytesTransferred: size,
            totalBytes: size,
            duration: duration,
            direction: .upload,
            filename: filename
        ))

        return response.eTag
    }

    /// Uploads a file to S3 using a standard PUT request with in-memory Data.
    /// Useful for small files in the share extension.
    public func putObjectData(
        bucket: String,
        key: String,
        data: Data
    ) async throws -> String? {
        let request = S3.PutObjectRequest(
            body: .byteBuffer(ByteBuffer(data: data)),
            bucket: bucket,
            key: key
        )
        let response = try await s3.putObject(request)
        return response.eTag
    }

    // MARK: - Multipart Upload

    /// Creates a multipart upload and returns the upload ID.
    public func createMultipartUpload(bucket: String, key: String) async throws -> String {
        let request = S3.CreateMultipartUploadRequest(bucket: bucket, key: key)
        let response = try await s3.createMultipartUpload(request)
        guard let uploadId = response.uploadId else {
            throw DS3ClientError.missingUploadId
        }
        return uploadId
    }

    /// Uploads a single part of a multipart upload.
    /// - Returns: A CompletedPartResult with the part number and ETag
    public func uploadPart(
        bucket: String,
        key: String,
        uploadId: String,
        partNumber: Int,
        data: Data
    ) async throws -> CompletedPartResult {
        let request = S3.UploadPartRequest(
            body: .byteBuffer(ByteBuffer(data: data)),
            bucket: bucket,
            key: key,
            partNumber: partNumber,
            uploadId: uploadId
        )

        let response = try await s3.uploadPart(request)

        guard let etag = response.eTag, !etag.isEmpty else {
            throw DS3ClientError.missingETag
        }

        return CompletedPartResult(partNumber: partNumber, etag: etag)
    }

    /// Completes a multipart upload.
    /// - Returns: The final ETag of the completed object
    public func completeMultipartUpload(
        bucket: String,
        key: String,
        uploadId: String,
        parts: [(partNumber: Int, etag: String)]
    ) async throws -> MultipartCompleteResult {
        let completedParts = parts
            .sorted { $0.partNumber < $1.partNumber }
            .map { S3.CompletedPart(eTag: $0.etag, partNumber: $0.partNumber) }

        let request = S3.CompleteMultipartUploadRequest(
            bucket: bucket,
            key: key,
            multipartUpload: S3.CompletedMultipartUpload(parts: completedParts),
            uploadId: uploadId
        )

        let response = try await s3.completeMultipartUpload(request)

        guard let etag = response.eTag, !etag.isEmpty else {
            throw DS3ClientError.missingETag
        }

        return MultipartCompleteResult(etag: etag)
    }

    /// Aborts a multipart upload.
    public func abortMultipartUpload(bucket: String, key: String, uploadId: String) async throws {
        let request = S3.AbortMultipartUploadRequest(bucket: bucket, key: key, uploadId: uploadId)
        _ = try await s3.abortMultipartUpload(request)
    }

    /// Performs a full multipart upload with concurrent parts, resume via PendingUploadStore, and abort on failure.
    public func putObjectMultipart(
        bucket: String,
        key: String,
        fileURL: URL,
        totalSize: Int64,
        pendingUploadStore: PendingUploadStore,
        driveId: UUID,
        onPartComplete: (@Sendable (Int) async -> Void)? = nil,
        onProgress: TransferProgressHandler? = nil
    ) async throws -> String {
        let pending = await pendingUploadStore.pendingUpload(forKey: key)
        let uploadId: String
        var alreadyCompletedParts: [(partNumber: Int, etag: String)] = []

        if let pending, pending.bucket == bucket {
            logger.info("Resuming multipart upload \(pending.uploadId, privacy: .public) for key \(key, privacy: .public)")
            uploadId = pending.uploadId
            alreadyCompletedParts = pending.completedPartETags.map { ($0.key, $0.value) }
        } else {
            uploadId = try await createMultipartUpload(bucket: bucket, key: key)
            await pendingUploadStore.register(uploadId: uploadId, bucket: bucket, key: key, driveId: driveId)
        }

        do {
            let newParts = try await uploadRemainingParts(
                bucket: bucket, key: key, uploadId: uploadId, fileURL: fileURL,
                totalSize: totalSize, alreadyCompletedParts: alreadyCompletedParts,
                pendingUploadStore: pendingUploadStore,
                onPartComplete: onPartComplete, onProgress: onProgress
            )

            let allCompleted = alreadyCompletedParts + newParts.map { ($0.partNumber, $0.etag) }
            logger.debug("Completing multipart upload for \(key, privacy: .public) with \(allCompleted.count) parts")

            let result = try await completeMultipartUpload(
                bucket: bucket, key: key, uploadId: uploadId, parts: allCompleted
            )

            await pendingUploadStore.remove(forKey: key)
            logger.info("Multipart upload complete for key \(key, privacy: .public) with ETag \(result.etag, privacy: .public)")
            return result.etag
        } catch {
            logger.error("Multipart upload failed for key \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            do {
                try await abortMultipartUpload(bucket: bucket, key: key, uploadId: uploadId)
            } catch {
                logger.warning("Failed to abort multipart upload \(uploadId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            await pendingUploadStore.remove(forKey: key)
            throw error
        }
    }

    /// Uploads remaining parts concurrently, returning the newly completed parts.
    private func uploadRemainingParts( // swiftlint:disable:this function_parameter_count
        bucket: String, key: String, uploadId: String, fileURL: URL,
        totalSize: Int64, alreadyCompletedParts: [(partNumber: Int, etag: String)],
        pendingUploadStore: PendingUploadStore,
        onPartComplete: (@Sendable (Int) async -> Void)?,
        onProgress: TransferProgressHandler?
    ) async throws -> [CompletedPartResult] {
        let completedPartNumbers = Set(alreadyCompletedParts.map(\.partNumber))
        let filename = key.components(separatedBy: "/").last
        let partSize = DefaultSettings.S3.multipartUploadPartSize
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSizeInt = (fileAttributes[.size] as? Int) ?? 0

        if fileSizeInt == 0 {
            logger.warning("Data is empty. Aborting multipart and failing.")
            try await abortMultipartUpload(bucket: bucket, key: key, uploadId: uploadId)
            throw DS3ClientError.emptyFileData
        }

        let allParts = stride(from: 0, to: fileSizeInt, by: partSize).enumerated().map { index, offset in
            PartDescriptor(partNumber: index + 1, offset: offset, length: min(partSize, fileSizeInt - offset))
        }
        let remainingParts = allParts.filter { !completedPartNumbers.contains($0.partNumber) }
        let maxConcurrency = DefaultSettings.S3.multipartUploadConcurrency

        return try await withThrowingTaskGroup(of: CompletedPartResult.self) { group in
            var results: [CompletedPartResult] = []
            var partIterator = remainingParts.makeIterator()

            func enqueueNext() {
                guard let part = partIterator.next() else { return }
                group.addTask {
                    let data = try Self.readFilePart(at: fileURL, offset: part.offset, length: part.length)
                    let uploadStart = Date()
                    let result = try await self.uploadPart(
                        bucket: bucket, key: key, uploadId: uploadId,
                        partNumber: part.partNumber, data: data
                    )
                    let transferTime = Date().timeIntervalSince(uploadStart)
                    onProgress?(TransferProgress(
                        bytesTransferred: Int64(data.count), totalBytes: totalSize,
                        duration: transferTime, direction: .upload, filename: filename
                    ))
                    return result
                }
            }

            for _ in 0..<min(maxConcurrency, remainingParts.count) { enqueueNext() }

            for try await completedPart in group {
                results.append(completedPart)
                await pendingUploadStore.markPartCompleted(
                    key: key, partNumber: completedPart.partNumber, etag: completedPart.etag
                )
                await onPartComplete?(completedPart.partNumber)
                enqueueNext()
            }

            return results
        }
    }

    // MARK: - Delete

    /// Deletes a single object from S3.
    public func deleteObject(bucket: String, key: String) async throws {
        let request = S3.DeleteObjectRequest(bucket: bucket, key: key)
        _ = try await s3.deleteObject(request)
    }

    /// Deletes multiple objects from S3 in a single batch request.
    /// - Returns: The number of errors (failed deletions)
    public func deleteObjects(bucket: String, keys: [String]) async throws -> Int {
        let objects = keys.map { S3.ObjectIdentifier(key: $0) }
        let request = S3.DeleteObjectsRequest(
            bucket: bucket,
            delete: S3.Delete(objects: objects, quiet: true)
        )
        let response = try await s3.deleteObjects(request)
        return response.errors?.count ?? 0
    }

    // MARK: - Copy

    /// Copies an S3 object to a new key within the same bucket.
    public func copyObject(bucket: String, sourceKey: String, destinationKey: String) async throws {
        guard let copySource = "\(bucket)/\(sourceKey)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw DS3ClientError.parseError
        }

        let request = S3.CopyObjectRequest(
            bucket: bucket,
            copySource: copySource,
            key: destinationKey
        )
        _ = try await s3.copyObject(request)
    }

    // MARK: - Utility

    /// Safely decode S3 URL-encoded keys.
    /// S3 with `encodingType: .url` uses `+` for spaces (form-URL style),
    /// but Swift's `removingPercentEncoding` only handles `%XX` sequences.
    /// We first replace `+` with `%20`, then percent-decode.
    /// Literal `+` characters in keys are returned by S3 as `%2B`, so this is safe.
    public static func decodeS3Key(_ key: String) throws -> String {
        let normalized = key.replacingOccurrences(of: "+", with: "%20")
        guard let decoded = normalized.removingPercentEncoding else {
            throw DS3ClientError.parseError
        }
        return decoded
    }

    /// Reads a chunk of a file at the specified offset and length.
    public static func readFilePart(at fileURL: URL, offset: Int, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        handle.seek(toFileOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: length), !data.isEmpty else {
            throw DS3ClientError.emptyFileData
        }
        return data
    }

    // MARK: - S3 Error Inspection

    /// Checks if an error is an S3ErrorType and returns the error code if so.
    /// This allows callers to handle S3 errors without importing SotoS3.
    public static func s3ErrorCode(from error: Error) -> String? {
        if let s3Error = error as? S3ErrorType {
            return s3Error.errorCode
        }
        return nil
    }

    /// Checks if an error is an S3 "not found" error (NoSuchKey, NotFound).
    public static func isNotFoundError(_ error: Error) -> Bool {
        guard let code = s3ErrorCode(from: error) else { return false }
        return code == "NoSuchKey" || code == "NotFound"
    }

    /// Checks if an error is a recoverable S3 auth error.
    public static func isRecoverableAuthError(_ error: Error) -> Bool {
        guard let code = s3ErrorCode(from: error) else { return false }
        return S3ErrorRecovery.isRecoverableAuthError(code)
    }

}
// swiftlint:enable file_length
