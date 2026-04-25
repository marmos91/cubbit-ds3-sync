import XCTest
import SwiftData
@testable import DS3Lib

/// Tests for `MetadataStore.fetchPendingThumbnails` + `setThumbnailStatus`
/// (the Schema V3 thumbnail query surface — Phase 12 / THUMB-04).
final class MetadataStoreThumbnailQueriesTests: XCTestCase {
    private var container: ModelContainer!
    private var store: MetadataStore!
    private let driveId = UUID()
    private let otherDriveId = UUID()

    override func setUp() async throws {
        let schema = Schema(versionedSchema: SyncedItemSchemaV3.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        store = MetadataStore(modelContainer: container)
    }

    // MARK: - fetchPendingThumbnails

    func testFetchPendingThumbnailsReturnsOnlyPendingForDrive() async throws {
        // Drive A: 1 pending raster, 1 uploaded raster, 1 failed raster
        try await store.upsertItem(
            s3Key: "a/pending.jpg", driveId: driveId, syncStatus: .synced, size: 100
        )
        try await store.upsertItem(
            s3Key: "a/uploaded.jpg", driveId: driveId, syncStatus: .synced, size: 100
        )
        try await store.setThumbnailStatus(s3Key: "a/uploaded.jpg", driveId: driveId, status: .uploaded)
        try await store.upsertItem(
            s3Key: "a/failed.jpg", driveId: driveId, syncStatus: .synced, size: 100
        )
        try await store.setThumbnailStatus(s3Key: "a/failed.jpg", driveId: driveId, status: .failed)

        // Drive B (other): 1 pending raster — must NOT come back when querying drive A
        try await store.upsertItem(
            s3Key: "b/other.png", driveId: otherDriveId, syncStatus: .synced, size: 100
        )

        let pending = try await store.fetchPendingThumbnails(driveId: driveId, limit: 100)
        let keys = Set(pending.map(\.s3Key))

        XCTAssertEqual(pending.count, 1, "Only the pending raster row from drive A should match")
        XCTAssertTrue(keys.contains("a/pending.jpg"))
        XCTAssertFalse(keys.contains("a/uploaded.jpg"))
        XCTAssertFalse(keys.contains("a/failed.jpg"))
        XCTAssertFalse(keys.contains("b/other.png"))
    }

    func testFetchPendingThumbnailsRespectsLimit() async throws {
        // Seed 5 pending raster items for the drive.
        for index in 0..<5 {
            try await store.upsertItem(
                s3Key: "img/\(index).jpg",
                driveId: driveId,
                syncStatus: .synced,
                size: 100
            )
        }

        let limited = try await store.fetchPendingThumbnails(driveId: driveId, limit: 3)

        // The descriptor.fetchLimit is applied at the SwiftData layer; the
        // raster filter then runs in-Swift over the 3 already-fetched rows.
        // All 5 items here are raster, so the result is exactly 3.
        XCTAssertEqual(limited.count, 3, "fetch must be bounded by the supplied limit")
    }

    /// The raster allow-list filter runs in Swift AFTER the SwiftData fetch is
    /// bounded by `limit` — this is the Pitfall 5 contract. Seed 4 pending items
    /// (.pdf, .mov, .jpg, .png), pass `limit: 10`, expect the 2 raster items.
    /// Document for callers: `result.count < limit` does NOT mean end-of-queue.
    func testFetchPendingThumbnailsRasterAllowListFiltersInSwift() async throws {
        try await store.upsertItem(
            s3Key: "mixed/doc.pdf", driveId: driveId, syncStatus: .synced, size: 100
        )
        try await store.upsertItem(
            s3Key: "mixed/clip.mov", driveId: driveId, syncStatus: .synced, size: 100
        )
        try await store.upsertItem(
            s3Key: "mixed/photo.jpg", driveId: driveId, syncStatus: .synced, size: 100
        )
        try await store.upsertItem(
            s3Key: "mixed/photo.png", driveId: driveId, syncStatus: .synced, size: 100
        )

        let result = try await store.fetchPendingThumbnails(driveId: driveId, limit: 10)
        let keys = Set(result.map(\.s3Key))

        XCTAssertEqual(result.count, 2, "raster allow-list must drop .pdf and .mov from the result")
        XCTAssertTrue(keys.contains("mixed/photo.jpg"))
        XCTAssertTrue(keys.contains("mixed/photo.png"))
        XCTAssertFalse(keys.contains("mixed/doc.pdf"))
        XCTAssertFalse(keys.contains("mixed/clip.mov"))
    }

    func testFetchPendingThumbnailsCarriesEtagAndContentTypeAndSize() async throws {
        try await store.upsertItem(
            s3Key: "carry/x.jpg",
            driveId: driveId,
            etag: "\"abc123\"",
            syncStatus: .synced,
            contentType: "image/jpeg",
            size: 4321
        )

        let result = try await store.fetchPendingThumbnails(driveId: driveId, limit: 10)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].s3Key, "carry/x.jpg")
        XCTAssertEqual(result[0].etag, "\"abc123\"")
        XCTAssertEqual(result[0].contentType, "image/jpeg")
        XCTAssertEqual(result[0].size, 4321)
    }

    // MARK: - setThumbnailStatus

    /// Updates the thumbnailStatus on an existing row and persists across re-fetch.
    func testSetThumbnailStatusUpdatesExistingRow() async throws {
        try await store.upsertItem(
            s3Key: "set/photo.jpg", driveId: driveId, syncStatus: .synced, size: 50
        )

        try await store.setThumbnailStatus(
            s3Key: "set/photo.jpg", driveId: driveId, status: .uploaded
        )

        // Re-fetch via fetchPendingThumbnails: the row should NO LONGER be pending.
        let stillPending = try await store.fetchPendingThumbnails(driveId: driveId, limit: 10)
        XCTAssertTrue(
            stillPending.allSatisfy { $0.s3Key != "set/photo.jpg" },
            "Row must transition out of pending after setThumbnailStatus(.uploaded)"
        )
    }

    /// Per D-22, `setThumbnailStatus` is a no-op when the row does not exist.
    /// The coordinator must NEVER create rows via this setter.
    func testSetThumbnailStatusIsNoOpWhenRowMissing() async throws {
        try await store.setThumbnailStatus(
            s3Key: "missing/ghost.jpg", driveId: driveId, status: .uploaded
        )

        // The setter must NOT have inserted anything.
        let count = try await store.countItemsByDrive(driveId: driveId)
        XCTAssertEqual(count, 0, "setThumbnailStatus must NOT insert a row when none exists")
    }

    func testSetThumbnailStatusFailedTransitionPersists() async throws {
        try await store.upsertItem(
            s3Key: "fail/bad.heic", driveId: driveId, syncStatus: .synced, size: 50
        )
        try await store.setThumbnailStatus(
            s3Key: "fail/bad.heic", driveId: driveId, status: .failed
        )

        // After .failed, the row should not appear in fetchPendingThumbnails.
        let pending = try await store.fetchPendingThumbnails(driveId: driveId, limit: 10)
        XCTAssertTrue(pending.isEmpty, "A row marked .failed must not be returned by fetchPendingThumbnails")
    }

    func testSetThumbnailStatusIsIdempotentWhenStatusUnchanged() async throws {
        try await store.upsertItem(
            s3Key: "idem/same.jpg", driveId: driveId, syncStatus: .synced, size: 100
        )
        try await store.setThumbnailStatus(
            s3Key: "idem/same.jpg", driveId: driveId, status: .uploaded
        )
        // Second call with the same status must not throw, must not flip the
        // row's status, and must not duplicate rows.
        try await store.setThumbnailStatus(
            s3Key: "idem/same.jpg", driveId: driveId, status: .uploaded
        )
        let pending = try await store.fetchPendingThumbnails(driveId: driveId, limit: 10)
        XCTAssertTrue(pending.isEmpty, ".uploaded → .uploaded must not resurrect the row as pending")
        let count = try await store.countItemsByDrive(driveId: driveId)
        XCTAssertEqual(count, 1, "Repeated setThumbnailStatus calls must not duplicate rows")
    }

    // MARK: - Non-raster reclassification

    func testFetchPendingThumbnailsReclassifiesNonRasterItems() async throws {
        // Seed: 1 raster pending, 2 non-raster pending (both default to .pending)
        try await store.upsertItem(
            s3Key: "mix/photo.jpg", driveId: driveId, syncStatus: .synced, size: 100
        )
        try await store.upsertItem(
            s3Key: "mix/notes.txt", driveId: driveId, syncStatus: .synced, size: 50
        )
        try await store.upsertItem(
            s3Key: "mix/data.json", driveId: driveId, syncStatus: .synced, size: 50
        )

        let first = try await store.fetchPendingThumbnails(driveId: driveId, limit: 10)
        XCTAssertEqual(first.count, 1, "Only the raster file should be returned")
        XCTAssertEqual(first.first?.s3Key, "mix/photo.jpg")

        // Both non-raster items must have transitioned to .notApplicable so a
        // second call has no work to reclassify.
        let txtStatus = try await store.fetchItemSyncStatusForThumbnails(
            s3Key: "mix/notes.txt", driveId: driveId
        )
        let jsonStatus = try await store.fetchItemSyncStatusForThumbnails(
            s3Key: "mix/data.json", driveId: driveId
        )
        XCTAssertEqual(txtStatus, ThumbnailStatus.notApplicable.rawValue)
        XCTAssertEqual(jsonStatus, ThumbnailStatus.notApplicable.rawValue)
    }

    func testCountPendingRasterThumbnailsReturnsRasterOnly() async throws {
        try await store.upsertItem(
            s3Key: "c/a.jpg", driveId: driveId, syncStatus: .synced, size: 100
        )
        try await store.upsertItem(
            s3Key: "c/b.png", driveId: driveId, syncStatus: .synced, size: 100
        )
        try await store.upsertItem(
            s3Key: "c/notes.txt", driveId: driveId, syncStatus: .synced, size: 100
        )
        let count = try await store.countPendingRasterThumbnails(driveId: driveId)
        XCTAssertEqual(count, 2)
    }
}

// Test-only helper for reading thumbnailStatus directly (the public surface
// only exposes status via fetchPendingThumbnails / setThumbnailStatus).
extension MetadataStore {
    func fetchItemSyncStatusForThumbnails(s3Key: String, driveId: UUID) throws -> String? {
        try findItem(byKey: s3Key, driveId: driveId)?.thumbnailStatus
    }
}
