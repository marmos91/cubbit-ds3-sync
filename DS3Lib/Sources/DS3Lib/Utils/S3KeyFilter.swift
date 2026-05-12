import Foundation

/// Centralized filter that determines whether an S3 key represents user-visible content.
/// Routes through S3PathUtils predicates for .trash/ and .thumbnails/ hidden prefixes,
/// hides `.ds3keep` folder markers (Phase A — empty-folder placeholder), and rejects
/// keys that begin with an Apple File Provider sentinel raw value (residue from a
/// pre-fix bug where `parentItemIdentifier.rawValue` was concatenated into S3 keys).
/// All ListObjectsV2 consumers MUST use this filter before surfacing keys to observers,
/// MetadataStore, SyncEngine, or Finder/Files.
public enum S3KeyFilter {
    /// Apple File Provider sentinel raw values that must never appear in legitimate S3
    /// keys. Hard-coded to keep DS3Lib free of FileProvider import.
    static let sentinelPrefixes: [String] = [
        "NSFileProviderRootContainerItemIdentifier",
        "NSFileProviderTrashContainerItemIdentifier",
        "NSFileProviderWorkingSetContainerItemIdentifier"
    ]

    /// Returns true if the key should be visible to the user (not hidden by .trash/,
    /// .thumbnails/, or by an Apple sentinel-prefixed bug residue).
    /// - Parameters:
    ///   - key: The S3 object key
    ///   - drivePrefix: The drive's S3 prefix (e.g., "photos/"), or nil for root
    /// - Returns: true if the key is user-facing content
    public static func isUserVisible(key: String, drivePrefix: String?) -> Bool {
        !S3PathUtils.isTrashedKey(key, drivePrefix: drivePrefix)
            && !S3PathUtils.isThumbnailKey(key, drivePrefix: drivePrefix)
            && !S3PathUtils.isDS3KeepMarkerKey(key)
            && !isSentinelPoisonedKey(key, drivePrefix: drivePrefix)
    }

    /// Returns true if the key (or its tail relative to drivePrefix) starts with an
    /// Apple File Provider sentinel raw value. These keys are bug residue, not user content.
    public static func isSentinelPoisonedKey(_ key: String, drivePrefix: String?) -> Bool {
        let prefix = drivePrefix ?? ""
        let relative = key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : key
        return sentinelPrefixes.contains { relative.hasPrefix($0) }
    }
}
