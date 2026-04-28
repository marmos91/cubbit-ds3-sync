import Foundation
import SwiftData
import XCTest

@testable import DS3Lib

/// Tests for the Phase 13 / Plan 13-04 3-strike rule and the upsert ETag-reset
/// path. Covers:
///   - `setThumbnailFailure` increments + transitions at the 3-strike boundary
///     (Pitfall 10 — `count >= maxFailStrikes`, NOT `>`).
///   - `setThumbnailFailure` is idempotent on terminal `.failed`.
///   - `setThumbnailFailure` is a no-op (returns `.failed`) on missing rows.
///   - `fetchPendingThumbnails` excludes `.failed` rows (regression guard
///     against the 3-strike terminal contract — D-30).
///   - Upsert path resets `thumbnailFailCount = 0` AND `thumbnailStatus = .pending`
///     when the persisted ETag differs from the new ETag (D-31).
///   - Upsert path does NOT reset when the ETag is unchanged (D-31 negative test).
final class ThumbnailStrikeRuleTests: XCTestCase {
    private var container: ModelContainer!
    private var store: MetadataStore!
    private let driveId = UUID()

    override func setUp() async throws {
        let schema = Schema(versionedSchema: SyncedItemSchemaV4.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        store = MetadataStore(modelContainer: container)
    }

    override func tearDown() async throws {
        store = nil
        container = nil
    }

    // MARK: - Helpers

    /// Reads the persisted thumbnailFailCount + thumbnailStatus for a key.
    private func currentState(forKey s3Key: String) async throws -> (Int, String)? {
        try await store.thumbnailStateForTesting(s3Key: s3Key, driveId: driveId)
    }

    // MARK: - Test 4: increment from zero stays pending

    /// Seed item with `thumbnailFailCount=0, thumbnailStatus=.pending`; call
    /// `setThumbnailFailure`; expect count=1, status=.pending.
    func testSetThumbnailFailureIncrementsFromZero() async throws {
        try await store.upsertItem(
            s3Key: "fail/a.jpg", driveId: driveId, etag: "\"abc\"", syncStatus: .synced, size: 100
        )

        let result = try await store.setThumbnailFailure(
            s3Key: "fail/a.jpg", driveId: driveId
        )

        XCTAssertEqual(result, .pending, "count=1 < 3 must NOT yet be terminal")
        let state = try await currentState(forKey: "fail/a.jpg")
        XCTAssertEqual(state?.0, 1, "thumbnailFailCount must increment to 1 from 0")
        XCTAssertEqual(state?.1, ThumbnailStatus.pending.rawValue,
                       "thumbnailStatus must remain .pending below the 3-strike threshold")
    }

    // MARK: - Test 5: third failure flips terminal (boundary)

    /// Seed `thumbnailFailCount=2, thumbnailStatus=.pending`; call setThumbnailFailure;
    /// expect count=3, status=.failed (THIRD failure flips terminal — Pitfall 10).
    func testSetThumbnailFailureBoundary() async throws {
        try await store.upsertItem(
            s3Key: "fail/b.jpg", driveId: driveId, etag: "\"abc\"", syncStatus: .synced, size: 100
        )
        // Bump thumbnailFailCount to 2 directly.
        try await store.bumpFailCountForTesting(s3Key: "fail/b.jpg", driveId: driveId, to: 2)

        let result = try await store.setThumbnailFailure(
            s3Key: "fail/b.jpg", driveId: driveId
        )

        XCTAssertEqual(result, .failed,
                       "count=3 (>= maxFailStrikes=3) must transition to .failed")
        let state = try await currentState(forKey: "fail/b.jpg")
        XCTAssertEqual(state?.0, 3, "thumbnailFailCount must increment from 2 to 3")
        XCTAssertEqual(state?.1, ThumbnailStatus.failed.rawValue,
                       "thumbnailStatus must transition to .failed at the boundary count==3")
    }

    // MARK: - Test 6: beyond-boundary stays failed (idempotent terminal)

    /// Seed `thumbnailFailCount=5, thumbnailStatus=.failed`; call setThumbnailFailure;
    /// expect count=6, status=.failed (idempotent terminal).
    func testSetThumbnailFailureBeyondBoundaryStaysFailed() async throws {
        try await store.upsertItem(
            s3Key: "fail/c.jpg", driveId: driveId, etag: "\"abc\"", syncStatus: .synced, size: 100
        )
        try await store.bumpFailCountForTesting(s3Key: "fail/c.jpg", driveId: driveId, to: 5)
        try await store.setThumbnailStatus(
            s3Key: "fail/c.jpg", driveId: driveId, status: .failed
        )

        let result = try await store.setThumbnailFailure(
            s3Key: "fail/c.jpg", driveId: driveId
        )

        XCTAssertEqual(result, .failed)
        let state = try await currentState(forKey: "fail/c.jpg")
        XCTAssertEqual(state?.0, 6, "thumbnailFailCount must keep incrementing past the boundary")
        XCTAssertEqual(state?.1, ThumbnailStatus.failed.rawValue,
                       "Already-failed rows must remain .failed")
    }

    // MARK: - Test 7: missing row → returns .failed, no insert, no throw

    /// Call with s3Key not in store; expect return == `.failed` (best-effort),
    /// no throw, no row inserted.
    func testSetThumbnailFailureMissingItemReturnsFailedNoCrash() async throws {
        let result = try await store.setThumbnailFailure(
            s3Key: "missing/ghost.jpg", driveId: driveId
        )

        XCTAssertEqual(result, .failed,
                       "missing-row best-effort contract returns .failed")
        let count = try await store.countItemsByDrive(driveId: driveId)
        XCTAssertEqual(count, 0, "setThumbnailFailure must NOT insert a row when none exists")
    }

    // MARK: - Test 8: fetchPendingThumbnails excludes .failed (regression)

    /// Seed `thumbnailStatus=.failed, thumbnailFailCount=3`; assert
    /// `fetchPendingThumbnails` does NOT include it (regression guard against
    /// D-30 — `.failed` is terminal until ETag change).
    func testFetchPendingThumbnailsExcludesFailed() async throws {
        try await store.upsertItem(
            s3Key: "term/done.jpg", driveId: driveId, etag: "\"abc\"", syncStatus: .synced, size: 100
        )
        try await store.bumpFailCountForTesting(s3Key: "term/done.jpg", driveId: driveId, to: 3)
        try await store.setThumbnailStatus(
            s3Key: "term/done.jpg", driveId: driveId, status: .failed
        )

        let pending = try await store.fetchPendingThumbnails(driveId: driveId, limit: 10)
        XCTAssertTrue(
            pending.allSatisfy { $0.s3Key != "term/done.jpg" },
            "fetchPendingThumbnails MUST exclude rows whose thumbnailStatus is .failed"
        )
    }

    // MARK: - Test 9: ETag change resets count + status (D-31)

    /// Seed item `etag="abc", thumbnailStatus=.failed, thumbnailFailCount=3`;
    /// call upsert with same s3Key + new etag `"def"`; assert post-upsert:
    /// `thumbnailFailCount == 0` AND `thumbnailStatus == .pending` (D-31 reset).
    /// Also assert OTHER fields (size, lastModified) updated as before.
    func testUpsertResetsCountWhenETagChanges() async throws {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.upsertItem(
            s3Key: "etag/file.jpg",
            driveId: driveId,
            etag: "\"abc\"",
            lastModified: baseDate,
            syncStatus: .synced,
            size: 100
        )
        try await store.bumpFailCountForTesting(s3Key: "etag/file.jpg", driveId: driveId, to: 3)
        try await store.setThumbnailStatus(
            s3Key: "etag/file.jpg", driveId: driveId, status: .failed
        )

        // Sanity check pre-upsert state.
        let pre = try await currentState(forKey: "etag/file.jpg")
        XCTAssertEqual(pre?.0, 3)
        XCTAssertEqual(pre?.1, ThumbnailStatus.failed.rawValue)

        // Upsert with the SAME key but a DIFFERENT etag — must re-arm thumbnail.
        let newDate = Date(timeIntervalSince1970: 1_700_999_999)
        try await store.upsertItem(
            s3Key: "etag/file.jpg",
            driveId: driveId,
            etag: "\"def\"",
            lastModified: newDate,
            syncStatus: .synced,
            size: 200
        )

        let post = try await currentState(forKey: "etag/file.jpg")
        XCTAssertEqual(post?.0, 0,
                       "thumbnailFailCount must reset to 0 when ETag changes (D-31)")
        XCTAssertEqual(post?.1, ThumbnailStatus.pending.rawValue,
                       "thumbnailStatus must reset to .pending when ETag changes (D-31)")

        // Also assert other fields followed the upsert (regression guard).
        let metadata = try await store.fetchItemMetadata(byKey: "etag/file.jpg", driveId: driveId)
        XCTAssertEqual(metadata?.etag, "\"def\"", "etag must persist the new value")
        XCTAssertEqual(metadata?.lastModified, newDate, "lastModified must persist the new value")
        XCTAssertEqual(metadata?.size, 200, "size must persist the new value")
    }

    // MARK: - Test 10: same ETag preserves state (D-31 negative)

    /// Seed item `etag="abc", thumbnailStatus=.failed, thumbnailFailCount=3`;
    /// call upsert with same s3Key + same etag `"abc"`; assert
    /// `thumbnailFailCount` and `thumbnailStatus` unchanged.
    func testUpsertDoesNotResetWhenETagUnchanged() async throws {
        try await store.upsertItem(
            s3Key: "etag/same.jpg",
            driveId: driveId,
            etag: "\"abc\"",
            syncStatus: .synced,
            size: 100
        )
        try await store.bumpFailCountForTesting(s3Key: "etag/same.jpg", driveId: driveId, to: 3)
        try await store.setThumbnailStatus(
            s3Key: "etag/same.jpg", driveId: driveId, status: .failed
        )

        // Upsert with the SAME key and SAME etag — must NOT reset.
        try await store.upsertItem(
            s3Key: "etag/same.jpg",
            driveId: driveId,
            etag: "\"abc\"",
            syncStatus: .synced,
            size: 100
        )

        let post = try await currentState(forKey: "etag/same.jpg")
        XCTAssertEqual(post?.0, 3,
                       "thumbnailFailCount must NOT reset when ETag is unchanged")
        XCTAssertEqual(post?.1, ThumbnailStatus.failed.rawValue,
                       "thumbnailStatus must NOT reset when ETag is unchanged")
    }
}

// MARK: - Test-only helpers

extension MetadataStore {
    /// Reads `(thumbnailFailCount, thumbnailStatus)` directly. Public surface
    /// only exposes status via `fetchPendingThumbnails` / `setThumbnailStatus`,
    /// which doesn't surface the count.
    func thumbnailStateForTesting(s3Key: String, driveId: UUID) throws -> (Int, String)? {
        guard let item = try findItem(byKey: s3Key, driveId: driveId) else { return nil }
        return (item.thumbnailFailCount, item.thumbnailStatus)
    }

    /// Bumps the strike count directly (test fixture seed). Bypasses the
    /// production `setThumbnailFailure` so tests can place rows at exact
    /// pre-conditions (count==2, count==5, etc.) without firing transitions.
    func bumpFailCountForTesting(s3Key: String, driveId: UUID, to value: Int) throws {
        guard let item = try findItem(byKey: s3Key, driveId: driveId) else { return }
        item.thumbnailFailCount = value
        try modelExecutor.modelContext.save()
    }
}
