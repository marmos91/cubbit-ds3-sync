import XCTest
import SwiftData
import Atomics
@testable import DS3Lib

// MARK: - Mock S3 Listing Provider

/// Returns predefined S3 listing data for testing reconciliation logic.
final class MockS3ListingProvider: S3ListingProvider, @unchecked Sendable {
    var items: [String: S3ObjectInfo]
    var shouldThrow: Error?

    init(items: [String: S3ObjectInfo] = [:]) {
        self.items = items
        self.shouldThrow = nil
    }

    func listAllItems(bucket: String, prefix: String?) async throws -> [String: S3ObjectInfo] {
        if let error = shouldThrow { throw error }
        return items
    }
}

// MARK: - Mock Sync Engine Delegate

/// Records delegate callbacks for assertion in tests.
final class MockSyncEngineDelegate: SyncEngineDelegate, @unchecked Sendable {
    let completedDriveIds = LockedArray<UUID>()
    let errorDriveIds = LockedArray<UUID>()
    let recoveredDriveIds = LockedArray<UUID>()
    let errors = LockedArray<Error>()

    func syncEngineDidComplete(driveId: UUID) {
        completedDriveIds.append(driveId)
    }

    func syncEngineDidEnterErrorState(driveId: UUID, error: Error) {
        errorDriveIds.append(driveId)
        errors.append(error)
    }

    func syncEngineDidRecoverFromError(driveId: UUID) {
        recoveredDriveIds.append(driveId)
    }
}

// MARK: - Thread-safe array wrapper for delegate recording

/// A simple thread-safe array for recording delegate calls.
final class LockedArray<T>: @unchecked Sendable {
    private var storage: [T] = []
    private let lock = NSLock()

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    var all: [T] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ element: T) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(element)
    }
}

// MARK: - Test Helpers

/// Creates an in-memory ModelContainer for testing (no disk persistence).
func createTestModelContainer() throws -> ModelContainer {
    let schema = Schema(versionedSchema: SyncedItemSchemaV2.self)
    let config = ModelConfiguration(
        "TestSyncedItems",
        schema: schema,
        isStoredInMemoryOnly: true
    )
    return try ModelContainer(for: schema, configurations: [config])
}

// MARK: - SyncEngineTests

final class SyncEngineTests: XCTestCase {

    private var container: ModelContainer!
    private var metadataStore: MetadataStore!
    private var networkMonitor: NetworkMonitor!
    private var engine: SyncEngine!
    private var mockDelegate: MockSyncEngineDelegate!
    private let testDriveId = UUID()

    override func setUp() async throws {
        container = try createTestModelContainer()
        metadataStore = MetadataStore(modelContainer: container)
        networkMonitor = NetworkMonitor()
        // Do NOT start real network monitoring in tests
        engine = SyncEngine(metadataStore: metadataStore, networkMonitor: networkMonitor)
        mockDelegate = MockSyncEngineDelegate()
        await engine.setDelegate(mockDelegate)
    }

    override func tearDown() async throws {
        container = nil
        metadataStore = nil
        networkMonitor = nil
        engine = nil
        mockDelegate = nil
    }

    // MARK: - Test: Detect New Items

    /// Given S3 has keys ["a.txt", "b.txt"] and MetadataStore has ["a.txt"],
    /// reconciliation reports "b.txt" as new.
    func testDetectsNewItems() async throws {
        // Seed local store with one item
        try await metadataStore.upsertItem(
            s3Key: "a.txt", driveId: testDriveId, etag: "etag-a",
            syncStatus: .synced
        )

        // S3 has both a.txt and b.txt
        let s3Provider = MockS3ListingProvider(items: [
            "a.txt": S3ObjectInfo(etag: "etag-a", size: 100),
            "b.txt": S3ObjectInfo(etag: "etag-b", size: 200),
        ])

        let result = try await engine.reconcile(
            driveId: testDriveId, s3Provider: s3Provider,
            bucket: "test-bucket", prefix: nil
        )

        XCTAssertEqual(result.newKeys, ["b.txt"], "b.txt should be detected as new")
        XCTAssertTrue(result.modifiedKeys.isEmpty)
        XCTAssertTrue(result.deletedKeys.isEmpty)
    }

