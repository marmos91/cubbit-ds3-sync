import DS3CoreFFI
import Foundation
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
    case thumbnailTooLarge(size: Int, limit: Int)
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

/// Centralized S3 client backed by the Rust core (Phase 16 Plan 03).
///
/// Wraps a `DS3SessionHandle` (`DS3CoreFFI`) and translates between FFI types
/// and the Swift public surface. Until Plan 04 wires the full session through
/// `DS3Authentication`, this adapter constructs an S3-only handle via
/// `Ds3SessionHandle.s3Only(...)` — only S3 methods are reachable on that
/// handle; auth/projects/keys remain in `DS3Authentication` + `DS3SDK` until
/// Plan 04.
///
/// Per D-13: this adapter owns its own error translation (`DS3S3Error.translate(_:)`).
/// Per D-16: every catch logs the Rust error code + Display BEFORE translating.
public final class DS3S3Client: @unchecked Sendable {
    let handle: Ds3SessionHandle
    let logger = os.Logger(subsystem: LogSubsystem.provider, category: LogCategory.transfer.rawValue)

    /// The custom S3 endpoint URL, if provided at init. Nil when not configured.
    public let customEndpoint: String?

    // MARK: - Date formatting (FFI returns ISO 8601 strings)

    /// ISO 8601 parser used to deserialize the FFI's RFC 3339 / ISO 8601 timestamps.
    /// `ISO8601DateFormatter` is not Sendable; the static is annotated to
    /// allow the Swift 6 strict-concurrency mode to absorb its de-facto
    /// thread-safety (parsing-only usage on read-only formatter state).
    private nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Fallback parser without fractional seconds (some S3 implementations omit them).
    private nonisolated(unsafe) static let iso8601NoFrac: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseDate(_ isoString: String?) -> Date? {
        guard let isoString else { return nil }
        if let date = iso8601.date(from: isoString) { return date }
        return iso8601NoFrac.date(from: isoString)
    }

    // MARK: - Init

    /// Creates a Rust-backed `DS3S3Client` with the given S3 credentials.
    ///
    /// Constructs an S3-only `Ds3SessionHandle` via the FFI; Plan 04 will
    /// migrate this constructor to accept a full `Ds3SessionHandle` already
    /// authenticated through DS3Authentication.
    ///
    /// - Parameters:
    ///   - accessKeyId: The S3 access key ID
    ///   - secretAccessKey: The S3 secret access key
    ///   - endpoint: The S3 endpoint URL (required — Cubbit DS3 always uses a custom endpoint)
    ///   - timeout: Unused (the Rust core's `aws-sdk-s3` has its own timeout config). Kept
    ///     for source compatibility with pre-Plan-03 call sites.
    public init(
        accessKeyId: String,
        secretAccessKey: String,
        endpoint: String?,
        timeout _: Int64 = DefaultSettings.S3.timeoutInSeconds
    ) {
        self.customEndpoint = endpoint
        // The FFI requires a non-nil endpoint. Cubbit DS3 always passes one;
        // fail loudly if a caller violates that invariant.
        // swiftlint:disable:next force_try
        self.handle = try! Ds3SessionHandle.s3Only(
            endpoint: endpoint ?? "",
            accessKey: accessKeyId,
            secretKey: secretAccessKey,
            region: nil
        )
    }

    /// Plan 04 initializer: takes an authenticated `Ds3SessionHandle` (the
    /// singleton owned by `DS3Authentication`) and connects the S3 sub-client
    /// to it via `connectS3`. This is the canonical main-app construction
    /// path — see RESEARCH §"DS3SessionHandle Lifecycle in Swift". The
    /// extension still uses the `accessKeyId:/secretAccessKey:/endpoint:`
    /// initializer (which constructs an `s3Only` handle) because the
    /// extension has no `DS3Authentication`.
    ///
    /// - Parameters:
    ///   - authenticatedHandle: a `Ds3SessionHandle` already authenticated
    ///     via `DS3Authentication.login(...)`.
    ///   - endpoint: the S3 endpoint URL.
    ///   - accessKey: the S3 access key ID.
    ///   - secretKey: the S3 secret access key.
    /// - Throws: `DS3S3Error` if `connectS3` fails (e.g. malformed endpoint).
    public init(
        authenticatedHandle: Ds3SessionHandle,
        endpoint: String,
        accessKey: String,
        secretKey: String
    ) throws {
        self.customEndpoint = endpoint
        self.handle = authenticatedHandle
        do {
            try authenticatedHandle.connectS3(
                endpoint: endpoint,
                accessKey: accessKey,
                secretKey: secretKey,
                region: nil
            )
        } catch let rustError as Ds3Error {
            throw DS3S3Error.translate(rustError)
        }
    }

