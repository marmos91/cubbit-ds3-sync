import Foundation
import os.log
import SotoS3

/// Re-export Soto error types so consumers can catch S3 errors via `import DS3Lib`
/// without importing SotoS3 directly.
///
/// `S3ErrorType` only covers 9 S3-specific codes (NoSuchKey, NoSuchBucket, etc.).
/// Auth errors (InvalidAccessKeyId, SignatureDoesNotMatch, ExpiredToken) arrive as
/// `AWSClientError` or `AWSResponseError`. Use `AWSErrorType` to catch all of them.
public typealias S3ErrorType = SotoS3.S3ErrorType
public typealias AWSErrorType = SotoCore.AWSErrorType

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
    public let metadata: [String: String]?

    public init(
        etag: String?, contentType: String?, lastModified: Date?,
        versionId: String?, contentLength: Int64, metadata: [String: String]? = nil
    ) {
        self.etag = etag
        self.contentType = contentType
        self.lastModified = lastModified
        self.versionId = versionId
        self.contentLength = contentLength
        self.metadata = metadata
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

    public init(
        bytesTransferred: Int64,
        totalBytes: Int64?,
        duration: TimeInterval,
        direction: TransferDirection,
        filename: String?
    ) {
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
public final class DS3S3Client: Sendable {
    let s3: S3
    let logger = os.Logger(subsystem: LogSubsystem.provider, category: LogCategory.transfer.rawValue)

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

    deinit {
        try? awsClient.syncShutdown()
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
            contentLength: response.contentLength ?? 0,
            metadata: response.metadata
        )
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

    /// Copies an S3 object to a new key within the same bucket, with optional custom metadata.
    public func copyObject(
        bucket: String, sourceKey: String, destinationKey: String, metadata: [String: String]? = nil
    ) async throws {
        guard let copySource = "\(bucket)/\(sourceKey)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else {
            throw DS3ClientError.parseError
        }

        let request = S3.CopyObjectRequest(
            bucket: bucket,
            copySource: copySource,
            key: destinationKey,
            metadata: metadata,
            metadataDirective: (metadata?.isEmpty == false) ? .replace : nil
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

    /// Extracts the error code from any Soto error type (S3ErrorType, AWSClientError,
    /// AWSServerError, AWSResponseError). All conform to `AWSErrorType`.
    public static func s3ErrorCode(from error: Error) -> String? {
        (error as? AWSErrorType)?.errorCode
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