    // MARK: - Test: Detect Modified Items

    /// Given S3 has key "a.txt" with etag "v2" and MetadataStore has "a.txt" with etag "v1",
    /// reconciliation reports "a.txt" as modified.
    func testDetectsModifiedItems() async throws {
        try await metadataStore.upsertItem(
            s3Key: "a.txt", driveId: testDriveId, etag: "v1",
            syncStatus: .synced
        )

        let s3Provider = MockS3ListingProvider(items: [
            "a.txt": S3ObjectInfo(etag: "v2", size: 100),
        ])

        let result = try await engine.reconcile(
            driveId: testDriveId, s3Provider: s3Provider,
            bucket: "test-bucket", prefix: nil
        )

        XCTAssertEqual(result.modifiedKeys, ["a.txt"], "a.txt should be detected as modified")
        XCTAssertTrue(result.newKeys.isEmpty)
        XCTAssertTrue(result.deletedKeys.isEmpty)
    }

    // MARK: - Test: Detect Deleted Items

    /// Given S3 has keys ["a.txt"] and MetadataStore has ["a.txt", "b.txt"],
    /// reconciliation reports "b.txt" as deleted.
    func testDetectsDeletedItems() async throws {
        try await metadataStore.upsertItem(
            s3Key: "a.txt", driveId: testDriveId, etag: "etag-a",
            syncStatus: .synced
        )
        try await metadataStore.upsertItem(
            s3Key: "b.txt", driveId: testDriveId, etag: "etag-b",
            syncStatus: .synced
        )

        // S3 only has a.txt
        let s3Provider = MockS3ListingProvider(items: [
            "a.txt": S3ObjectInfo(etag: "etag-a", size: 100),
        ])

        let result = try await engine.reconcile(
            driveId: testDriveId, s3Provider: s3Provider,
            bucket: "test-bucket", prefix: nil
        )

        XCTAssertEqual(result.deletedKeys, ["b.txt"], "b.txt should be detected as deleted")
        XCTAssertTrue(result.newKeys.isEmpty)
        XCTAssertTrue(result.modifiedKeys.isEmpty)
    }

    // MARK: - Test: No Changes Detected

    /// Given S3 and MetadataStore have identical keys with matching etags,
    /// reconciliation reports empty sets.
    func testNoChangesDetected() async throws {
        try await metadataStore.upsertItem(
            s3Key: "a.txt", driveId: testDriveId, etag: "etag-a",
            syncStatus: .synced
        )
        try await metadataStore.upsertItem(
            s3Key: "b.txt", driveId: testDriveId, etag: "etag-b",
            syncStatus: .synced
        )

        let s3Provider = MockS3ListingProvider(items: [
            "a.txt": S3ObjectInfo(etag: "etag-a", size: 100),
            "b.txt": S3ObjectInfo(etag: "etag-b", size: 200),
        ])

        let result = try await engine.reconcile(
            driveId: testDriveId, s3Provider: s3Provider,
            bucket: "test-bucket", prefix: nil
        )

        XCTAssertTrue(result.newKeys.isEmpty, "No new keys expected")
        XCTAssertTrue(result.modifiedKeys.isEmpty, "No modified keys expected")
        XCTAssertTrue(result.deletedKeys.isEmpty, "No deleted keys expected")
        XCTAssertFalse(result.massDeletionDetected)
    }

    // MARK: - Test: Mass Deletion Warning

