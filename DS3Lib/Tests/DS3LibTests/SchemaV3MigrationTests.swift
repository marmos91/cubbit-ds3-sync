import XCTest
import SwiftData
@testable import DS3Lib

/// Tests for SchemaV2 to SchemaV3 lightweight migration.
///
/// Schema V3 adds a `thumbnailStatus: String` field (defaulted to `.pending`)
/// to `SyncedItem` and a typed `@Transient thumbnail: ThumbnailStatus` accessor.
/// The migration must:
///  - preserve all existing `SyncedItem` rows
///  - default `thumbnailStatus` to `"pending"` on existing rows
///  - preserve all existing `SyncAnchorRecord` rows (Pitfall 3 — V3 must list
///    BOTH `SyncedItem` and `SyncAnchorRecord` in `models`)
final class SchemaV3MigrationTests: XCTestCase {

    /// Round-trip migration: seed an in-memory V2 container with 3 SyncedItem
    /// rows (varied syncStatus) plus 1 SyncAnchorRecord, close, re-open with V3
    /// schema + SyncedItemMigrationPlan, assert all rows survive and that
    /// `thumbnailStatus == "pending"` is populated by the lightweight migration.
    func testV2ToV3LightweightMigrationPreservesRowsAndDefaultsThumbnailStatus() throws {
        let storeURL = try Self.makeTempStoreURL()
        defer { try? Self.removeStoreFiles(at: storeURL) }

        let driveId = UUID()
        let anchorDriveId = UUID()

        // 1. Seed the store via a V2-only schema.
        do {
            let v2Schema = Schema(versionedSchema: SyncedItemSchemaV2.self)
            let config = ModelConfiguration(
                "MigrationV2V3Test",
                schema: v2Schema,
                url: storeURL
            )
            let container = try ModelContainer(for: v2Schema, configurations: [config])
            let context = ModelContext(container)

            // 3 SyncedItem rows with varied syncStatus — use the explicit V2
            // class (NOT the `SyncedItem` typealias, which now resolves to V3)
            // to seed the V2-schema container.
            let pendingItem = SyncedItemSchemaV2.SyncedItem(
                s3Key: "folder/pending.jpg",
                driveId: driveId,
                size: 100,
                syncStatus: SyncStatus.pending.rawValue
            )
            let syncedItem = SyncedItemSchemaV2.SyncedItem(
                s3Key: "folder/synced.png",
                driveId: driveId,
                size: 200,
                syncStatus: SyncStatus.synced.rawValue
            )
            let errorItem = SyncedItemSchemaV2.SyncedItem(
                s3Key: "folder/error.heic",
                driveId: driveId,
                size: 300,
                syncStatus: SyncStatus.error.rawValue
            )
            context.insert(pendingItem)
            context.insert(syncedItem)
            context.insert(errorItem)

            // 1 SyncAnchorRecord — must survive the migration (Pitfall 3).
            // V3's SyncAnchorRecord is a typealias for V2's, so the same Swift
            // class is used in the seed and the post-migration fetch.
            let anchor = SyncedItemSchemaV2.SyncAnchorRecord(driveId: anchorDriveId, lastSyncDate: Date())
            anchor.itemCount = 42
            anchor.consecutiveFailures = 3
            context.insert(anchor)

            try context.save()
        }

        // 2. Re-open with V3 schema + the migration plan. The lightweight stage
        //    `migrateV2toV3` runs and populates `thumbnailStatus = "pending"`
        //    on every existing row.
        let v3Schema = Schema(versionedSchema: SyncedItemSchemaV3.self)
        let v3Config = ModelConfiguration(
            "MigrationV2V3Test",
            schema: v3Schema,
            url: storeURL
        )
        let v3Container = try ModelContainer(
            for: v3Schema,
            migrationPlan: SyncedItemMigrationPlan.self,
            configurations: [v3Config]
        )
        let v3Context = ModelContext(v3Container)

        // 3. All 3 SyncedItem rows present, all default to .pending thumbnail status.
        let items = try v3Context.fetch(FetchDescriptor<SyncedItem>())
        XCTAssertEqual(items.count, 3, "All 3 V2 SyncedItem rows must survive V2→V3 migration")
        for item in items {
            XCTAssertEqual(
                item.thumbnailStatus,
                ThumbnailStatus.pending.rawValue,
                "Existing rows must default to 'pending' after lightweight migration"
            )
            XCTAssertEqual(item.thumbnail, .pending)
        }

        // 4. The SyncAnchorRecord row must survive (Pitfall 3 regression test).
        let anchors = try v3Context.fetch(FetchDescriptor<SyncAnchorRecord>())
        XCTAssertEqual(anchors.count, 1, "SyncAnchorRecord must survive V2→V3 migration (Pitfall 3)")
        XCTAssertEqual(anchors[0].driveId, anchorDriveId)
        XCTAssertEqual(anchors[0].itemCount, 42)
        XCTAssertEqual(anchors[0].consecutiveFailures, 3)
    }

    /// A freshly-inserted V3 SyncedItem (via designated init) defaults
    /// `thumbnailStatus` to `"pending"` and the @Transient accessor reads `.pending`.
    func testFreshV3SyncedItemDefaultsToPendingThumbnailStatus() throws {
        let schema = Schema(versionedSchema: SyncedItemSchemaV3.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let item = SyncedItem(s3Key: "fresh.jpg", driveId: UUID(), size: 1)
        context.insert(item)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SyncedItem>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].thumbnailStatus, ThumbnailStatus.pending.rawValue)
        XCTAssertEqual(fetched[0].thumbnail, .pending)
    }

    /// Round-trip a non-default `ThumbnailStatus` through the @Transient accessor:
    /// set `.uploaded` via accessor, assert raw stored field is `"uploaded"`,
    /// re-fetch and assert accessor reads `.uploaded` again.
    func testThumbnailStatusAccessorRoundTrip() throws {
        let schema = Schema(versionedSchema: SyncedItemSchemaV3.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let driveId = UUID()
        let item = SyncedItem(s3Key: "round-trip.png", driveId: driveId, size: 1)
        context.insert(item)
        item.thumbnail = .uploaded
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SyncedItem>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(
            fetched[0].thumbnailStatus,
            "uploaded",
            "Accessor must persist the raw value into the stored String field"
        )
        XCTAssertEqual(fetched[0].thumbnail, .uploaded)
    }

    // MARK: - Helpers

    private static func makeTempStoreURL() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let unique = UUID().uuidString
        return tempDir.appendingPathComponent("SchemaV3MigrationTest-\(unique).store")
    }

    private static func removeStoreFiles(at storeURL: URL) throws {
        let suffixes = ["", "-shm", "-wal"]
        for suffix in suffixes {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
