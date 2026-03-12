import XCTest
import SwiftData
@testable import DS3Lib

/// Tests for SchemaV1 to SchemaV2 migration and MetadataStore actor behavior.
final class MetadataStoreMigrationTests: XCTestCase {
    func testSchemaV2HasIsMaterializedField() throws {
        // Verify SyncedItem in V2 schema has isMaterialized with default false
        let schema = Schema(versionedSchema: SyncedItemSchemaV2.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let item = SyncedItem(s3Key: "test/file.txt", driveId: UUID())
        context.insert(item)
        try context.save()

        let descriptor = FetchDescriptor<SyncedItem>()
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertFalse(fetched[0].isMaterialized, "isMaterialized should default to false")
    }

    func testSchemaV2IncludesSyncAnchorRecord() throws {
        // Verify SyncAnchorRecord can be persisted in V2 schema
        let schema = Schema(versionedSchema: SyncedItemSchemaV2.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let driveId = UUID()
        let anchor = SyncAnchorRecord(driveId: driveId)
        context.insert(anchor)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SyncAnchorRecord>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].driveId, driveId)
        XCTAssertEqual(fetched[0].consecutiveFailures, 0)
        XCTAssertEqual(fetched[0].itemCount, 0)
        XCTAssertNil(fetched[0].lastSuccessfulSync)
    }

    func testMetadataStoreActorIsolation() async throws {
        // Verify MetadataStore is usable from async context (not @MainActor).
        // Note: SyncedItem and SyncAnchorRecord are @Model classes (not Sendable),
        // so we test actor isolation via methods that return Sendable types (Void, Int, Date).
        let schema = Schema(versionedSchema: SyncedItemSchemaV2.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let store = MetadataStore(modelContainer: container)

        let driveId = UUID()

        // Upsert an item (returns Void -- Sendable)
        try await store.upsertItem(s3Key: "test/isolation.txt", driveId: driveId, syncStatus: .pending, size: 100)

        // Delete item (returns Void -- Sendable)
        try await store.deleteItem(byKey: "test/isolation.txt")

        // SyncAnchor operations returning Sendable types
        try await store.upsertSyncAnchor(driveId: driveId, lastSyncDate: Date(), itemCount: 5)
        let syncDate = try await store.advanceSyncAnchor(driveId: driveId, itemCount: 10)
        XCTAssertNotNil(syncDate)

        let failures = try await store.incrementFailureCount(driveId: driveId)
        XCTAssertEqual(failures, 1)

        try await store.resetFailureCount(driveId: driveId)
        try await store.deleteSyncAnchor(driveId: driveId)
    }
}