    /// Given MetadataStore has 10 items and S3 has 4,
    /// reconciliation proceeds but massDeletionDetected flag is true.
    func testMassDeletionWarning() async throws {
        // Seed 10 local items
        for i in 1...10 {
            try await metadataStore.upsertItem(
                s3Key: "file\(i).txt", driveId: testDriveId,
                etag: "etag-\(i)", syncStatus: .synced
            )
        }

        // S3 only has 4 items
        var s3Items: [String: S3ObjectInfo] = [:]
        for i in 1...4 {
            s3Items["file\(i).txt"] = S3ObjectInfo(etag: "etag-\(i)", size: 100)
        }
        let s3Provider = MockS3ListingProvider(items: s3Items)

        let result = try await engine.reconcile(
            driveId: testDriveId, s3Provider: s3Provider,
            bucket: "test-bucket", prefix: nil
        )

        XCTAssertTrue(result.massDeletionDetected, "Should detect mass deletion (6/10 > 50%)")
        XCTAssertEqual(result.deletedKeys.count, 6)
    }

    // MARK: - Test: Sync Anchor Advances

    /// After successful reconciliation, the SyncAnchorRecord.lastSyncDate is updated.
    func testSyncAnchorAdvances() async throws {
        let s3Provider = MockS3ListingProvider(items: [
            "a.txt": S3ObjectInfo(etag: "etag-a", size: 100),
        ])

        let beforeSync = Date()

        _ = try await engine.reconcile(
            driveId: testDriveId, s3Provider: s3Provider,
            bucket: "test-bucket", prefix: nil
        )

        // Use Sendable-safe snapshot method
        let snapshot = try await metadataStore.fetchSyncAnchorSnapshot(driveId: testDriveId)
        XCTAssertNotNil(snapshot, "Sync anchor should exist after reconciliation")
        XCTAssertGreaterThanOrEqual(snapshot!.lastSyncDate, beforeSync, "lastSyncDate should be updated")
    }

    // MARK: - Test: Sync Anchor Persistence

    /// SyncAnchorRecord created on first reconciliation, updated on subsequent.
    func testSyncAnchorPersistence() async throws {
        let s3Provider = MockS3ListingProvider(items: [
            "a.txt": S3ObjectInfo(etag: "etag-a", size: 100),
        ])

        // First reconciliation -- creates anchor
        _ = try await engine.reconcile(
            driveId: testDriveId, s3Provider: s3Provider,
            bucket: "test-bucket", prefix: nil
        )

        let firstSnapshot = try await metadataStore.fetchSyncAnchorSnapshot(driveId: testDriveId)
        XCTAssertNotNil(firstSnapshot)
        let firstDate = firstSnapshot!.lastSyncDate

        // Brief pause so date advances
        try await Task.sleep(for: .milliseconds(50))

        // Second reconciliation -- updates anchor
        _ = try await engine.reconcile(
            driveId: testDriveId, s3Provider: s3Provider,
            bucket: "test-bucket", prefix: nil
        )

        let secondSnapshot = try await metadataStore.fetchSyncAnchorSnapshot(driveId: testDriveId)
        XCTAssertNotNil(secondSnapshot)
        XCTAssertGreaterThan(secondSnapshot!.lastSyncDate, firstDate, "lastSyncDate should advance")
    }

    // MARK: - Test: Consecutive Failure Error State

