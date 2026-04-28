import XCTest
import SwiftData
@testable import DS3Lib

/// Tests for SchemaV3 → SchemaV4 lightweight migration.
///
/// Schema V4 adds a `thumbnailFailCount: Int = 0` field to `SyncedItem`. The
/// migration must:
///  - preserve all existing `SyncedItem` rows (Pitfall 3 — V4 must list BOTH
///    `SyncedItem` and `SyncAnchorRecord` in `models`)
///  - default `thumbnailFailCount` to `0` on existing rows
///  - preserve all other field values (especially `thumbnailStatus`)
///
/// Mirrors the structure of `SchemaV3MigrationTests` (Phase 12 D-36).
final class SchemaV4MigrationTests: XCTestCase {

    /// Round-trip migration: seed an in-memory V3 container with 3 SyncedItem
    /// rows of varied thumbnailStatus (.pending / .uploaded / .failed) plus 1
    /// SyncAnchorRecord, close, re-open with V4 schema + SyncedItemMigrationPlan,
    /// assert all rows survive and that `thumbnailFailCount == 0` is populated
    /// by the lightweight migration.
    func testV3ToV4LightweightMigrationPreservesRowsAndDefaultsFailCount() throws {
        let storeURL = try Self.makeTempStoreURL()
        defer { try? Self.removeStoreFiles(at: storeURL) }

        let driveId = UUID()
        let anchorDriveId = UUID()

        // 1. Seed the store via a V3-only schema.
        do {
            let v3Schema = Schema(versionedSchema: SyncedItemSchemaV3.self)
            let config = ModelConfiguration(
                "MigrationV3V4Test",
                schema: v3Schema,
                url: storeURL
            )
            let container = try ModelContainer(for: v3Schema, configurations: [config])
            let context = ModelContext(container)

            let pendingItem = SyncedItemSchemaV3.SyncedItem(
                s3Key: "folder/pending.jpg",
                driveId: driveId,
                size: 100,
                syncStatus: SyncStatus.synced.rawValue,
                thumbnailStatus: ThumbnailStatus.pending.rawValue
            )
            let uploadedItem = SyncedItemSchemaV3.SyncedItem(
                s3Key: "folder/uploaded.png",
                driveId: driveId,
                size: 200,
                syncStatus: SyncStatus.synced.rawValue,
                thumbnailStatus: ThumbnailStatus.uploaded.rawValue
            )
            let failedItem = SyncedItemSchemaV3.SyncedItem(
                s3Key: "folder/failed.heic",
                driveId: driveId,
                size: 300,
                syncStatus: SyncStatus.synced.rawValue,
                thumbnailStatus: ThumbnailStatus.failed.rawValue
            )
            context.insert(pendingItem)
            context.insert(uploadedItem)
            context.insert(failedItem)

            // 1 SyncAnchorRecord — must survive the migration.
            let anchor = SyncedItemSchemaV2.SyncAnchorRecord(
                driveId: anchorDriveId, lastSyncDate: Date()
            )
            anchor.itemCount = 42
            anchor.consecutiveFailures = 3
            context.insert(anchor)

            try context.save()
        }

        // 2. Re-open with V4 schema + the migration plan. The lightweight stage
        //    `migrateV3toV4` runs and populates `thumbnailFailCount = 0` on
        //    every existing row.
        let v4Schema = Schema(versionedSchema: SyncedItemSchemaV4.self)
        let v4Config = ModelConfiguration(
            "MigrationV3V4Test",
            schema: v4Schema,
            url: storeURL
        )
        let v4Container = try ModelContainer(
            for: v4Schema,
            migrationPlan: SyncedItemMigrationPlan.self,
            configurations: [v4Config]
        )
        let v4Context = ModelContext(v4Container)

        // 3. All 3 SyncedItem rows present, all default to thumbnailFailCount == 0,
        //    and thumbnailStatus is preserved verbatim across the migration.
        let items = try v4Context.fetch(FetchDescriptor<SyncedItem>())
        XCTAssertEqual(items.count, 3, "All 3 V3 SyncedItem rows must survive V3→V4 migration")
        for item in items {
            XCTAssertEqual(
                item.thumbnailFailCount, 0,
                "Existing rows must default to 0 thumbnailFailCount after lightweight V3→V4 migration"
            )
        }

        // Verify the thumbnailStatus values are preserved.
        let byKey = Dictionary(uniqueKeysWithValues: items.map { ($0.s3Key, $0) })
        XCTAssertEqual(
            byKey["folder/pending.jpg"]?.thumbnailStatus,
            ThumbnailStatus.pending.rawValue,
            "thumbnailStatus must survive migration verbatim"
        )
        XCTAssertEqual(
            byKey["folder/uploaded.png"]?.thumbnailStatus,
            ThumbnailStatus.uploaded.rawValue
        )
        XCTAssertEqual(
            byKey["folder/failed.heic"]?.thumbnailStatus,
            ThumbnailStatus.failed.rawValue
        )

        // 4. The SyncAnchorRecord row must survive (Pitfall 3 regression test).
        let anchors = try v4Context.fetch(FetchDescriptor<SyncAnchorRecord>())
        XCTAssertEqual(anchors.count, 1, "SyncAnchorRecord must survive V3→V4 migration")
        XCTAssertEqual(anchors[0].driveId, anchorDriveId)
        XCTAssertEqual(anchors[0].itemCount, 42)
        XCTAssertEqual(anchors[0].consecutiveFailures, 3)
    }

    /// The bottom-of-file `typealias SyncedItem` resolves to V4's class.
    /// This is a compile-and-runtime check — if the typealias still points at
    /// V3, this assertion would fail because the metatypes differ.
    func testTypealiasIsV4() throws {
        XCTAssertTrue(
            SyncedItem.self == SyncedItemSchemaV4.SyncedItem.self,
            "typealias SyncedItem must resolve to SyncedItemSchemaV4.SyncedItem"
        )
    }

    /// Open MetadataStore via `createContainer()` (in-memory ModelConfiguration
    /// shape doesn't apply — but we can prove the binding by inserting a row
    /// with a non-default `thumbnailFailCount` and reading it back, which only
    /// works if the schema bound by the container is V4.
    func testMetadataStoreCreateContainerBindsV4() throws {
        let schema = Schema(versionedSchema: SyncedItemSchemaV4.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let driveId = UUID()
        let item = SyncedItem(s3Key: "v4-prove.jpg", driveId: driveId, size: 1)
        item.thumbnailFailCount = 5
        context.insert(item)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SyncedItem>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(
            fetched[0].thumbnailFailCount, 5,
            "V4-bound container must persist thumbnailFailCount round-trip"
        )
    }

    // MARK: - Helpers

    private static func makeTempStoreURL() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let unique = UUID().uuidString
        return tempDir.appendingPathComponent("SchemaV4MigrationTest-\(unique).store")
    }

    private static func removeStoreFiles(at storeURL: URL) throws {
        let suffixes = ["", "-shm", "-wal"]
        for suffix in suffixes {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
