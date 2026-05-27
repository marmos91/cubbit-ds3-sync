import XCTest
@testable import DS3Lib

/// Tests for RecentFilesTracker ring buffer and sorting.
final class RecentFilesTrackerTests: XCTestCase {
    var tracker: RecentFilesTracker!
    let driveId = UUID()

    override func setUp() {
        super.setUp()
        tracker = RecentFilesTracker()
    }

    // MARK: - Test 1: add() stores entries up to maxCount (10)

    func testAddStoresEntriesUpToMaxCount() {
        for i in 0..<10 {
            let entry = RecentFileEntry(
                driveId: driveId,
                filename: "file\(i).txt",
                size: Int64(i * 100),
                status: .completed,
                timestamp: Date()
            )
            tracker.add(entry)
        }

        let entries = tracker.entries(forDrive: driveId)
        XCTAssertEqual(entries.count, 10)
    }

    // MARK: - Test 2: Adding 11th entry evicts oldest completed entry

    func testRingBufferEvictsOldestCompletedEntry() {
        for i in 0..<10 {
            let entry = RecentFileEntry(
                driveId: driveId,
                filename: "file\(i).txt",
                size: Int64(i * 100),
                status: .completed,
                timestamp: Date().addingTimeInterval(Double(i))
            )
            tracker.add(entry)
        }

        // Add 11th entry
        let newEntry = RecentFileEntry(
            driveId: driveId,
            filename: "file10.txt",
            size: 1000,
            status: .completed,
            timestamp: Date().addingTimeInterval(10)
        )
        tracker.add(newEntry)

        let entries = tracker.entries(forDrive: driveId)
        XCTAssertEqual(entries.count, 10)
        // The oldest entry (file0.txt) should have been evicted
        XCTAssertFalse(entries.contains(where: { $0.filename == "file0.txt" }))
        XCTAssertTrue(entries.contains(where: { $0.filename == "file10.txt" }))
    }

    // MARK: - Test 3: sorted() returns entries ordered: syncing, error, completed

