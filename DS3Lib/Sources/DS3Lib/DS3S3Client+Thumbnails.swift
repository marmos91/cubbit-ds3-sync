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
        // Inclusive upper bound: `maxSinglePartBytes` is the largest size we
        // accept, matching the constant's "max 500KB" semantic. The previous
        // `<` check rejected payloads exactly at the boundary.
        guard data.count <= maxBytes else {
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

    /// Server-side copy of a thumbnail. Preserves source metadata
    /// (`x-amz-meta-source-etag`, `x-amz-meta-ds3drive-thumb-version`) by
    /// passing `metadata: nil` — Soto omits the `x-amz-metadata-directive`
    /// header and AWS S3's default behavior is COPY.
    ///
    /// Throws on `NoSuchKey` and on transient/server errors. The Phase 13
    /// rename/move cascade (D-22) maps `NoSuchKey` to "mark new key .pending,
    /// let backfill regenerate", and maps 5xx to the same fallback path.
    ///
    /// Per Phase 13 D-22, D-23.
    func copyThumbnail(
        bucket: String,
        fromKey: String,
        toKey: String
    ) async throws {
        try await copyObject(
            bucket: bucket,
            sourceKey: fromKey,
            destinationKey: toKey,
            metadata: nil
        )
    }
}

#if os(iOS)
    public extension DS3S3Client {
        /// iOS-only: fetches thumbnail bytes via URLSessionDownloadTask (writes to disk,
        /// then mmap-maps the file) to stay within the extension's 20 MB jetsam ceiling.
        /// Returns nil on HTTP 404 (cache miss). Throws URLError on other failures so
        /// callers can map via `mapThumbnailFetchError`.
        func getThumbnailBytesViaDownloadTask(bucket: String, key: String) async throws -> Data? {
            let signedURL = try await presignedGetURL(bucket: bucket, key: key, expiresIn: 300)
            let (tempURL, response) = try await URLSession.shared.download(from: signedURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            guard let http = response as? HTTPURLResponse else {
                throw URLError(.resourceUnavailable)
            }

            switch http.statusCode {
            case 404:
                return nil
            case 200 ..< 300:
                return try autoreleasepool {
                    try Data(contentsOf: tempURL, options: .alwaysMapped)
                }
            default:
                throw URLError(.resourceUnavailable)
            }
        }
    }
#endif
