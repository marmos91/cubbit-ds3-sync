import XCTest
import SwiftData
@testable import DS3Lib

/// V5 → V6 migration test (Phase 13.2 D-05, D-06, D-07, D-08, D-23).
///
/// Schema V6 DROPS the `thumbnailStatus: String` field and the `thumbnail`
/// transient accessor. With the BFS coordinator + sweeper gone (Plans 06, 07),
/// the upload-hook's `.notApplicable` / `.uploaded` writes removed (this plan,
/// D-08), and `consumeThumbnail`'s `markPending` parameter stripped (this plan),
/// the field has no remaining consumer. The "is the thumbnail uploaded?"
/// question is answered by S3 itself going forward — `getThumbnailBytes`
/// returns bytes or nil.
///
/// SwiftData "remove field" migrations are an under-trodden path; this test
/// pins the contract: a V5 store seeded with non-default `thumbnailStatus`
/// values migrates cleanly to V6, all rows survive, all preserved fields
/// retain their values.
///
/// V6's `SyncedItem` simply lacks the `thumbnailStatus` property — the type
/// system enforces "field is gone" at every callsite.
///
/// Mirrors the structure of `SchemaV5MigrationTests` (Phase 13.2 Plan 08).
final class SchemaV6MigrationTests: XCTestCase {

    /// Round-trip migration: seed an in-memory V5 container with 3 SyncedItem
    /// rows of varied `thumbnailStatus` plus 1 SyncAnchorRecord, close, re-open
    /// with V6 schema + SyncedItemMigrationPlan, assert rows survive and that
    /// other fields are preserved verbatim. The dropped column is invisible to
    /// V6's `SyncedItem` — no runtime "field is gone" assertion needed; the
    /// type system enforces it at every callsite.
    func testV5ToV6LightweightMigrationDropsStatusPreservesRows() throws {
        let storeURL = try Self.makeTempStoreURL()
        defer { try? Self.removeStoreFiles(at: storeURL) }

        let driveId = UUID()
        let anchorDriveId = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        // 1. Seed the store via a V5-only schema with non-default thumbnailStatus values.
        do {
            let v5Schema = Schema(versionedSchema: SyncedItemSchemaV5.self)
            let config = ModelConfiguration(
                "MigrationV5V6Test",
                schema: v5Schema,
                url: storeURL
            )
            let container = try ModelContainer(for: v5Schema, configurations: [config])
            let context = ModelContext(container)

            // Pending row.
            let pendingRow = SyncedItemSchemaV5.SyncedItem(
                s3Key: "folder/pending.jpg",
                driveId: driveId,
                size: 100,
                syncStatus: SyncStatus.synced.rawValue,
                thumbnailStatus: ThumbnailStatus.pending.rawValue
            )
            pendingRow.etag = "\"abc\""
            pendingRow.lastModified = baseDate
            // Uploaded row.
            let uploadedRow = SyncedItemSchemaV5.SyncedItem(
                s3Key: "folder/uploaded.png",
                driveId: driveId,
                size: 200,
                syncStatus: SyncStatus.synced.rawValue,
                thumbnailStatus: ThumbnailStatus.uploaded.rawValue
            )
            uploadedRow.etag = "\"def\""
            // Failed row.
            let failedRow = SyncedItemSchemaV5.SyncedItem(
                s3Key: "folder/failed.heic",
                driveId: driveId,
                size: 300,
                syncStatus: SyncStatus.synced.rawValue,
                thumbnailStatus: ThumbnailStatus.failed.rawValue
            )
            failedRow.etag = "\"ghi\""

            context.insert(pendingRow)
            context.insert(uploadedRow)
            context.insert(failedRow)

            // 1 SyncAnchorRecord — must survive the migration (Pitfall 3 regression
            // guard — V6 must list both SyncedItem AND SyncAnchorRecord in `models`).
            let anchor = SyncedItemSchemaV2.SyncAnchorRecord(
                driveId: anchorDriveId, lastSyncDate: baseDate
            )
            anchor.itemCount = 99
            anchor.consecutiveFailures = 1
            context.insert(anchor)

            try context.save()
        }

        // 2. Re-open with V6 schema + the migration plan. The lightweight stage
        //    `migrateV5toV6` runs; SwiftData drops the column from the schema.
        let v6Schema = Schema(versionedSchema: SyncedItemSchemaV6.self)
        let v6Config = ModelConfiguration(
            "MigrationV5V6Test",
            schema: v6Schema,
            url: storeURL
        )
        let v6Container = try ModelContainer(
            for: v6Schema,
            migrationPlan: SyncedItemMigrationPlan.self,
            configurations: [v6Config]
        )
        let v6Context = ModelContext(v6Container)

        // 3. All 3 rows must survive — the column drop must not cull data.
        let items = try v6Context.fetch(FetchDescriptor<SyncedItemSchemaV6.SyncedItem>())
        XCTAssertEqual(items.count, 3, "All 3 V5 SyncedItem rows must survive V5→V6 migration")

        // Other fields preserved verbatim — these are the V6 surface.
        let byKey = Dictionary(uniqueKeysWithValues: items.map { ($0.s3Key, $0) })

        let pending = try XCTUnwrap(byKey["folder/pending.jpg"])
        XCTAssertEqual(pending.driveId, driveId)
        XCTAssertEqual(pending.size, 100)
        XCTAssertEqual(pending.etag, "\"abc\"")
        XCTAssertEqual(pending.lastModified, baseDate)
        XCTAssertEqual(pending.syncStatus, SyncStatus.synced.rawValue)
        // thumbnailStatus is GONE from V6 type — type system enforces it at
        // compile time; no runtime assertion needed.

        let uploaded = try XCTUnwrap(byKey["folder/uploaded.png"])
        XCTAssertEqual(uploaded.size, 200)
        XCTAssertEqual(uploaded.etag, "\"def\"")

        let failed = try XCTUnwrap(byKey["folder/failed.heic"])
        XCTAssertEqual(failed.size, 300)
        XCTAssertEqual(failed.etag, "\"ghi\"")

        // 4. The SyncAnchorRecord row must survive (Pitfall 3 regression test
        // — V6.models MUST list SyncAnchorRecord, not just SyncedItem).
        let anchors = try v6Context.fetch(FetchDescriptor<SyncedItemSchemaV2.SyncAnchorRecord>())
        XCTAssertEqual(anchors.count, 1, "SyncAnchorRecord must survive V5→V6 migration")
        XCTAssertEqual(anchors[0].driveId, anchorDriveId)
        XCTAssertEqual(anchors[0].itemCount, 99)
        XCTAssertEqual(anchors[0].consecutiveFailures, 1)
    }