    func testSortedReturnsSyncingFirstThenErrorThenCompleted() {
        let completedEntry = RecentFileEntry(
            driveId: driveId,
            filename: "completed.txt",
            size: 100,
            status: .completed,
            timestamp: Date()
        )
        let errorEntry = RecentFileEntry(
            driveId: driveId,
            filename: "error.txt",
            size: 200,
            status: .error,
            timestamp: Date()
        )
        let syncingEntry = RecentFileEntry(
            driveId: driveId,
            filename: "syncing.txt",
            size: 300,
            status: .syncing,
            timestamp: Date()
        )

        // Add in reverse order
        tracker.add(completedEntry)
        tracker.add(errorEntry)
        tracker.add(syncingEntry)

        let entries = tracker.entries(forDrive: driveId)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].status, .syncing)
        XCTAssertEqual(entries[1].status, .error)
        XCTAssertEqual(entries[2].status, .completed)
    }

    // MARK: - Test 4: RecentFileEntry has correct properties

    func testRecentFileEntryProperties() {
        let now = Date()
        let entry = RecentFileEntry(
            driveId: driveId,
            filename: "test.txt",
            size: 1024,
            status: .syncing,
            timestamp: now
        )

        XCTAssertEqual(entry.driveId, driveId)
        XCTAssertEqual(entry.filename, "test.txt")
        XCTAssertEqual(entry.size, 1024)
        XCTAssertEqual(entry.status, .syncing)
        XCTAssertEqual(entry.timestamp, now)
        XCTAssertNotNil(entry.id)
    }

    // MARK: - Test 5: Update status of existing entry by filename

    func testUpdateStatusChangesExistingEntry() {
        let entry = RecentFileEntry(
            driveId: driveId,
            filename: "uploading.txt",
            size: 500,
            status: .syncing,
            timestamp: Date()
        )
        tracker.add(entry)

        tracker.update(filename: "uploading.txt", driveId: driveId, status: .completed)

        let entries = tracker.entries(forDrive: driveId)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].status, .completed)
        XCTAssertEqual(entries[0].filename, "uploading.txt")
    }

    // MARK: - Test 6: entries(forDrive:) filters by drive ID

    func testEntriesForDriveFiltersCorrectly() {
        let otherDriveId = UUID()

        let entry1 = RecentFileEntry(
            driveId: driveId,
            filename: "drive1.txt",
            size: 100,
            status: .completed,
            timestamp: Date()
        )
        let entry2 = RecentFileEntry(
            driveId: otherDriveId,
            filename: "drive2.txt",
            size: 200,
            status: .completed,
            timestamp: Date()
        )

        tracker.add(entry1)
        tracker.add(entry2)

        let driveEntries = tracker.entries(forDrive: driveId)
        XCTAssertEqual(driveEntries.count, 1)
        XCTAssertEqual(driveEntries[0].filename, "drive1.txt")

        let otherEntries = tracker.entries(forDrive: otherDriveId)
        XCTAssertEqual(otherEntries.count, 1)
        XCTAssertEqual(otherEntries[0].filename, "drive2.txt")
    }

    // MARK: - Display size

    func testDisplaySizeFormatsCorrectly() {
        let kbEntry = RecentFileEntry(
            driveId: driveId,
            filename: "small.txt",
            size: 2048,
            status: .completed,
            timestamp: Date()
        )
        XCTAssertEqual(kbEntry.displaySize, "2.0 KB")

        let mbEntry = RecentFileEntry(
            driveId: driveId,
            filename: "large.txt",
            size: 5 * 1024 * 1024,
            status: .completed,
            timestamp: Date()
        )
        XCTAssertEqual(mbEntry.displaySize, "5.0 MB")
    }

    // MARK: - TransferStatus Comparable

    func testTransferStatusComparable() {
        XCTAssertTrue(TransferStatus.syncing < TransferStatus.error)
        XCTAssertTrue(TransferStatus.error < TransferStatus.completed)
        XCTAssertTrue(TransferStatus.syncing < TransferStatus.completed)
    }

    // MARK: - Dedupe by identifier (Gap 14)

    /// Upserting an entry with the same identifier must replace the existing
    /// row instead of producing a duplicate. The previous array-backed tracker
    /// would happily store two rows for the same file (one .syncing, one
    /// .completed) — this test guards against the regression.
    func testUpsertReplacesExistingEntryByIdentifier() {
        let initial = RecentFileEntry(
            driveId: driveId,
            filename: "photo.png",
            size: 100,
            status: .syncing,
            timestamp: Date()
        )
        tracker.upsert(initial)

        let completed = RecentFileEntry(
            driveId: driveId,
            filename: "photo.png",
            size: 100,
            status: .completed,
            timestamp: Date().addingTimeInterval(1)
        )
        tracker.upsert(completed)

        let entries = tracker.entries(forDrive: driveId)
        XCTAssertEqual(entries.count, 1, "Same identifier must dedupe to a single entry")
        XCTAssertEqual(entries[0].status, .completed)
    }

    /// Merge must preserve the earliest `timestamp` (transfer start) but adopt
    /// the latest `status` and `updatedAt`.
    func testUpsertMergesEarliestStartedAtAndLatestStatus() {
        let earlyStart = Date().addingTimeInterval(-60)
        let lateUpdate = Date()

        let started = RecentFileEntry(
            driveId: driveId,
            filename: "doc.pdf",
            size: 0,
            status: .syncing,
            timestamp: earlyStart,
            updatedAt: earlyStart
        )
        tracker.upsert(started)

        let finished = RecentFileEntry(
            driveId: driveId,
            filename: "doc.pdf",
            size: 4096,
            status: .completed,
            timestamp: lateUpdate,
            updatedAt: lateUpdate
        )
        tracker.upsert(finished)

        let entries = tracker.entries(forDrive: driveId)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].timestamp, earlyStart, "Earliest startedAt must survive merge")
        XCTAssertEqual(entries[0].updatedAt, lateUpdate, "Latest updatedAt must survive merge")
        XCTAssertEqual(entries[0].status, .completed)
    }

    // MARK: - Stuck transfer watchdog (Gap 14)

    /// A `.syncing` entry whose `updatedAt` is older than the threshold must
    /// be transitioned to `.error("timeout")` by the watchdog sweep.
    func testSweepStuckTransfersFailsOldSyncingEntries() {
        let stale = RecentFileEntry(
            driveId: driveId,
            filename: "stale.bin",
            size: 0,
            status: .syncing,
            timestamp: Date().addingTimeInterval(-600),
            updatedAt: Date().addingTimeInterval(-600)
        )
        tracker.upsert(stale)

        tracker.sweepStuckTransfers(olderThan: 60)

        let entries = tracker.entries(forDrive: driveId)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].status, .error)
        XCTAssertEqual(entries[0].errorMessage, "timeout")
    }

    /// Recent (still-fresh) syncing entries must NOT be touched by the sweep.
    func testSweepStuckTransfersIgnoresFreshEntries() {
        let fresh = RecentFileEntry(
            driveId: driveId,
            filename: "fresh.bin",
            size: 0,
            status: .syncing,
            timestamp: Date(),
            updatedAt: Date()
        )
        tracker.upsert(fresh)

        tracker.sweepStuckTransfers(olderThan: 60)

        let entries = tracker.entries(forDrive: driveId)
        XCTAssertEqual(entries[0].status, .syncing)
    }

    // MARK: - Startup purge (Gap 14)

    /// On extension startup, any `.syncing` entries left over from a previous
    /// session are auto-failed with `"interrupted"`.
    func testPurgeOnStartupFailsLeftoverSyncingEntries() {
        tracker.upsert(RecentFileEntry(
            driveId: driveId,
            filename: "leftover.bin",
            size: 0,
            status: .syncing,
            timestamp: Date()
        ))

        tracker.purgeOnStartup()

        let entries = tracker.entries(forDrive: driveId)
        XCTAssertEqual(entries[0].status, .error)
        XCTAssertEqual(entries[0].errorMessage, "interrupted")
    }

    // MARK: - clearAll (Gap 14)

    func testClearAllEmptiesEverything() {
        for index in 0 ..< 3 {
            tracker.upsert(RecentFileEntry(
                driveId: driveId,
                filename: "file\(index).txt",
                size: 0,
                status: .completed,
                timestamp: Date()
            ))
        }
        XCTAssertEqual(tracker.recentEntries.count, 3)

        tracker.clearAll()

        XCTAssertTrue(tracker.recentEntries.isEmpty)
        XCTAssertTrue(tracker.entries(forDrive: driveId).isEmpty)
    }

    // MARK: - recentEntries sort order

    func testRecentEntriesSortedByUpdatedAtDescending() {
        let oldest = RecentFileEntry(
            driveId: driveId,
            filename: "oldest.txt",
            size: 0,
            status: .completed,
            timestamp: Date().addingTimeInterval(-30),
            updatedAt: Date().addingTimeInterval(-30)
        )
        let newest = RecentFileEntry(
            driveId: driveId,
            filename: "newest.txt",
            size: 0,
            status: .completed,
            timestamp: Date(),
            updatedAt: Date()
        )

        tracker.upsert(oldest)
        tracker.upsert(newest)

        let entries = tracker.recentEntries
        XCTAssertEqual(entries.first?.filename, "newest.txt")
        XCTAssertEqual(entries.last?.filename, "oldest.txt")
    }

    // MARK: - Concurrency

    /// Concurrent upserts from multiple tasks must not crash and must converge
    /// to a stable state guarded by the internal lock.
    func testConcurrentUpsertsAreSerialized() {
        let iterations = 200
        let group = DispatchGroup()
        let tracker = self.tracker!
        let driveId = self.driveId

        for index in 0 ..< iterations {
            group.enter()
            DispatchQueue.global().async {
                tracker.upsert(RecentFileEntry(
                    driveId: driveId,
                    filename: "file\(index % 5).txt",
                    size: Int64(index),
                    status: .syncing,
                    timestamp: Date()
                ))
                group.leave()
            }
        }

        group.wait()

        // 5 distinct filenames -> 5 deduped entries
        XCTAssertEqual(tracker.entries(forDrive: driveId).count, 5)
    }
}
