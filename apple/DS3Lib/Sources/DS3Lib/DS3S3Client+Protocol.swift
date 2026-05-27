import Foundation

// MARK: - DS3S3ClientProtocol Conformance

extension DS3S3Client: DS3S3ClientProtocol {
    public func listObjects(
        bucket: String,
        prefix: String?,
        delimiter: String?,
        maxKeys: Int?,
        continuationToken: String?
    ) async throws -> S3ListingResult {
        try await listObjects(
            bucket: bucket,
            prefix: prefix,
            delimiter: delimiter,
            maxKeys: maxKeys,
            continuationToken: continuationToken,
            encodingType: .url
        )
    }
}
