import Foundation
import SwiftData

/// Access layer for the SyncedItem and SyncAnchorRecord metadata database.
/// Uses @ModelActor for background-safe SwiftData access from the File Provider extension.
/// Each process (main app and File Provider extension) creates its own
/// MetadataStore instance pointing to the same SQLite file in the App Group container.
@ModelActor
public actor MetadataStore {

    /// Creates a ModelContainer pointing to the App Group shared directory with V2 schema.
    /// Callers create the container once and pass it: `MetadataStore(modelContainer: container)`
    public static func createContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SyncedItemSchemaV2.self)
        let config = ModelConfiguration(
            "SyncedItems",
            schema: schema,
            groupContainer: .identifier(DefaultSettings.appGroup)
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: SyncedItemMigrationPlan.self,
            configurations: [config]
        )
    }

    // MARK: - SyncedItem CRUD

    /// Insert or update a SyncedItem by s3Key.
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
        let context = modelExecutor.modelContext
        let predicate = #Predicate<SyncedItem> { $0.s3Key == s3Key }
        let descriptor = FetchDescriptor<SyncedItem>(predicate: predicate)

        if let existing = try context.fetch(descriptor).first {
            existing.driveId = driveId
            existing.etag = etag
            existing.lastModified = lastModified
            existing.localFileHash = localFileHash
            existing.syncStatus = syncStatus.rawValue
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
            context.insert(item)
        }

        try context.save()
    }

    /// Fetch all SyncedItems for a specific drive.
    public func fetchItemsByDrive(driveId: UUID) throws -> [SyncedItem] {
        let context = modelExecutor.modelContext
        let predicate = #Predicate<SyncedItem> { $0.driveId == driveId }
        let descriptor = FetchDescriptor<SyncedItem>(predicate: predicate)
        return try context.fetch(descriptor)
    }

    /// Fetch a single SyncedItem by its S3 key.
    public func fetchItem(byKey s3Key: String) throws -> SyncedItem? {
        let context = modelExecutor.modelContext
        let predicate = #Predicate<SyncedItem> { $0.s3Key == s3Key }
        let descriptor = FetchDescriptor<SyncedItem>(predicate: predicate)
        return try context.fetch(descriptor).first
    }

    /// Delete all SyncedItems for a specific drive (hard delete).
    public func deleteItemsForDrive(driveId: UUID) throws {
        let context = modelExecutor.modelContext
        let predicate = #Predicate<SyncedItem> { $0.driveId == driveId }
        let descriptor = FetchDescriptor<SyncedItem>(predicate: predicate)
        let items = try context.fetch(descriptor)
        for item in items {
            context.delete(item)
        }
        try context.save()
    }

    /// Delete a single SyncedItem by S3 key.
    public func deleteItem(byKey s3Key: String) throws {
        let context = modelExecutor.modelContext
        let predicate = #Predicate<SyncedItem> { $0.s3Key == s3Key }
        let descriptor = FetchDescriptor<SyncedItem>(predicate: predicate)
        if let item = try context.fetch(descriptor).first {
            context.delete(item)
            try context.save()
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
        let context = modelExecutor.modelContext
        let predicate = #Predicate<SyncAnchorRecord> { $0.driveId == driveId }
        let descriptor = FetchDescriptor<SyncAnchorRecord>(predicate: predicate)
        return try context.fetch(descriptor).first
    }

    /// Insert or update a SyncAnchorRecord for a drive.
    public func upsertSyncAnchor(driveId: UUID, lastSyncDate: Date, itemCount: Int) throws {
        let context = modelExecutor.modelContext
        let predicate = #Predicate<SyncAnchorRecord> { $0.driveId == driveId }
        let descriptor = FetchDescriptor<SyncAnchorRecord>(predicate: predicate)

        if let existing = try context.fetch(descriptor).first {
            existing.lastSyncDate = lastSyncDate
            existing.itemCount = itemCount
        } else {
            let anchor = SyncAnchorRecord(driveId: driveId, lastSyncDate: lastSyncDate)
            anchor.itemCount = itemCount
            context.insert(anchor)
        }

        try context.save()
    }

    /// Advance the sync anchor after a successful sync cycle.
    /// Updates lastSyncDate to now, sets lastSuccessfulSync, resets consecutiveFailures.
    /// - Returns: The new lastSyncDate.
    @discardableResult
    public func advanceSyncAnchor(driveId: UUID, itemCount: Int) throws -> Date {
        let context = modelExecutor.modelContext
        let predicate = #Predicate<SyncAnchorRecord> { $0.driveId == driveId }
        let descriptor = FetchDescriptor<SyncAnchorRecord>(predicate: predicate)

        let now = Date()

        if let existing = try context.fetch(descriptor).first {
            existing.lastSyncDate = now
            existing.lastSuccessfulSync = now
            existing.consecutiveFailures = 0
            existing.itemCount = itemCount
        } else {
            let anchor = SyncAnchorRecord(driveId: driveId, lastSyncDate: now)
            anchor.lastSuccessfulSync = now
            anchor.itemCount = itemCount
            context.insert(anchor)
        }

        try context.save()
        return now
    }

    /// Increment the consecutive failure count for a drive.
    /// - Returns: The new failure count.
    @discardableResult
    public func incrementFailureCount(driveId: UUID) throws -> Int {
        let context = modelExecutor.modelContext
        let predicate = #Predicate<SyncAnchorRecord> { $0.driveId == driveId }
        let descriptor = FetchDescriptor<SyncAnchorRecord>(predicate: predicate)

        if let existing = try context.fetch(descriptor).first {
            existing.consecutiveFailures += 1
            existing.lastSyncDate = Date()
            try context.save()
            return existing.consecutiveFailures
        } else {
            let anchor = SyncAnchorRecord(driveId: driveId, lastSyncDate: Date())
            anchor.consecutiveFailures = 1
            context.insert(anchor)
            try context.save()
            return 1
        }
    }

    /// Reset the consecutive failure count for a drive.
    public func resetFailureCount(driveId: UUID) throws {
        let context = modelExecutor.modelContext
        let predicate = #Predicate<SyncAnchorRecord> { $0.driveId == driveId }
        let descriptor = FetchDescriptor<SyncAnchorRecord>(predicate: predicate)

        if let existing = try context.fetch(descriptor).first {
            existing.consecutiveFailures = 0
            try context.save()
        }
    }

    /// Delete the sync anchor record for a drive.
    public func deleteSyncAnchor(driveId: UUID) throws {
        let context = modelExecutor.modelContext
        let predicate = #Predicate<SyncAnchorRecord> { $0.driveId == driveId }
        let descriptor = FetchDescriptor<SyncAnchorRecord>(predicate: predicate)

        if let anchor = try context.fetch(descriptor).first {
            context.delete(anchor)
            try context.save()
        }
    }

    // MARK: - Sendable-safe Queries

    // These methods return Sendable types (Bool, Int, String?, Date?) so they can be
    // safely called across actor boundaries in Swift 6 strict concurrency mode.

    /// Check whether an item with the given S3 key exists.
    public func itemExists(byKey s3Key: String) throws -> Bool {
        let context = modelExecutor.modelContext
        let predicate = #Predicate<SyncedItem> { $0.s3Key == s3Key }
        let descriptor = FetchDescriptor<SyncedItem>(predicate: predicate)
        return try context.fetch(descriptor).first != nil
    }

    /// Fetch the etag of an item by S3 key, or nil if not found.
    public func fetchItemEtag(byKey s3Key: String) throws -> String? {
        let context = modelExecutor.modelContext
        let predicate = #Predicate<SyncedItem> { $0.s3Key == s3Key }
        let descriptor = FetchDescriptor<SyncedItem>(predicate: predicate)
        return try context.fetch(descriptor).first?.etag
    }

    /// Fetch the sync status raw string of an item by S3 key, or nil if not found.
    public func fetchItemSyncStatus(byKey s3Key: String) throws -> String? {
        let context = modelExecutor.modelContext
        let predicate = #Predicate<SyncedItem> { $0.s3Key == s3Key }
        let descriptor = FetchDescriptor<SyncedItem>(predicate: predicate)
        return try context.fetch(descriptor).first?.syncStatus
    }

    /// Count items for a specific drive.
    public func countItemsByDrive(driveId: UUID) throws -> Int {
        let context = modelExecutor.modelContext
        let predicate = #Predicate<SyncedItem> { $0.driveId == driveId }
        let descriptor = FetchDescriptor<SyncedItem>(predicate: predicate)
        return try context.fetch(descriptor).count
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
        let context = modelExecutor.modelContext
        let predicate = #Predicate<SyncAnchorRecord> { $0.driveId == driveId }
        let descriptor = FetchDescriptor<SyncAnchorRecord>(predicate: predicate)
        guard let record = try context.fetch(descriptor).first else { return nil }
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
        let context = modelExecutor.modelContext
        let predicate = #Predicate<SyncedItem> { $0.driveId == driveId }
        let descriptor = FetchDescriptor<SyncedItem>(predicate: predicate)
        let items = try context.fetch(descriptor)
        var result: [String: String?] = [:]
        for item in items {
            result[item.s3Key] = item.etag
        }
        return result
    }

    /// Fetch all item keys and their sync status for a drive as a Sendable dictionary.
    /// Used by SyncEngine to determine which items qualify for deletion detection.
    public func fetchItemKeysAndStatuses(driveId: UUID) throws -> [String: String] {
        let context = modelExecutor.modelContext
        let predicate = #Predicate<SyncedItem> { $0.driveId == driveId }
        let descriptor = FetchDescriptor<SyncedItem>(predicate: predicate)
        let items = try context.fetch(descriptor)
        var result: [String: String] = [:]
        for item in items {
            result[item.s3Key] = item.syncStatus
        }
        return result
    }
}
