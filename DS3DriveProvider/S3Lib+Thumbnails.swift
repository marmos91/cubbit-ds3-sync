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

    // MARK: - ListObjectsV2 Consumer Audit (Phase 11, D-21)
    //
    // Sites routed through S3Lib.isUserVisible:
    //   1. S3Enumerator.swift ~line 299 — per-folder enumeration (was: NO filter — latent trash leak fixed)
    //   2. S3Enumerator.swift ~line 416 — recursive/working-set (was: inline isTrashedKey)
    //   3. S3Enumerator.swift ~line 547 — enumerateChanges fallback (was: NO filter)
    //   4. BreadthFirstIndexer.swift ~line 118 — BFS dequeue (was: inline hasPrefix(trashPrefix))
    //   5. S3LibListingAdapter.swift ~line 47 — SyncEngine feed (was: inline hasPrefix(trashPrefix))
    //   6. FileProviderExtension+Lifecycle.swift ~line 59 — warm-up cache (was: NO filter — latent trash leak fixed)
    //
    // Intentionally EXEMPT (destructive or internal — must see all keys):
    //   7. S3Lib.swift deleteFolder recursive listing (~line 241)
    //   8. S3Lib.swift copyFolder recursive listing (~line 381)
    //   9. S3Lib+Trash.swift trash operations (lines 110, 206, 232) — scoped inside .trash/
    //
    // Non-extension sites (commonPrefixes filter):
    //   10. SyncAnchorSelectionViewModel.swift ~line 138
    //   11. TreeNavigationView.swift ~line 214, 260
    //   12. ShareFolderPickerView.swift ~line 239
}
