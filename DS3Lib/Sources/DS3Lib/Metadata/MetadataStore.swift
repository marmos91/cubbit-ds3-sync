import Foundation
import SwiftData

/// Access layer for the SyncedItem metadata database.
/// Each process (main app and File Provider extension) creates its own
/// MetadataStore instance pointing to the same SQLite file in the App Group container.
@MainActor
public final class MetadataStore {
    private let container: ModelContainer

    /// Creates a MetadataStore with a ModelContainer pointing to the App Group shared directory.
    public init() throws {
        let schema = Schema(versionedSchema: SyncedItemSchemaV1.self)
        let config = ModelConfiguration(
            "SyncedItems",
            schema: schema,
            groupContainer: .identifier(DefaultSettings.appGroup)
        )
        self.container = try ModelContainer(
            for: schema,
            migrationPlan: SyncedItemMigrationPlan.self,
            configurations: [config]
        )
    }

    /// Creates a MetadataStore with a custom container (for testing).
    internal init(container: ModelContainer) {
        self.container = container
    }

    /// The underlying ModelContainer (for use with @Query in SwiftUI if needed).
    public var modelContainer: ModelContainer { container }

    /// Insert or update a SyncedItem by s3Key.
    @MainActor
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
        let context = container.mainContext
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
    @MainActor
    public func fetchItemsByDrive(driveId: UUID) throws -> [SyncedItem] {
        let context = container.mainContext
        let predicate = #Predicate<SyncedItem> { $0.driveId == driveId }
        let descriptor = FetchDescriptor<SyncedItem>(predicate: predicate)
        return try context.fetch(descriptor)
    }

    /// Fetch a single SyncedItem by its S3 key.
    @MainActor
    public func fetchItem(byKey s3Key: String) throws -> SyncedItem? {
        let context = container.mainContext
        let predicate = #Predicate<SyncedItem> { $0.s3Key == s3Key }
        let descriptor = FetchDescriptor<SyncedItem>(predicate: predicate)
        return try context.fetch(descriptor).first
    }

    /// Delete all SyncedItems for a specific drive (hard delete).
    @MainActor
    public func deleteItemsForDrive(driveId: UUID) throws {
        let context = container.mainContext
        let predicate = #Predicate<SyncedItem> { $0.driveId == driveId }
        let descriptor = FetchDescriptor<SyncedItem>(predicate: predicate)
        let items = try context.fetch(descriptor)
        for item in items {
            context.delete(item)
        }
        try context.save()
    }

    /// Delete a single SyncedItem by S3 key.
    @MainActor
    public func deleteItem(byKey s3Key: String) throws {
        let context = container.mainContext
        let predicate = #Predicate<SyncedItem> { $0.s3Key == s3Key }
        let descriptor = FetchDescriptor<SyncedItem>(predicate: predicate)
        if let item = try context.fetch(descriptor).first {
            context.delete(item)
            try context.save()
        }
    }

    /// Fetch items by drive and sync status (e.g., all items in error state).
    @MainActor
    public func fetchItems(driveId: UUID, status: SyncStatus) throws -> [SyncedItem] {
        let statusRaw = status.rawValue
        let context = container.mainContext
        let predicate = #Predicate<SyncedItem> { $0.driveId == driveId && $0.syncStatus == statusRaw }
        let descriptor = FetchDescriptor<SyncedItem>(predicate: predicate)
        return try context.fetch(descriptor)
    }
}
