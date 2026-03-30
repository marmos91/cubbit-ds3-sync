import Foundation
import os.log
import SwiftData

/// Access layer for the SyncedItem and SyncAnchorRecord metadata database.
/// Uses @ModelActor for background-safe SwiftData access from the File Provider extension.
/// Each process (main app and File Provider extension) creates its own
/// MetadataStore instance pointing to the same SQLite file in the App Group container.
@ModelActor
public actor MetadataStore {
    /// Creates a ModelContainer pointing to the App Group shared directory.
    /// If the on-disk store has an incompatible schema version (e.g. from a
    /// previous build that used a different versioned schema), the store is
    /// deleted and recreated — metadata is ephemeral cache, not user data.
    public static func createContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SyncedItemSchemaV2.self)
        let config = ModelConfiguration(
            "SyncedItems",
            schema: schema,
            groupContainer: .identifier(DefaultSettings.appGroup)
        )
        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: SyncedItemMigrationPlan.self,
                configurations: [config]
            )
        } catch {
            // Migration failed (unknown schema version, corrupted store, etc.)
            // Delete the store and recreate — metadata will be rebuilt from S3.
            let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.metadata.rawValue)
            logger.warning("MetadataStore migration failed, recreating store: \(error.localizedDescription)")
            if let containerURL = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup) {
                let storeDir = containerURL.appendingPathComponent("Library/Application Support")
                let storeFiles = ["SyncedItems.store", "SyncedItems.store-shm", "SyncedItems.store-wal"]
                for file in storeFiles {
                    try? FileManager.default.removeItem(at: storeDir.appendingPathComponent(file))
                }
            }
            return try ModelContainer(
                for: schema,
                migrationPlan: SyncedItemMigrationPlan.self,
                configurations: [config]
            )
        }
    }

    // MARK: - Fetch Helpers

    func findItem(byKey s3Key: String, driveId: UUID) throws -> SyncedItem? {
        let compositeKey = "\(driveId.uuidString):\(s3Key)"
        let predicate = #Predicate<SyncedItem> { $0.uniqueKey == compositeKey }
        return try modelExecutor.modelContext.fetch(FetchDescriptor<SyncedItem>(predicate: predicate)).first
    }

    func findItems(byDrive driveId: UUID) throws -> [SyncedItem] {
        let predicate = #Predicate<SyncedItem> { $0.driveId == driveId }
        return try modelExecutor.modelContext.fetch(FetchDescriptor<SyncedItem>(predicate: predicate))
    }

    func findAnchor(byDrive driveId: UUID) throws -> SyncAnchorRecord? {
        let predicate = #Predicate<SyncAnchorRecord> { $0.driveId == driveId }
        return try modelExecutor.modelContext.fetch(FetchDescriptor<SyncAnchorRecord>(predicate: predicate)).first
    }

    // MARK: - Batch Types

    /// Sendable data transfer object for batch upsert operations.
    public struct ItemUpsertData: Sendable {
        public let s3Key: String
        public let driveId: UUID
        public let etag: String?
        public let lastModified: Date?
        public let syncStatus: SyncStatus
        public let parentKey: String?
        public let contentType: String?
        public let size: Int64

        public init(
            s3Key: String,
            driveId: UUID,
            etag: String? = nil,
            lastModified: Date? = nil,
            syncStatus: SyncStatus = .synced,
            parentKey: String? = nil,
            contentType: String? = nil,
            size: Int64 = 0
        ) {
            self.s3Key = s3Key
            self.driveId = driveId
            self.etag = etag
            self.lastModified = lastModified
            self.syncStatus = syncStatus
            self.parentKey = parentKey
            self.contentType = contentType
            self.size = size
        }
    }

    // MARK: - SyncedItem CRUD

    private func applyUpsert(
        s3Key: String,
        driveId: UUID,
        etag: String? = nil,
        lastModified: Date? = nil,
        localFileHash: String? = nil,
        syncStatus: SyncStatus = .pending,
        parentKey: String? = nil,
        contentType: String? = nil,
        size: Int64 = 0
    ) throws {
        if let existing = try findItem(byKey: s3Key, driveId: driveId) {
            existing.etag = etag
            existing.lastModified = lastModified
            existing.localFileHash = localFileHash
            // Don't downgrade transient states (error, syncing, conflict)
            // to synced — S3 listing upserts would silently clear error badges.
            if !(existing.status.isTransient && syncStatus == .synced) {
                existing.syncStatus = syncStatus.rawValue
            }
            existing.parentKey = parentKey
            existing.contentType = contentType
            existing.size = size
        } else {
            let item = SyncedItem(s3Key: s3Key, driveId: driveId, size: size, syncStatus: syncStatus.rawValue)
            item.etag = etag
            item.lastModified = lastModified
            item.localFileHash = localFileHash
            item.parentKey = parentKey
            item.contentType = contentType
            modelExecutor.modelContext.insert(item)
        }
    }

    /// Batch insert or update multiple SyncedItems with a single save at the end.
    public func batchUpsertItems(_ items: [ItemUpsertData]) throws {
        for data in items {
            try applyUpsert(
                s3Key: data.s3Key,
                driveId: data.driveId,
                etag: data.etag,
                lastModified: data.lastModified,
                syncStatus: data.syncStatus,
                parentKey: data.parentKey,
                contentType: data.contentType,
                size: data.size
            )
        }
        try modelExecutor.modelContext.save()
    }

    /// Batch delete multiple SyncedItems with a single save at the end.
    public func batchDeleteItems(_ keys: [(s3Key: String, driveId: UUID)]) throws {
        let context = modelExecutor.modelContext
        var changed = false
        for (s3Key, driveId) in keys {
            if let item = try findItem(byKey: s3Key, driveId: driveId) {
                context.delete(item)
                changed = true
            }
        }
        if changed {
            try context.save()
        }
    }

    /// Insert or update a SyncedItem by s3Key within a specific drive.
    public func upsertItem(
        s3Key: String,
        driveId: UUID,
        etag: String? = nil,
        lastModified: Date? = nil,
        localFileHash: String? = nil,
        syncStatus: SyncStatus = .pending,
        parentKey: String? = nil,
        contentType: String? = nil,
        size: Int64 = 0
    ) throws {
        try applyUpsert(
            s3Key: s3Key,
            driveId: driveId,
            etag: etag,
            lastModified: lastModified,
            localFileHash: localFileHash,
            syncStatus: syncStatus,
            parentKey: parentKey,
            contentType: contentType,
            size: size
        )
        try modelExecutor.modelContext.save()
    }

    /// Fetch all SyncedItems for a specific drive.
    public func fetchItemsByDrive(driveId: UUID) throws -> [SyncedItem] {
        try findItems(byDrive: driveId)
    }

    /// Fetch a single SyncedItem by its S3 key within a specific drive.
    public func fetchItem(byKey s3Key: String, driveId: UUID) throws -> SyncedItem? {
        try findItem(byKey: s3Key, driveId: driveId)
    }

    /// Delete all SyncedItems for a specific drive (hard delete).
    public func deleteItemsForDrive(driveId: UUID) throws {
        let context = modelExecutor.modelContext
        for item in try findItems(byDrive: driveId) {
            context.delete(item)
        }
        try context.save()
    }

    /// Remove cached children of a folder that are no longer present in S3.
    /// Only prunes items with `.synced` status — items being uploaded or in error are preserved.
    public func pruneChildren(parentKey: String?, driveId: UUID, keepKeys: Set<String>) throws {
        let context = modelExecutor.modelContext
        let syncedStatus = SyncStatus.synced.rawValue
        let items: [SyncedItem]

        if let parentKey {
            let predicate = #Predicate<SyncedItem> {
                $0.driveId == driveId && $0.parentKey == parentKey && $0.syncStatus == syncedStatus
            }
            items = try context.fetch(FetchDescriptor<SyncedItem>(predicate: predicate))
        } else {
            let predicate = #Predicate<SyncedItem> {
                $0.driveId == driveId && $0.parentKey == nil && $0.syncStatus == syncedStatus
            }
            items = try context.fetch(FetchDescriptor<SyncedItem>(predicate: predicate))
        }

        let staleItems = items.filter { !keepKeys.contains($0.s3Key) }
        for item in staleItems {
            context.delete(item)
        }
        if !staleItems.isEmpty {
            try context.save()
        }
    }

    /// Delete a single SyncedItem by S3 key within a specific drive.
    public func deleteItem(byKey s3Key: String, driveId: UUID) throws {
        if let item = try findItem(byKey: s3Key, driveId: driveId) {
            modelExecutor.modelContext.delete(item)
            try modelExecutor.modelContext.save()
        }
    }

    /// Fetch items by drive and sync status (e.g., all items in error state).
    public func fetchItems(driveId: UUID, status: SyncStatus) throws -> [SyncedItem] {
        let statusRaw = status.rawValue
        let context = modelExecutor.modelContext
        let predicate = #Predicate<SyncedItem> { $0.driveId == driveId && $0.syncStatus == statusRaw }
        let descriptor = FetchDescriptor<SyncedItem>(predicate: predicate)
        return try context.fetch(descriptor)
    }

    // MARK: - SyncAnchorRecord CRUD

    /// Fetch the sync anchor record for a specific drive.
    public func fetchSyncAnchor(driveId: UUID) throws -> SyncAnchorRecord? {
        try findAnchor(byDrive: driveId)
    }

    /// Insert or update a SyncAnchorRecord for a drive.
    public func upsertSyncAnchor(driveId: UUID, lastSyncDate: Date, itemCount: Int) throws {
        if let existing = try findAnchor(byDrive: driveId) {
            existing.lastSyncDate = lastSyncDate
            existing.itemCount = itemCount
        } else {
            let anchor = SyncAnchorRecord(driveId: driveId, lastSyncDate: lastSyncDate)
            anchor.itemCount = itemCount
            modelExecutor.modelContext.insert(anchor)
        }

        try modelExecutor.modelContext.save()
    }

    /// Advance the sync anchor after a successful sync cycle.
    /// Updates lastSyncDate to now, sets lastSuccessfulSync, resets consecutiveFailures.
    /// - Returns: The new lastSyncDate.
    @discardableResult
    public func advanceSyncAnchor(driveId: UUID, itemCount: Int) throws -> Date {
        let now = Date()

        if let existing = try findAnchor(byDrive: driveId) {
            existing.lastSyncDate = now
            existing.lastSuccessfulSync = now
            existing.consecutiveFailures = 0
            existing.itemCount = itemCount
        } else {
            let anchor = SyncAnchorRecord(driveId: driveId, lastSyncDate: now)
            anchor.lastSuccessfulSync = now
            anchor.itemCount = itemCount
            modelExecutor.modelContext.insert(anchor)
        }

        try modelExecutor.modelContext.save()
        return now
    }

    /// Increment the consecutive failure count for a drive.
    /// - Returns: The new failure count.
    @discardableResult
    public func incrementFailureCount(driveId: UUID) throws -> Int {
        let context = modelExecutor.modelContext

        if let existing = try findAnchor(byDrive: driveId) {
            existing.consecutiveFailures += 1
            existing.lastSyncDate = Date()
            try context.save()
            return existing.consecutiveFailures
        }
        let anchor = SyncAnchorRecord(driveId: driveId, lastSyncDate: Date())
        anchor.consecutiveFailures = 1
        context.insert(anchor)
        try context.save()
        return 1
    }

    /// Reset the consecutive failure count for a drive.
    public func resetFailureCount(driveId: UUID) throws {
        if let existing = try findAnchor(byDrive: driveId) {
            existing.consecutiveFailures = 0
            try modelExecutor.modelContext.save()
        }
    }

    /// Delete the sync anchor record for a drive.
    public func deleteSyncAnchor(driveId: UUID) throws {
        if let anchor = try findAnchor(byDrive: driveId) {
            modelExecutor.modelContext.delete(anchor)
            try modelExecutor.modelContext.save()
        }
    }
}
