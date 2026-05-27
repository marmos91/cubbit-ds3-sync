import DS3Lib
import Foundation

extension S3Lib {
    // MARK: - Thumbnail Operations

    /// Computes the full `.thumbnails/` prefix for a drive (e.g., `prefix/.thumbnails/`).
    static func fullThumbnailPrefix(forDrive drive: DS3Drive) -> String {
        S3PathUtils.thumbnailsPrefix(forDrivePrefix: drive.syncAnchor.prefix)
    }

    /// Returns `true` if the key lives inside any `.thumbnails/` prefix segment.
    static func isThumbnailKey(_ key: String, drive: DS3Drive) -> Bool {
        S3PathUtils.isThumbnailKey(key, drivePrefix: drive.syncAnchor.prefix)
    }

    /// Returns `true` if the key is user-visible content (not .trash/ or .thumbnails/).
    /// Central choke point for ALL enumeration filter decisions in the extension.
    static func isUserVisible(_ key: String, drive: DS3Drive) -> Bool {
        S3KeyFilter.isUserVisible(key: key, drivePrefix: drive.syncAnchor.prefix)
    }
}
