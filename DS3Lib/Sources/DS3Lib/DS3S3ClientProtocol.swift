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

    // MARK: - Uploads

    func putObject(
        bucket: String,
        key: String,
        fileURL: URL?,
        onProgress: TransferProgressHandler?
    ) async throws -> String?

    func putObjectData(
        bucket: String,
        key: String,
        data: Data
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
