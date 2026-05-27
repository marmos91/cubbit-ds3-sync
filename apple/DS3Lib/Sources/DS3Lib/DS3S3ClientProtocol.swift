import Foundation

/// Protocol abstracting S3 client operations for testability.
/// Allows unit tests to inject mock implementations without hitting real S3.
public protocol DS3S3ClientProtocol: Sendable {
    // MARK: - Bucket Operations

    func listBuckets() async throws -> [(name: String, creationDate: Date?)]

    // MARK: - List and Metadata

    func listObjects(
        bucket: String,
        prefix: String?,
        delimiter: String?,
        maxKeys: Int?,
        continuationToken: String?
    ) async throws -> S3ListingResult

    func headObject(bucket: String, key: String) async throws -> S3ObjectMetadata

    // MARK: - Delete

    func deleteObject(bucket: String, key: String) async throws
    func deleteObjects(bucket: String, keys: [String]) async throws -> Int

    // MARK: - Copy

    func copyObject(
        bucket: String, sourceKey: String, destinationKey: String, metadata: [String: String]?
    ) async throws

    // MARK: - Downloads

    func getObject(
        bucket: String,
        key: String,
        toFile fileURL: URL,
        onProgress: TransferProgressHandler?
    ) async throws -> S3DownloadResult

    /// In-memory GET; intended for small payloads where a temp-file round-trip
    /// would be wasteful (e.g. thumbnails).
    func getObjectData(bucket: String, key: String) async throws -> Data

    // MARK: - Uploads

    func putObject(
        bucket: String,
        key: String,
        fileURL: URL?,
        onProgress: TransferProgressHandler?
    ) async throws -> String?

    /// Single-part PUT with optional user-metadata. Pass BARE keys; Soto
    /// prepends `x-amz-meta-` automatically.
    func putObjectData(
        bucket: String,
        key: String,
        data: Data,
        metadata: [String: String]?
    ) async throws -> String?

    // MARK: - Multipart Upload

    func createMultipartUpload(bucket: String, key: String) async throws -> String

    func uploadPart(
        bucket: String,
        key: String,
        uploadId: String,
        partNumber: Int,
        data: Data
    ) async throws -> CompletedPartResult

    func completeMultipartUpload(
        bucket: String,
        key: String,
        uploadId: String,
        parts: [(partNumber: Int, etag: String)]
    ) async throws -> MultipartCompleteResult

    func abortMultipartUpload(bucket: String, key: String, uploadId: String) async throws

    // MARK: - Lifecycle

    func shutdown() throws
}

// MARK: - Convenience defaults

public extension DS3S3ClientProtocol {
    /// Backwards-compatible 3-arg overload: forwards to the metadata-aware variant
    /// with `metadata: nil`. Existing call sites stay green.
    func putObjectData(
        bucket: String,
        key: String,
        data: Data
    ) async throws -> String? {
        try await putObjectData(bucket: bucket, key: key, data: data, metadata: nil)
    }
}