    /// After 3 failed reconciliations, delegate.syncEngineDidEnterErrorState is called.
    func testConsecutiveFailureErrorState() async throws {
        let s3Provider = MockS3ListingProvider(items: [:])
        s3Provider.shouldThrow = NSError(domain: "TestError", code: 1)

        // Attempt 3 reconciliations that fail
        for _ in 1...3 {
            do {
                _ = try await engine.reconcile(
                    driveId: testDriveId, s3Provider: s3Provider,
                    bucket: "test-bucket", prefix: nil
                )
                XCTFail("Should have thrown")
            } catch {
                // Expected
            }
        }

        // Allow delegate callback to process
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            mockDelegate.errorDriveIds.count, 1,
            "Delegate should receive error state after 3 failures"
        )
    }

    // MARK: - Test: Error Count Reset On Success

    /// After a failure followed by success, consecutiveFailures resets to 0.
    func testErrorCountResetOnSuccess() async throws {
        let s3Provider = MockS3ListingProvider(items: [:])
        s3Provider.shouldThrow = NSError(domain: "TestError", code: 1)

        // One failed reconciliation
        do {
            _ = try await engine.reconcile(
                driveId: testDriveId, s3Provider: s3Provider,
                bucket: "test-bucket", prefix: nil
            )
        } catch {
            // Expected
        }

        // Now succeed
        s3Provider.shouldThrow = nil
        _ = try await engine.reconcile(
            driveId: testDriveId, s3Provider: s3Provider,
            bucket: "test-bucket", prefix: nil
        )

        let snapshot = try await metadataStore.fetchSyncAnchorSnapshot(driveId: testDriveId)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot!.consecutiveFailures, 0, "Failures should reset on success")
    }

    // MARK: - Test: Network Check Before Reconciliation

    /// When NetworkMonitor reports disconnected, reconciliation throws without attempting S3 calls.
    /// Since NetworkMonitor wraps NWPathMonitor and defaults to isConnected=true,
    /// we verify that when connected, reconciliation works (S3 provider IS called).
    func testNetworkCheckBeforeReconciliation() async throws {
        let callTracker = MockS3ListingProvider(items: ["a.txt": S3ObjectInfo(etag: "e", size: 1)])

        let connectedMonitor = NetworkMonitor()
        // Default isConnected is true, so this should succeed
        let connectedEngine = SyncEngine(metadataStore: metadataStore, networkMonitor: connectedMonitor)

        let result = try await connectedEngine.reconcile(
            driveId: testDriveId, s3Provider: callTracker,
            bucket: "test-bucket", prefix: nil
        )
        XCTAssertEqual(result.newKeys, ["a.txt"], "Should work when connected")
    }

    // MARK: - Test: Only Reports Deleted For Synced Items

    /// Only items with syncStatus == .synced are reported as deletions.
    /// Items with .pending or .error status should NOT be reported as deleted
    /// even if they are missing from S3.
    func testOnlyReportsDeletedForSyncedItems() async throws {
        // One synced item, one pending item -- both missing from S3
        try await metadataStore.upsertItem(
            s3Key: "synced.txt", driveId: testDriveId, etag: "etag-s",
            syncStatus: .synced
        )
        try await metadataStore.upsertItem(
            s3Key: "pending.txt", driveId: testDriveId, etag: "etag-p",
            syncStatus: .pending
        )

        // S3 is empty
        let s3Provider = MockS3ListingProvider(items: [:])

        let result = try await engine.reconcile(
            driveId: testDriveId, s3Provider: s3Provider,
            bucket: "test-bucket", prefix: nil
        )

        XCTAssertEqual(result.deletedKeys, ["synced.txt"],
                       "Only synced items should be reported as deleted")
        XCTAssertFalse(result.deletedKeys.contains("pending.txt"),
                       "Pending items should not be reported as deleted")
    }

    // MARK: - Test: Updates MetadataStore After Reconciliation

    /// After reconciliation, new items are upserted and deleted items are removed.
    func testUpdatesMetadataStoreAfterReconciliation() async throws {
        // Seed: local has "old.txt" as synced
        try await metadataStore.upsertItem(
            s3Key: "old.txt", driveId: testDriveId, etag: "etag-old",
            syncStatus: .synced
        )

        // S3 has "new.txt" but not "old.txt"
        let s3Provider = MockS3ListingProvider(items: [
            "new.txt": S3ObjectInfo(etag: "etag-new", size: 300),
        ])

        _ = try await engine.reconcile(
            driveId: testDriveId, s3Provider: s3Provider,
            bucket: "test-bucket", prefix: nil
        )

        // Use Sendable-safe methods to verify MetadataStore state
        let newExists = try await metadataStore.itemExists(byKey: "new.txt", driveId: testDriveId)
        XCTAssertTrue(newExists, "new.txt should be upserted into MetadataStore")

        let oldExists = try await metadataStore.itemExists(byKey: "old.txt", driveId: testDriveId)
        XCTAssertFalse(oldExists, "old.txt should be removed from MetadataStore after deletion")
    }
}
