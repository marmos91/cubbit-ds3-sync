import Foundation

/// Pure utility functions for S3 path/key manipulation.
/// Extracts logic from S3Item and S3Enumerator into testable, framework-independent helpers.
public enum S3PathUtils {
    /// Extracts the filename (last path component) from an S3 key.
    /// - Parameter key: The S3 object key (e.g., "photos/vacation/beach.jpg")
    /// - Returns: The filename (e.g., "beach.jpg"), or empty string if the key is empty
    public static func filename(fromKey key: String) -> String {
        guard !key.isEmpty, key != String(DefaultSettings.S3.delimiter) else { return "" }
        return String(key.split(separator: DefaultSettings.S3.delimiter).last ?? "")
    }

    /// Determines if an S3 key represents a folder (ends with delimiter).
    /// - Parameter key: The S3 object key
    /// - Returns: true if the key ends with the delimiter
    public static func isFolder(_ key: String) -> Bool {
        key.last == DefaultSettings.S3.delimiter
    }

    /// Computes the parent key for an S3 key within a drive's prefix.
    /// - Parameters:
    ///   - key: The S3 object key
    ///   - drivePrefix: The drive's prefix (e.g., "photos/")
    /// - Returns: The parent key (e.g., "photos/vacation/"), or nil if the key is at the root level
    public static func parentKey(forKey key: String, drivePrefix: String?) -> String? {
        let delimiter = DefaultSettings.S3.delimiter
        var pathSegments = key.split(separator: delimiter)
        let prefixSegmentsCount = (drivePrefix?.split(separator: delimiter) ?? []).count

        if pathSegments.count == prefixSegmentsCount + 1 {
            // At the root level of the drive prefix
            return nil
        }

        _ = pathSegments.popLast()
        let parentIdentifier = pathSegments.joined(separator: String(delimiter))
        return parentIdentifier + String(delimiter)
    }

    /// Computes the trash prefix for a drive (e.g., "prefix/.trash/").
    /// - Parameter drivePrefix: The drive's S3 prefix (e.g., "photos/"), or nil for root
    /// - Returns: The full trash prefix (e.g., "photos/.trash/")
    public static func trashPrefix(forDrivePrefix drivePrefix: String?) -> String {
        (drivePrefix ?? "") + DefaultSettings.S3.trashPrefix
    }

    /// Returns true if the key lives inside the trash prefix.
    /// - Parameters:
    ///   - key: The S3 object key
    ///   - drivePrefix: The drive's S3 prefix
    /// - Returns: true if the key is in the trash
    public static func isTrashedKey(_ key: String, drivePrefix: String?) -> Bool {
        key.hasPrefix(trashPrefix(forDrivePrefix: drivePrefix))
    }

    /// Computes the trash key for a given item key.
    /// - Parameters:
    ///   - key: The original S3 key (e.g., "prefix/docs/file.txt")
    ///   - drivePrefix: The drive's S3 prefix
    /// - Returns: The trash key (e.g., "prefix/.trash/docs/file.txt")
    public static func trashKey(forKey key: String, drivePrefix: String?) -> String {
        let prefix = drivePrefix ?? ""
        let relativePath = String(key.dropFirst(prefix.count))
        return trashPrefix(forDrivePrefix: drivePrefix) + relativePath
    }

    /// Derives the original key from a trash key.
    /// - Parameters:
    ///   - key: The trash key (e.g., "prefix/.trash/docs/file.txt")
    ///   - drivePrefix: The drive's S3 prefix
    /// - Returns: The original key (e.g., "prefix/docs/file.txt")
    public static func originalKey(fromTrashKey key: String, drivePrefix: String?) -> String {
        let trash = trashPrefix(forDrivePrefix: drivePrefix)
        let relativePath = String(key.dropFirst(trash.count))
        return (drivePrefix ?? "") + relativePath
    }

    /// Computes the parent key within the trash hierarchy.
    /// - Parameters:
    ///   - key: The trashed S3 key
    ///   - drivePrefix: The drive's S3 prefix
    /// - Returns: nil if the item is a top-level trash item, otherwise the parent key within trash
    public static func trashParentKey(forKey key: String, drivePrefix: String?) -> String? {
        let trash = trashPrefix(forDrivePrefix: drivePrefix)
        let relativePath = String(key.dropFirst(trash.count))
        let segments = relativePath.split(separator: DefaultSettings.S3.delimiter)
        if segments.count <= 1 {
            return nil // Top-level item in trash
        }
        let delimiter = DefaultSettings.S3.delimiter
        var pathSegments = key.split(separator: delimiter)
        _ = pathSegments.popLast()
        let parentIdentifier = pathSegments.joined(separator: String(delimiter))
        return parentIdentifier + String(delimiter)
    }

    /// Synthesizes virtual parent folder keys from a list of S3 object keys.
    /// Used by the working set enumerator to build a complete folder hierarchy.
    /// - Parameters:
    ///   - keys: The S3 object keys from a recursive listing
    ///   - prefix: The drive's S3 prefix
    /// - Returns: Set of virtual folder keys that don't exist in the input but are needed as parents
    public static func synthesizeVirtualFolderKeys(
        fromKeys keys: Set<String>,
        prefix: String?
    ) -> Set<String> {
        let delimiter = DefaultSettings.S3.delimiter
        var synthesized: Set<String> = []

        for key in keys {
            let components = key.split(
                separator: delimiter,
                omittingEmptySubsequences: true
            )

            for idx in 1 ..< components.count {
                let dirKey = components[0 ..< idx].joined(separator: String(delimiter))
                    + String(delimiter)

                if dirKey == prefix { continue }
                if let prefix, !dirKey.hasPrefix(prefix) { continue }
                if keys.contains(dirKey) || synthesized.contains(dirKey) { continue }

                synthesized.insert(dirKey)
            }
        }

        return synthesized
    }

    /// Determines the suggested drive name from a bucket and optional prefix.
    /// - Parameters:
    ///   - bucketName: The bucket name
    ///   - prefix: Optional S3 prefix
    /// - Returns: A suggested drive name (e.g., "my-bucket" or "my-bucket/subfolder")
    public static func suggestedDriveName(bucketName: String, prefix: String?) -> String {
        if let prefix, !prefix.isEmpty {
            let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let lastComponent = trimmed.components(separatedBy: "/").last ?? trimmed
            return "\(bucketName)/\(lastComponent)"
        }
        return bucketName
    }
}
