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
    /// Inspects the `.thumbnails/` prefix under a drive's S3 path to detect pre-existing
    /// content that may conflict with DS3Drive's thumbnail layout.
    ///
    /// Makes a single ListObjectsV2 call with MaxKeys=10 (per D-03).
    /// Does NOT self-rate-limit -- callers that invoke this for multiple drives in batch
    /// should add their own throttling.
    ///
    /// - Parameters:
    ///   - bucket: The S3 bucket name
    ///   - prefix: The drive's S3 prefix (e.g., "photos/"), or nil for root
    /// - Returns: The detected state of the `.thumbnails/` prefix
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
        let rasterExtensions: Set<String> = [
            "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tiff",
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