    /// Lifecycle no-op: handle ownership is via Swift's reference counting + Rust
    /// `Arc<DS3SessionHandle>`. The aws-sdk-s3 client is dropped when the handle
    /// is dropped. Kept for source compatibility with the Soto-era API.
    public func shutdown() throws {
        // Intentionally empty.
    }

    // MARK: - Bucket Operations

    /// Lists all buckets accessible with the current credentials.
    public func listBuckets() async throws -> [(name: String, creationDate: Date?)] {
        do {
            let buckets = try handle.listBuckets()
            return buckets.map { ($0.name, Self.parseDate($0.creationDate)) }
        } catch let error as Ds3Error {
            logS3Error(operation: "listBuckets", error: error)
            throw DS3S3Error.translate(error)
        }
    }

    // MARK: - List and Metadata

    /// Lists objects in an S3 bucket with the given parameters.
    /// - Note: The `encodingType` parameter is preserved for API compatibility but is
    ///   ignored — the Rust core handles URL encoding internally and always returns
    ///   decoded keys.
    public func listObjects(
        bucket: String,
        prefix: String? = nil,
        delimiter: String? = nil,
        maxKeys: Int? = nil,
        continuationToken: String? = nil,
        encodingType _: S3EncodingType? = .url
    ) async throws -> S3ListingResult {
        do {
            let result = try handle.listObjects(
                bucket: bucket,
                prefix: prefix,
                delimiter: delimiter,
                maxKeys: maxKeys.map(Int32.init),
                continuationToken: continuationToken
            )
            let objects = result.objects.map { ffi -> S3ObjectSummary in
                S3ObjectSummary(
                    key: ffi.key,
                    etag: ETagUtils.normalize(ffi.etag),
                    lastModified: Self.parseDate(ffi.lastModified),
                    size: ffi.size
                )
            }
            return S3ListingResult(
                objects: objects,
                commonPrefixes: result.commonPrefixes,
                nextContinuationToken: result.isTruncated ? result.nextContinuationToken : nil,
                isTruncated: result.isTruncated
            )
        } catch let error as Ds3Error {
            logS3Error(operation: "listObjects", error: error)
            throw DS3S3Error.translate(error)
        }
    }

    /// Retrieves metadata for an S3 object using a HEAD request.
    public func headObject(bucket: String, key: String) async throws -> S3ObjectMetadata {
        do {
            let meta = try handle.headObject(bucket: bucket, key: key)
            return S3ObjectMetadata(
                etag: ETagUtils.normalize(meta.etag),
                contentType: meta.contentType,
                lastModified: Self.parseDate(meta.lastModified),
                versionId: meta.versionId,
                contentLength: meta.contentLength,
                metadata: meta.metadata
            )
        } catch let error as Ds3Error {
            logS3Error(operation: "headObject", error: error)
            throw DS3S3Error.translate(error)
        }
    }

    // MARK: - Delete

    /// Deletes a single object from S3.
    public func deleteObject(bucket: String, key: String) async throws {
        do {
            try handle.deleteObject(bucket: bucket, key: key)
        } catch let error as Ds3Error {
            logS3Error(operation: "deleteObject", error: error)
            throw DS3S3Error.translate(error)
        }
    }

    /// Deletes multiple objects from S3 in a single batch request.
    /// - Returns: The number of errors (failed deletions); 0 if all succeeded.
    ///   The FFI returns the count of successful deletions; we convert to error
    ///   count to preserve the legacy Soto-era contract.
    public func deleteObjects(bucket: String, keys: [String]) async throws -> Int {
        do {
            let successCount = try handle.deleteObjects(bucket: bucket, keys: keys)
            return max(0, keys.count - Int(successCount))
        } catch let error as Ds3Error {
            logS3Error(operation: "deleteObjects", error: error)
            throw DS3S3Error.translate(error)
        }
    }

    // MARK: - Copy

    /// Copies an S3 object to a new key within the same bucket, with optional custom metadata.
    public func copyObject(
        bucket: String, sourceKey: String, destinationKey: String, metadata: [String: String]? = nil
    ) async throws {
        do {
            try handle.copyObject(
                bucket: bucket,
                sourceKey: sourceKey,
                destKey: destinationKey,
                metadata: metadata
            )
        } catch let error as Ds3Error {
            logS3Error(operation: "copyObject", error: error)
            throw DS3S3Error.translate(error)
        }
    }

