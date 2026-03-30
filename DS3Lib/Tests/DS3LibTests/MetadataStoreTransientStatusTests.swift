import XCTest
import SwiftData
@testable import DS3Lib

/// Tests that MetadataStore preserves transient sync statuses (error, syncing, conflict)
/// when an upsert attempts to overwrite them with `.synced`.
final class MetadataStoreTransientStatusTests: XCTestCase {
    private var container: ModelContainer!
    private var store: MetadataStore!
    private let driveId = UUID()

    override func setUp() async throws {
        let schema = Schema(versionedSchema: SyncedItemSchemaV2.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        store = MetadataStore(modelContainer: container)
    }

    // MARK: - SyncStatus.isTransient

    func testIsTransientForErrorSyncingConflict() {
        XCTAssertTrue(SyncStatus.error.isTransient)
        XCTAssertTrue(SyncStatus.syncing.isTransient)
        XCTAssertTrue(SyncStatus.conflict.isTransient)
    }

    func testIsTransientFalseForPendingSyncedTrashed() {
        XCTAssertFalse(SyncStatus.pending.isTransient)
        XCTAssertFalse(SyncStatus.synced.isTransient)
        XCTAssertFalse(SyncStatus.trashed.isTransient)
    }

    // MARK: - Upsert preserves transient states

    func testUpsertPreservesErrorStatusWhenNewStatusIsSynced() async throws {
        try await store.upsertItem(s3Key: "folder/", driveId: driveId, syncStatus: .error)
        try await store.upsertItem(s3Key: "folder/", driveId: driveId, syncStatus: .synced)

        let status = try await store.fetchItemSyncStatus(byKey: "folder/", driveId: driveId)
        XCTAssertEqual(status, SyncStatus.error.rawValue, "Error status should be preserved when upserting with .synced")
    }

    func testUpsertPreservesSyncingStatusWhenNewStatusIsSynced() async throws {
        try await store.upsertItem(s3Key: "folder/", driveId: driveId, syncStatus: .syncing)
        try await store.upsertItem(s3Key: "folder/", driveId: driveId, syncStatus: .synced)

        let status = try await store.fetchItemSyncStatus(byKey: "folder/", driveId: driveId)
        XCTAssertEqual(status, SyncStatus.syncing.rawValue, "Syncing status should be preserved when upserting with .synced")
    }

    func testUpsertPreservesConflictStatusWhenNewStatusIsSynced() async throws {
        try await store.upsertItem(s3Key: "folder/", driveId: driveId, syncStatus: .conflict)
        try await store.upsertItem(s3Key: "folder/", driveId: driveId, syncStatus: .synced)

        let status = try await store.fetchItemSyncStatus(byKey: "folder/", driveId: driveId)
        XCTAssertEqual(status, SyncStatus.conflict.rawValue, "Conflict status should be preserved when upserting with .synced")
    }

    // MARK: - Upsert allows explicit status transitions

    func testUpsertAllowsErrorToBeOverwrittenByExplicitError() async throws {
        try await store.upsertItem(s3Key: "file.txt", driveId: driveId, syncStatus: .error)
        try await store.upsertItem(s3Key: "file.txt", driveId: driveId, syncStatus: .error)

        let status = try await store.fetchItemSyncStatus(byKey: "file.txt", driveId: driveId)
        XCTAssertEqual(status, SyncStatus.error.rawValue)
    }

    func testUpsertAllowsErrorToBeOverwrittenByPending() async throws {
        try await store.upsertItem(s3Key: "file.txt", driveId: driveId, syncStatus: .error)
        try await store.upsertItem(s3Key: "file.txt", driveId: driveId, syncStatus: .pending)

        let status = try await store.fetchItemSyncStatus(byKey: "file.txt", driveId: driveId)
        XCTAssertEqual(status, SyncStatus.pending.rawValue, "Non-.synced status should be able to overwrite error")
    }

    func testUpsertAllowsSyncedToBeOverwrittenBySynced() async throws {
        try await store.upsertItem(s3Key: "file.txt", driveId: driveId, syncStatus: .synced)
        try await store.upsertItem(s3Key: "file.txt", driveId: driveId, syncStatus: .synced)

        let status = try await store.fetchItemSyncStatus(byKey: "file.txt", driveId: driveId)
        XCTAssertEqual(status, SyncStatus.synced.rawValue)
    }

    func testUpsertAllowsSyncedToBeOverwrittenByError() async throws {
        try await store.upsertItem(s3Key: "file.txt", driveId: driveId, syncStatus: .synced)
        try await store.upsertItem(s3Key: "file.txt", driveId: driveId, syncStatus: .error)

        let status = try await store.fetchItemSyncStatus(byKey: "file.txt", driveId: driveId)
        XCTAssertEqual(status, SyncStatus.error.rawValue, ".synced should transition to .error")
    }

    // MARK: - Batch upsert respects transient protection

    func testBatchUpsertPreservesTransientStatus() async throws {
        try await store.upsertItem(s3Key: "folder/", driveId: driveId, syncStatus: .error)

        let batch = [
            MetadataStore.ItemUpsertData(s3Key: "folder/", driveId: driveId, syncStatus: .synced)
        ]
        try await store.batchUpsertItems(batch)

        let status = try await store.fetchItemSyncStatus(byKey: "folder/", driveId: driveId)
        XCTAssertEqual(status, SyncStatus.error.rawValue, "Batch upsert should also preserve transient status")
    }

    // MARK: - clearParentErrorIfResolved

    func testClearParentErrorWhenNoChildrenInError() async throws {
        try await store.upsertItem(s3Key: "folder/", driveId: driveId, syncStatus: .error)
        try await store.upsertItem(
            s3Key: "folder/file.txt", driveId: driveId, syncStatus: .synced, parentKey: "folder/"
        )

        let cleared = try await store.clearParentErrorIfResolved(
            childKey: "folder/file.txt", driveId: driveId
        )
        XCTAssertTrue(cleared, "Parent error should be cleared when no children are in error")

        let status = try await store.fetchItemSyncStatus(byKey: "folder/", driveId: driveId)
        XCTAssertEqual(status, SyncStatus.synced.rawValue)
    }

    func testClearParentErrorNotClearedWhenSiblingInError() async throws {
        try await store.upsertItem(s3Key: "folder/", driveId: driveId, syncStatus: .error)
        try await store.upsertItem(
            s3Key: "folder/good.txt", driveId: driveId, syncStatus: .synced, parentKey: "folder/"
        )
        try await store.upsertItem(
            s3Key: "folder/bad.txt", driveId: driveId, syncStatus: .error, parentKey: "folder/"
        )

        let cleared = try await store.clearParentErrorIfResolved(
            childKey: "folder/good.txt", driveId: driveId
        )
        XCTAssertFalse(cleared, "Parent error should remain when a sibling is still in error")

        let status = try await store.fetchItemSyncStatus(byKey: "folder/", driveId: driveId)
        XCTAssertEqual(status, SyncStatus.error.rawValue)
    }

    func testClearParentErrorNoOpWhenParentNotInError() async throws {
        try await store.upsertItem(s3Key: "folder/", driveId: driveId, syncStatus: .synced)
        try await store.upsertItem(
            s3Key: "folder/file.txt", driveId: driveId, syncStatus: .synced, parentKey: "folder/"
        )

        let cleared = try await store.clearParentErrorIfResolved(
            childKey: "folder/file.txt", driveId: driveId
        )
        XCTAssertFalse(cleared, "Should return false when parent is not in error state")
    }

    func testClearParentErrorReturnsFalseForRootItem() async throws {
        try await store.upsertItem(s3Key: "file.txt", driveId: driveId, syncStatus: .synced)

        let cleared = try await store.clearParentErrorIfResolved(
            childKey: "file.txt", driveId: driveId
        )
        XCTAssertFalse(cleared, "Root-level items have no parent to clear")
    }
}
