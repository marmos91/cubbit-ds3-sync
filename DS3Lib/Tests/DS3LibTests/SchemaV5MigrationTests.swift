import XCTest
import SwiftData
@testable import DS3Lib

/// Tests for SchemaV4 → SchemaV5 lightweight migration (Phase 13.2 D-05, D-06).
///
/// Schema V5 DROPS the `thumbnailFailCount: Int = 0` field added in V4.
/// SwiftData "remove field" migrations are an under-trodden path; this test
/// pins the contract: a V4 store seeded with non-default `thumbnailFailCount`
/// values migrates cleanly to V5, all rows survive, all preserved fields
/// retain their values.
///
/// V5's `SyncedItem` simply lacks the `thumbnailFailCount` property — the
/// type system enforces "field is gone" at every callsite.
///
/// Mirrors the structure of `SchemaV4MigrationTests` (Phase 13 Plan 04).
final class SchemaV5MigrationTests: XCTestCase {

    /// Round-trip migration: seed an in-memory V4 container with 3 SyncedItem
    /// rows of varied (thumbnailStatus, thumbnailFailCount) plus 1 SyncAnchorRecord,
    /// close, re-open with V5 schema + SyncedItemMigrationPlan, assert rows
    /// survive and that other fields are preserved verbatim.
    func testV4ToV5LightweightMigrationDropsFailCountPreservesRows() throws {
        let storeURL = try Self.makeTempStoreURL()
        defer { try? Self.removeStoreFiles(at: storeURL) }

        let driveId = UUID()
        let anchorDriveId = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        // 1. Seed the store via a V4-only schema with non-default
        //    thumbnailFailCount values across the 3-strike spectrum.
        do {
            let v4Schema = Schema(versionedSchema: SyncedItemSchemaV4.self)
            let config = ModelConfiguration(
                "MigrationV4V5Test",
                schema: v4Schema,
                url: storeURL
            )
            let container = try ModelContainer(for: v4Schema, configurations: [config])
            let context = ModelContext(container)

            // Pre-strike: count=0, status=.pending
            let preStrike = SyncedItemSchemaV4.SyncedItem(
                s3Key: "folder/pre.jpg",
                driveId: driveId,
                size: 100,
                syncStatus: SyncStatus.synced.rawValue,
                thumbnailStatus: ThumbnailStatus.pending.rawValue,
                thumbnailFailCount: 0
            )
            preStrike.etag = "\"abc\""
            preStrike.lastModified = baseDate
            // Mid-strike: count=2 (just below the 3-strike boundary), status=.pending
            let midStrike = SyncedItemSchemaV4.SyncedItem(
                s3Key: "folder/mid.png",
                driveId: driveId,
                size: 200,
                syncStatus: SyncStatus.synced.rawValue,
                thumbnailStatus: ThumbnailStatus.pending.rawValue,
                thumbnailFailCount: 2
            )
            midStrike.etag = "\"def\""
            // Terminal: count=5 (exceeds boundary), status=.failed
            let terminalRow = SyncedItemSchemaV4.SyncedItem(
                s3Key: "folder/done.heic",
                driveId: driveId,
                size: 300,
                syncStatus: SyncStatus.synced.rawValue,
                thumbnailStatus: ThumbnailStatus.failed.rawValue,
                thumbnailFailCount: 5
            )
            terminalRow.etag = "\"ghi\""

            context.insert(preStrike)
            context.insert(midStrike)
            context.insert(terminalRow)

            // 1 SyncAnchorRecord — must survive the migration (Pitfall 3 regression
            // guard — V5 must list both SyncedItem AND SyncAnchorRecord in `models`).
            let anchor = SyncedItemSchemaV2.SyncAnchorRecord(
                driveId: anchorDriveId, lastSyncDate: baseDate
            )
            anchor.itemCount = 99
            anchor.consecutiveFailures = 1
            context.insert(anchor)

            try context.save()
        }

        // 2. Re-open with V5 schema + the migration plan. The lightweight stage
        //    `migrateV4toV5` runs; SwiftData drops the column from the schema.
        let v5Schema = Schema(versionedSchema: SyncedItemSchemaV5.self)
        let v5Config = ModelConfiguration(
            "MigrationV4V5Test",
            schema: v5Schema,
            url: storeURL
        )
        let v5Container = try ModelContainer(
            for: v5Schema,
            migrationPlan: SyncedItemMigrationPlan.self,
            configurations: [v5Config]
        )
        let v5Context = ModelContext(v5Container)

        // 3. All 3 rows must survive — the column drop must not cull data.
        let items = try v5Context.fetch(FetchDescriptor<SyncedItemSchemaV5.SyncedItem>())
        XCTAssertEqual(items.count, 3, "All 3 V4 SyncedItem rows must survive V4→V5 migration")

        // Other fields preserved verbatim — these are the V5 surface.
        let byKey = Dictionary(uniqueKeysWithValues: items.map { ($0.s3Key, $0) })

        let pre = try XCTUnwrap(byKey["folder/pre.jpg"])
        XCTAssertEqual(pre.driveId, driveId)
        XCTAssertEqual(pre.size, 100)
        XCTAssertEqual(pre.etag, "\"abc\"")
        XCTAssertEqual(pre.lastModified, baseDate)
        XCTAssertEqual(pre.syncStatus, SyncStatus.synced.rawValue)
        XCTAssertEqual(pre.thumbnailStatus, ThumbnailStatus.pending.rawValue)

        let mid = try XCTUnwrap(byKey["folder/mid.png"])
        XCTAssertEqual(mid.size, 200)
        XCTAssertEqual(mid.etag, "\"def\"")
        XCTAssertEqual(mid.thumbnailStatus, ThumbnailStatus.pending.rawValue)

        let terminalFetched = try XCTUnwrap(byKey["folder/done.heic"])
        XCTAssertEqual(terminalFetched.size, 300)
        XCTAssertEqual(terminalFetched.etag, "\"ghi\"")
        XCTAssertEqual(terminalFetched.thumbnailStatus, ThumbnailStatus.failed.rawValue)

        // 4. The SyncAnchorRecord row must survive (Pitfall 3 regression test
        // — V5.models MUST list SyncAnchorRecord, not just SyncedItem).
        let anchors = try v5Context.fetch(FetchDescriptor<SyncedItemSchemaV2.SyncAnchorRecord>())
        XCTAssertEqual(anchors.count, 1, "SyncAnchorRecord must survive V4→V5 migration")
        XCTAssertEqual(anchors[0].driveId, anchorDriveId)
        XCTAssertEqual(anchors[0].itemCount, 99)
        XCTAssertEqual(anchors[0].consecutiveFailures, 1)
    }

