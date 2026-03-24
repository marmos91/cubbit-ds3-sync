import Foundation
import SwiftData

// MARK: - Sendable-safe Queries

// These methods return Sendable types (Bool, Int, String?, Date?) so they can be
// safely called across actor boundaries in Swift 6 strict concurrency mode.

extension MetadataStore {

    /// Check whether an item with the given S3 key exists in a specific drive.
    public func itemExists(byKey s3Key: String, driveId: UUID) throws -> Bool {
        try findItem(byKey: s3Key, driveId: driveId) != nil
    }

    /// Fetch the etag of an item by S3 key within a specific drive, or nil if not found.
    public func fetchItemEtag(byKey s3Key: String, driveId: UUID) throws -> String? {
        try findItem(byKey: s3Key, driveId: driveId)?.etag
    }

    /// Fetch the sync status raw string of an item by S3 key within a specific drive, or nil if not found.
    public func fetchItemSyncStatus(byKey s3Key: String, driveId: UUID) throws -> String? {
        try findItem(byKey: s3Key, driveId: driveId)?.syncStatus
    }

    /// Count items for a specific drive.
    public func countItemsByDrive(driveId: UUID) throws -> Int {
        try findItems(byDrive: driveId).count
    }

    /// Sendable snapshot of a SyncedItem's metadata used to avoid redundant HEAD requests in `item(for:)`.
    public struct CachedItemMetadata: Sendable {
        public let etag: String?
        public let lastModified: Date?
        public let contentType: String?
        public let size: Int64
        public let syncStatus: String?
    }

    /// Sendable snapshot of a child item for cache-first folder enumeration.
    public struct CachedChildItem: Sendable {
        public let s3Key: String
        public let etag: String?
        public let lastModified: Date?
        public let contentType: String?
        public let size: Int64
        public let syncStatus: String?
    }

    /// Fetch all children of a given parent key within a drive.
    /// Used by S3Enumerator for cache-first enumeration after the BFS indexer
    /// has already populated the metadata store.
    /// - Parameters:
    ///   - parentKey: The parent folder's S3 key, or nil for root items.
    ///   - driveId: The drive to query.
    /// - Returns: Array of cached child item snapshots.
    public func fetchChildren(parentKey: String?, driveId: UUID) throws -> [CachedChildItem] {
        let items: [SyncedItem]
        let context = modelExecutor.modelContext

        if let parentKey {
            let predicate = #Predicate<SyncedItem> {
                $0.driveId == driveId && $0.parentKey == parentKey
            }
            items = try context.fetch(FetchDescriptor<SyncedItem>(predicate: predicate))
        } else {
            let predicate = #Predicate<SyncedItem> {
                $0.driveId == driveId && $0.parentKey == nil
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
                syncStatus: $0.syncStatus
            )
        }
    }

    /// Fetch a Sendable metadata snapshot for an item, or nil if not found.
    public func fetchItemMetadata(byKey s3Key: String, driveId: UUID) throws -> CachedItemMetadata? {
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
    public struct SyncAnchorSnapshot: Sendable {
        public let driveId: UUID
        public let lastSyncDate: Date
        public let lastSuccessfulSync: Date?
        public let consecutiveFailures: Int
        public let itemCount: Int
    }

    /// Fetch a Sendable snapshot of the sync anchor for a drive.
    public func fetchSyncAnchorSnapshot(driveId: UUID) throws -> SyncAnchorSnapshot? {
        guard let record = try findAnchor(byDrive: driveId) else { return nil }
        return SyncAnchorSnapshot(
            driveId: record.driveId,
            lastSyncDate: record.lastSyncDate,
            lastSuccessfulSync: record.lastSuccessfulSync,
            consecutiveFailures: record.consecutiveFailures,
            itemCount: record.itemCount
        )
    }

    /// Fetch all item keys and etags for a drive as a Sendable dictionary.
    /// Used by SyncEngine for reconciliation without crossing actor boundary with @Model objects.
    public func fetchItemKeysAndEtags(driveId: UUID) throws -> [String: String?] {
        let items = try findItems(byDrive: driveId)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.s3Key, $0.etag) })
    }

    /// Fetch all item keys and their sync status for a drive as a Sendable dictionary.
    /// Used by SyncEngine to determine which items qualify for deletion detection.
    public func fetchItemKeysAndStatuses(driveId: UUID) throws -> [String: String] {
        let items = try findItems(byDrive: driveId)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.s3Key, $0.syncStatus) })
    }

    /// Update only the sync status for an item, preserving all other fields.
    /// If the item doesn't exist yet, creates it with the given status.
    public func setSyncStatus(s3Key: String, driveId: UUID, status: SyncStatus) throws {
        if let existing = try findItem(byKey: s3Key, driveId: driveId) {
            existing.syncStatus = status.rawValue
        } else {
            let item = SyncedItem(s3Key: s3Key, driveId: driveId, size: 0, syncStatus: status.rawValue)
            modelExecutor.modelContext.insert(item)
        }
        try modelExecutor.modelContext.save()
    }

    /// Set the materialization state for an item by S3 key within a specific drive.
    /// Called after a file is downloaded (isMaterialized = true) or evicted (isMaterialized = false).
    public func setMaterialized(s3Key: String, driveId: UUID, isMaterialized: Bool) throws {
        guard let item = try findItem(byKey: s3Key, driveId: driveId) else { return }
        item.isMaterialized = isMaterialized
        try modelExecutor.modelContext.save()
    }

    /// Batch-updates the materialized state for all items of a drive.
    /// Items whose keys are in `materializedKeys` are marked as materialized;
    /// all others are marked as not materialized.
    public func updateMaterializedState(driveId: UUID, materializedKeys: Set<String>) throws {
        let items = try findItems(byDrive: driveId)
        var changed = false
        for item in items {
            let shouldBeMaterialized = materializedKeys.contains(item.s3Key)
            if item.isMaterialized != shouldBeMaterialized {
                item.isMaterialized = shouldBeMaterialized
                changed = true
            }
        }
        if changed {
            try modelExecutor.modelContext.save()
        }
    }
}