    /// The bottom-of-file `typealias SyncedItem` resolves to V6's class.
    /// If this fails, the typealias is still pointing at V5 (or earlier).
    func testTypealiasIsV6() throws {
        XCTAssertTrue(
            SyncedItem.self == SyncedItemSchemaV6.SyncedItem.self,
            "typealias SyncedItem must resolve to SyncedItemSchemaV6.SyncedItem"
        )
    }

    /// Open a V6-bound container and prove the container's SyncedItem schema
    /// is V6 by inserting + reading back a row through the public `SyncedItem`
    /// typealias. (V6 lacks `thumbnailStatus` — type system enforces it; we
    /// don't need to assert "field is gone" at runtime.)
    func testMetadataStoreV6BoundContainerRoundTrip() throws {
        let schema = Schema(versionedSchema: SyncedItemSchemaV6.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let driveId = UUID()
        let item = SyncedItem(
            s3Key: "v6-prove.jpg",
            driveId: driveId,
            size: 7,
            syncStatus: SyncStatus.synced.rawValue
        )
        context.insert(item)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SyncedItem>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].s3Key, "v6-prove.jpg")
        XCTAssertEqual(fetched[0].syncStatus, SyncStatus.synced.rawValue)
    }

    // MARK: - Helpers (mirror SchemaV5MigrationTests)

    private static func makeTempStoreURL() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let unique = UUID().uuidString
        return tempDir.appendingPathComponent("SchemaV6MigrationTest-\(unique).store")
    }

    private static func removeStoreFiles(at storeURL: URL) throws {
        let suffixes = ["", "-shm", "-wal"]
        for suffix in suffixes {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
