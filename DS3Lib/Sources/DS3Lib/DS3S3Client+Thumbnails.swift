import Foundation

/// Soto prepends `x-amz-meta-` to user-metadata keys; pass bare keys in the dict.
public extension DS3S3ClientProtocol {
    /// Single-part PUT. Throws `DS3ClientError.thumbnailTooLarge` if `data.count`
    /// exceeds `DefaultSettings.Thumbnail.maxSinglePartBytes` so callers can
    /// recover (skip + mark `.failed`) instead of crashing the host process.
    func putThumbnail(
        bucket: String,
        key: String,
        data: Data,
        sourceETag: String
    ) async throws -> String {
        let maxBytes = DefaultSettings.Thumbnail.maxSinglePartBytes
        guard data.count < maxBytes else {
            throw DS3ClientError.thumbnailTooLarge(size: data.count, limit: maxBytes)
        }

        // Strip CR/LF defensively — a hostile S3-compatible endpoint could
        // return an ETag containing control chars and we forward it as a
        // user-metadata header.
        let safeETag = sourceETag
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")

        let metadata: [String: String] = [
            DefaultSettings.Thumbnail.sourceETagMetadataKey: safeETag,
            DefaultSettings.Thumbnail.formatVersionMetadataKey: "\(DefaultSettings.Thumbnail.formatVersion)"
        ]

        guard let etag = try await putObjectData(
            bucket: bucket, key: key, data: data, metadata: metadata
        )
        else {
            throw DS3ClientError.missingETag
        }
        return etag
    }

    /// Returns nil on 404; throws on other errors.
    func getThumbnailBytes(
        bucket: String,
        key: String
    ) async throws -> Data? {
        do {
            return try await getObjectData(bucket: bucket, key: key)
        } catch {
            if DS3S3Client.isNotFoundError(error) { return nil }
            throw error
        }
    }

    /// Silent on 404; throws on other errors.
    func deleteThumbnail(
        bucket: String,
        key: String
    ) async throws {
        do {
            try await deleteObject(bucket: bucket, key: key)
        } catch {
            if DS3S3Client.isNotFoundError(error) { return }
            throw error
        }
    }
}