    // The typealias check moved to SchemaV6MigrationTests after Phase 13.2
    // Plan 09 bumped `SyncedItem` to V6.

    /// Open a V5-bound container directly and prove a V5 row round-trips
    /// through the V5 type. Phase 13.2 Plan 09 bumped the public `SyncedItem`
    /// typealias to V6, so this test uses `SyncedItemSchemaV5.SyncedItem`
    /// explicitly to retain coverage of the V5 surface (V5 still ships in
    /// the migration plan to bridge older stores).
    func testV5BoundContainerRoundTrip() throws {
        let schema = Schema(versionedSchema: SyncedItemSchemaV5.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let driveId = UUID()
        let item = SyncedItemSchemaV5.SyncedItem(
            s3Key: "v5-prove.jpg",
            driveId: driveId,
            size: 7,
            syncStatus: SyncStatus.synced.rawValue,
            thumbnailStatus: ThumbnailStatus.uploaded.rawValue
        )
        context.insert(item)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SyncedItemSchemaV5.SyncedItem>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].s3Key, "v5-prove.jpg")
        XCTAssertEqual(fetched[0].thumbnailStatus, ThumbnailStatus.uploaded.rawValue)
    }

    // MARK: - Helpers (mirror SchemaV4MigrationTests)

    private static func makeTempStoreURL() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let unique = UUID().uuidString
        return tempDir.appendingPathComponent("SchemaV5MigrationTest-\(unique).store")
    }

    private static func removeStoreFiles(at storeURL: URL) throws {
        let suffixes = ["", "-shm", "-wal"]
        for suffix in suffixes {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
