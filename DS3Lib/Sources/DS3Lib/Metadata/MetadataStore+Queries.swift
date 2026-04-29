import Foundation
import SwiftData

// MARK: - Sendable-safe Queries

// These methods return Sendable types (Bool, Int, String?, Date?) so they can be
// safely called across actor boundaries in Swift 6 strict concurrency mode.

public extension MetadataStore {
    /// Check whether an item with the given S3 key exists in a specific drive.
    func itemExists(byKey s3Key: String, driveId: UUID) throws -> Bool {
        try findItem(byKey: s3Key, driveId: driveId) != nil
    }

    /// Fetch the etag of an item by S3 key within a specific drive, or nil if not found.
    func fetchItemEtag(byKey s3Key: String, driveId: UUID) throws -> String? {
        try findItem(byKey: s3Key, driveId: driveId)?.etag
    }

    /// Fetch the sync status raw string of an item by S3 key within a specific drive, or nil if not found.
    func fetchItemSyncStatus(byKey s3Key: String, driveId: UUID) throws -> String? {
        try findItem(byKey: s3Key, driveId: driveId)?.syncStatus
    }

    /// Count items for a specific drive.
    func countItemsByDrive(driveId: UUID) throws -> Int {
        try findItems(byDrive: driveId).count
    }

    /// Sendable snapshot of a SyncedItem's metadata used to avoid redundant HEAD requests in `item(for:)`.
    struct CachedItemMetadata: Sendable {
        public let etag: String?
        public let lastModified: Date?
        public let contentType: String?
        public let size: Int64
        public let syncStatus: String?
    }

    /// Sendable snapshot of a child item for cache-first folder enumeration.
    struct CachedChildItem: Sendable {
        public let s3Key: String
        public let etag: String?
        public let lastModified: Date?
        public let contentType: String?
        public let size: Int64
        public let syncStatus: String?
        public let isMaterialized: Bool
    }

