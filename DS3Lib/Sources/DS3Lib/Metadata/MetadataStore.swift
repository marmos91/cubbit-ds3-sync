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

    // MARK: - Private Fetch Helpers

    private func findItem(byKey s3Key: String, driveId: UUID) throws -> SyncedItem? {
        let compositeKey = "\(driveId.uuidString):\(s3Key)"
        let predicate = #Predicate<SyncedItem> { $0.uniqueKey == compositeKey }
        return try modelExecutor.modelContext.fetch(FetchDescriptor<SyncedItem>(predicate: predicate)).first
    }

    private func findItems(byDrive driveId: UUID) throws -> [SyncedItem] {
        let predicate = #Predicate<SyncedItem> { $0.driveId == driveId }
        return try modelExecutor.modelContext.fetch(FetchDescriptor<SyncedItem>(predicate: predicate))
    }

    private func findAnchor(byDrive driveId: UUID) throws -> SyncAnchorRecord? {
        let predicate = #Predicate<SyncAnchorRecord> { $0.driveId == driveId }
        return try modelExecutor.modelContext.fetch(FetchDescriptor<SyncAnchorRecord>(predicate: predicate)).first
    }

    // MARK: - SyncedItem CRUD

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
        if let existing = try findItem(byKey: s3Key, driveId: driveId) {
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
            modelExecutor.modelContext.insert(item)
        }

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

    // MARK: - Sendable-safe Queries

    // These methods return Sendable types (Bool, Int, String?, Date?) so they can be
    // safely called across actor boundaries in Swift 6 strict concurrency mode.

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
    }

    /// Fetch a Sendable metadata snapshot for an item, or nil if not found.
    public func fetchItemMetadata(byKey s3Key: String, driveId: UUID) throws -> CachedItemMetadata? {
        guard let item = try findItem(byKey: s3Key, driveId: driveId) else { return nil }
        return CachedItemMetadata(
            etag: item.etag,
            lastModified: item.lastModified,
            contentType: item.contentType,
            size: item.size
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

    /// Set the materialization state for an item by S3 key within a specific drive.
    /// Called after a file is downloaded (isMaterialized = true) or evicted (isMaterialized = false).
    public func setMaterialized(s3Key: String, driveId: UUID, isMaterialized: Bool) throws {
        guard let item = try findItem(byKey: s3Key, driveId: driveId) else { return }
        item.isMaterialized = isMaterialized
        try modelExecutor.modelContext.save()
    }
}
