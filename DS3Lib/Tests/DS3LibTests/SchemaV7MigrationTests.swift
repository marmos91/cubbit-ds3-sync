import SwiftData
import XCTest
@testable import DS3Lib

/// Validates that the V6→V7 lightweight migration adds `isPinned` (default
/// false) without dropping rows, and that the runtime `SyncedItem` typealias
/// resolves to V7.
final class SchemaV7MigrationTests: XCTestCase {
    // MARK: - V6 → V7 lightweight migration

    func testV6ToV7LightweightMigrationPreservesRowsAndDefaultsIsPinned() throws {
        let storeURL = try Self.makeTempStoreURL()
        defer { try? Self.removeStoreFiles(at: storeURL) }

        let driveId = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        // 1. Seed V6 store with a few rows.
        do {
            let v6Schema = Schema(versionedSchema: SyncedItemSchemaV6.self)
            let v6Config = ModelConfiguration(
                "MigrationV6V7Test",
                schema: v6Schema,
                url: storeURL
            )
            let v6Container = try ModelContainer(
                for: v6Schema,
                migrationPlan: SyncedItemMigrationPlan.self,
                configurations: [v6Config]
            )
            let v6Context = ModelContext(v6Container)

            let item = SyncedItemSchemaV6.SyncedItem(
                s3Key: "folder/file.jpg",
                driveId: driveId,
                size: 100,
                syncStatus: SyncStatus.synced.rawValue
            )
            item.etag = "\"abc\""
            item.lastModified = baseDate
            v6Context.insert(item)
            try v6Context.save()
        }

        // 2. Re-open with V7 schema + the migration plan. The lightweight
        //    `migrateV6toV7` stage runs; SwiftData adds the new column with
        //    its declared default value.
        let v7Schema = Schema(versionedSchema: SyncedItemSchemaV7.self)
        let v7Config = ModelConfiguration(
            "MigrationV6V7Test",
            schema: v7Schema,
            url: storeURL
        )
        let v7Container = try ModelContainer(
            for: v7Schema,
            migrationPlan: SyncedItemMigrationPlan.self,
            configurations: [v7Config]
        )
        let v7Context = ModelContext(v7Container)

        let items = try v7Context.fetch(FetchDescriptor<SyncedItemSchemaV7.SyncedItem>())
        XCTAssertEqual(items.count, 1, "V6 row must survive the V6→V7 migration")
        let row = try XCTUnwrap(items.first)
        XCTAssertEqual(row.s3Key, "folder/file.jpg")
        XCTAssertEqual(row.driveId, driveId)
        XCTAssertEqual(row.etag, "\"abc\"")
        XCTAssertFalse(row.isPinned, "isPinned must default to false on migrated rows")
        XCTAssertFalse(row.isMaterialized)
    }

    func testTypealiasIsV7() {
        XCTAssertTrue(
            SyncedItem.self == SyncedItemSchemaV7.SyncedItem.self,
            "typealias SyncedItem must resolve to SyncedItemSchemaV7.SyncedItem"
        )
    }

    func testMetadataStoreV7BoundContainerRoundTrip() throws {
        let schema = Schema(versionedSchema: SyncedItemSchemaV7.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let driveId = UUID()
        let item = SyncedItem(
            s3Key: "pinned.jpg",
            driveId: driveId,
            size: 7,
            syncStatus: SyncStatus.synced.rawValue
        )
        item.isPinned = true
        context.insert(item)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SyncedItem>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertTrue(fetched[0].isPinned)
    }

    // MARK: - Helpers

    private static func makeTempStoreURL() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let unique = UUID().uuidString
        return tempDir.appendingPathComponent("SchemaV7MigrationTest-\(unique).store")
    }

    private static func removeStoreFiles(at storeURL: URL) throws {
        let suffixes = ["", "-shm", "-wal"]
        for suffix in suffixes {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
