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
}
