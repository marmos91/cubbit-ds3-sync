import Foundation

/// Centralized filter that determines whether an S3 key represents user-visible content.
/// Routes through S3PathUtils predicates for .trash/ and .thumbnails/ hidden prefixes.
/// All ListObjectsV2 consumers MUST use this filter before surfacing keys to observers,
/// MetadataStore, SyncEngine, or Finder/Files.
public enum S3KeyFilter {
    /// Returns true if the key should be visible to the user (not hidden by .trash/ or .thumbnails/).
    /// - Parameters:
    ///   - key: The S3 object key
    ///   - drivePrefix: The drive's S3 prefix (e.g., "photos/"), or nil for root
    /// - Returns: true if the key is user-facing content
    public static func isUserVisible(key: String, drivePrefix: String?) -> Bool {
        !S3PathUtils.isTrashedKey(key, drivePrefix: drivePrefix)
            && !S3PathUtils.isThumbnailKey(key, drivePrefix: drivePrefix)
    }
}