    // MARK: - Utility

    /// Safely decode S3 URL-encoded keys.
    /// Preserved for source compatibility with pre-Plan-03 callers. The Rust core
    /// already decodes keys, so this helper is now a no-op for FFI-returned values.
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

    // MARK: - S3 Error Inspection (post-swap helpers)

    /// Extracts the AWS-style S3 error code substring from any error.
    /// Returns nil if not a known DS3S3Error/Ds3Error, or if the case has no
    /// specific AWS code mapping.
    public static func s3ErrorCode(from error: Error) -> String? {
        if let ds3Error = error as? DS3S3Error {
            let code = ds3Error.errorCode
            return code.isEmpty ? nil : code
        }
        if let rust = error as? Ds3Error {
            return s3ErrorCode(from: DS3S3Error.translate(rust))
        }
        return nil
    }

    /// Checks if an error is an S3 "not found" error (NoSuchKey, NoSuchBucket).
    public static func isNotFoundError(_ error: Error) -> Bool {
        if let ds3Error = error as? DS3S3Error { return ds3Error.isNotFound }
        if let rust = error as? Ds3Error { return DS3S3Error.translate(rust).isNotFound }
        return false
    }

    /// Checks if an error is a recoverable S3 auth error (InvalidAccessKeyId,
    /// SignatureDoesNotMatch, ExpiredToken).
    public static func isRecoverableAuthError(_ error: Error) -> Bool {
        if let ds3Error = error as? DS3S3Error { return ds3Error.isRecoverableAuthError }
        if let rust = error as? Ds3Error { return DS3S3Error.translate(rust).isRecoverableAuthError }
        return false
    }

    /// Formats any error so logs surface the AWS error code instead of
    /// Foundation's opaque "Module.Type error N" bridge form.
    ///
    /// Renamed from `describeSotoError` per Plan 03 (no more Soto). Behavior:
    /// - DS3S3Error: returns `errorDescription` with code prefix.
    /// - Ds3Error: returns `String(describing:)` (Rust Display is already
    ///   structured and grep-friendly — e.g. "S3 error: NoSuchKey: ...").
    /// - Other errors: returns `String(describing:)`.
    public static func describeS3Error(_ error: Error) -> String {
        if let ds3Error = error as? DS3S3Error {
            if let code = s3ErrorCode(from: ds3Error) {
                return "\(code): \(ds3Error.errorDescription ?? String(describing: ds3Error))"
            }
            return ds3Error.errorDescription ?? String(describing: ds3Error)
        }
        return String(describing: error)
    }

    /// Soto-era name retained as an alias so legacy call sites compile during Plan 03.
    /// New code should call `describeS3Error(_:)`. Plan 05 will delete this alias.
    public static func describeSotoError(_ error: Error) -> String {
        describeS3Error(error)
    }

    // MARK: - Logging helper

    func logS3Error(operation: String, error: Ds3Error) {
        let code = ds3ErrorCode(message: ds3ErrorMessage(error))
        logger.error(
            "S3 \(operation, privacy: .public) failed: code=\(code, privacy: .public) \(String(describing: error), privacy: .public)"
        )
    }
}

// MARK: - S3 EncodingType replacement

/// Source-compatibility shim for `S3.EncodingType` (formerly Soto-provided).
/// The Rust core handles URL encoding internally, so this value is ignored at
/// the FFI boundary. Kept as an enum so existing call sites with
/// `encodingType: .url` compile unchanged.
public enum S3EncodingType: Sendable {
    case url
}

/// Helper: extract the Display string from a `Ds3Error` (UniFFI flat_error).
/// All variants carry the Rust `Display` text in the `message` field.
func ds3ErrorMessage(_ rust: Ds3Error) -> String {
    switch rust {
    case let .InvalidUrl(message),
         let .ServerError(message),
         let .JsonError(message),
         let .Encoding(message),
         let .LoggedOut(message),
         let .TokenExpired(message),
         let .Missing2Fa(message),
         let .CookieError(message),
         let .MissingUploadId(message),
         let .EmptyFileData(message),
         let .MissingETag(message),
         let .ParseError(message),
         let .UnableToOpenFile(message),
         let .IoError(message),
         let .HttpError(message),
         let .S3Error(message),
         let .AuthError(message):
        message
    }
}
