import Foundation

/// Result of inspecting a bucket's `.thumbnails/` prefix for pre-existing content.
public enum ThumbnailPrefixState: Sendable, Equatable {
    /// No `.thumbnails/` content exists under the drive prefix.
    case empty
    /// All sampled `.thumbnails/` keys match DS3Drive's structural layout.
    case matchesOurs
    /// At least one sampled key doesn't match DS3Drive's layout.
    /// The first offending key is provided for logging.
    case conflicting(sampleKey: String)
}

public extension DS3S3ClientProtocol {
    /// Inspects the `.thumbnails/` prefix with a timeout (default 10 seconds).
    /// Returns `.empty` on timeout or network error (fail-open per D-07, Pitfall 5).
    /// Convenience wrapper used by both macOS and iOS drive-setup wizards.
    func inspectThumbnailPrefixWithTimeout(
        bucket: String,
        prefix: String?,
        timeoutSeconds: Int = 10
    ) async -> ThumbnailPrefixState {
        do {
            return try await withThrowingTaskGroup(of: ThumbnailPrefixState.self) { group in
                group.addTask {
                    try await self.inspectThumbnailPrefix(bucket: bucket, prefix: prefix)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    throw CancellationError()
                }
                guard let result = try await group.next() else { return .empty }
                group.cancelAll()
                return result
            }
        } catch {
            return .empty
        }
    }

    /// Inspects the `.thumbnails/` prefix under a drive's S3 path to detect pre-existing
    /// content that may conflict with DS3Drive's thumbnail layout.
    /// Makes a single ListObjectsV2 call with MaxKeys=10.
    func inspectThumbnailPrefix(bucket: String, prefix: String?) async throws -> ThumbnailPrefixState {
        let thumbPrefix = S3PathUtils.thumbnailsPrefix(forDrivePrefix: prefix)

        let result = try await listObjects(
            bucket: bucket,
            prefix: thumbPrefix,
            delimiter: nil,
            maxKeys: 10,
            continuationToken: nil
        )

        guard !result.objects.isEmpty else {
            return .empty
        }

        // Raster allow-list for the stripped original extension (D-02c)
        let rasterExtensions: Set = [
            "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tiff"
        ]

        for object in result.objects {
            let key = object.key

            // Check (b): thumbnail key must end in .jpg
            guard key.hasSuffix(".jpg") else {
                return .conflicting(sampleKey: key)
            }

            // Check (c): strip .jpg suffix, then verify the remaining extension
            // is a known raster format.
            // e.g., "drive/.thumbnails/photo.heic.jpg" -> "drive/.thumbnails/photo.heic" -> "heic"
            let withoutJpg = String(key.dropLast(4)) // drop ".jpg"
            let originalExtension = (withoutJpg as NSString).pathExtension.lowercased()

            guard rasterExtensions.contains(originalExtension) else {
                return .conflicting(sampleKey: key)
            }
        }

        return .matchesOurs
    }
}