    /// Fetch all children of a given parent key within a drive.
    /// Used by S3Enumerator for cache-first enumeration after the BFS indexer
    /// has already populated the metadata store.
    /// - Parameters:
    ///   - parentKey: The parent folder's S3 key, or nil for root items.
    ///   - driveId: The drive to query.
    /// - Returns: Array of cached child item snapshots.
    func fetchChildren(parentKey: String?, driveId: UUID) throws -> [CachedChildItem] {
        let items: [SyncedItem]
        let context = modelExecutor.modelContext
        let trashedStatus = SyncStatus.trashed.rawValue

        if let parentKey {
            let predicate = #Predicate<SyncedItem> {
                $0.driveId == driveId && $0.parentKey == parentKey && $0.syncStatus != trashedStatus
            }
            items = try context.fetch(FetchDescriptor<SyncedItem>(predicate: predicate))
        } else {
            let predicate = #Predicate<SyncedItem> {
                $0.driveId == driveId && $0.parentKey == nil && $0.syncStatus != trashedStatus
            }
            items = try context.fetch(FetchDescriptor<SyncedItem>(predicate: predicate))
        }

        return items.map {
            CachedChildItem(
                s3Key: $0.s3Key,
                etag: $0.etag,
                lastModified: $0.lastModified,
                contentType: $0.contentType,
                size: $0.size,
                syncStatus: $0.syncStatus,
                isMaterialized: $0.isMaterialized
            )
        }
    }

    /// Fetch a Sendable metadata snapshot for an item, or nil if not found.
    func fetchItemMetadata(byKey s3Key: String, driveId: UUID) throws -> CachedItemMetadata? {
        guard let item = try findItem(byKey: s3Key, driveId: driveId) else { return nil }
        return CachedItemMetadata(
            etag: item.etag,
            lastModified: item.lastModified,
            contentType: item.contentType,
            size: item.size,
            syncStatus: item.syncStatus
        )
    }

    /// Sendable snapshot of a SyncAnchorRecord's key fields.
    struct SyncAnchorSnapshot: Sendable {
        public let driveId: UUID
        public let lastSyncDate: Date
        public let lastSuccessfulSync: Date?
        public let consecutiveFailures: Int
        public let itemCount: Int
    }

    /// Fetch a Sendable snapshot of the sync anchor for a drive.
    func fetchSyncAnchorSnapshot(driveId: UUID) throws -> SyncAnchorSnapshot? {
        guard let record = try findAnchor(byDrive: driveId) else { return nil }
        return SyncAnchorSnapshot(
            driveId: record.driveId,
            lastSyncDate: record.lastSyncDate,
            lastSuccessfulSync: record.lastSuccessfulSync,
            consecutiveFailures: record.consecutiveFailures,
            itemCount: record.itemCount
        )
    }

    /// Update only the sync status for an item, preserving all other fields.
    /// If the item doesn't exist yet, creates it with the given status.
    func setSyncStatus(s3Key: String, driveId: UUID, status: SyncStatus) throws {
        if let existing = try findItem(byKey: s3Key, driveId: driveId) {
            existing.syncStatus = status.rawValue
        } else {
            let item = SyncedItem(s3Key: s3Key, driveId: driveId, size: 0, syncStatus: status.rawValue)
            modelExecutor.modelContext.insert(item)
        }
        try modelExecutor.modelContext.save()
    }

    /// Clears the error status on a parent folder if none of its children are
    /// in error state. Called after a child item's error is resolved (e.g. after
    /// a successful retry in fetchContents) so the parent folder badge updates.
    /// - Returns: `true` if the parent's status was changed.
    @discardableResult
    func clearParentErrorIfResolved(childKey: String, driveId: UUID) throws -> Bool {
        let delimiter = String(DefaultSettings.S3.delimiter)
        let trimmed = childKey.hasSuffix(delimiter) ? String(childKey.dropLast()) : childKey
        guard let lastSlash = trimmed.lastIndex(of: Character(delimiter)) else { return false }
        let parentKey = String(trimmed[...lastSlash])

        guard let parent = try findItem(byKey: parentKey, driveId: driveId),
              parent.syncStatus == SyncStatus.error.rawValue
        else { return false }

        // Check whether any sibling (other than the resolved child) is still in error
        let errorStatus = SyncStatus.error.rawValue
        let predicate = #Predicate<SyncedItem> {
            $0.driveId == driveId && $0.parentKey == parentKey && $0.syncStatus == errorStatus && $0.s3Key != childKey
        }
        let errorChildren = try modelExecutor.modelContext.fetch(
            FetchDescriptor<SyncedItem>(predicate: predicate)
        )

        if errorChildren.isEmpty {
            parent.syncStatus = SyncStatus.synced.rawValue
            try modelExecutor.modelContext.save()
            return true
        }
        return false
    }

    /// Set the materialization state for an item by S3 key within a specific drive.
    /// Called after a file is downloaded (isMaterialized = true) or evicted (isMaterialized = false).
    func setMaterialized(s3Key: String, driveId: UUID, isMaterialized: Bool) throws {
        guard let item = try findItem(byKey: s3Key, driveId: driveId) else { return }
        item.isMaterialized = isMaterialized
        try modelExecutor.modelContext.save()
    }

    /// Fetch members of the working set for a drive: items currently
    /// materialised on disk. Apple's "Keep Downloaded" affordance maps to
    /// materialisation, so this naturally surfaces user-pinned content
    /// without us tracking a separate pin flag.
    func fetchWorkingSetMembers(driveId: UUID) throws -> [CachedChildItem] {
        let trashedStatus = SyncStatus.trashed.rawValue
        let predicate = #Predicate<SyncedItem> {
            $0.driveId == driveId
                && $0.syncStatus != trashedStatus
                && $0.isMaterialized
        }
        let items = try modelExecutor.modelContext.fetch(
            FetchDescriptor<SyncedItem>(predicate: predicate)
        )
        return items.map {
            CachedChildItem(
                s3Key: $0.s3Key,
                etag: $0.etag,
                lastModified: $0.lastModified,
                contentType: $0.contentType,
                size: $0.size,
                syncStatus: $0.syncStatus,
                isMaterialized: $0.isMaterialized
            )
        }
    }

    /// Marks the supplied keys as materialised (working-set members) for a drive.
    /// Additive: never clears rows not in the set. Apple's
    /// `enumeratorForMaterializedItems` reports only items physically on disk, so
    /// we union it with the visited-folder rows already flagged by `S3Enumerator`.
    /// Visited folders are cleared exclusively by the explicit evict path
    /// (`FileProviderExtension+CustomActions.swift`).
    func markMaterialized(_ keys: Set<String>, driveId: UUID) throws {
        guard !keys.isEmpty else { return }
        let items = try findItems(byDrive: driveId)
        var changed = false
        for item in items where keys.contains(item.s3Key) && !item.isMaterialized {
            item.isMaterialized = true
            changed = true
        }
        if changed {
            try modelExecutor.modelContext.save()
        }
    }

    // MARK: - Thumbnail Queries

    //
    // All thumbnail-related queries removed in Phase 13.2 Plan 09 (D-05, D-08, D-23):
    //
    // - `fetchPendingThumbnails(...)` — gone; the BFS coordinator is gone (Plan 07)
    //   and the consume-path fallback (Plan 02) decides per-item via S3.
    // - `setThumbnailStatus(...)` — gone; the `thumbnailStatus` SwiftData field is
    //   dropped in Schema V6.
    // - `setThumbnailFailure(...)` — gone (Plan 08 / D-05, D-19); the 3-strike rule
    //   now lives in `ThumbnailFallbackLimiter` as in-memory state.
    //
    // The "is the thumbnail uploaded?" question is now answered by S3 itself —
    // `getThumbnailBytes` returns bytes or nil.
}
